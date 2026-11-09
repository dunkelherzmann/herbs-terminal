import Foundation
import WinSDK

/// A reversible change made in an explorer, kept for Undo and Redo, as on the Mac and Linux.
enum ExplorerChange {
    /// Copies and new items on this PC: undoing moves them to the Recycle Bin.
    case created([String])
    /// Moves and renames on this PC: undoing moves each item back to where it was.
    case moved([(from: String, to: String)])
    /// Items moved to the Recycle Bin from these paths: undoing puts them back.
    case recycled([String])
    /// Moves and renames on the host: undoing renames them back.
    case remoteMoved([(from: String, to: String)])
}

/// Undo and Redo for one explorer. Each step keeps the name of the action the user took, so undoing Move to
/// Recycle Bin offers "Redo Move to Recycle Bin" although putting the item back is itself a move.
@MainActor
final class ExplorerUndo {
    struct Step {
        let change: ExplorerChange
        let title: String
    }

    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []

    var undoTitle: String { undoStack.last.map { "Undo \($0.title)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.title)" } ?? "Redo" }

    func record(_ change: ExplorerChange, as title: String) {
        switch change {
        case .created(let paths), .recycled(let paths): if paths.isEmpty { return }
        case .moved(let moves), .remoteMoved(let moves): if moves.isEmpty { return }
        }
        undoStack.append(Step(change: change, title: title))
        redoStack.removeAll()
    }

    /// Takes the step to undo (or redo); `finish` puts its reverse on the other stack, or the step back if it failed.
    func take(redo: Bool) -> Step? { redo ? redoStack.popLast() : undoStack.popLast() }

