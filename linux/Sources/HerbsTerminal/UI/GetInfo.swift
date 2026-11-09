import CGtk
import CHerb
import Foundation

/// The Get Info window: one per selection. It shows the item and lets you change its permissions (chmod), owner and
/// group (chown), on this computer or on a host, optionally for everything inside a folder.
@MainActor
final class FileInfoWindow {
    private let source: FileInfoSource
    private let window: ToolWindow
    private var items: [FileInfo] = []
    private var original: FileInfo?
    private var mode: UInt32 = 0
    private var busy = true
    private var updating = false

    private let header: Widget
    private let owner: Widget
    private let group: Widget
    private var bits: [UInt32: Widget] = [:]
    private let octal: Widget
    private let symbolic: Widget
    private let recursive: Widget
    private let message: Widget
    private let revert: Widget
    private let apply: Widget
    private let spinner: Widget
    private let executeHeading: Widget

    /// The newest window still open, for the feature tests' bridge.
    private(set) static weak var newest: FileInfoWindow?
    private var closed = false

    static func show(_ source: FileInfoSource, parent: Widget?) {
        let info = FileInfoWindow(source: source, parent: parent)
        info.window.owner = info
        newest = info
        info.window.onClose = { [weak info] in info?.closed = true }
        info.window.present()
        Task { await info.load() }
    }

    private init(source: FileInfoSource, parent: Widget?) {
        self.source = source
        window = ToolWindow(title: "\(source.title) Info", width: 440, parent: parent)
        header = box(.vertical, spacing: 4)
        owner = entry(placeholder: "user name or number")
        group = entry(placeholder: "group name or number")
        hint(owner, "Owner\nThe account that owns it (chown). Giving it to someone else needs Administrator mode.")
        hint(group, "Group\nThe group whose members get the Group permissions (chgrp).")
        accessibleLabel(owner, "Owner")
        accessibleLabel(group, "Group")
        octal = entry(placeholder: "755")
        gtk_editable_set_width_chars(c(octal), 6)
        gtk_widget_add_css_class(octal, "monospace-text")
        hint(octal, "Octal\nThe same permissions as chmod takes them, e.g. 644 or 755.")
        accessibleLabel(octal, "Octal permissions")
        symbolic = label("", classes: ["monospace-text", "dim-label"])
        recursive = check("Apply to enclosed items",
                          hint: "Apply to enclosed items\nAlso change everything inside the folder. Folders inside stay openable; links are left alone.")
        message = label("", classes: ["caption"], wrap: true)
        revert = gtk_button_new_with_label("Revert")!
        apply = gtk_button_new_with_label("Apply")!
        gtk_widget_add_css_class(apply, "suggested-action")
        hint(revert, "Revert\nGo back to the values on disk.")
        hint(apply, "Apply (Return)\nMake these changes.")
        spinner = gtk_spinner_new()!
        executeHeading = label("Execute", classes: ["caption", "dim-label"], xalign: 0.5)
        build()
    }

