import SwiftUI

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
    private let service: any RemoteFileService
    private let makeClient: @Sendable () throws -> SFTPClient
    private var flags: [UUID: CancelFlag] = [:]

    init(endpoint: RemoteEndpoint, service: (any RemoteFileService)? = nil,
         makeClient: (@Sendable () throws -> SFTPClient)? = nil, queue: TransferQueue = .shared) {
        self.endpoint = endpoint
        self.queue = queue
        self.service = service ?? (try? SFTPClient(endpoint: endpoint)) ?? FallbackRemoteService()
        // One SFTP channel per background operation, multiplexed over the tab's SSH connection.
        self.makeClient = makeClient ?? { try SFTPClient(endpoint: endpoint) }
    }

    func load(path: String) async {
        currentPath = path
        isLoading = true
        errorMessage = nil

        let svc = self.service
        let hidden = self.showHidden

        do {
            let items = try await Task.detached {
                let listed = try svc.list(path)
                return listed.filter { item in
                    hidden || !item.name.hasPrefix(".")
                }.sorted {
                    if $0.attributes.directory != $1.attributes.directory {
                        return $0.attributes.directory
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }.value

            if !Task.isCancelled {
                self.entries = items
                self.isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
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
        for url in urls {
            let total = await Task.detached { SFTPTransfer.size(of: url) }.value
            let id = queue.enqueueUpload(localURL: url, remotePath: remoteJoin(folder, url.lastPathComponent), totalBytes: total)
            await transfer(id) { client, meter, flag in
                let transfer = SFTPTransfer(client: client, progress: meter.add, isCancelled: { flag.isSet })
                try transfer.upload(url, to: try transfer.destination(for: url.lastPathComponent, in: folder))
            }
        }
        await load(path: currentPath)
    }

    func download(_ names: [String], from folder: String, to local: URL) async {
        for name in names {
            let remote = remoteJoin(folder, name)
            let target = LocalFiles.destination(for: name, in: local)
            let total = (try? await withClient { try SFTPTransfer(client: $0).size(of: remote) }) ?? 0
            let id = queue.enqueueDownload(remotePath: remote, localURL: target, totalBytes: total)
            await transfer(id) { client, meter, flag in
                try SFTPTransfer(client: client, progress: meter.add, isCancelled: { flag.isSet }).download(remote, to: target)
            }
        }
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
        do {
            try await withClient { client in
                let transfer = SFTPTransfer(client: client)
                for name in names { try transfer.remove(remoteJoin(folder, name)) }
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
        return try await Task.detached { try body(try make()) }.value
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
    @StateObject private var selection = ListSelection<String>()
    @StateObject private var filter = ExplorerFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocationBar(path: currentPath, history: $history, home: nil, showHidden: $viewModel.showHidden,
                        go: { currentPath = $0 },
                        reload: { Task { await viewModel.load(path: currentPath) } }) {
                Text(viewModel.endpoint.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Remote host\nFiles here are on \(viewModel.endpoint.label), the host this tab's shell is connected to.")
                FileActionsMenu(actions: actions)
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
                    .help("Retry\nList this remote folder again.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleEntries, selection: $selection.ids) { entry in
                    HStack {
                        Label(entry.name, systemImage: entry.attributes.directory ? "folder" : "doc")
                            .opacity(entry.name.hasPrefix(".") ? 0.6 : 1)

                        Spacer()

                        if !entry.attributes.directory, let size = entry.attributes.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(entry.id)
                    .help(entry.attributes.directory ? "Remote folder\nDouble-click or press Return to open it."
                                                     : "Remote file\nSelect it and choose Download from File Actions to copy it to this Mac.")
                }
                .contextMenu(forSelectionType: String.self) { names in
                    if let entry = entry(named: names.first) {
                        if entry.attributes.directory {
                            Button("Open") { open(entry) }
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
                TransfersStrip(queue: viewModel.queue, cancel: viewModel.cancelTransfer)
            }
        }
        .onChange(of: currentPath) { history.visit(currentPath); filter.close() }
        .onChange(of: viewModel.showHidden) { Task { await viewModel.load(path: currentPath) } }
        .onChange(of: findRequest) { filter.active = true }
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

    private func entry(named name: String?) -> RemoteEntry? {
        viewModel.entries.first { $0.name == name }
    }

    private func open(_ entry: RemoteEntry) {
        guard entry.attributes.directory else { return }
        let target = remoteJoin(currentPath, entry.name)
        history.visit(target)
        currentPath = target
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
        FileClipboard.shared.writeRemote(names.map { remoteJoin(currentPath, $0) }, on: viewModel.endpoint, cut: cut)
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
