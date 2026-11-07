import CGtk
import CHerb
import Foundation

/// The window's toolbar, laid out as on the Mac but with the window controls (minimize, maximize, close) on the
/// right, as Linux and Windows place them, and the Main Menu taking the left corner the Mac's traffic lights use.
@MainActor
final class SessionToolbar {
    let header: Widget
    weak var workspace: Workspace?
    private let menuButton: Widget
    private let connect: Widget
    private let explorer: Widget
    private let multiExec: Widget
    private let search: Widget
    private let screenshot: Widget
    private var confirmation: Widget?
    private let titleLabel: Widget
    private let subtitleLabel: Widget
    private let titleBox: Widget

    init() {
        header = adw_header_bar_new()!
        gtk_widget_add_css_class(header, "session-toolbar")
        adw_header_bar_set_decoration_layout(c(header), ":minimize,maximize,close")

        menuButton = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(c(menuButton), "ht-menu-symbolic")
        gtk_widget_add_css_class(menuButton, "glyph")
        gtk_widget_set_focus_on_click(menuButton, 0)
        hint(menuButton, "Main Menu\nTabs, windows, zoom, themes, appearance and settings.")
        accessibleLabel(menuButton, "Main Menu")

        var weakSelf: SessionToolbar?
        func glyph(_ icon: String, _ name: String, _ action: @escaping @MainActor (Workspace) -> Void) -> Widget {
            let widget = gtk_button_new_from_icon_name(icon)!
            gtk_widget_add_css_class(widget, "glyph")
            gtk_widget_add_css_class(widget, "flat")
            // Like the Mac's toolbar buttons, they never take the keyboard focus from the terminal.
            gtk_widget_set_focus_on_click(widget, 0)
            accessibleLabel(widget, name)
            on(widget, "clicked") { _ in if let workspace = weakSelf?.workspace { action(workspace) } }
            return widget
        }
        let newTab = glyph("ht-tab-new-symbolic", "New Tab") { $0.add() }
        hint(newTab, "New Tab (Ctrl+Shift+T)\nOpen another local terminal in this window.")
        connect = glyph("ht-network-symbolic", "Connect via SSH") { $0.connectButton() }
        let export = glyph("ht-share-symbolic", "Export Session") { $0.exportSession() }
        hint(export, "Export Session (Ctrl+Shift+S)\nSave everything in this terminal, scrollback included, to a text file.")
        screenshot = glyph("ht-camera-symbolic", "Take Screenshot") { $0.takeScreenshot() }
        hint(screenshot, "Take Screenshot (Ctrl+Alt+S)\nCopy a picture of this whole window to the clipboard, ready to paste.")
        explorer = glyph("ht-folder-symbolic", "Switch Terminal / Explorer") { workspace in
            workspace.setLayout(workspace.selected.state.layout == .explorer ? .terminal : .explorer)
        }
        multiExec = glyph("ht-layers-symbolic", "MultiExec") { $0.setMultiExec(!$0.multiExec) }
        let peers = glyph("ht-peers-symbolic", "Tailcat Peers") { TailcatWindow.show($0) }
        hint(peers, "Tailcat Peers\nPair with machines that can't reach each other by IP, and connect through Tailcat.")
        search = glyph("ht-search-symbolic", "Search") { $0.find() }

        let left = box(.horizontal, spacing: 4, [menuButton, newTab, connect])
        adw_header_bar_pack_start(c(header), left)
        // One group, so Search sits the same 4 px from Tailcat Peers as the other buttons from each other.
        let right = box(.horizontal, spacing: 4, [export, screenshot, explorer, multiExec, peers, search])
        adw_header_bar_pack_end(c(header), right)

        titleLabel = label("", classes: ["session-title"], ellipsize: PANGO_ELLIPSIZE_MIDDLE)
        subtitleLabel = label("", classes: ["session-subtitle"], ellipsize: PANGO_ELLIPSIZE_MIDDLE)
        // Long titles (a command line in the foreground) shorten in the middle rather than push the buttons away.
        gtk_label_set_max_width_chars(c(titleLabel), 60)
        gtk_label_set_max_width_chars(c(subtitleLabel), 30)
        titleBox = box(.horizontal, spacing: 5, [titleLabel, subtitleLabel])
        gtk_widget_set_valign(titleBox, GTK_ALIGN_CENTER)
        gtk_box_set_baseline_position(c(titleBox), GTK_BASELINE_POSITION_CENTER)
        gtk_widget_set_valign(titleLabel, GTK_ALIGN_BASELINE_FILL)
        gtk_widget_set_valign(subtitleLabel, GTK_ALIGN_BASELINE_FILL)
        adw_header_bar_set_title_widget(c(header), titleBox)
        weakSelf = self

        // Double-click the title: default size and zoom. Right-click: make the current size the default. The title
        // claims the clicks, so they don't maximize the window the way the rest of the toolbar does.
        let clicks = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(c(clicks), 0)
        on(clicks, "pressed") { [weak self] args in
            guard let self, let workspace = self.workspace else { return }
            let button = gtk_gesture_single_get_current_button(c(clicks))
            gtk_gesture_set_state(c(clicks), GTK_EVENT_SEQUENCE_CLAIMED)
            if button == 3 {
                let menu = MenuBuilder()
                menu.item("Restore Default Size", "win.restore-size")
                menu.item("Make Current Size the Default", "win.default-size")
                popUp(menu.finish(), on: self.titleBox, x: args.double(2), y: args.double(3))
            } else if args.int(1) == 2 {
                workspace.restoreDefaultSize()
            }
        }
        gtk_widget_add_controller(titleBox, c(clicks))
    }

