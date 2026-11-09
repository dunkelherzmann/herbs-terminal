import CHerbUIA
import Foundation
import WinSDK

/// The drawn toolbar, tab strip and window buttons as UI Automation sees them: each one a control with the same
/// identifier as on the Mac and Linux (`toolbar.newTab`, …), the name and hover text its hint shows, its shortcut
/// and its place. Screen readers read them, and the parity check (`parity/`) compares them with the other versions.
extension WindowChrome {
    /// The tag of the location shown beside the title (the title itself uses `toolID(.title)`).
    static let subtitleTag = 14

    /// Sends the current items to UI Automation. Cheap when nothing changed: it runs on every layout.
    func updateAccessibility(owner: HWND, dpi: UINT, state: State) {
        typealias Entry = AccessibleItem
        var entries: [Entry] = []

        /// `name` fixes a control's name where its hover text changes with the state, as on the Mac and Linux.
        /// `toggle` and `selected` are the on/off state of a toggle button and the selected state of a tab, which
        /// screen readers announce.
        func add(_ item: Item, _ identifier: String, name: String? = nil, controlType: Int32 = Int32(HERB_UIA_BUTTON), popup: Bool = false,
                 toggle: Bool? = nil, selected: Bool? = nil) {
            guard let rect = rects[item] else { return }
            let parts = Self.hintParts(Self.hint(for: item, state: state) ?? "")
            entries.append(Entry(identifier: identifier, name: name ?? parts.name, help: parts.help, accelerator: parts.accelerator,
                                 rect: rect, controlType: controlType, enabled: !state.isUnavailable(item), popup: popup,
                                 tag: Int(Self.toolID(item)), toggle: toggle.map { $0 ? 1 : 0 } ?? -1, selected: selected.map { $0 ? 1 : 0 } ?? -1))
        }

        // In reading order: left to right along the toolbar, then the tab strip, then the window buttons.
        add(.menu, "toolbar.mainMenu", popup: true)
        add(.newTab, "toolbar.newTab")
        add(.connect, "toolbar.connect", name: state.connected == nil ? "Connect via SSH" : "Connection")
        add(.passwords, "toolbar.savedPasswords", name: "Saved Passwords", popup: true)
        if let parts = titleParts(dpi: dpi, state: state) {
            let help = Self.hintParts(Self.hint(for: .title, state: state) ?? "").help
            entries.append(Entry(identifier: "toolbar.title", name: state.title, help: help, accelerator: nil, rect: parts.title,
                                 controlType: Int32(HERB_UIA_TEXT), invokable: false, tag: Int(Self.toolID(.title))))
            if let subtitle = parts.subtitle {
                entries.append(Entry(identifier: "toolbar.title", name: state.subtitle, help: help, accelerator: nil, rect: subtitle,
                                     controlType: Int32(HERB_UIA_TEXT), invokable: false, tag: Self.subtitleTag))
            }
        }
        add(.export, "toolbar.exportSession")
        add(.screenshot, "toolbar.takeScreenshot")
        add(.explorer, "toolbar.switchView", name: "Switch Terminal / Explorer")
        add(.multiExec, "toolbar.multiExec", toggle: state.multiExecOn)
        add(.peers, "toolbar.tailcatPeers")
        add(.search, "toolbar.search", name: "Search")
        for index in state.tabNames.indices {
            add(.tab(index), "tabStrip.tab.\(index + 1)", controlType: Int32(HERB_UIA_TAB_ITEM), selected: index == state.active)
            add(.tabClose(index), "tabStrip.close.\(index + 1)")
        }
        for (item, identifier, name) in [(Item.minimize, "window.minimize", "Minimize"),
                                         (.maximize, "window.maximize", state.maximized ? "Restore" : "Maximize"),
                                         (.close, "window.close", "Close")] {
            guard let rect = rects[item] else { continue }
            entries.append(Entry(identifier: identifier, name: name, help: nil, accelerator: nil, rect: rect,
                                 controlType: Int32(HERB_UIA_BUTTON), tag: Int(Self.toolID(item))))
        }

        AccessibleItem.publish(entries, owner: owner)
    }

    /// The item an assistive tool pressed, from its tag.
    func item(forTag tag: Int) -> Item? {
        rects.keys.first { Int(Self.toolID($0)) == tag }
    }

    /// A hint's first line is the control's name and shortcut ("New Tab (Ctrl+Shift+T)"); the rest is what it does.
    static func hintParts(_ hint: String) -> (name: String, help: String?, accelerator: String?) {
        let lines = hint.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var name = lines.first ?? ""
        var accelerator: String?
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            let inside = String(name[open.upperBound..<name.index(before: name.endIndex)])
            if inside.hasPrefix("Ctrl") || inside.hasPrefix("Alt") || inside.hasPrefix("Shift") || inside.hasPrefix("F") {
                accelerator = inside
                name = String(name[..<open.lowerBound])
            }
        }
        let help = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        return (name, help, accelerator)
    }
}
