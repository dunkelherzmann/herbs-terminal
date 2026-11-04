import AppKit

/// A reversible change made by an explorer, kept for Undo / Redo.
enum FileChange: Equatable {
    case created([URL])
    case moved([Move])
    case trashed([Move])

    struct Move: Equatable {
        let from: URL
        let to: URL
    }

    var title: String {
        switch self {
        case .created: "Copy"
        case .moved: "Move"
        case .trashed: "Move to Trash"
        }
    }
}

/// Local file operations. Nothing is overwritten: clashes get Finder-style "name copy" names,
/// and Delete moves items to the Trash so Undo can bring them back.
enum LocalFiles {
    static func destination(for name: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard exists(candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for index in 1... {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let next = folder.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            if !exists(next) { return next }
        }
        fatalError("unreachable")
    }

    static func copy(_ items: [URL], into folder: URL) throws -> FileChange {
        var created: [URL] = []
        for item in items {
            let target = destination(for: item.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: item, to: target)
            created.append(target)
        }
        return .created(created)
    }

    static func move(_ items: [URL], into folder: URL) throws -> FileChange {
        var moves: [FileChange.Move] = []
        for item in items where item.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            guard !folder.standardizedFileURL.path.hasPrefix(item.standardizedFileURL.path + "/") else {
                throw FileIssue("“\(item.lastPathComponent)” can't be moved into itself.")
            }
            let target = destination(for: item.lastPathComponent, in: folder)
            try FileManager.default.moveItem(at: item, to: target)
            moves.append(.init(from: item, to: target))
        }
        return .moved(moves)
    }

    static func trash(_ items: [URL]) throws -> FileChange {
        var moves: [FileChange.Move] = []
        for item in items {
            var result: NSURL?
            try FileManager.default.trashItem(at: item, resultingItemURL: &result)
            moves.append(.init(from: item, to: (result as URL?) ?? item))
        }
        return .trashed(moves)
    }

    /// Performs the opposite of `change` and returns that opposite, so it can be undone in turn.
    static func revert(_ change: FileChange) throws -> FileChange {
        switch change {
        case .created(let urls):
            return try trash(urls)
        case .moved(let moves), .trashed(let moves):
            var back: [FileChange.Move] = []
            for move in moves.reversed() {
                guard !FileManager.default.fileExists(atPath: move.from.path) else {
                    throw FileIssue("“\(move.from.lastPathComponent)” already exists, so it can't be put back.")
                }
                try FileManager.default.moveItem(at: move.to, to: move.from)
                back.append(.init(from: move.to, to: move.from))
            }
            return .moved(back)
        }
    }
}

/// Undo / Redo stacks for one explorer pane. Each step keeps the name of the action the user took,
/// so undoing a Move to Trash offers "Redo Move to Trash" although putting it back is itself a move.
@MainActor
final class FileOperationLog: ObservableObject {
    struct Step {
        let change: FileChange
        let title: String
    }

    @Published private(set) var undoStack: [Step] = []
    @Published private(set) var redoStack: [Step] = []
    private let revert: (FileChange) throws -> FileChange

    init(revert: @escaping (FileChange) throws -> FileChange = LocalFiles.revert) { self.revert = revert }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.title)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.title)" } ?? "Redo" }

    func record(_ change: FileChange) {
        if case .created(let urls) = change, urls.isEmpty { return }
        if case .moved(let moves) = change, moves.isEmpty { return }
        undoStack.append(Step(change: change, title: change.title))
        redoStack.removeAll()
    }

    func undo() throws {
        guard let step = undoStack.popLast() else { return }
        do { redoStack.append(Step(change: try revert(step.change), title: step.title)) }
        catch { undoStack.append(step); throw error }
    }

    func redo() throws {
        guard let step = redoStack.popLast() else { return }
        do { undoStack.append(Step(change: try revert(step.change), title: step.title)) }
        catch { redoStack.append(step); throw error }
    }
}

/// Cut / Copy / Paste of files. Local items go on the general pasteboard as file URLs, so Finder can
/// paste them too; remote paths are kept here with the pasteboard change count that owns them.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()
    private let pasteboard: NSPasteboard
    private var cutCount: Int?
    private var remote: (endpoint: RemoteEndpoint, paths: [String], cut: Bool, count: Int)?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func writeLocal(_ urls: [URL], cut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutCount = cut ? pasteboard.changeCount : nil
        remote = nil
    }

    /// File URLs on the pasteboard, and whether they were cut here (so Paste moves them).
    func readLocal() -> (urls: [URL], cut: Bool) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, cutCount == pasteboard.changeCount)
    }

    func finishCut() { cutCount = nil; remote = nil }

    func writeRemote(_ paths: [String], on endpoint: RemoteEndpoint, cut: Bool) {
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        remote = (endpoint, paths, cut, pasteboard.changeCount)
        cutCount = nil
    }

    func readRemote(for endpoint: RemoteEndpoint) -> (paths: [String], cut: Bool)? {
        guard let remote, remote.count == pasteboard.changeCount, remote.endpoint == endpoint else { return nil }
        return (remote.paths, remote.cut)
    }

    var hasContent: Bool { remote?.count == pasteboard.changeCount || !readLocal().urls.isEmpty }
}