    /// A short bubble under the Take Screenshot button, as on the Mac, which hides itself; screen readers announce it.
    func confirm(_ text: String) {
        if let confirmation { gtk_popover_popdown(c(confirmation)); gtk_widget_unparent(confirmation) }
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let content = box(.vertical, spacing: 2, [label(lines[0], classes: ["heading"])] + lines.dropFirst().map { label($0, classes: ["dim-label"]) })
        let popover = gtk_popover_new()!
        gtk_popover_set_child(c(popover), content)
        gtk_popover_set_autohide(c(popover), 0)
        gtk_widget_set_parent(popover, screenshot)
        gtk_popover_popup(c(popover))
        confirmation = popover
        gtk_accessible_announce(c(screenshot), lines.joined(separator: ". "), GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM)
        _ = after(milliseconds: 1500) { [weak self] in
            guard let self, self.confirmation == popover else { return }
            gtk_popover_popdown(c(popover))
            gtk_widget_unparent(popover)
            self.confirmation = nil
        }
    }

    func setMenu(_ model: OpaquePointer) {
        gtk_menu_button_set_menu_model(c(menuButton), c(model))
    }

    /// Follows the selected tab: its title and location, whether it's connected, and which layout it shows.
    func update() {
        guard let workspace else { return }
        let tab = workspace.selected
        let title = tab.editor.map { $0.source.name } ?? tab.shell.title
        let subtitle = tab.editor.map { $0.source.location } ?? tab.shell.subtitle
        setLabel(titleLabel, title)
        setLabel(subtitleLabel, subtitle)
        setVisible(subtitleLabel, !subtitle.isEmpty)
        hint(titleBox, [title, subtitle].joined(separator: " ")
             + "\nDouble-click to return the window and text to their default size; right-click to make the current size the default.")
        gtk_window_set_title(c(workspace.window), title)

        if case .connected(let endpoint) = tab.state.connection {
            gtk_button_set_icon_name(c(connect), "ht-network-connected-symbolic")
            gtk_widget_add_css_class(connect, "active")
            hint(connect, "Connected to \(endpoint.label)\nShow connection details, disconnect, or open a new connection (Ctrl+Shift+K).")
            accessibleLabel(connect, "Connection")
        } else {
            gtk_button_set_icon_name(c(connect), "ht-network-symbolic")
            gtk_widget_remove_css_class(connect, "active")
            hint(connect, "Connect via SSH (Ctrl+Shift+K)\nOpen a remote shell with a saved or new login; the explorer follows that host.")
            accessibleLabel(connect, "Connect via SSH")
        }
        let explorerShowing = tab.state.layout == .explorer
        gtk_button_set_icon_name(c(explorer), explorerShowing ? "ht-terminal-symbolic" : "ht-folder-symbolic")
        hint(explorer, explorerShowing ? "Show Terminal (Ctrl+Shift+X)\nReplace the file explorer with this tab's shell."
                                       : "Show File Explorer (Ctrl+Shift+X)\nBrowse files on the host this tab is connected to.")
        enable(explorer, tab.editor == nil)
        if workspace.multiExec { gtk_widget_add_css_class(multiExec, "active") } else { gtk_widget_remove_css_class(multiExec, "active") }
        accessiblePressed(multiExec, workspace.multiExec)
        hint(multiExec, workspace.multiExec ? "Exit MultiExec (Ctrl+Shift+M)\nBack to one tab at a time; typing goes to the current tab only."
                                            : "MultiExec (Ctrl+Shift+M)\nShow every tab side by side and type into all of them at once.")
        hint(search, explorerShowing ? "Find Files (Ctrl+Shift+F)\nFilter this folder by name."
                                     : "Search Terminal (Ctrl+Shift+F)\nFind text in this tab's scrollback.")
    }
}

