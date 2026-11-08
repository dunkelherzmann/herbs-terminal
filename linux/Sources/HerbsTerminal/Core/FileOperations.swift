import Foundation
import Glibc

/// A reversible change made by an explorer, kept for Undo / Redo.
enum FileChange: Equatable, Sendable {
    case created([URL])
    case moved([Move])
    case trashed([Move])

    struct Move: Equatable, Sendable {
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

/// The freedesktop.org Trash: ~/.local/share/Trash for the home volume, `.Trash-<uid>` at the top of other
/// volumes. Each trashed item gets a .trashinfo file with its original path, so file managers can restore it,
/// and the explorer's Undo moves it straight back.
enum Trash {
    /// The host's own Trash: inside the Flatpak, XDG_DATA_HOME points at the app's private folder.
    static var homeTrash: String { FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/Trash" }
    static var homeFiles: String { homeTrash + "/files" }

    /// Moves `url` to the Trash and returns where it went.
    static func trash(_ url: URL) throws -> URL {
        let path = url.path
        var problem: String?
        for trash in candidates(for: path) {
            do {
                try FileManager.default.createDirectory(atPath: trash + "/files", withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createDirectory(atPath: trash + "/info", withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let name = freeName(url.lastPathComponent, in: trash)
                let info = trash + "/info/" + name + ".trashinfo"
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                let text = "[Trash Info]\nPath=\(encoded)\nDeletionDate=\(formatter.string(from: Date()))\n"
                guard FileManager.default.createFile(atPath: info, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                    throw FileIssue("Couldn't write the Trash record for “\(url.lastPathComponent)”.")
                }
                let target = trash + "/files/" + name
                guard rename(path, target) == 0 else {
                    let reason = String(cString: strerror(errno))
                    try? FileManager.default.removeItem(atPath: info)
                    problem = reason
                    continue
                }
                return URL(fileURLWithPath: target)
            } catch {
                problem = error.localizedDescription
            }
        }
        throw FileIssue("“\(url.lastPathComponent)” couldn't be moved to the Trash" + (problem.map { ": \($0)" } ?? "."))
    }

    /// Puts a trashed item back at `original` and forgets its Trash record.
    static func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
        let folder = trashed.deletingLastPathComponent()
        if folder.lastPathComponent == "files" {
            let info = folder.deletingLastPathComponent().appendingPathComponent("info/" + trashed.lastPathComponent + ".trashinfo")
            try? FileManager.default.removeItem(at: info)
        }
    }

    /// The home Trash when the item is on the home volume, otherwise the volume's own `.Trash-<uid>`.
    private static func candidates(for path: String) -> [String] {
        var info = stat(), home = stat()
        let homeTrashParent = (homeTrash as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: homeTrashParent, withIntermediateDirectories: true)
        guard lstat(path, &info) == 0, stat(homeTrashParent, &home) == 0 else { return [homeTrash] }
        if info.st_dev == home.st_dev { return [homeTrash] }
        // The top of the item's volume: the last folder upward on the same device.
        var top = (path as NSString).deletingLastPathComponent
        while top != "/" {
            let up = (top as NSString).deletingLastPathComponent
            var parent = stat()
            guard stat(up, &parent) == 0, parent.st_dev == info.st_dev else { break }
            top = up
        }
        return [top + "/.Trash-\(getuid())"]
    }

    private static func freeName(_ name: String, in trash: String) -> String {
        var candidate = name, index = 2
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: trash + "/files/" + candidate)
                || FileManager.default.fileExists(atPath: trash + "/info/" + candidate + ".trashinfo") {
            candidate = base + ".\(index)" + (ext.isEmpty ? "" : "." + ext)
            index += 1
        }
        return candidate
    }
}

/// Local file operations. Nothing is overwritten: clashes get "name copy" names, and Delete moves items to the
/// Trash so Undo can bring them back.
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
            let source = item.standardizedFileURL.path, target = folder.standardizedFileURL.path
            guard target != source, !target.hasPrefix(source + "/") else {
                throw FileIssue("“\(item.lastPathComponent)” can't be copied into itself.")
            }
            let destination = destination(for: item.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: item, to: destination)
            created.append(destination)
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

