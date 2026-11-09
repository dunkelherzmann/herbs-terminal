import SwiftUI
import HerbsTerminalUI

/// What Get Info shows for one file or folder.
struct FileInfo: Equatable, Sendable {
    var name: String
    var location: String
    var isFolder: Bool
    var isLink = false
    var size: UInt64?
    var modified: Date?
    /// Permission bits, including setuid, setgid and sticky (07777).
    var mode: UInt32
    var owner: String
    var group: String
    /// Only on this Mac: Finder's Hidden flag and Locked (the user-immutable flag).
    var hidden: Bool?
    var locked: Bool?
}

/// The changes Apply makes; nil leaves that attribute as it is on each item.
struct FileInfoChange: Equatable, Sendable {
    var mode: UInt32?
    var owner: String?
    var group: String?
    var hidden: Bool?
    var locked: Bool?
    /// Also change everything inside folders. Folders inside keep their search (x) bits wherever they are
    /// readable, so they stay openable; links inside are left alone.
    var recursive = false

    var isEmpty: Bool { mode == nil && owner == nil && group == nil && hidden == nil && locked == nil }
}

/// rwx text for a mode, as `ls -l` shows it (`rwxr-x---`, with s/S and t/T for the special bits).
func symbolicMode(_ mode: UInt32) -> String {
    let marks: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                        (0o004, "r"), (0o002, "w"), (0o001, "x")]
    var text = marks.map { mode & $0.0 != 0 ? $0.1 : "-" }
    func special(_ bit: UInt32, at index: Int, _ set: Character) {
        guard mode & bit != 0 else { return }
        text[index] = text[index] == "x" ? set : Character(set.uppercased())
    }
    special(0o4000, at: 2, "s")
    special(0o2000, at: 5, "s")
    special(0o1000, at: 8, "t")
    return String(text)
}

/// The mode a folder inside a recursive change gets: `mode`, plus search wherever reading is allowed.
func folderMode(_ mode: UInt32) -> UInt32 {
    var result = mode
    if mode & 0o400 != 0 { result |= 0o100 }
    if mode & 0o040 != 0 { result |= 0o010 }
    if mode & 0o004 != 0 { result |= 0o001 }
    return result
}

