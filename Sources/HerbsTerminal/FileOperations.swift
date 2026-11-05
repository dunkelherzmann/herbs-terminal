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

    /// New Folder / New File with a free "untitled" name, like Thunar and Finder.
    static func create(folder: Bool, named name: String? = nil, in parent: URL) throws -> FileChange {
        let target = destination(for: name ?? (folder ? "untitled folder" : "untitled"), in: parent)
        if folder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } else {
            try Data().write(to: target, options: .withoutOverwriting)
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

    /// Remote items: Herb's Terminal pastes them on the host (or uploads them elsewhere), and Finder or the
    /// local explorer gets real files. `fetch` downloads one item to a local URL; it runs only when something
    /// asks for the files, so copying never downloads anything by itself.
    func writeRemote(_ paths: [String], on endpoint: RemoteEndpoint, cut: Bool,
                     fetch: (@Sendable (String, URL) throws -> Void)? = nil) {
        pasteboard.clearContents()
        provider = fetch.map { RemoteFileProvider(fetch: $0) }
        if let provider {
            let items = paths.map { path -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(path, forType: RemoteFileProvider.pathType)
                item.setDataProvider(provider, forTypes: [.fileURL])
                return item
            }
            pasteboard.writeObjects(items)
        } else {
            pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        }
        remote = (endpoint, paths, cut, pasteboard.changeCount)
        cutCount = nil
    }

    private var provider: RemoteFileProvider?

    func readRemote(for endpoint: RemoteEndpoint) -> (paths: [String], cut: Bool)? {
        guard let remote, remote.count == pasteboard.changeCount, remote.endpoint == endpoint else { return nil }
        return (remote.paths, remote.cut)
    }

    var hasContent: Bool { remote?.count == pasteboard.changeCount || !readLocal().urls.isEmpty }
}

/// Downloads a copied remote item when an app pastes it, into a staging folder that is emptied each launch
/// and whenever new remote items are copied.
final class RemoteFileProvider: NSObject, NSPasteboardItemDataProvider {
    static let pathType = NSPasteboard.PasteboardType("org.herbsterminal.remote-path")
    static let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HerbsTerminal/Clipboard", isDirectory: true)

    private let fetch: @Sendable (String, URL) throws -> Void
    private let folder: URL

    init(fetch: @escaping @Sendable (String, URL) throws -> Void) {
        self.fetch = fetch
        try? FileManager.default.removeItem(at: Self.staging)
        folder = Self.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        super.init()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL, let path = item.string(forType: Self.pathType) else { return }
        let target = folder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            if !FileManager.default.fileExists(atPath: target.path) { try fetch(path, target) }
            item.setString(target.absoluteString, forType: .fileURL)
        } catch {
            NSLog("Herb's Terminal: couldn't fetch %@ for the clipboard: %@", path, error.localizedDescription)
        }
    }
}

/// Streams files and folders over one SFTP channel. Uploads land under a temporary name and are
/// renamed into place, so an interrupted upload never leaves a half-written file under the real name.
struct SFTPTransfer {
    static let read: UInt32 = 0x01, write: UInt32 = 0x02, create: UInt32 = 0x08, truncate: UInt32 = 0x10, exclusive: UInt32 = 0x20
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
        // No setuid, setgid or sticky bits: an Administrator mode upload must not hand them to root's files.
        let mode = ((try? FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644) & 0o777
        // An unguessable name opened exclusively, so nothing planted at that name (a symlink, say) is written through.
        let tag = UUID().uuidString.prefix(8).lowercased()
        let part = remoteJoin(parentPath(remote), ".\((remote as NSString).lastPathComponent).\(tag).herbsterminal-part")
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        let handle = try client.open(part, flags: Self.write | Self.create | Self.exclusive, mode: mode)
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

    /// `top` is the item the user picked, followed if it's a link. Inside a folder, links to folders are
    /// skipped so a link such as `loop -> ..` can't recurse forever; links to files copy their contents.
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
        var offset: UInt64 = 0
        while true {
            try checkCancelled()
            let chunk = try client.read(input, offset: offset)
            if chunk.isEmpty { break }
            try client.write(output, offset: offset, bytes: chunk)
            offset += UInt64(chunk.count)
            progress(Int64(chunk.count))
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
        while true {
            let chunk = try client.read(handle, offset: UInt64(data.count))
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= limit else { throw FileIssue("“\((path as NSString).lastPathComponent)” is too big to edit here.") }
        }
        return data
    }

    /// Saves the text editor's file: written in full under an unguessable name next to it, then renamed
    /// over it, so a dropped connection never leaves it half written. Its permissions are kept.
    func replace(_ path: String, with data: Data) throws {
        let mode = ((try? client.stat(path, follow: true))?.mode ?? 0o644) & 0o777
        let tag = UUID().uuidString.prefix(8).lowercased()
        let part = remoteJoin(parentPath(path), ".\((path as NSString).lastPathComponent).\(tag).herbsterminal-part")
        let handle = try client.open(part, flags: Self.write | Self.create | Self.exclusive, mode: mode)
        do {
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(data.count, offset + 32768))
                try client.write(handle, offset: UInt64(offset), bytes: chunk)
                offset += chunk.count
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

/// Asks for a file or folder name, pre-selecting the part before the extension as Finder does.
@MainActor
func askForName(title: String, message: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    DispatchQueue.main.async {
        let base = (initial as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? initial : base).utf16.count)
    }
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}