/// One tab in the tab strip: click to switch, double-click to rename, drag to reorder.
@MainActor
enum TabChip {
    static func build(_ tab: TerminalTab, in workspace: Workspace, selected: Bool) -> Widget {
        let title = label(tab.title, classes: ["tab-title"], ellipsize: PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(c(title), 28)
        let select = gtk_button_new()!
        gtk_button_set_child(c(select), title)
        gtk_widget_add_css_class(select, "flat")
        gtk_widget_set_focus_on_click(select, 0)
        accessibleLabel(select, tab.title)
        accessibleSelected(select, selected)
        hint(select, "\(tab.title)\nClick to switch, double-click to rename, drag to reorder.")
        on(select, "clicked") { [weak workspace, weak tab] _ in if let workspace, let tab { workspace.select(tab) } }
        onClick(select, capture: true) { [weak workspace, weak tab] count, _, _ in
            if count == 2, let workspace, let tab { workspace.rename(tab) }
        }
        let close = iconButton("window-close-symbolic", label: "Close \(tab.title)",
                               hint: "Close \(tab.title)\nEnd this tab's shell and release its resources.") { [weak workspace, weak tab] in
            if let workspace, let tab { workspace.close(tab) }
        }
        gtk_widget_set_focus_on_click(close, 0)
        let chip = box(.horizontal, spacing: 2, [select, close], classes: selected ? ["tab-chip", "selected"] : ["tab-chip"])
        onClick(chip, button: 3) { [weak tab] _, x, y in
            guard let tab else { return }
            let menu = MenuBuilder()
            menu.item("Rename Tab…", "win.rename-tab-id", target: tab.id.uuidString)
            menu.item("Move Tab Left", "win.move-tab-left-id", target: tab.id.uuidString)
            menu.item("Move Tab Right", "win.move-tab-right-id", target: tab.id.uuidString)
            menu.divider()
            menu.item("Close Tab", "win.close-tab-id", target: tab.id.uuidString)
            popUp(menu.finish(), on: chip, x: x, y: y)
        }
        // Drag a chip onto another to put it there.
        let drag = gtk_drag_source_new()!
        on(drag, "prepare") { args in
            var value = GValue()
            g_value_init(&value, herb_type_string())
            g_value_set_string(&value, tab.id.uuidString)
            let provider = gdk_content_provider_new_for_value(&value)
            g_value_unset(&value)
            herb_return_pointer(args.result, provider)
        }
        gtk_widget_add_controller(chip, c(drag))
        let drop = gtk_drop_target_new(herb_type_string(), GDK_ACTION_MOVE)!
        on(drop, "drop") { [weak workspace, weak tab] args in
            guard let workspace, let tab, let value = args.value(1), let id = takeString(herb_drop_paths(value)),
                  let moved = workspace.tabs.first(where: { $0.id.uuidString == id }),
                  let index = workspace.tabs.firstIndex(where: { $0 === tab }) else { args.returns(false); return }
            workspace.move(moved, to: index)
            args.returns(true)
        }
        gtk_widget_add_controller(chip, c(drop))
        return chip
    }
}

/// MultiExec, after MobaXterm's: every tab as a live terminal in a grid, each with a caption bar. Typing in an
/// included terminal goes to every included terminal; uncheck a caption's box to leave that tab out.
@MainActor
final class MultiExecGrid {
    let view: Widget
    private weak var workspace: Workspace?
    private let status: Widget
    private let includeAll: Widget
    private var cells: [(tab: TerminalTab, pane: TerminalPane, cell: Widget, include: Widget)] = []