/// Get Info on this Mac.
enum LocalFileInfo {
    static func load(_ url: URL) throws -> FileInfo {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        let values = try? url.resourceValues(forKeys: [.isHiddenKey])
        return FileInfo(name: url.lastPathComponent, location: url.deletingLastPathComponent().path,
                        isFolder: type == .typeDirectory, isLink: type == .typeSymbolicLink,
                        size: (attributes[.size] as? NSNumber)?.uint64Value,
                        modified: attributes[.modificationDate] as? Date,
                        mode: ((attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0) & 0o7777,
                        owner: attributes[.ownerAccountName] as? String ?? "\((attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1)",
                        group: attributes[.groupOwnerAccountName] as? String ?? "\((attributes[.groupOwnerAccountID] as? NSNumber)?.intValue ?? -1)",
                        hidden: values?.isHidden ?? false,
                        locked: attributes[.immutable] as? Bool ?? false)
    }

    static func apply(_ change: FileInfoChange, to urls: [URL]) throws {
        for url in urls { try apply(change, to: url, top: true) }
    }

    private static func apply(_ change: FileInfoChange, to url: URL, top: Bool) throws {
        let manager = FileManager.default
        let type = (try manager.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType
        // Inside a folder, links are skipped: changing one would change whatever it points at.
        if !top, type == .typeSymbolicLink { return }
        let isFolder = type == .typeDirectory
        // A locked item refuses every other change, so unlocking comes first and locking last.
        if change.locked == false { try manager.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        var attributes: [FileAttributeKey: Any] = [:]
        if let mode = change.mode { attributes[.posixPermissions] = NSNumber(value: (isFolder && !top) ? folderMode(mode) : mode) }
        if let owner = change.owner { attributes[.ownerAccountID] = NSNumber(value: try Accounts.localUser(owner)) }
        if let group = change.group { attributes[.groupOwnerAccountID] = NSNumber(value: try Accounts.localGroup(group)) }
        if !attributes.isEmpty {
            do { try manager.setAttributes(attributes, ofItemAtPath: url.path) }
            catch { throw explain(error, url: url, ownership: change.owner != nil || change.group != nil) }
        }
        if let hidden = change.hidden {
            var values = URLResourceValues()
            values.isHidden = hidden
            var target = url
            try target.setResourceValues(values)
        }
        if change.recursive, isFolder {
            for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try apply(change, to: child, top: false)
            }
        }
        if change.locked == true { try manager.setAttributes([.immutable: true], ofItemAtPath: url.path) }
    }

    private static func explain(_ error: Error, url: URL, ownership: Bool) -> Error {
        let code = (error as NSError).code
        guard code == NSFileWriteNoPermissionError || ((error as NSError).underlyingErrors.first as NSError?)?.code == Int(EPERM) else { return error }
        return FileIssue(ownership
            ? "Only an administrator can give “\(url.lastPathComponent)” to another owner. Turn on Administrator mode (the lock) and try again."
            : "You don't have permission to change “\(url.lastPathComponent)”. Turn on Administrator mode (the lock) and try again.")
    }
}

/// Account names ↔ numbers. A number is always accepted as it is.
enum Accounts {
    static func localUser(_ name: String) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        guard let entry = getpwnam(name) else { throw FileIssue("There's no user named “\(name)” on this Mac.") }
        return entry.pointee.pw_uid
    }

    static func localGroup(_ name: String) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        guard let entry = getgrnam(name) else { throw FileIssue("There's no group named “\(name)” on this Mac.") }
        return entry.pointee.gr_gid
    }

    /// The number for a user or group name on `endpoint`, asked over the tab's shared SSH connection.
    static func remote(_ name: String, group: Bool, on endpoint: RemoteEndpoint) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw FileIssue("“\(name)” isn't a valid account name.") }
        let quoted = shellQuote(name)
        // getent on Linux, dscl on a Mac host; id covers users anywhere.
        let command = group
            ? "getent group \(quoted) 2>/dev/null | cut -d: -f3 || dscl . -read /Groups/\(quoted) PrimaryGroupID 2>/dev/null | awk '{print $2}'"
            : "id -u \(quoted) 2>/dev/null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = endpoint.sshArguments(["-o", "BatchMode=yes", "-T"]) + [command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let id = UInt32(text.trimmingCharacters(in: .whitespaces)) else {
            throw FileIssue("There's no \(group ? "group" : "user") named “\(name)” on \(endpoint.host).")
        }
        return id
    }
}

/// Where Get Info reads and writes: this Mac's files, or a host's over SFTP.
struct FileInfoSource {
    let title: String
    let load: () async throws -> [FileInfo]
    let apply: (FileInfoChange) async throws -> Void
    /// Hidden and Locked exist only on this Mac.
    let hasMacFlags: Bool

    static func local(_ urls: [URL]) -> FileInfoSource {
        FileInfoSource(title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
                       load: { try await Task.detached { try urls.map(LocalFileInfo.load) }.value },
                       apply: { change in try await Task.detached { try LocalFileInfo.apply(change, to: urls) }.value },
                       hasMacFlags: true)
    }
}

/// The Get Info panel's editable state.
@MainActor
final class FileInfoModel: ObservableObject {
    let source: FileInfoSource
    @Published private(set) var items: [FileInfo] = []
    @Published var mode: UInt32 = 0
    @Published var owner = ""
    @Published var group = ""
    @Published var hidden = false
    @Published var locked = false
    @Published var recursive = false
    @Published var error: String?
    @Published var busy = true
    @Published var notice: String?
    private var original: FileInfo?

    init(source: FileInfoSource) { self.source = source }