    private func build() {
        let content = box(.vertical, spacing: 14)
        margins(content, 20)
        append(content, header, separator())

        let ownership = grid(rowSpacing: 8, columnSpacing: 12)
        attach(ownership, label("Owner", classes: ["dim-label"]), column: 0, row: 0)
        attach(ownership, owner, column: 1, row: 0)
        attach(ownership, label("Group", classes: ["dim-label"]), column: 0, row: 1)
        attach(ownership, group, column: 1, row: 1)
        gtk_widget_set_hexpand(owner, 1)
        append(content, ownership)

        let table = grid(rowSpacing: 6, columnSpacing: 18)
        attach(table, label("Read", classes: ["caption", "dim-label"], xalign: 0.5), column: 1, row: 0)
        attach(table, label("Write", classes: ["caption", "dim-label"], xalign: 0.5), column: 2, row: 0)
        attach(table, executeHeading, column: 3, row: 0)
        for (row, (title, shift)) in [("Owner", UInt32(6)), ("Group", 3), ("Others", 0)].enumerated() {
            attach(table, label(title, classes: ["dim-label"]), column: 0, row: Int32(row + 1))
            for (column, value) in ([4, 2, 1] as [UInt32]).enumerated() {
                let bit = value << shift
                let toggle = check("") { [weak self] on in self?.setBit(bit, on) }
                accessibleLabel(toggle, "\(title) \(value == 4 ? "read" : value == 2 ? "write" : "execute")")
                gtk_widget_set_halign(toggle, GTK_ALIGN_CENTER)
                bits[bit] = toggle
                attach(table, toggle, column: Int32(column + 1), row: Int32(row + 1))
            }
        }
        append(content, table)
        let specials = box(.horizontal, spacing: 14)
        for (title, bit, help) in [("Set user ID", UInt32(0o4000), "Set user ID (setuid)\nA program runs with its owner's rights."),
                                   ("Set group ID", 0o2000, "Set group ID (setgid)\nA program runs with its group's rights; in a folder, new items get its group."),
                                   ("Sticky", 0o1000, "Sticky\nIn a folder, only an item's owner can rename or delete it, as in /tmp.")] {
            let toggle = check(title, hint: help) { [weak self] on in self?.setBit(bit, on) }
            bits[bit] = toggle
            append(specials, toggle)
        }
        append(content, specials)
        append(content, box(.horizontal, spacing: 8, [label("Octal", classes: ["dim-label"]), octal, symbolic]))
        append(content, recursive, message)
        let buttons = box(.horizontal, spacing: 8, [spinner, spacer(), revert, apply])
        append(content, buttons)
        append(window.content, content)

        on(octal, "changed") { [weak self] _ in
            guard let self, !self.updating else { return }
            let digits = text(of: self.octal).filter(\.isNumber)
            if let value = UInt32(digits, radix: 8), value <= 0o7777 { self.mode = value; self.refresh(octalToo: false) }
        }
        for field in [owner, group] { on(field, "changed") { [weak self] _ in self?.refreshButtons() } }
        on(recursive, "toggled") { [weak self] _ in self?.refreshButtons() }
        on(revert, "clicked") { [weak self] _ in Task { await self?.load() } }
        on(apply, "clicked") { [weak self] _ in Task { await self?.applyChanges() } }
        gtk_window_set_default_widget(c(window.window), apply)
    }

    private func setBit(_ bit: UInt32, _ on: Bool) {
        guard !updating else { return }
        if on { mode |= bit } else { mode &= ~bit }
        refresh(octalToo: true)
    }

    private var hasFolders: Bool { items.contains { $0.isFolder } }

    private var change: FileInfoChange {
        guard let original else { return FileInfoChange() }
        var change = FileInfoChange(recursive: isActive(recursive))
        if mode != original.mode { change.mode = mode }
        let ownerText = text(of: owner).trimmingCharacters(in: .whitespaces), groupText = text(of: group).trimmingCharacters(in: .whitespaces)
        if !ownerText.isEmpty, ownerText != original.owner { change.owner = ownerText }
        if !groupText.isEmpty, groupText != original.group { change.group = groupText }
        // A recursive change applies the current values all the way down even where the first item matches.
        if change.recursive, change.isEmpty, hasFolders { change.mode = mode }
        return change
    }

    private func refresh(octalToo: Bool) {
        updating = true
        for (bit, toggle) in bits { setActive(toggle, mode & bit != 0) }
        if octalToo {
            let digits = String(mode, radix: 8)
            setText(octal, digits.count >= 3 ? digits : String(repeating: "0", count: 3 - digits.count) + digits)
        }
        setLabel(symbolic, symbolicMode(mode))
        updating = false
        refreshButtons()
    }