    /// New Folder / New File with a free "untitled" name, like Thunar.
    static func create(folder: Bool, named name: String? = nil, in parent: URL) throws -> FileChange {
        let target = destination(for: name ?? (folder ? "untitled folder" : "untitled"), in: parent)
        if folder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } else {
            guard FileManager.default.createFile(atPath: target.path, contents: Data()) else {
                throw FileIssue("Couldn't create “\(target.lastPathComponent)”.")
            }
        }
        return .created([target])
    }

    /// Rename is a move within the folder, so Undo puts the old name back.
    static func rename(_ item: URL, to name: String) throws -> FileChange {
        try validateFileName(name)
        let target = item.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileIssue("An item named “\(name)” already exists here.")
        }
        try FileManager.default.moveItem(at: item, to: target)
        return .moved([.init(from: item, to: target)])
    }

    static func trash(_ items: [URL]) throws -> FileChange {
        var moves: [FileChange.Move] = []
        for item in items {
            moves.append(.init(from: item, to: try Trash.trash(item)))
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
                if case .trashed = change { try Trash.restore(move.to, to: move.from) }
                else { try FileManager.default.moveItem(at: move.to, to: move.from) }
                back.append(.init(from: move.to, to: move.from))
            }
            return .moved(back)
        }
    }
}

/// Undo / Redo stacks for one explorer pane. Each step keeps the name of the action the user took, so undoing a
/// Move to Trash offers "Redo Move to Trash" although putting it back is itself a move.
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

    func record(_ change: FileChange, as title: String? = nil) {
        if case .created(let urls) = change, urls.isEmpty { return }
        if case .moved(let moves) = change, moves.isEmpty { return }
        undoStack.append(Step(change: change, title: title ?? change.title))
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

/// Folders and links to folders open in the explorer.
func opensAsFolder(_ url: URL) -> Bool {
    var isFolder: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.resolvingSymlinksInPath().path, isDirectory: &isFolder) && isFolder.boolValue
}

/// Streams files and folders over one SFTP channel. Uploads land under a temporary name and are renamed into
/// place, so an interrupted upload never leaves a half-written file under the real name.
struct SFTPTransfer {
    static let read: UInt32 = 0x01, write: UInt32 = 0x02, create: UInt32 = 0x08, truncate: UInt32 = 0x10, exclusive: UInt32 = 0x20
    let client: SFTPClient
    var progress: (Int64) -> Void = { _ in }
    var isCancelled: () -> Bool = { false }