/// Streams files and folders over one SFTP channel. Uploads land under a temporary name and are
/// renamed into place, so an interrupted upload never leaves a half-written file under the real name.
struct SFTPTransfer {
    static let read: UInt32 = 0x01, write: UInt32 = 0x02, create: UInt32 = 0x08, truncate: UInt32 = 0x10
    let client: SFTPClient
    var progress: (Int64) -> Void = { _ in }
    var isCancelled: () -> Bool = { false }

    func upload(_ local: URL, to remote: String) throws {
        try checkCancelled()
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true && values.isSymbolicLink != true {
            try client.mkdir(remote)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, to: remoteJoin(remote, child.lastPathComponent))
            }
            return
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let part = remoteJoin(parentPath(remote), ".\((remote as NSString).lastPathComponent).herbsterminal-part")
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        let handle = try client.open(part, flags: Self.write | Self.create | Self.truncate, mode: mode)
        do {
            var offset: UInt64 = 0
            while let chunk = try source.read(upToCount: 32768), !chunk.isEmpty {
                try checkCancelled()
                try client.write(handle, offset: offset, bytes: chunk)
                offset += UInt64(chunk.count)
                progress(Int64(chunk.count))
            }
            try client.close(handle)
            try client.rename(part, remote)
        } catch {
            try? client.close(handle)
            try? client.remove(part)
            throw error
        }
    }

    func download(_ remote: String, to local: URL) throws {
        try checkCancelled()
        let attributes = try client.stat(remote, follow: true)
        if attributes.directory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            for entry in try client.list(remote) {
                try download(remoteJoin(remote, entry.name), to: local.appendingPathComponent(entry.name))
            }
            return
        }
        let part = local.deletingLastPathComponent().appendingPathComponent(".\(local.lastPathComponent).herbsterminal-part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        do {
            let target = try FileHandle(forWritingTo: part)
            defer { try? target.close() }
            let handle = try client.open(remote, flags: Self.read)
            defer { try? client.close(handle) }
            var offset: UInt64 = 0
            while true {
                try checkCancelled()
                let chunk = try client.read(handle, offset: offset)
                if chunk.isEmpty { break }
                try target.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
                progress(Int64(chunk.count))
            }
            try FileManager.default.moveItem(at: part, to: local)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    /// Server-side copy by streaming through this Mac, for Copy then Paste between remote folders.
    func copy(_ source: String, to target: String) throws {
        try checkCancelled()
        let attributes = try client.stat(source, follow: true)
        if attributes.directory {
            try client.mkdir(target)
            for entry in try client.list(source) {
                try copy(remoteJoin(source, entry.name), to: remoteJoin(target, entry.name))
            }
            return
        }
        let input = try client.open(source, flags: Self.read)
        defer { try? client.close(input) }
        let output = try client.open(target, flags: Self.write | Self.create | Self.truncate, mode: (attributes.mode ?? 0o644) & 0o777)
        defer { try? client.close(output) }
        var offset: UInt64 = 0
        while true {
            try checkCancelled()
            let chunk = try client.read(input, offset: offset)
            if chunk.isEmpty { break }
            try client.write(output, offset: offset, bytes: chunk)
            offset += UInt64(chunk.count)
            progress(Int64(chunk.count))
        }
    }

    /// Deletes a remote file or folder tree. SFTP only removes empty folders, so children go first.
    func remove(_ path: String) throws {
        let attributes = try client.stat(path)
        if attributes.directory {
            for entry in try client.list(path) { try remove(remoteJoin(path, entry.name)) }
            try client.remove(path, directory: true)
        } else {
            try client.remove(path)
        }
    }

    func size(of remote: String) throws -> Int64 {
        let attributes = try client.stat(remote, follow: true)
        guard attributes.directory else { return Int64(attributes.size ?? 0) }
        return try client.list(remote).reduce(0) { $0 + (try size(of: remoteJoin(remote, $1.name))) }
    }

    static func size(of local: URL) -> Int64 {
        guard opensAsFolder(local) else {
            return Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let walker = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total: Int64 = 0
        while let url = walker?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// A remote name that does not exist yet in `folder`, Finder style.
    func destination(for name: String, in folder: String) throws -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = remoteJoin(folder, name)
        var index = 1
        while try client.existing(candidate) != nil {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            candidate = remoteJoin(folder, base + suffix + (ext.isEmpty ? "" : "." + ext))
            index += 1
        }
        return candidate
    }

    private func checkCancelled() throws {
        if isCancelled() { throw FileIssue("Transfer cancelled.") }
    }
}