    private func refreshButtons() {
        let empty = change.isEmpty
        enable(revert, !empty && !busy)
        enable(apply, !empty && !busy)
        if busy { gtk_spinner_start(c(spinner)) } else { gtk_spinner_stop(c(spinner)) }
    }

    private func load() async {
        busy = true
        refreshButtons()
        do {
            items = try await source.load()
            busy = false
            guard let first = items.first else { return }
            original = first
            mode = first.mode
            updating = true
            setText(owner, first.owner)
            setText(group, first.group)
            updating = false
            renderHeader()
            setVisible(recursive, hasFolders)
            setLabel(executeHeading, hasFolders && items.count == 1 ? "Open" : "Execute")
            refresh(octalToo: true)
        } catch {
            busy = false
            showMessage(error.localizedDescription, error: true)
            refreshButtons()
        }
    }

    private func renderHeader() {
        removeChildren(header)
        guard items.count == 1, let item = items.first else {
            append(header, label("\(items.count) items: changes apply to each of them."))
            return
        }
        let table = grid(rowSpacing: 4, columnSpacing: 12)
        var rows: [(String, String)] = [("Name", item.name), ("Where", item.location), ("Kind", item.isLink ? "Link" : item.isFolder ? "Folder" : "File")]
        if !item.isFolder, let size = item.size { rows.append(("Size", formatBytes(Int64(size)) + " (\(size) bytes)")) }
        if let modified = item.modified {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            rows.append(("Modified", formatter.string(from: modified)))
        }
        rows.append(("Permissions", symbolicMode(item.mode) + "  (" + String(item.mode, radix: 8) + ")"))
        for (index, row) in rows.enumerated() {
            attach(table, label(row.0, classes: ["dim-label"]), column: 0, row: Int32(index))
            attach(table, label(row.1, selectable: true, ellipsize: PANGO_ELLIPSIZE_MIDDLE), column: 1, row: Int32(index))
        }
        append(header, table)
    }

    private func applyChanges() async {
        let change = change
        guard !change.isEmpty else { return }
        busy = true
        refreshButtons()
        do {
            try await source.apply(change)
            showMessage("Changes applied.", error: false)
        } catch {
            showMessage(error.localizedDescription, error: true)
        }
        busy = false
        await load()
    }

    private func showMessage(_ text: String, error: Bool) {
        setLabel(message, text)
        if error { gtk_widget_add_css_class(message, "error-text") } else { gtk_widget_remove_css_class(message, "error-text") }
    }

    /// Feature tests: what the window shows.
    var bridgeState: [String: Any] {
        ["open": !closed, "title": "\(source.title) Info", "names": items.map(\.name), "folders": items.filter(\.isFolder).map(\.name),
         "location": items.first?.location ?? "", "size": items.first?.size.map { Int($0) as Any } ?? NSNull(), "modified": items.first?.modified != nil,
         "octal": text(of: octal), "symbolic": String(cString: gtk_label_get_text(c(symbolic))), "owner": text(of: owner), "group": text(of: group),
         "recursive": isActive(recursive), "hasFolders": hasFolders, "macFlags": false, "busy": busy,
         "message": String(cString: gtk_label_get_text(c(message))), "changed": !change.isEmpty]
    }

    /// Feature tests: edits the fields as a person would, then Apply, Revert, Close or neither.
    func bridge(_ request: [String: Any]) {
        if let value = request["octal"] as? String { setText(octal, value) }
        for bit in request["toggle"] as? [Int] ?? [] {
            if let toggle = bits[UInt32(bit)] { setActive(toggle, !isActive(toggle)) }
        }
        if let value = request["owner"] as? String { setText(owner, value) }
        if let value = request["group"] as? String { setText(group, value) }
        if let value = request["recursive"] as? Bool { setActive(recursive, value) }
        switch request["action"] as? String {
        case "apply": Task { await applyChanges() }
        case "revert": Task { await load() }
        case "close": closed = true; window.close()
        default: break
        }
    }
}