    var octal: String {
        get { String(mode, radix: 8).leftPadded(to: 3) }
        set {
            let digits = newValue.filter(\.isNumber)
            if let value = UInt32(digits, radix: 8), value <= 0o7777 { mode = value }
        }
    }

    var hasFolders: Bool { items.contains { $0.isFolder } }

    var change: FileInfoChange {
        guard let original else { return FileInfoChange() }
        var change = FileInfoChange(recursive: recursive)
        if mode != original.mode { change.mode = mode }
        let owner = owner.trimmingCharacters(in: .whitespaces), group = group.trimmingCharacters(in: .whitespaces)
        if !owner.isEmpty, owner != original.owner { change.owner = owner }
        if !group.isEmpty, group != original.group { change.group = group }
        if source.hasMacFlags, hidden != original.hidden { change.hidden = hidden }
        if source.hasMacFlags, locked != original.locked { change.locked = locked }
        // A recursive change applies the current values all the way down even where the first item matches.
        if recursive, change.isEmpty, hasFolders { change.mode = mode }
        return change
    }

    func load() async {
        busy = true
        defer { busy = false }
        do {
            items = try await source.load()
            guard let first = items.first else { return }
            original = first
            mode = first.mode
            owner = first.owner
            group = first.group
            hidden = first.hidden ?? false
            locked = first.locked ?? false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        let change = change
        guard !change.isEmpty else { return }
        busy = true
        var failure: String?
        do {
            try await source.apply(change)
            notice = "Changes applied."
            error = nil
        } catch {
            failure = error.localizedDescription
            notice = nil
        }
        busy = false
        await load()
        // Reloading shows what's on disk now; the reason Apply failed stays in view (load would clear it).
        if let failure { error = failure }
    }

    func toggle(_ bit: UInt32) { mode ^= bit }
}

extension FileInfoModel {
    /// Feature tests: what the Get Info window shows.
    var bridgeState: [String: Any] {
        ["names": items.map(\.name), "folders": items.filter(\.isFolder).map(\.name), "location": items.first?.location ?? "",
         "size": items.first?.size.map { Int($0) as Any } ?? NSNull(), "modified": items.first?.modified != nil,
         "octal": octal, "symbolic": symbolicMode(mode), "owner": owner, "group": group, "recursive": recursive,
         "hasFolders": hasFolders, "macFlags": source.hasMacFlags, "hidden": hidden, "locked": locked,
         "busy": busy, "error": error ?? "", "notice": notice ?? "", "changed": !change.isEmpty]
    }

    /// Feature tests: edits the fields as a person would, then Apply, Revert or neither.
    func bridge(_ request: [String: Any]) async {
        if let value = request["octal"] as? String { octal = value }
        for bit in request["toggle"] as? [Int] ?? [] { toggle(UInt32(bit)) }
        if let value = request["owner"] as? String { owner = value }
        if let value = request["group"] as? String { group = value }
        if let value = request["recursive"] as? Bool { recursive = value }
        if let value = request["hidden"] as? Bool { hidden = value }
        if let value = request["locked"] as? Bool { locked = value }
        switch request["action"] as? String {
        case "apply": await apply()
        case "revert": await load()
        default: break
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}

/// The Get Info window: one per selection, like Finder's.
@MainActor
enum FileInfoWindow {
    private static var windows: [NSWindow] = []
    /// The open windows' models, newest last, for the feature tests' bridge.
    private(set) static var models: [(window: NSWindow, model: FileInfoModel)] = []

    static func show(_ source: FileInfoSource) {
        let model = FileInfoModel(source: source)
        let window = NSWindow(contentViewController: NSHostingController(rootView: FileInfoView(model: model)))
        window.title = "\(source.title) Info"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        windows.append(window)
        models.append((window, model))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === window }
                models.removeAll { $0.window === window }
            }
        }
        window.makeKeyAndOrderFront(nil)
        Task { await model.load() }
    }
}