    func upload(_ local: URL, to remote: String) throws {
        try checkCancelled()
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeDirectory {
            try client.mkdir(remote)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, to: remoteJoin(remote, child.lastPathComponent))
            }
            return
        }
        // No setuid, setgid or sticky bits: an Administrator mode upload must not hand them to root's files.
        let mode = ((attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644) & 0o777
        // An unguessable name opened exclusively, so nothing planted at that name (a symlink, say) is written through.
        let tag = UUID().uuidString.prefix(8).lowercased()
        let part = remoteJoin(parentPath(remote), ".\((remote as NSString).lastPathComponent).\(tag).herbsterminal-part")
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        let handle = try client.open(part, flags: Self.write | Self.create | Self.exclusive, mode: mode)
        do {
            try client.writeAll(handle) {
                try checkCancelled()
                guard let chunk = try source.read(upToCount: 32768), !chunk.isEmpty else { return nil }
                progress(Int64(chunk.count))
                return chunk
            }
            try client.close(handle)
            try client.rename(part, remote)
        } catch {
            try? client.close(handle)
            try? client.remove(part)
            throw error
        }
    }

    /// `top` is the item the user picked, followed if it's a link. Inside a folder, links to folders are skipped
    /// so a link such as `loop -> ..` can't recurse forever; links to files copy their contents.
    func download(_ remote: String, to local: URL, top: Bool = true) throws {
        try checkCancelled()
        guard let attributes = try entryAttributes(remote, top: top) else { return }
        if attributes.directory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            for entry in try client.list(remote) {
                try download(remoteJoin(remote, entry.name), to: local.appendingPathComponent(entry.name), top: false)
            }
            return
        }
        let part = local.deletingLastPathComponent().appendingPathComponent(".\(local.lastPathComponent).herbsterminal-part")
        _ = FileManager.default.createFile(atPath: part.path, contents: nil)
        do {
            let target = try FileHandle(forWritingTo: part)
            defer { try? target.close() }
            let handle = try client.open(remote, flags: Self.read)
            defer { try? client.close(handle) }
            try client.readAll(handle) { chunk in
                try checkCancelled()
                try target.write(contentsOf: chunk)
                progress(Int64(chunk.count))
            }
            try FileManager.default.moveItem(at: part, to: local)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    /// Server-side copy by streaming through this computer, for Copy then Paste between remote folders.
    func copy(_ source: String, to target: String, top: Bool = true) throws {
        try checkCancelled()
        guard let attributes = try entryAttributes(source, top: top) else { return }
        if attributes.directory {
            let children = try client.list(source)
            try client.mkdir(target)
            for entry in children {
                try copy(remoteJoin(source, entry.name), to: remoteJoin(target, entry.name), top: false)
            }
            return
        }
        let input = try client.open(source, flags: Self.read)
        defer { try? client.close(input) }
        // The target is always a new name; opening it exclusively never writes through something already there.
        let output = try client.open(target, flags: Self.write | Self.create | Self.exclusive, mode: (attributes.mode ?? 0o644) & 0o777)
        var closed = false
        defer { if !closed { try? client.close(output) } }
        // One channel can't read and write in the same pipeline, so the file passes through a private temporary
        // file here: pipelined in, then pipelined out.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("herbsterminal-copy-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FileIssue("Couldn't stage the copy on this computer.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let sink = try FileHandle(forWritingTo: staging)
        try client.readAll(input) { chunk in
            try checkCancelled()
            try sink.write(contentsOf: chunk)
            progress(Int64(chunk.count) / 2)
        }
        try sink.close()
        let back = try FileHandle(forReadingFrom: staging)
        defer { try? back.close() }
        try client.writeAll(output) {
            try checkCancelled()
            guard let chunk = try back.read(upToCount: 32768), !chunk.isEmpty else { return nil }
            progress(Int64(chunk.count) - Int64(chunk.count) / 2)
            return chunk
        }
        // Some servers report a full disk or quota only when the file is closed.
        closed = true
        try client.close(output)
    }

    private func entryAttributes(_ path: String, top: Bool) throws -> RemoteAttributes? {
        let own = try client.stat(path, follow: top)
        guard !top, own.link else { return own }
        let target = try client.stat(path, follow: true)
        return target.directory ? nil : target
    }

    /// A whole remote file, for the text editor; refuses anything over `limit` bytes.
    func readAll(_ path: String, limit: Int) throws -> Data {
        let attributes = try client.stat(path, follow: true)
        guard !attributes.directory else { throw FileIssue("“\((path as NSString).lastPathComponent)” is a folder.") }
        if let size = attributes.size, size > UInt64(limit) {
            throw FileIssue("“\((path as NSString).lastPathComponent)” is larger than \(limit / 1_048_576) MB, too big to edit here.")
        }
        let handle = try client.open(path, flags: Self.read)
        defer { try? client.close(handle) }
        var data = Data()
        try client.readAll(handle) { chunk in
            data.append(chunk)
            guard data.count <= limit else { throw FileIssue("“\((path as NSString).lastPathComponent)” is too big to edit here.") }
        }
        return data
    }

    /// Saves the text editor's file: written in full under an unguessable name next to it, then renamed over it,
    /// so a dropped connection never leaves it half written. Its permissions are kept.
    func replace(_ path: String, with data: Data) throws {
        let mode = ((try? client.stat(path, follow: true))?.mode ?? 0o644) & 0o777
        let tag = UUID().uuidString.prefix(8).lowercased()
        let part = remoteJoin(parentPath(path), ".\((path as NSString).lastPathComponent).\(tag).herbsterminal-part")
        let handle = try client.open(part, flags: Self.write | Self.create | Self.exclusive, mode: mode)
        do {
            var offset = 0
            try client.writeAll(handle) {
                guard offset < data.count else { return nil }
                let chunk = data.subdata(in: offset..<min(data.count, offset + 32768))
                offset += chunk.count
                return chunk
            }
            try client.close(handle)
            try client.rename(part, path, replace: true)
        } catch {
            try? client.close(handle)
            try? client.remove(part)
            throw error
        }
    }

    /// Deletes a remote file or folder tree. SFTP only removes empty folders, so children go first.
    ///
    /// `asRoot` (Administrator mode): SFTP removes by path, so another account that could change a folder in the
    /// tree could swap it for a link mid-delete and point root's deletes elsewhere. As root, a folder is only
    /// emptied when root owns it and the folder holding it and no other account can write to them; otherwise
    /// nothing more is deleted and the error says why. Links are removed, never followed.
    func remove(_ path: String, asRoot: Bool = false, top: Bool = true) throws {
        let attributes = try client.stat(path)
        if attributes.directory {
            if asRoot {
                if top { try requireRootOnly(parentPath(path), try client.stat(parentPath(path)), deleting: path) }
                try requireRootOnly(path, attributes, deleting: path)
            }
            for entry in try client.list(path) { try remove(remoteJoin(path, entry.name), asRoot: asRoot, top: false) }
            try client.remove(path, directory: true)
        } else {
            try client.remove(path)
        }
    }

    private func requireRootOnly(_ folder: String, _ attributes: RemoteAttributes, deleting path: String) throws {
        let mode = attributes.mode ?? 0o7777
        // Group write is fine for root's and the administrators' groups, whose members can use sudo anyway.
        let trustedGroup = attributes.gid == 0 || attributes.gid == 80
        guard attributes.uid == 0, mode & 0o002 == 0, mode & 0o020 == 0 || trustedGroup else {
            throw FileIssue("“\((path as NSString).lastPathComponent)” wasn't deleted as root: \(folder) can be changed by another account, "
                + "which could redirect the deletion. Turn off Administrator mode to delete it with your own account's access.")
        }
    }

    func size(of remote: String) throws -> Int64 {
        let attributes = try client.stat(remote, follow: true)
        guard attributes.directory else { return Int64(attributes.size ?? 0) }
        return try client.list(remote).reduce(0) { $0 + (try size(of: remoteJoin(remote, $1.name))) }
    }

    static func size(of local: URL) -> Int64 {
        guard opensAsFolder(local) else {
            return ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        let walker = FileManager.default.enumerator(atPath: local.path)
        var total: Int64 = 0
        while let name = walker?.nextObject() as? String {
            total += ((walker?.fileAttributes?[.size]) as? NSNumber)?.int64Value ?? 0
            _ = name
        }
        return total
    }

    /// A remote name that does not exist yet in `folder`.
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

/// Shared between a background transfer and the Cancel button that stops it.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func cancel() { lock.withLock { set = true } }
}

/// Collects byte counts from a background transfer and reports them about ten times a second.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var reported = Date.distantPast
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func add(_ bytes: Int64) {
        let snapshot: Int64? = lock.withLock {
            done += bytes
            guard Date().timeIntervalSince(reported) > 0.1 else { return nil }
            reported = Date()
            return done
        }
        if let snapshot { report(snapshot) }
    }
}

extension TransferItem {
    var isUpload: Bool { if case .upload = direction { true } else { false } }
    var route: String {
        switch direction {
        case .upload(let local, let remote): "\(local.path) → \(remote)"
        case .download(let remote, let local): "\(remote) → \(local.path)"
        }
    }
}

extension TransferQueue {
    func clearFinished() {
        items.removeAll {
            switch $0.state {
            case .completed, .failed, .cancelled: true
            default: false
            }
        }
    }
}