    init(_ workspace: Workspace) {
        self.workspace = workspace
        let bar = box(.horizontal, spacing: 10, classes: ["multiexec-bar"])
        status = label("")
        setAttributes(status, weight: 600)
        includeAll = button("Include All", hint: "Include All\nSend typing to every terminal again.") { [weak workspace] in workspace?.includeAll() }
        append(bar, image("ht-layers-symbolic", classes: ["warning"]), status, spacer(),
               button("New Tab", hint: "New Tab\nAdd a local terminal to the grid; it's included in MultiExec.") { [weak workspace] in workspace?.add() },
               button("Connect via SSH…", hint: "Connect via SSH\nOpen a session to another host in a new tab of the grid.") { [weak workspace] in workspace?.showConnect() },
               includeAll,
               button("Close All", hint: "Close All\nEnd every terminal in the grid and leave MultiExec with one new terminal.") { [weak workspace] in workspace?.closeAllTerminals() },
               button("Exit MultiExec", hint: "Exit MultiExec (Esc)\nBack to one tab at a time.") { [weak workspace] in workspace?.setMultiExec(false) })

        let entries = workspace.tabs.flatMap { tab in tab.panes.map { (tab, $0) } }
        let columns = max(1, Int(Double(entries.count).squareRoot().rounded(.up)))
        let gridWidget = gtk_grid_new()!
        gtk_grid_set_row_spacing(c(gridWidget), 6)
        gtk_grid_set_column_spacing(c(gridWidget), 6)
        gtk_grid_set_row_homogeneous(c(gridWidget), 1)
        gtk_grid_set_column_homogeneous(c(gridWidget), 1)
        margins(gridWidget, 6)
        gtk_widget_set_vexpand(gridWidget, 1)
        for (index, (tab, pane)) in entries.enumerated() {
            unparent(pane.view)
            let caption = box(.horizontal, spacing: 6, classes: ["multiexec-caption"])
            let title = Self.paneTitle(tab, pane)
            let include = check("") { [weak workspace] on in workspace?.setIncluded(pane, on) }
            accessibleLabel(include, "Include \(index + 1). \(title) in MultiExec")
            let remote: Bool = { if pane === tab.shell, case .connected = tab.state.connection { true } else { false } }()
            append(caption, include, image(remote ? "ht-network-symbolic" : "ht-terminal-symbolic", pixels: 12, classes: ["dim-label"]),
                   label("\(index + 1). \(title)", ellipsize: PANGO_ELLIPSIZE_MIDDLE))
            let cell = box(.vertical, [pane.view, caption], classes: ["multiexec-cell"])
            gtk_widget_set_hexpand(cell, 1)
            gtk_widget_set_vexpand(cell, 1)
            gtk_widget_set_overflow(cell, GTK_OVERFLOW_HIDDEN)
            gtk_grid_attach(c(gridWidget), cell, Int32(index % columns), Int32(index / columns), 1, 1)
            cells.append((tab, pane, cell, include))
        }
        view = box(.vertical, [bar, gridWidget])
        let keys = LocalShortcuts(view)
        keys.add("Escape") { [weak workspace] in workspace?.setMultiExec(false) }
        update()
    }

    /// Who is included and which terminal is active, without moving any terminal.
    func update() {
        guard let workspace else { return }
        let all = workspace.allPanes.count
        setLabel(status, "MultiExec: typing goes to \(workspace.multiExecTargets.count) of \(all) terminal\(all == 1 ? "" : "s")")
        enable(includeAll, !workspace.excludedFromMultiExec.isEmpty)
        for entry in cells {
            let included = !workspace.excludedFromMultiExec.contains(entry.pane.id)
            let focused = entry.tab === workspace.selected && entry.tab.focused === entry.pane
            if isActive(entry.include) != included { setActive(entry.include, included) }
            hint(entry.include, included ? "Included\nTyping in MultiExec goes to this terminal. Uncheck to leave it out."
                                         : "Left out\nThis terminal only takes what you type into it. Check to include it.")
            if included { gtk_widget_add_css_class(entry.cell, "included") } else { gtk_widget_remove_css_class(entry.cell, "included") }
            if focused { gtk_widget_add_css_class(entry.cell, "focused") } else { gtk_widget_remove_css_class(entry.cell, "focused") }
        }
    }

    /// The tab's name, plus the pane's position when the tab is split.
    private static func paneTitle(_ tab: TerminalTab, _ pane: TerminalPane) -> String {
        let base = tab.customTitle ?? pane.title
        let panes = tab.panes
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === pane }) else { return base }
        return "\(base) (pane \(index + 1))"
    }
}

/// Shown by the SSH button while the tab is connected.
@MainActor
enum ConnectionDetails {
    static func show(_ workspace: Workspace) {
        let tab = workspace.selected
        guard case .connected(let endpoint) = tab.state.connection else { return }
        let table = grid(rowSpacing: 6, columnSpacing: 12)
        var rows: [(String, String)] = [
            ("Account", endpoint.username),
            ("Host", endpoint.proxyCommand == nil ? endpoint.host : endpoint.host.replacingOccurrences(of: "tailcat-", with: "")),
            ("Port", String(endpoint.port)),
            ("Route", endpoint.proxyCommand == nil ? "Direct SSH" : "Tailcat peer"),
            ("Remote home", tab.state.remoteHome),
        ]
        if let since = tab.state.connectedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            rows.append(("Connected", formatter.string(from: since) + (minutes < 1 ? " (just now)" : " (\(minutes) min ago)")))
        }
        rows.append(("Explorer", "Following this host over the shared SSH connection"))
        for (index, row) in rows.enumerated() {
            attach(table, label(row.0, classes: ["dim-label"]), column: 0, row: Int32(index))
            attach(table, label(row.1, wrap: true, selectable: true), column: 1, row: Int32(index))
        }
        Task {
            let answer = await Dialogs.ask(workspace.window, "Connection", choices: [
                .init("new", "New Connection…"), .init("close", "Close"), .init("disconnect", "Disconnect", .destructive),
            ], defaultID: "disconnect", cancel: "close", extra: table)
            switch answer {
            case "disconnect": workspace.disconnect()
            case "new": workspace.showConnect()
            default: break
            }
        }
    }
}