struct FileInfoView: View {
    @ObservedObject var model: FileInfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ownership
            permissions
            if model.source.hasMacFlags {
                HStack(spacing: 18) {
                    Toggle("Hidden", isOn: $model.hidden)
                        .hint("Hidden\nHide it in Finder and in the explorer unless hidden files are shown.")
                    Toggle("Locked", isOn: $model.locked)
                        .hint("Locked\nPrevent changes, renaming and deletion until it's unlocked (the user-immutable flag).")
                }
            }
            if model.hasFolders {
                Toggle("Apply to enclosed items", isOn: $model.recursive)
                    .hint("Apply to enclosed items\nAlso change everything inside the folder. Folders inside stay openable; links are left alone.")
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Revert") { Task { await model.load() } }
                    .disabled(model.change.isEmpty || model.busy)
                    .hint("Revert\nGo back to the values on disk.")
                Button("Apply") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.change.isEmpty || model.busy)
                    .hint("Apply (Return)\nMake these changes.")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private var header: some View {
        if model.items.count == 1, let item = model.items.first {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Name", item.name)
                row("Where", item.location)
                row("Kind", item.isLink ? "Link" : item.isFolder ? "Folder" : "File")
                if !item.isFolder, let size = item.size {
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " (\(size.formatted()) bytes)")
                }
                if let modified = item.modified { row("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
                row("Permissions", symbolicMode(item.mode) + "  (" + String(item.mode, radix: 8) + ")")
            }
            .font(.callout)
        } else {
            Text("\(model.items.count) items: changes apply to each of them.").font(.callout)
        }
    }

    private var ownership: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Owner").foregroundStyle(.secondary)
                TextField("user name or number", text: $model.owner)
                    .hint("Owner\nThe account that owns it (chown). Giving it to someone else needs Administrator mode.")
            }
            GridRow {
                Text("Group").foregroundStyle(.secondary)
                TextField("group name or number", text: $model.group)
                    .hint("Group\nThe group whose members get the Group permissions (chgrp).")
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Read").font(.caption).foregroundStyle(.secondary)
                    Text("Write").font(.caption).foregroundStyle(.secondary)
                    Text(model.hasFolders && model.items.count == 1 ? "Open" : "Execute").font(.caption).foregroundStyle(.secondary)
                }
                permissionRow("Owner", shift: 6)
                permissionRow("Group", shift: 3)
                permissionRow("Others", shift: 0)
            }
            HStack(spacing: 14) {
                bit("Set user ID", 0o4000, help: "Set user ID (setuid)\nA program runs with its owner's rights.")
                bit("Set group ID", 0o2000, help: "Set group ID (setgid)\nA program runs with its group's rights; in a folder, new items get its group.")
                bit("Sticky", 0o1000, help: "Sticky\nIn a folder, only an item's owner can rename or delete it, as in /tmp.")
            }
            .font(.caption)
            HStack {
                Text("Octal").foregroundStyle(.secondary)
                TextField("755", text: Binding(get: { model.octal }, set: { model.octal = $0 }))
                    .frame(width: 70)
                    .font(.system(.body, design: .monospaced))
                    .hint("Octal\nThe same permissions as chmod takes them, e.g. 644 or 755.")
                Text(symbolicMode(model.mode)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ title: String, shift: UInt32) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            ForEach([4, 2, 1] as [UInt32], id: \.self) { value in
                let bit = value << shift
                Toggle("", isOn: Binding(get: { model.mode & bit != 0 }, set: { _ in model.toggle(bit) }))
                    .labelsHidden()
                    .accessibilityLabel("\(title) \(value == 4 ? "read" : value == 2 ? "write" : "execute")")
            }
        }
    }

    private func bit(_ title: String, _ bit: UInt32, help: String) -> some View {
        Toggle(title, isOn: Binding(get: { model.mode & bit != 0 }, set: { _ in model.toggle(bit) })).hint(help)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}