    func finish(_ step: Step, redo: Bool, reverse: ExplorerChange?) {
        if let reverse {
            if redo { undoStack.append(Step(change: reverse, title: step.title)) } else { redoStack.append(Step(change: reverse, title: step.title)) }
        } else {
            if redo { redoStack.append(step) } else { undoStack.append(step) }
        }
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

/// This PC's side of Undo: reverses a change made here and returns the change that reverses it again.
@MainActor
enum LocalUndo {
    static func revert(_ change: ExplorerChange, owner: HWND?) throws -> ExplorerChange {
        switch change {
        case .created(let paths):
            let present = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard present.count == paths.count else { throw FileIssue("“\(name(missing(paths)))” is no longer there.") }
            guard ShellOperation.run(.recycle, paths, owner: owner) else { throw FileIssue("Moving to the Recycle Bin was cancelled.") }
            return .recycled(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        case .recycled(let paths):
            var restored: [String] = []
            for path in paths {
                do { try RecycleBin.restore(path) } catch {
                    // What was put back stays back; Undo can move it to the Recycle Bin again.
                    if !restored.isEmpty { throw FileIssue("\(error.localizedDescription) The others were put back.") }
                    throw error
                }
                restored.append(path)
            }
            return .created(restored)
        case .moved(let moves):
            for move in moves where !FileManager.default.fileExists(atPath: move.to) {
                throw FileIssue("“\(name(move.to))” is no longer there.")
            }
            for move in moves where FileManager.default.fileExists(atPath: move.from) && move.from.caseInsensitiveCompare(move.to) != .orderedSame {
                throw FileIssue("“\(name(move.from))” can't go back: an item with that name is there now.")
            }
            let back = moves.map { (from: $0.to, to: $0.from) }
            guard ShellOperation.move(back, owner: owner) else { throw FileIssue("Moving back was cancelled.") }
            return .moved(back)
        case .remoteMoved:
            throw FileIssue("A host's change can only be undone in that host's explorer.")
        }
    }

    private static func missing(_ paths: [String]) -> String { paths.first { !FileManager.default.fileExists(atPath: $0) } ?? paths[0] }
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// Puts items back from the Recycle Bin. Windows keeps each recycled item in `<drive>\$Recycle.Bin\<user SID>` as a
/// `$R…` file or folder beside a `$I…` record holding its original path and when it was deleted; this is what File
/// Explorer's Restore uses too.
enum RecycleBin {
    /// Puts the item most recently recycled from `path` back there.
    static func restore(_ path: String) throws {
        let name = (path as NSString).lastPathComponent
        guard !FileManager.default.fileExists(atPath: path) else {
            throw FileIssue("“\(name)” can't go back: an item with that name is there now.")
        }
        guard path.count >= 3, path.dropFirst().hasPrefix(":\\") else { throw FileIssue("“\(name)” has no Recycle Bin to come back from.") }
        let bin = String(path.prefix(3)) + "$Recycle.Bin"
        var best: (record: String, item: String, time: UInt64)?
        for user in (try? FileManager.default.contentsOfDirectory(atPath: bin)) ?? [] {
            let folder = bin + "\\" + user
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasPrefix("$I") {
                guard let data = FileManager.default.contents(atPath: folder + "\\" + file), let record = parse(data),
                      record.path.caseInsensitiveCompare(path) == .orderedSame, record.time >= (best?.time ?? 0) else { continue }
                best = (folder + "\\" + file, folder + "\\$R" + file.dropFirst(2), record.time)
            }
        }
        guard let best, FileManager.default.fileExists(atPath: best.item) else {
            throw FileIssue("“\(name)” isn't in the Recycle Bin any more.")
        }
        let moved = withWide(best.item) { from in withWide(path) { to in MoveFileExW(from, to, 0) } }
        guard moved else { throw FileIssue("“\(name)” couldn't be put back (error \(GetLastError())).") }
        _ = withWide(best.record) { DeleteFileW($0) }
        withWide((path as NSString).deletingLastPathComponent) { SHChangeNotify(LONG(SHCNE_UPDATEDIR), UINT(SHCNF_PATHW), $0, nil) }
    }

    /// A `$I` record: version 1 has a fixed 260-character path, version 2 (Windows 10 and later) a counted one.
    static func parse(_ data: Data) -> (path: String, time: UInt64)? {
        guard data.count >= 28 else { return nil }
        func integer<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            data.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        let version = integer(0, UInt64.self), time = integer(16, UInt64.self)
        let start: Int, count: Int
        switch version {
        case 1: start = 24; count = min(260, (data.count - 24) / 2)
        case 2: start = 28; count = min(Int(integer(24, UInt32.self)), (data.count - 28) / 2)
        default: return nil
        }
        var units: [UInt16] = (0..<count).map { integer(start + $0 * 2, UInt16.self) }
        if let end = units.firstIndex(of: 0) { units.removeSubrange(end...) }
        return (String(decoding: units, as: UTF16.self), time)
    }
}

extension ShellOperation {
    /// Moves each item to exactly the given path (Undo of a move or rename), through the shell like any move.
    static func move(_ moves: [(from: String, to: String)], owner: HWND?) -> Bool {
        guard !moves.isEmpty else { return true }
        var from: [UInt16] = moves.flatMap { Array($0.from.utf16) + [0] } + [0]
        var to: [UInt16] = moves.flatMap { Array($0.to.utf16) + [0] } + [0]
        var operation = SHFILEOPSTRUCTW()
        operation.hwnd = owner.flatMap { GetAncestor($0, UINT(GA_ROOT)) }
        operation.wFunc = UINT(FO_MOVE)
        operation.fFlags = FILEOP_FLAGS(FOF_NOCONFIRMMKDIR | FOF_ALLOWUNDO | FOF_MULTIDESTFILES | FOF_NOCONFIRMATION)
        return from.withUnsafeMutableBufferPointer { fromPointer in
            to.withUnsafeMutableBufferPointer { toPointer in
                operation.pFrom = UnsafePointer(fromPointer.baseAddress)
                operation.pTo = UnsafePointer(toPointer.baseAddress)
                return SHFileOperationW(&operation) == 0 && !operation.fAnyOperationsAborted.boolValue
            }
        }
    }
}
