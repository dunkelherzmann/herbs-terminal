import Foundation

/// A remote explorer's listing and file actions over SFTP, through the tab's shared SSH connection, or over a root
/// SFTP session in Administrator mode.
@MainActor
final class RemoteExplorerModel {
    private(set) var entries: [RemoteEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var showHidden = false
    private(set) var currentPath = "/"
    let changed = ObjectChange()
    /// Shown in an alert; file actions report failures here instead of replacing the listing.
    var onAlert: ((String) -> Void)?
    private(set) var undoMoves: [[RemoteMove]] = []
    private(set) var redoMoves: [[RemoteMove]] = []

    let endpoint: RemoteEndpoint
    let queue: TransferQueue
    private var service: any RemoteFileService
    private let makeClient: @Sendable () throws -> SFTPClient
    private var flags: [UUID: CancelFlag] = [:]
    private var retries: [UUID: () async -> Void] = [:]
    /// Administrator mode: every listing and action uses this one root session, one at a time.
    private let shared: SFTPClient?
    private let sharedLock = NSLock()
    private var loadGeneration = 0
    var isAdministrator: Bool { shared != nil }
    /// Where account names are looked up for Get Info's owner and group.
    let accountsOn: PrivilegedAccess.Target

    init(endpoint: RemoteEndpoint, queue: TransferQueue = .shared) {
        self.endpoint = endpoint
        self.queue = queue
        shared = nil
        accountsOn = .remote(endpoint)
        service = (try? SFTPClient(endpoint: endpoint)) ?? FallbackRemoteService()
        makeClient = { try SFTPClient(endpoint: endpoint) }
    }

    /// An explorer over a root SFTP session started through sudo (see `PrivilegedAccess`).
    init(administrator client: SFTPClient, endpoint: RemoteEndpoint, target: PrivilegedAccess.Target, queue: TransferQueue = .shared) {
        self.endpoint = endpoint
        self.queue = queue
        accountsOn = target
        shared = client
        service = client
        makeClient = { client }
    }

    private func alert(_ message: String) { onAlert?(message) }

    func load(path: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        currentPath = path
        isLoading = true
        errorMessage = nil
        changed.send()
        let svc = service, hidden = showHidden, lock = shared == nil ? nil : sharedLock
        do {
            let items = try await Task.detached { () -> [RemoteEntry] in
                func work() throws -> [RemoteEntry] {
                    // Links list with their own attributes; follow them, as Thunar does, so a link to a folder shows
                    // and opens as a folder. A dangling link stays as it is.
                    let listed = try svc.list(path).map { entry in
                        guard entry.attributes.link, let target = try? svc.stat(remoteJoin(path, entry.name), follow: true) else { return entry }
                        return RemoteEntry(name: entry.name, attributes: target)
                    }
                    return listed.filter { hidden || !$0.name.hasPrefix(".") }.sorted {
                        if $0.attributes.directory != $1.attributes.directory { return $0.attributes.directory }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                }
                if let lock { return try lock.withLock(work) }
                return try work()
            }.value
            if generation == loadGeneration { entries = items; isLoading = false; changed.send() }
        } catch {
            if generation == loadGeneration { errorMessage = error.localizedDescription; isLoading = false; changed.send() }
            // A broken or timed-out channel stays broken: open a fresh one, so Reload works again.
            if shared == nil, !(error is SFTPStatus), let fresh = try? await Task.detached(operation: { [makeClient] in try makeClient() }).value {
                service = fresh
            }
        }
    }

    // MARK: Transfers

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

    /// Runs a failed or cancelled transfer again from the start, as a new queue item.
    func retryTransfer(_ id: UUID) async {
        guard let again = retries.removeValue(forKey: id) else { return }
        queue.items.removeAll { $0.id == id }
        await again()
    }

    func canRetry(_ id: UUID) -> Bool { retries[id] != nil }

    func cancelTransfer(_ id: UUID) {
        flags[id]?.cancel()
        queue.cancel(id: id)
    }

    // MARK: File actions

    func newFolder(named name: String, in folder: String) async {
        do {
            try await withClient { client in
                try validateFileName(name)
                try client.mkdir(try SFTPTransfer(client: client).destination(for: name, in: folder))
            }
        } catch { alert(error.localizedDescription) }
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
            alert(error.localizedDescription)
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

    /// Downloads one copied item when a file manager pastes it, over its own SFTP channel.
    nonisolated var clipboardFetcher: @Sendable (String, URL) throws -> Void {
        let make = makeClient, lock = shared == nil ? nil : sharedLock
        return { path, target in
            func download() throws { try SFTPTransfer(client: try make()).download(path, to: target) }
            if let lock { try lock.withLock(download) } else { try download() }
        }
    }

    /// Get Info for items in `folder`: their permissions and owners, changed over SFTP.
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
            })
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
        } catch { alert(error.localizedDescription) }
        await load(path: currentPath)
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
            alert(error.localizedDescription)
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
            alert(error.localizedDescription)
        }
        await load(path: currentPath)
    }

    func undo() async {
        guard let moves = undoMoves.popLast() else { return }
        if let back = await revert(moves) { redoMoves.append(back) } else { undoMoves.append(moves) }
        changed.send()
    }

    func redo() async {
        guard let moves = redoMoves.popLast() else { return }
        if let back = await revert(moves) { undoMoves.append(back) } else { redoMoves.append(moves) }
        changed.send()
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
            alert(error.localizedDescription)
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
