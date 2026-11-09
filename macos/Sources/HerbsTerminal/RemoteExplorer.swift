import SwiftUI
import HerbsTerminalUI

@MainActor
final class RemoteExplorerViewModel: ObservableObject {
    @Published var entries: [RemoteEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var showHidden = false
    @Published var currentPath: String = "/"

    /// Shown in an alert; file actions report failures here instead of replacing the listing.
    @Published var alert: String?
    @Published private(set) var undoMoves: [[RemoteMove]] = []
    @Published private(set) var redoMoves: [[RemoteMove]] = []

    let endpoint: RemoteEndpoint
    let queue: TransferQueue
    /// The channel listings use; replaced with a fresh one when it breaks or times out.
    private var service: any RemoteFileService
    private let makeClient: @Sendable () throws -> SFTPClient
    private var flags: [UUID: CancelFlag] = [:]
    private var retries: [UUID: () async -> Void] = [:]

    /// Administrator mode: every listing and action uses this one root session, one at a time.
    private let shared: SFTPClient?
    /// Guards the channel listings share: one SFTP channel answers one request at a time.
    private let sharedLock = NSLock()
    /// Counts listings so one that finishes after a newer one started is dropped.
    private var loadGeneration = 0
    var isAdministrator: Bool { shared != nil }
    /// Where account names are looked up for Get Info's owner and group: the host itself, or this Mac for
    /// Administrator mode here.
    let accountsOn: PrivilegedAccess.Target

    init(endpoint: RemoteEndpoint, service: (any RemoteFileService)? = nil,
         makeClient: (@Sendable () throws -> SFTPClient)? = nil, queue: TransferQueue = .shared) {
        self.endpoint = endpoint
        self.queue = queue
        self.shared = nil
        self.accountsOn = .remote(endpoint)
        self.service = service ?? (try? SFTPClient(endpoint: endpoint)) ?? FallbackRemoteService()
        // One SFTP channel per background operation, multiplexed over the tab's SSH connection.
        self.makeClient = makeClient ?? { try SFTPClient(endpoint: endpoint) }
    }

    /// An explorer over a root SFTP session started through sudo (see `PrivilegedAccess`).
    init(administrator client: SFTPClient, endpoint: RemoteEndpoint, target: PrivilegedAccess.Target = .local, queue: TransferQueue = .shared) {
        self.endpoint = endpoint
        self.queue = queue
        self.accountsOn = target
        self.shared = client
        self.service = client
        self.makeClient = { client }
    }

    func load(path: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        currentPath = path
        isLoading = true
        errorMessage = nil

        let svc = self.service
        let hidden = self.showHidden
        let lock = sharedLock

        do {
            let items = try await Task.detached {
                try serialized(lock) {
                    // Symbolic links list with the link's own attributes; follow them, as Thunar does, so a
                    // link to a folder shows and opens as a folder. A dangling link stays as it is.
                    let listed = try svc.list(path).map { entry in
                        guard entry.attributes.link, let target = try? svc.stat(remoteJoin(path, entry.name), follow: true) else { return entry }
                        return RemoteEntry(name: entry.name, attributes: target)
                    }
                    return listed.filter { item in
                        hidden || !item.name.hasPrefix(".")
                    }.sorted {
                        if $0.attributes.directory != $1.attributes.directory {
                            return $0.attributes.directory
                        }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                }
            }.value

            if !Task.isCancelled, generation == loadGeneration {
                self.entries = items
                self.isLoading = false
            }
        } catch {
            if !Task.isCancelled, generation == loadGeneration {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            // A broken or timed-out channel stays broken: open a fresh one, so Reload works again. A status
            // from the server (no permission, no such folder) means the channel itself is fine.
            if shared == nil, !(error is SFTPStatus), let fresh = try? await Task.detached(operation: { [makeClient] in try makeClient() }).value {
                service = fresh
            }
        }
    }

    func createFolder(name: String, in path: String) throws {
        try validateFileName(name)
        try service.mkdir(remoteJoin(path, name))
    }

    func delete(entry: RemoteEntry, in path: String) throws {
        try service.remove(remoteJoin(path, entry.name), directory: entry.attributes.directory)
    }

    func rename(entry: RemoteEntry, newName: String, in path: String) throws {
        try validateFileName(newName)
        try service.rename(remoteJoin(path, entry.name), remoteJoin(path, newName), replace: false)
    }

    // MARK: Transfers and file actions

    func upload(_ urls: [URL], into folder: String) async {
        for url in urls { await uploadOne(url, into: folder) }
        await load(path: currentPath)
    }

    private func uploadOne(_ url: URL, into folder: String) async {
        let total = await Task.detached { SFTPTransfer.size(of: url) }.value
        let id = queue.enqueueUpload(localURL: url, remotePath: remoteJoin(folder, url.lastPathComponent), totalBytes: total)
        retries[id] = { [weak self] in await self?.uploadOne(url, into: folder); await self?.load(path: self?.currentPath ?? folder) }
        await transfer(id) { client, meter, flag in
            let transfer = SFTPTransfer(client: client, progress: meter.add, isCancelled: { flag.isSet })
            try transfer.upload(url, to: try transfer.destination(for: url.lastPathComponent, in: folder))
        }
    }

    func download(_ names: [String], from folder: String, to local: URL) async {
        for name in names { await downloadOne(name, from: folder, to: local) }
    }

    private func downloadOne(_ name: String, from folder: String, to local: URL) async {
        let remote = remoteJoin(folder, name)
        let target = LocalFiles.destination(for: name, in: local)
        let total = (try? await withClient { try SFTPTransfer(client: $0).size(of: remote) }) ?? 0
        let id = queue.enqueueDownload(remotePath: remote, localURL: target, totalBytes: total)
        retries[id] = { [weak self] in await self?.downloadOne(name, from: folder, to: local) }
        await transfer(id) { client, meter, flag in
            try SFTPTransfer(client: client, progress: meter.add, isCancelled: { flag.isSet }).download(remote, to: target)
        }
    }

    /// Runs a failed or cancelled transfer again from the start, as a new queue item. Uploads are staged
    /// under a temporary name, so nothing partial from the first attempt is left in place.
    func retryTransfer(_ id: UUID) async {
        guard let again = retries.removeValue(forKey: id) else { return }
        queue.items.removeAll { $0.id == id }
        await again()
    }

    func canRetry(_ id: UUID) -> Bool { retries[id] != nil }

    func newFolder(named name: String, in folder: String) async {
        do {
            try await withClient { client in
                let transfer = SFTPTransfer(client: client)
                try validateFileName(name)
                try client.mkdir(try transfer.destination(for: name, in: folder))
            }
        } catch { alert = error.localizedDescription }
        await load(path: currentPath)
    }

    /// New File: an empty file under a free name; returns its path so it can open in the text editor.
    func newFile(named name: String, in folder: String) async -> String? {
        defer { Task { await load(path: currentPath) } }
        do {
            return try await withClient { client in
                try validateFileName(name)
                let path = try SFTPTransfer(client: client).destination(for: name, in: folder)
                try client.close(try client.open(path, flags: SFTPTransfer.write | SFTPTransfer.create | SFTPTransfer.exclusive, mode: 0o644))
                return path
            }
        } catch {
            alert = error.localizedDescription
            return nil
        }
    }

    /// The text editor's access to a remote file, through this explorer's connection (root in Administrator mode).
    func textSource(for path: String) -> TextFileSource {
        TextFileSource(
            name: (path as NSString).lastPathComponent,
            location: "\(endpoint.label):\(path)" + (isAdministrator ? " (root)" : ""),
            read: { [weak self] in
                guard let self else { throw FileIssue("The explorer for this file was closed.") }
                return try await self.withClient { try SFTPTransfer(client: $0).readAll(path, limit: TextCodec.sizeLimit) }
            },
            version: { [weak self] in
                guard let self else { return nil }
                let attributes = try await self.withClient { try $0.stat(path, follow: true) }
                return TextFileSource.Version(size: attributes.size, modified: attributes.modified.map(Double.init))
            },
            write: { [weak self] data in
                guard let self else { throw FileIssue("The explorer for this file was closed; reopen the file to save it.") }
                try await self.withClient { try SFTPTransfer(client: $0).replace(path, with: data) }
                await self.load(path: self.currentPath)
            })
    }

    /// Downloads one copied item when Finder or the local explorer pastes it. It runs on the main thread while
    /// the paste waits, over its own SFTP channel (the root session, one request at a time, in Administrator mode).
    nonisolated var clipboardFetcher: @Sendable (String, URL) throws -> Void {
        let make = makeClient, lock = shared == nil ? nil : sharedLock
        return { path, target in
            func download() throws { try SFTPTransfer(client: try make()).download(path, to: target) }
            if let lock { try lock.withLock(download) } else { try download() }
        }
    }

    /// Get Info for items in `folder`: their permissions and owners, changed over SFTP (as root in Administrator mode).
    func infoSource(for names: [String], in folder: String) -> FileInfoSource {
        let accounts = accountsOn
        return FileInfoSource(
            title: names.count == 1 ? names[0] : "\(names.count) items",
            load: { [weak self] in
                guard let self else { return [] }
                return try await self.withClient { client in
                    // A listing carries owner and group names; stat alone only has the numbers.
                    let listed = Dictionary((try? client.list(folder))?.map { ($0.name, $0.attributes) } ?? [], uniquingKeysWith: { a, _ in a })
                    return try names.map { name in
                        let own = try client.stat(remoteJoin(folder, name), follow: false)
                        let attributes = own.link ? ((try? client.stat(remoteJoin(folder, name), follow: true)) ?? own) : own
                        return FileInfo(name: name, location: folder, isFolder: attributes.directory, isLink: own.link,
                                        size: attributes.size, modified: attributes.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                        mode: (attributes.mode ?? 0) & 0o7777,
                                        owner: listed[name]?.owner ?? attributes.uid.map(String.init) ?? "",
                                        group: listed[name]?.group ?? attributes.gid.map(String.init) ?? "")
                    }
                }
            },
            apply: { [weak self] change in
                guard let self else { return }
                // Names become numbers before the SFTP work starts.
                let ids: (UInt32?, UInt32?) = try await Task.detached {
                    func lookup(_ name: String?, group: Bool) throws -> UInt32? {
                        guard let name else { return nil }
                        switch accounts {
                        case .local: return group ? try Accounts.localGroup(name) : try Accounts.localUser(name)
                        case .remote(let endpoint): return try Accounts.remote(name, group: group, on: endpoint)
                        }
                    }
                    return (try lookup(change.owner, group: false), try lookup(change.group, group: true))
                }.value
                try await self.withClient { client in
                    for name in names { try Self.apply(change, uid: ids.0, gid: ids.1, to: remoteJoin(folder, name), top: true, client: client) }
                }
                await self.load(path: self.currentPath)
            },
            hasMacFlags: false)
    }

    nonisolated private static func apply(_ change: FileInfoChange, uid: UInt32?, gid: UInt32?, to path: String, top: Bool, client: SFTPClient) throws {
        let own = try client.stat(path, follow: false)
        // Inside a folder, links are skipped: SFTP would change whatever they point at.
        if !top, own.link { return }
        let attributes = own.link ? try client.stat(path, follow: true) : own
        if let mode = change.mode { try client.permissions(path, (attributes.directory && !top) ? folderMode(mode) : mode) }
        if uid != nil || gid != nil {
            guard let newUID = uid ?? attributes.uid, let newGID = gid ?? attributes.gid else {
                throw FileIssue("The server didn't report who owns “\((path as NSString).lastPathComponent)”.")
            }
            do { try client.owner(path, uid: newUID, gid: newGID) }
            catch let status as SFTPStatus where status.code == 3 {
                throw FileIssue("Only root can give “\((path as NSString).lastPathComponent)” to another owner. Turn on Administrator mode (the lock) and try again.")
            }
        }
        if change.recursive, attributes.directory, !own.link {
            for entry in try client.list(path) {
                try apply(change, uid: uid, gid: gid, to: remoteJoin(path, entry.name), top: false, client: client)
            }
        }
    }

    /// Rename on the host; undoable like a move.
    func rename(_ name: String, to newName: String, in folder: String) async {
        do {
            try validateFileName(newName)
            let from = remoteJoin(folder, name), to = remoteJoin(folder, newName)
            try await withClient { client in
                guard try client.existing(to) == nil else { throw FileIssue("An item named “\(newName)” already exists here.") }
                try client.rename(from, to)
            }
            undoMoves.append([RemoteMove(from: from, to: to)])
            redoMoves.removeAll()
        } catch { alert = error.localizedDescription }
        await load(path: currentPath)
    }

    func cancelTransfer(_ id: UUID) {
        flags[id]?.cancel()
        queue.cancel(id: id)
    }

    /// Paste of remote items: cut ones are renamed into `folder` (undoable), copied ones duplicated there.
    func paste(_ paths: [String], cut: Bool, into folder: String) async {
        do {
            if cut {
                let moves = try await withClient { client in
                    let transfer = SFTPTransfer(client: client)
                    var moves: [RemoteMove] = []
                    for path in paths where parentPath(path) != normalizePath(folder) {
                        guard !normalizePath(folder).hasPrefix(normalizePath(path) + "/") else {
                            throw FileIssue("“\((path as NSString).lastPathComponent)” can't be moved into itself.")
                        }
                        let target = try transfer.destination(for: (path as NSString).lastPathComponent, in: folder)
                        try client.rename(path, target)
                        moves.append(RemoteMove(from: path, to: target))
                    }
                    return moves
                }
                if !moves.isEmpty { undoMoves.append(moves); redoMoves.removeAll() }
            } else {
                try await withClient { client in
                    let transfer = SFTPTransfer(client: client)
                    for path in paths {
                        let source = normalizePath(path), target = normalizePath(folder)
                        guard target != source, !target.hasPrefix(source + "/") else {
                            throw FileIssue("“\((path as NSString).lastPathComponent)” can't be copied into itself.")
                        }
                        try transfer.copy(path, to: try transfer.destination(for: (path as NSString).lastPathComponent, in: folder))
                    }
                }
            }
        } catch {
            alert = error.localizedDescription
        }
        await load(path: currentPath)
    }

    /// Permanently deletes remote items, folders included. The view confirms first: this can't be undone.
    func delete(_ names: [String], in folder: String) async {
        let asRoot = isAdministrator
        do {
            try await withClient { client in
                let transfer = SFTPTransfer(client: client)
                for name in names { try transfer.remove(remoteJoin(folder, name), asRoot: asRoot) }
            }
        } catch {
            alert = error.localizedDescription
        }
        await load(path: currentPath)
    }

    func undo() async {
        guard let moves = undoMoves.popLast() else { return }
        if let back = await revert(moves) { redoMoves.append(back) } else { undoMoves.append(moves) }
    }

    func redo() async {
        guard let moves = redoMoves.popLast() else { return }
        if let back = await revert(moves) { undoMoves.append(back) } else { redoMoves.append(moves) }
    }

    private func revert(_ moves: [RemoteMove]) async -> [RemoteMove]? {
        defer { Task { await load(path: currentPath) } }
        do {
            return try await withClient { client in
                var back: [RemoteMove] = []
                for move in moves.reversed() {
                    guard try client.existing(move.from) == nil else {
                        throw FileIssue("“\((move.from as NSString).lastPathComponent)” already exists, so it can't be put back.")
                    }
                    try client.rename(move.to, move.from)
                    back.append(RemoteMove(from: move.to, to: move.from))
                }
                return back
            }
        } catch {
            alert = error.localizedDescription
            return nil
        }
    }

    private func withClient<T: Sendable>(_ body: @escaping @Sendable (SFTPClient) throws -> T) async throws -> T {
        let make = makeClient
        let lock = shared == nil ? nil : sharedLock
        return try await Task.detached {
            if let lock { return try lock.withLock { try body(try make()) } }
            return try body(try make())
        }.value
    }

    private func transfer(_ id: UUID, _ body: @escaping @Sendable (SFTPClient, ProgressMeter, CancelFlag) throws -> Void) async {
        let flag = CancelFlag()
        flags[id] = flag
        let queue = self.queue
        let meter = ProgressMeter { done in Task { @MainActor in queue.updateProgress(id: id, bytesTransferred: done) } }
        queue.updateProgress(id: id, bytesTransferred: 0)
        do {
            try await withClient { try body($0, meter, flag) }
            queue.markCompleted(id: id)
        } catch {
            if flag.isSet { queue.cancel(id: id) } else { queue.markFailed(id: id, message: error.localizedDescription) }
        }
        flags[id] = nil
    }
}

struct RemoteMove: Equatable, Sendable {
    let from: String
    let to: String
}

private final class FallbackRemoteService: RemoteFileService, @unchecked Sendable {
    func list(_ path: String) throws -> [RemoteEntry] { throw FileIssue("Remote session is disconnected.") }
    func mkdir(_ path: String) throws { throw FileIssue("Remote session is disconnected.") }
    func remove(_ path: String, directory: Bool) throws { throw FileIssue("Remote session is disconnected.") }
    func rename(_ old: String, _ new: String, replace: Bool) throws { throw FileIssue("Remote session is disconnected.") }
    func stat(_ path: String, follow: Bool) throws -> RemoteAttributes { throw FileIssue("Remote session is disconnected.") }
}

struct RemoteExplorer: View {
    @Binding var currentPath: String
    @Binding var history: NavigationHistory
    @ObservedObject var viewModel: RemoteExplorerViewModel
    var findRequest = 0
    var localFolder: URL = FileManager.default.homeDirectoryForCurrentUser
    var home = "/"
    /// The Places side pane's width; 0 hides it when the pane is too narrow, so nothing is clipped.
    var sidebarWidth: CGFloat = 170
    /// Turns Administrator mode on or off; nil hides the lock button.
    var administratorToggle: (() -> Void)?
    var isAdministrator = false
    /// The tab whose feature-test bridge this explorer answers.
    var bridgeHost: WindowState?
    @StateObject private var selection = ListSelection<String>()
    @StateObject private var filter = ExplorerFilter()
    @AppStorage("remoteExplorerBookmarks") private var bookmarkStore = ""

    private var bookmarks: BookmarkList {
        BookmarkList(raw: bookmarkStore, scope: "\(viewModel.endpoint.label):\(viewModel.endpoint.port)")
    }

    var body: some View {
      HStack(spacing: 0) {
        if sidebarWidth > 0 {
        PlacesSidebar(sections: [
            PlacesSection(title: viewModel.endpoint.label, places: [
                Place(name: "Home", symbol: "house", path: home),
                Place(name: "File System", symbol: "internaldrive", path: "/"),
            ]),
            PlacesSection(title: "Bookmarks", places: bookmarks.paths.map {
                Place(name: ($0 as NSString).lastPathComponent.isEmpty ? "/" : ($0 as NSString).lastPathComponent, symbol: "folder", path: $0)
            }, removable: true),
        ], current: normalizePath(currentPath), open: navigate, remove: toggleBookmark, width: sidebarWidth)
        Divider()
        }
        VStack(alignment: .leading, spacing: 0) {
            LocationBar(path: currentPath, history: $history, home: home, showHidden: $viewModel.showHidden,
                        go: { currentPath = $0 },
                        reload: { Task { await viewModel.load(path: currentPath) } }) {
                Button { toggleBookmark(history.current) } label: {
                    Label("Bookmark", systemImage: bookmarks.contains(normalizePath(currentPath)) ? "bookmark.fill" : "bookmark")
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .accessibilityValue(bookmarks.contains(normalizePath(currentPath)) ? "On" : "Off")
                .hint(bookmarks.contains(normalizePath(currentPath)) ? "Remove Bookmark (⌥⌘D)\nTake this folder out of the side pane's Bookmarks."
                                                                     : "Bookmark This Folder (⌥⌘D)\nAdd it to this host's Bookmarks in the side pane.")
                if let administratorToggle {
                    Button(action: administratorToggle) {
                        Label("Administrator mode", systemImage: isAdministrator ? "lock.open.fill" : "lock")
                            .foregroundStyle(isAdministrator ? Color.red : Color.primary)
                    }
                    .accessibilityValue(isAdministrator ? "On" : "Off")
                    .hint(isAdministrator ? "Leave Administrator Mode\nGo back to working with your own account's access."
                                          : "Administrator Mode\nWork as root with sudo: open and change any file. Asks for the sudo password.")
                }
                FileActionsMenu(actions: actions)
                    .hint("File Actions\nUpload, download, undo, cut, copy, paste, delete, select all and find.")
            }

            Divider()
            if filter.active { FilterBar(filter: filter); Divider() }

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 8) {
                    Text(error).foregroundColor(.red).padding()
                    Button("Retry") {
                        Task { await viewModel.load(path: currentPath) }
                    }
                    .hint("Retry\nList this remote folder again.")
                    if !isAdministrator, let administratorToggle, isPermissionError(error) {
                        Button("Open with Administrator Mode…", action: administratorToggle)
                            .hint("Administrator Mode\nOpen this folder as root with sudo on the host.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleEntries, selection: $selection.ids) { entry in
                    FileRow(name: entry.name, isFolder: entry.attributes.directory, size: entry.attributes.size.map(Int64.init))
                    .tag(entry.id)
                    .hint(entry.attributes.directory ? "Remote folder\nDouble-click or press Return to open it."
                                                     : "Remote file\nDouble-click to edit a text file here; Download from File Actions copies any file to this Mac.")
                }
                .contextMenu(forSelectionType: String.self) { names in
                    if names.isEmpty {
                        Button("New Folder…") { newFolder() }
                        Button("New File…") { newFile() }
                        Button("Paste") { paste() }
                    }
                    if names.count == 1, let name = names.first {
                        Button("Rename…") { rename(name) }
                    }
                    if let entry = entry(named: names.first) {
                        if entry.attributes.directory {
                            Button("Open") { open(entry) }
                        } else {
                            Button("Open in Text Editor") {
                                names.compactMap { self.entry(named: $0) }.filter { !$0.attributes.directory }.forEach(edit)
                            }
                        }
                        Button("Get Info…") {
                            FileInfoWindow.show(viewModel.infoSource(for: Array(names), in: currentPath))
                        }
                        Button("Download…") { download(Array(names)) }
                        Divider()
                        Button("Cut") { clip(Array(names), cut: true) }
                        Button("Copy") { clip(Array(names), cut: false) }
                        Button("Paste") { paste() }
                        Button("Delete…", role: .destructive) { delete(Array(names)) }
                    }
                } primaryAction: { names in
                    entry(named: names.first).map(open)
                }
                .fileCommands(actions) {
                    if let previous = history.goBack() { currentPath = previous }
                }
            }
            if !viewModel.queue.items.isEmpty {
                Divider()
                TransfersStrip(queue: viewModel.queue, cancel: viewModel.cancelTransfer,
                               retry: viewModel.canRetry) { id in Task { await viewModel.retryTransfer(id) } }
            }
        }
      }
        .onChange(of: currentPath) { history.visit(currentPath); filter.close() }
        .onChange(of: viewModel.showHidden) { Task { await viewModel.load(path: currentPath) } }
        .onChange(of: findRequest) { filter.active = true }
        .onAppear { bridgeHost?.explorerBridge = makeBridge() }
        .onDisappear { if bridgeHost?.explorerBridge?.owner == bridgeOwner { bridgeHost?.explorerBridge = nil } }
        .task(id: currentPath) {
            selection.ids = []
            await viewModel.load(path: currentPath)
        }
        .alert("File action failed", isPresented: Binding(get: { viewModel.alert != nil }, set: { if !$0 { viewModel.alert = nil } })) {
            Button("OK") { viewModel.alert = nil }
        } message: {
            Text(viewModel.alert ?? "")
        }
    }

    private var visibleEntries: [RemoteEntry] { viewModel.entries.filter { filter.matches($0.name) } }
    private var selectedNames: [String] { visibleEntries.map(\.name).filter(selection.ids.contains) }

    private var actions: FileActions {
        let hasSelection = !selection.ids.isEmpty
        return FileActions(
            upload: { upload() },
            download: hasSelection ? { download(selectedNames) } : nil,
            transferHelp: "Copy between this Mac and \(viewModel.endpoint.label). Progress shows under the file list.",
            undoTitle: viewModel.undoMoves.isEmpty ? "Undo" : "Undo Move",
            redoTitle: viewModel.redoMoves.isEmpty ? "Redo" : "Redo Move",
            undo: viewModel.undoMoves.isEmpty ? nil : { Task { await viewModel.undo() } },
            redo: viewModel.redoMoves.isEmpty ? nil : { Task { await viewModel.redo() } },
            cut: hasSelection ? { clip(selectedNames, cut: true) } : nil,
            copy: hasSelection ? { clip(selectedNames, cut: false) } : nil,
            paste: { paste() },
            delete: hasSelection ? { delete(selectedNames) } : nil,
            selectAll: { selection.ids = Set(visibleEntries.map(\.name)) },
            deleteHelp: "Permanently delete the selected items from the remote host, after confirming.",
            find: { filter.active = true })
    }

    private func navigate(to target: String) {
        history.visit(target)
        currentPath = target
    }

    private func toggleBookmark(_ path: String) {
        var list = bookmarks
        list.toggle(normalizePath(path))
        bookmarkStore = list.raw
    }

    private func entry(named name: String?) -> RemoteEntry? {
        viewModel.entries.first { $0.name == name }
    }

    private func open(_ entry: RemoteEntry) {
        guard entry.attributes.directory else {
            // Text opens in the editor; for files of an unknown type the editor checks the content itself.
            if TextCodec.isText(name: entry.name, sniff: { Data() }) { edit(entry) }
            return
        }
        let target = remoteJoin(currentPath, entry.name)
        history.visit(target)
        currentPath = target
    }

    private func newFolder() {
        guard let name = askForName(title: "New Folder", message: "Name for the new folder on \(viewModel.endpoint.label):",
                                    initial: "untitled folder") else { return }
        let folder = currentPath
        Task { await viewModel.newFolder(named: name, in: folder) }
    }

    private func edit(_ entry: RemoteEntry) {
        Workspace.openEditor(viewModel.textSource(for: remoteJoin(currentPath, entry.name)))
    }

    private func newFile() {
        guard let name = askForName(title: "New File", message: "Name for the new file on \(viewModel.endpoint.label):",
                                    initial: "untitled.txt") else { return }
        let folder = currentPath
        Task {
            if let path = await viewModel.newFile(named: name, in: folder) {
                Workspace.openEditor(viewModel.textSource(for: path))
            }
        }
    }

    private func rename(_ name: String) {
        guard let newName = askForName(title: "Rename", message: "New name for “\(name)”:", initial: name),
              newName != name else { return }
        let folder = currentPath
        Task { await viewModel.rename(name, to: newName, in: folder) }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(viewModel.endpoint.label)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = localFolder
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, folder = currentPath
        Task { await viewModel.upload(urls, into: folder) }
    }

    private func download(_ names: [String]) {
        guard !names.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Download from \(viewModel.endpoint.label)"
        panel.prompt = "Download Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let folder = currentPath
        Task { await viewModel.download(names, from: folder, to: target) }
    }

    private func clip(_ names: [String], cut: Bool) {
        FileClipboard.shared.writeRemote(names.map { remoteJoin(currentPath, $0) }, on: viewModel.endpoint, cut: cut,
                                         fetch: viewModel.clipboardFetcher)
    }

    /// Remote items paste as a move or copy on this host; Mac files copied in Finder or the local explorer upload.
    private func paste() {
        let folder = currentPath
        if let clip = FileClipboard.shared.readRemote(for: viewModel.endpoint) {
            if clip.cut { FileClipboard.shared.finishCut() }
            Task { await viewModel.paste(clip.paths, cut: clip.cut, into: folder) }
        } else {
            let urls = FileClipboard.shared.readLocal().urls
            guard !urls.isEmpty else { NSSound.beep(); return }
            Task { await viewModel.upload(urls, into: folder) }
        }
    }

    private func delete(_ names: [String]) {
        guard !names.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1 ? "Delete “\(names[0])” from \(viewModel.endpoint.label)?"
                                             : "Delete \(names.count) items from \(viewModel.endpoint.label)?"
        alert.informativeText = "Remote items are deleted permanently, folders with everything inside. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let folder = currentPath
        Task { await viewModel.delete(names, in: folder) }
    }
}

extension RemoteExplorer {
    /// Each host explorer's own key: Administrator mode's explorer appears before the user's one has gone.
    fileprivate var bridgeOwner: String { "remote-\(ObjectIdentifier(viewModel).hashValue)" }

    /// What the feature tests' bridge reads and runs, through the same code the menus and buttons use. Upload
    /// and Download take their files and folder from the bridge instead of the open panel.
    fileprivate func makeBridge() -> ExplorerBridge {
        let bridge = ExplorerBridge(owner: bridgeOwner)
        bridge.path = { currentPath }
        bridge.items = { visibleEntries.map { $0.attributes.directory ? $0.name + "/" : $0.name } }
        bridge.selected = { selectedNames }
        bridge.select = { names in selection.ids = Set(visibleEntries.map(\.name).filter { names.contains($0) || names.contains($0 + "/") }) }
        bridge.go = { navigate(to: $0) }
        bridge.setFilter = { filter.active = true; filter.text = $0 }
        bridge.upload = { paths in
            let folder = currentPath
            Task { await viewModel.upload(paths.map { URL(fileURLWithPath: $0) }, into: folder) }
        }
        bridge.download = { target in
            let names = selectedNames, folder = currentPath
            Task { await viewModel.download(names, from: folder, to: URL(fileURLWithPath: target, isDirectory: true)) }
        }
        bridge.extra = {
            ["hidden": viewModel.showHidden, "bookmarked": bookmarks.contains(normalizePath(currentPath)),
             "status": viewModel.errorMessage ?? (viewModel.isLoading ? "Loading…" : ""),
             "finding": filter.active, "filter": filter.text, "canUndo": !viewModel.undoMoves.isEmpty, "canRedo": !viewModel.redoMoves.isEmpty,
             "undoTitle": viewModel.undoMoves.isEmpty ? "Undo" : "Undo Move", "redoTitle": viewModel.redoMoves.isEmpty ? "Redo" : "Redo Move",
             "remote": true, "loading": viewModel.isLoading,
             "transfers": viewModel.queue.items.map { ["name": $0.name, "state": "\($0.state)"] as [String: Any] }]
        }
        bridge.command = { name, run in
            let actions = self.actions
            let names = selectedNames
            let entries = names.compactMap { self.entry(named: $0) }
            let one: String? = names.count == 1 ? names[0] : nil
            let commands: [String: (() -> Void)?] = [
                "cut": actions.cut, "copy": actions.copy, "paste": actions.paste, "delete": actions.delete,
                "select-all": actions.selectAll, "undo": actions.undo, "redo": actions.redo, "find": actions.find,
                "upload": actions.upload, "download": actions.download,
                "new-folder": { newFolder() }, "new-file": { newFile() },
                "open": entries.first.map { entry in { open(entry) } },
                "edit": entries.contains { !$0.attributes.directory } ? { entries.filter { !$0.attributes.directory }.forEach(edit) } : nil,
                "rename": one.map { name in { rename(name) } },
                "info": names.isEmpty ? nil : { FileInfoWindow.show(viewModel.infoSource(for: names, in: currentPath)) },
                "bookmark-selected": entries.count == 1 && entries[0].attributes.directory ? { toggleBookmark(remoteJoin(currentPath, entries[0].name)) } : nil,
                "hidden": { viewModel.showHidden.toggle() },
                "reload": { Task { await viewModel.load(path: currentPath) } },
            ]
            guard let entry = commands[name] else { return "missing" }
            guard let action = entry else { return "disabled" }
            if run { DispatchQueue.main.async { action() } }
            return run ? "ran" : "enabled"
        }
        return bridge
    }
}

/// Runs `body` holding `lock` when there is one (Administrator mode's single root session).
private func serialized<T>(_ lock: NSLock?, _ body: () throws -> T) rethrows -> T {
    guard let lock else { return try body() }
    return try lock.withLock(body)
}

/// "Permission denied" from the Mac or an SFTP server: the case Administrator mode solves.
func isPermissionError(_ message: String) -> Bool {
    let text = message.lowercased()
    return text.contains("permission") || text.contains("not permitted") || text.contains("sftp 3:")
}
