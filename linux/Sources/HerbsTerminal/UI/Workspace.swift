import CGtk
import CHerb
import Foundation

enum SessionLayout: String {
    case terminal, explorer
}

enum SessionEndpoint: Equatable {
    case local
    case remote(RemoteEndpoint)
}

/// What the tab's shell is actually connected to, as verified through the shared SSH connection.
enum ConnectionState: Equatable {
    case local
    case connecting(RemoteEndpoint)
    case connected(RemoteEndpoint)
    case failed(String)
}

/// One tab's explorer and connection state.
@MainActor
final class TabState {
    var layout = SessionLayout.terminal
    var directory = FileManager.default.homeDirectoryForCurrentUser
    var endpoint: SessionEndpoint = .local
    var connection: ConnectionState = .local
    var connectedAt: Date?
    var remoteHome = "/"
    var localHistory = NavigationHistory(FileManager.default.homeDirectoryForCurrentUser.path)
    var remoteDirectory = "/"
    var remoteHistory = NavigationHistory("/")
    let localLog = FileOperationLog()
    var remoteModel: RemoteExplorerModel?
    /// Administrator mode: the explorer's root session, where it runs, and its own location.
    var adminModel: RemoteExplorerModel?
    var adminTarget: PrivilegedAccess.Target?
    var adminPath = "/"
    var adminHistory = NavigationHistory("/")
}

@MainActor
final class TerminalTab {
    let id = UUID()
    /// "Terminal 2": the lowest free number when it opened; 1 again once it's the only terminal tab left.
    var number: Int
    let state = TabState()
    /// The tab's first pane: its SSH connection, the explorer and the title follow this shell. If it is closed while
    /// other panes remain, the next pane takes over.
    private(set) var shell: TerminalPane
    let root: PaneNode
    /// The pane that has keyboard focus; zoom, Clear, Reset and Find act on it.
    var focused: TerminalPane
    var monitor: Task<Void, Never>?
    var typedSSHWatch: Task<Void, Never>?
    var customTitle: String?
    /// A text editor tab shows a file instead of a shell; its shell is never started.
    let editor: TextEditor?
    /// The explorer's widgets, made when the tab first shows its explorer.
    var explorer: ExplorerHost?

    var title: String {
        if let editor { return (editor.isEdited ? "• " : "") + editor.source.name }
        return customTitle ?? "Terminal \(number)"
    }
    /// The tab's terminal panes; none for an editor tab.
    var panes: [TerminalPane] { editor == nil ? root.leaves : [] }

    init(number: Int, directory: String? = nil, profile: UUID? = nil, panes: SavedPane? = nil, editor: TextEditor? = nil) {
        self.number = number
        self.editor = editor
        let main = TerminalPane(profileID: profile)
        if let directory { main.startDirectory = directory }
        shell = main
        focused = main
        if let panes, panes.children?.isEmpty == false {
            var first: TerminalPane? = main
            root = PaneNode.restore(panes, first: &first, profile: profile)
        } else {
            root = PaneNode(pane: main)
        }
    }

    func promote(_ next: TerminalPane) { shell = next }
}

/// One window: its tabs, the toolbar, MultiExec, and following the shell's SSH connections.
@MainActor
final class Workspace {
    private(set) var tabs: [TerminalTab] = []
    private(set) var selected: TerminalTab
    let multiHost = MultiHostModel()

    let window: Widget
    private let toolbar: SessionToolbar
    private let tabStrip: Widget
    private let tabStripBox: Widget
    private let content: Widget
    private var actions: [String: OpaquePointer] = [:]
    private var tokens: [ObservationToken] = []
    private var paneTokens: [UUID: ObservationToken] = [:]
    private var closing = false
    private var sized = false

    private static var registry: [Workspace] = []
    static var all: [Workspace] { registry }

    /// MultiExec, like MobaXterm's: every pane of every tab in a grid, and what you type in an included pane goes to
    /// all included panes.
    private(set) var multiExec = false
    private(set) var excludedFromMultiExec: Set<UUID> = []

    var allPanes: [TerminalPane] { tabs.flatMap(\.panes) }
    var multiExecTargets: [TerminalPane] { allPanes.filter { !excludedFromMultiExec.contains($0.id) } }

    /// The lowest number no open tab uses, so closing tabs frees their numbers again.
    private var nextNumber: Int {
        let used = Set(tabs.filter { $0.editor == nil }.map(\.number))
        return (1...).first { !used.contains($0) }!
    }

    /// The default profile's start folder, where a new window's first tab starts; nil when it has none.
    private static var defaultProfileFolder: String? {
        let profile = TerminalProfile.shared
        let folder = profile.settings(for: profile.defaultProfileID).startDirectory
        return folder.isEmpty ? nil : (folder as NSString).expandingTildeInPath
    }

    init(restoring saved: SavedWindow? = nil) {
        let restored = (saved?.tabs ?? []).enumerated().map { index, tab -> TerminalTab in
            let item = TerminalTab(number: index + 1,
                                   directory: FileManager.default.fileExists(atPath: tab.directory) ? tab.directory : nil,
                                   profile: tab.profile.flatMap(UUID.init(uuidString:)), panes: tab.panes)
            item.customTitle = tab.title
            item.state.layout = SessionLayout(rawValue: tab.layout) ?? .terminal
            if FileManager.default.fileExists(atPath: tab.explorerPath) {
                item.state.directory = URL(fileURLWithPath: tab.explorerPath, isDirectory: true)
                item.state.localHistory = NavigationHistory(tab.explorerPath)
            }
            return item
        }
        let all = restored.isEmpty ? [TerminalTab(number: 1, directory: Self.defaultProfileFolder)] : restored
        tabs = all
        selected = all[min(max(saved?.selected ?? 0, 0), all.count - 1)]

        window = adw_application_window_new(c(App.shared.application))!
        gtk_window_set_title(c(window), "Herb's Terminal")
        gtk_widget_set_size_request(window, 640, 360)
        toolbar = SessionToolbar()
        tabStripBox = box(.horizontal, spacing: 6)
        tabStrip = box(.horizontal, [scrolled(tabStripBox, horizontal: true, vertical: false)], classes: ["tab-strip"])
        gtk_widget_set_vexpand(gtk_widget_get_first_child(tabStrip), 0)
        content = box(.vertical)
        gtk_widget_set_vexpand(content, 1)
        let body = box(.vertical, [tabStrip, content])
        let view = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(c(view), toolbar.header)
        adw_toolbar_view_set_content(c(view), body)
        adw_toolbar_view_set_top_bar_style(c(view), ADW_TOOLBAR_FLAT)
        adw_application_window_set_content(c(window), view)

        Self.registry.append(self)
        toolbar.workspace = self
        installActions()
        // The window's shortcuts run before the focused widget sees the key, as in Ptyxis: otherwise the terminal
        // would type Ctrl+Shift+T and friends into the shell instead.
        let keys = LocalShortcuts(window, capture: true)
        gtk_shortcut_controller_set_scope(c(keys.controller), GTK_SHORTCUT_SCOPE_GLOBAL)
        for (action, triggers) in Self.accelerators where action.hasPrefix("win.") {
            let name = String(action.dropFirst(4))
            keys.add(triggers.joined(separator: "|")) { [weak self] in
                guard let self else { return }
                g_action_group_activate_action(c(self.window), name, nil)
            }
        }
        all.forEach(configure)
        tokens.append(TerminalProfile.shared.objectWillChange.observe { [weak self] in self?.profilesChanged() })
        tokens.append(ThemeLibrary.shared.objectWillChange.observe { [weak self] in self?.allPanes.forEach { $0.applyColors() }; self?.updateMenu() })
        on(window, "close-request") { [weak self] args in
            guard let self else { args.returns(false); return }
            args.returns(!self.requestClose())
        }
        on(window, "destroy") { [weak self] _ in self?.destroyed() }
        // The toolbar's title follows the selected tab's shell.
        every(milliseconds: 1000) { [weak self] in
            guard let self else { return false }
            if self.selected.editor == nil { self.selected.shell.refresh() }
            return true
        }
        render()
    }

    func present() {
        gtk_window_present(c(window))
        sizeToDefault()
    }

    // MARK: Tabs

    /// Opens a tab with `profile` (default: the current tab's): in the profile's start folder when it has one, else
    /// in the current tab's folder when that's a local shell and Settings asks for it.
    func add(profile: UUID? = nil) {
        let profileID = profile ?? selected.shell.profileID
        let settings = TerminalProfile.shared.settings(for: profileID)
        var directory: String?
        if !settings.startDirectory.isEmpty {
            directory = (settings.startDirectory as NSString).expandingTildeInPath
        } else if TerminalProfile.shared.newTabsInSameFolder, case .local = selected.state.connection, selected.editor == nil {
            directory = selected.shell.currentDirectory
        }
        let tab = TerminalTab(number: nextNumber, directory: directory, profile: profileID)
        tabs.append(tab)
        selected = tab
        configure(tab)
        updateBroadcast()
        render()
        focusSelected()
    }

    /// Opens `source` in an editor tab of the active window, or selects the tab already showing it.
    static func openEditor(_ source: TextFileSource) {
        let active = App.shared.application.flatMap { gtk_application_get_active_window(c($0)) }.map { w($0) }
        let workspace = all.first { $0.window == active } ?? all.first
        workspace?.openEditor(source)
    }

    func openEditor(_ source: TextFileSource) {
        if let open = tabs.first(where: { $0.editor?.source.location == source.location }) {
            select(open)
            return
        }
        let editor = TextEditor(source: source)
        let tab = TerminalTab(number: 0, editor: editor)
        editor.onFailure = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.remove(tab)
        }
        editor.onChange = { [weak self] in self?.render(toolbarOnly: false) }
        editor.window = window
        if let index = tabs.firstIndex(where: { $0 === selected }) { tabs.insert(tab, at: index + 1) } else { tabs.append(tab) }
        selected = tab
        render()
        Task { await editor.load() }
    }

    func select(_ tab: TerminalTab) {
        selected = tab
        render()
        focusSelected()
    }

    private func focusSelected() {
        let tab = selected
        idle {
            if let editor = tab.editor { editor.focus() }
            else if tab.state.layout == .terminal { tab.focused.focus() }
        }
    }

    /// Alt+1–Alt+9: the tab at that position; 9 is the last tab. In MultiExec the numbers are the grid's.
    func selectTab(number index: Int) {
        if multiExec {
            let cells = tabs.flatMap { tab in tab.panes.map { (tab, $0) } }
            guard !cells.isEmpty else { return }
            let target = index == 8 ? cells.count - 1 : index
            guard cells.indices.contains(target) else { return }
            selected = cells[target].0
            cells[target].0.focused = cells[target].1
            render()
            cells[target].1.focus()
            return
        }
        let target = index == 8 ? tabs.count - 1 : index
        guard tabs.indices.contains(target) else { return }
        select(tabs[target])
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === selected }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Moves `tab` to `index` in the tab strip (drag to reorder, Move Tab Left/Right).
    func move(_ tab: TerminalTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let target = max(0, min(tabs.count - 1, index))
        guard target != from else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: target)
        render()
    }

    func moveSelected(by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === selected }) else { return }
        move(selected, to: index + offset)
    }

    /// Terminal's Edit Title: an empty name goes back to the numbered title.
    func rename(_ tab: TerminalTab) {
        guard tab.editor == nil else { return }
        Task {
            guard let values = await Dialogs.prompt(window, "Rename Tab", "Leave empty to use the numbered name.",
                                                    fields: [Dialogs.Field(label: "Tab name", initial: tab.customTitle ?? "",
                                                                           placeholder: "Terminal \(tab.number)")],
                                                    ok: "Rename") else { return }
            let name = values[0].trimmingCharacters(in: .whitespaces)
            tab.customTitle = name.isEmpty ? nil : name
            render()
        }
    }

    func close(_ tab: TerminalTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else { gtk_window_close(c(window)); return }
        Task {
            if let editor = tab.editor {
                guard await editor.confirmClose() else { return }
            } else {
                guard await Self.confirmClosing([tab], parent: window) else { return }
            }
            remove(tab)
        }
    }

    /// Takes `tab` out of the window and ends its shells; asks nothing.
    private func remove(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else { closeWithoutAsking(); return }
        if selected === tab { selected = tabs[index == 0 ? 1 : index - 1] }
        tabs.remove(at: index)
        // The only terminal tab left becomes Terminal 1 again (a renamed tab keeps its name).
        let terminals = tabs.filter { $0.editor == nil }
        if terminals.count == 1, terminals[0].number != 1 { terminals[0].number = 1; render() }
        tab.monitor?.cancel()
        tab.typedSSHWatch?.cancel()
        for pane in tab.panes {
            excludedFromMultiExec.remove(pane.id)
            pane.broadcast = nil
            pane.close()
            paneTokens[pane.id] = nil
        }
        updateBroadcast()
        if multiExec, allPanes.isEmpty { multiExec = false }
        render()
        focusSelected()
    }

    // MARK: Panes

    /// A pane's right-click menu, focus tracking, and closing it when its shell exits.
    private func configure(_ tab: TerminalTab) {
        guard tab.editor == nil else { return }
        watchTypedSSH(tab)
        tab.panes.forEach { configurePane($0, in: tab) }
    }

    private func configurePane(_ pane: TerminalPane, in tab: TerminalTab) {
        pane.onFocus = { [weak self, weak tab, weak pane] in
            guard let self, let tab, let pane else { return }
            let changedTab = self.selected !== tab
            guard changedTab || tab.focused !== pane else { return }
            self.selected = tab
            tab.focused = pane
            self.render(keepContent: !self.multiExec && !changedTab)
        }
        pane.onResize = { [weak self] in self?.sizeToDefaultOnce() }
        // Typing `exit` closes the pane, the tab when it was the tab's last pane, and the window when it was the
        // last terminal. An ssh session ends on its own and leaves the local shell running.
        pane.onExit = { [weak self, weak tab, weak pane] in
            guard let self, let tab, let pane else { return }
            self.shellExited(pane, in: tab)
        }
        pane.extraMenu = { [weak self, weak tab] menu in
            guard let self, let tab else { return }
            menu.item("Split Vertically", "win.split-vertical")
            menu.item("Split Horizontally", "win.split-horizontal")
            if tab.panes.count > 1 { menu.item("Close Pane", "win.close-pane") }
            menu.divider()
            menu.item("New Tab", "win.new-tab")
            menu.item("Show File Explorer", "win.show-explorer")
            menu.divider()
            if case .connected(let endpoint) = tab.state.connection {
                menu.item("Disconnect from \(endpoint.label)", "win.disconnect")
            }
            menu.item("Connect via SSH…", "win.connect")
            menu.divider()
            menu.item("Bigger", "win.zoom-in")
            menu.item("Smaller", "win.zoom-out")
            menu.item("Settings…", "app.settings")
            _ = self
        }
        paneTokens[pane.id] = pane.changed.observe { [weak self, weak pane] in
            guard let self, let pane else { return }
            if self.selected.panes.contains(where: { $0 === pane }) || self.multiExec { self.render(toolbarOnly: true) }
        }
        pane.start()
    }

    func shellExited(_ pane: TerminalPane, in tab: TerminalTab) {
        // Shells the app closed itself report their exit too; only a shell still showing counts.
        guard tabs.contains(where: { $0 === tab }), tab.panes.contains(where: { $0 === pane }) else { return }
        if tab.panes.count > 1 {
            closePane(pane, in: tab, confirm: false)
        } else if tabs.count > 1 {
            remove(tab)
        } else if Self.registry.count == 1 {
            // `exit` in the app's last terminal quits Herb's Terminal, Settings and other windows included.
            App.shared.quit()
        } else {
            closeWithoutAsking()
        }
    }

    /// Splits the focused pane of the selected tab. The new pane gets the same profile and, per Settings, the same
    /// folder.
    func split(_ axis: PaneNode.Axis) {
        let tab = selected
        guard tab.editor == nil else { return }
        let source = tab.focused
        guard let leaf = tab.root.leaf(for: source) else { return }
        let pane = TerminalPane(profileID: source.profileID)
        if TerminalProfile.shared.newTabsInSameFolder, let folder = source.currentDirectory { pane.startDirectory = folder }
        leaf.split(axis, adding: PaneNode(pane: pane))
        configurePane(pane, in: tab)
        tab.focused = pane
        tab.state.layout = .terminal
        updateBroadcast()
        render()
        idle { pane.focus() }
    }

    /// Closes one pane; the last pane closes the tab instead.
    func closePane(_ pane: TerminalPane? = nil, in tab: TerminalTab? = nil, confirm: Bool = true) {
        let tab = tab ?? selected
        guard tab.editor == nil else { close(tab); return }
        let pane = pane ?? tab.focused
        guard tab.panes.count > 1 else { close(tab); return }
        Task {
            if confirm, TerminalProfile.shared.askBeforeClosing, let program = pane.foregroundProgram {
                guard await Self.confirmProcess(program, scope: "this pane", parent: window) else { return }
            }
            guard let leaf = tab.root.leaf(for: pane) else { return }
            let order = tab.panes
            let index = order.firstIndex { $0 === pane } ?? 0
            leaf.removeFromParent()
            let remaining = tab.panes
            if pane === tab.shell, let next = remaining.first {
                // The connection belonged to this pane's shell; the next pane starts local.
                tab.monitor?.cancel()
                Self.detach(tab, message: nil)
                tab.promote(next)
            }
            tab.focused = remaining[min(index, remaining.count - 1)]
            excludedFromMultiExec.remove(pane.id)
            pane.broadcast = nil
            pane.close()
            paneTokens[pane.id] = nil
            updateBroadcast()
            render()
            let focus = tab.focused
            idle { focus.focus() }
        }
    }

    /// Next / previous pane in display order.
    func focusPane(offset: Int) {
        let tab = selected
        let order = tab.panes
        guard order.count > 1, let index = order.firstIndex(where: { $0 === tab.focused }) else { return }
        let next = order[(index + offset + order.count) % order.count]
        tab.focused = next
        render()
        next.focus()
    }

    // MARK: MultiExec

    func setMultiExec(_ on: Bool) {
        guard multiExec != on else { return }
        multiExec = on
        updateBroadcast()
        render()
        if !on { focusSelected() }
    }

    func setIncluded(_ pane: TerminalPane, _ included: Bool) {
        if included { excludedFromMultiExec.remove(pane.id) } else { excludedFromMultiExec.insert(pane.id) }
        updateBroadcast()
        render()
    }

    func includeAll() {
        excludedFromMultiExec = []
        updateBroadcast()
        render()
    }

    /// Wires each included pane to send its user input on to the other included panes' shells.
    private func updateBroadcast() {
        for pane in allPanes {
            guard multiExec, !excludedFromMultiExec.contains(pane.id) else {
                pane.broadcast = nil
                continue
            }
            pane.broadcast = { [weak self, weak pane] text in
                guard let self, let pane else { return }
                for other in self.multiExecTargets where other !== pane { other.sendQuietly(text) }
            }
        }
    }

    /// MultiExec ▸ Close All: ends every terminal in the grid after asking, then leaves MultiExec with one fresh
    /// terminal. Editor tabs stay open.
    func closeAllTerminals() {
        let terminals = tabs.filter { $0.editor == nil }
        let count = terminals.reduce(0) { $0 + $1.panes.count }
        Task {
            let answer = await Dialogs.ask(window, "Close all \(count) terminal\(count == 1 ? "" : "s")?",
                                           "Every shell and remote session in the grid ends. A new terminal opens in their place.",
                                           choices: [.init("cancel", "Cancel"), .init("close", "Close All", .destructive)], cancel: "cancel")
            guard answer == "close", await Self.confirmClosing(terminals, scope: "these terminals", parent: window) else { return }
            for tab in terminals {
                tab.monitor?.cancel()
                tab.typedSSHWatch?.cancel()
                for pane in tab.panes {
                    pane.broadcast = nil
                    pane.close()
                    paneTokens[pane.id] = nil
                }
            }
            let fresh = TerminalTab(number: 1, directory: Self.defaultProfileFolder)
            tabs = tabs.filter { $0.editor != nil } + [fresh]
            excludedFromMultiExec = []
            selected = fresh
            configure(fresh)
            multiExec = false
            updateBroadcast()
            render()
            focusSelected()
        }
    }

    // MARK: SSH

    /// Saved logins plus this tab's live connection, for Run Command on Hosts.
    var hostTargets: [HostTarget] {
        var targets: [HostTarget] = []
        if case .connected(let endpoint) = selected.state.connection {
            targets.append(HostTarget(endpoint: endpoint, password: nil, source: "this tab's connection"))
        }
        for login in CredentialStore.shared?.logins ?? [] {
            let target = HostTarget(endpoint: RemoteEndpoint(host: login.host, port: login.port, username: login.username),
                                    password: login.password, source: "saved login")
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    func connectSSH(_ login: SSHLogin) {
        connect(RemoteEndpoint(host: login.host, port: login.port, username: login.username), password: login.password)
    }

    /// Starts the login in the selected tab's shell. The explorer follows only once the shared connection is
    /// verified, and returns to local files when the session ends or the link drops.
    func connect(_ endpoint: RemoteEndpoint, password: String?) {
        // A tab already in a remote session (or an editor tab) gets its own shell: typing a login there would nest it.
        // So does one running a program: the launcher would wait for it, or be typed into it.
        switch selected.state.connection {
        case .connecting, .connected: add()
        default: if selected.editor != nil || selected.shell.foregroundProgram != nil { add() }
        }
        let tab = selected
        tab.shell.connectSSH(endpoint, password: password)
        follow(tab, endpoint)
    }

    private func follow(_ tab: TerminalTab, _ endpoint: RemoteEndpoint) {
        tab.monitor?.cancel()
        tab.state.connection = .connecting(endpoint)
        tab.shell.setRemote(target: "Connecting to \(endpoint.label)…", location: "")
        render()
        tab.monitor = Task { [weak self, weak tab] in
            guard let tab else { return }
            await Workspace.watch(tab, endpoint)
            self?.render()
        }
    }

    /// Picks up an `ssh` typed in a local tab: the shell integration announces where it is going.
    private func watchTypedSSH(_ tab: TerminalTab) {
        tab.typedSSHWatch = Task { [weak self, weak tab] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self, let tab else { return }
                switch tab.state.connection {
                case .local, .failed: break
                default: continue
                }
                let pid = tab.shell.shellPid
                guard pid > 0 else { continue }
                let file = ShellIntegration.announcement(for: pid)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(at: file)
                if let endpoint = ShellIntegration.endpoint(fromAnnouncement: text) { self.follow(tab, endpoint) }
            }
        }
    }

    private static func watch(_ tab: TerminalTab, _ endpoint: RemoteEndpoint) async {
        let started = Date()
        var connected = false
        // Closing the pane cancels this and may hand the tab to another pane; nothing after that may touch it.
        let shell = tab.shell
        var current: Bool { !Task.isCancelled && tab.shell === shell }
        while current {
            do { try await Task.sleep(nanoseconds: connected ? 2_000_000_000 : 500_000_000) } catch { return }
            let up = await Task.detached { SSHControl.isConnected(endpoint) }.value
            guard current else { return }
            if up && !connected {
                connected = true
                let home = await Task.detached { (try? SFTPClient(endpoint: endpoint).canonical(".")) ?? "/" }.value
                guard current else { return }
                tab.state.remoteModel = RemoteExplorerModel(endpoint: endpoint)
                tab.state.remoteDirectory = home
                tab.state.remoteHistory = NavigationHistory(home)
                tab.state.remoteHome = home
                tab.state.connectedAt = Date()
                tab.state.endpoint = .remote(endpoint)
                tab.state.connection = .connected(endpoint)
                tab.explorer?.rebuild()
                tab.shell.setRemote(target: endpoint.label, location: home)
                all.forEach { $0.render() }
            } else if !up && connected {
                detach(tab, message: nil)
                return
            } else if connected, !(await shell.runsSSH()) {
                // The session ended (`exit`): close the shared connection unless another tab still uses it, and the
                // tab returns to this computer.
                let shared = all.flatMap(\.tabs).contains { $0 !== tab && $0.state.connection == .connected(endpoint) }
                if !shared { Task.detached { SSHControl.run(endpoint.sshArguments(["-O", "exit"])) } }
                detach(tab, message: nil)
                return
            } else if !up, Date().timeIntervalSince(started) > 2, !(await shell.runsSSH()) {
                detach(tab, message: "Couldn't connect to \(endpoint.label). The terminal shows ssh's reason.")
                return
            }
        }
    }

    static func detach(_ tab: TerminalTab, message: String?) {
        // A root session on the host ends with the connection it ran over.
        if case .remote = tab.state.adminTarget {
            tab.state.adminModel = nil
            tab.state.adminTarget = nil
        }
        tab.state.endpoint = .local
        tab.state.remoteModel = nil
        tab.state.connection = message.map(ConnectionState.failed) ?? .local
        tab.state.connectedAt = nil
        tab.shell.setRemote(target: nil)
        tab.explorer?.rebuild()
        all.forEach { $0.render() }
    }

    /// Ends the selected tab's remote session by closing its shared connection; the shell returns to this computer.
    func disconnect() {
        guard case .connected(let endpoint) = selected.state.connection else { return }
        Task.detached { SSHControl.run(endpoint.sshArguments(["-O", "exit"])) }
    }

    /// The SSH button: connection details while connected, otherwise the Connect dialog.
    func connectButton() {
        if case .connected = selected.state.connection { ConnectionDetails.show(self) } else { showConnect() }
    }

    func showConnect() {
        SSHConnectDialog.show(parent: window) { [weak self] login in self?.connectSSH(login) }
    }

    // MARK: Closing

    private static func confirmProcess(_ program: String, scope: String, parent: Widget?) async -> Bool {
        await Dialogs.ask(parent, "Do you want to terminate running processes in \(scope)?", "Closing \(scope) will terminate: \(program).",
                          choices: [.init("cancel", "Cancel"), .init("terminate", "Terminate", .destructive)], cancel: "cancel") == "terminate"
    }

    /// Terminal's rule: ask before ending tabs that run something other than their login shell, and before
    /// discarding unsaved edits.
    static func confirmClosing(_ tabs: [TerminalTab], scope: String = "this tab", parent: Widget?) async -> Bool {
        let unsaved = tabs.compactMap(\.editor).filter(\.isEdited)
        if !unsaved.isEmpty {
            let answer = await Dialogs.ask(parent, "Discard unsaved changes?",
                                           "These files have changes that aren't saved: " + unsaved.map(\.source.name).joined(separator: ", ")
                                           + ". Cancel, then save them with Ctrl+S in their tabs, to keep them.",
                                           choices: [.init("cancel", "Cancel"), .init("discard", "Discard Changes", .destructive)], cancel: "cancel")
            guard answer == "discard" else { return false }
        }
        guard TerminalProfile.shared.askBeforeClosing else { return true }
        let panes = tabs.flatMap { tab in tab.panes.map { (tab, $0) } }
        let running: [String] = await Task.detached { @MainActor in
            panes.flatMap { tab, pane -> [String] in
                var programs = pane.foregroundProgram.map { [$0] } ?? []
                if pane === tab.shell, case .connected(let endpoint) = tab.state.connection {
                    programs.removeAll { $0 == "ssh" }
                    programs.append("ssh (\(endpoint.label))")
                }
                return programs
            }
        }.value
        guard !running.isEmpty else { return true }
        return await Dialogs.ask(parent, "Do you want to terminate running processes in \(scope)?",
                                 "Closing \(scope) will terminate: " + running.joined(separator: ", ") + ".",
                                 choices: [.init("cancel", "Cancel"), .init("terminate", "Terminate", .destructive)], cancel: "cancel") == "terminate"
    }

    /// The window's close button: asks first; returns true when the window may close now.
    private func requestClose() -> Bool {
        if closing || App.shared.isQuitting { return true }
        Task {
            guard await Self.confirmClosing(tabs, scope: "this window", parent: window) else { return }
            closeWithoutAsking()
        }
        return false
    }

    func closeWithoutAsking() {
        guard !closing else { return }
        // Closing the last window ends the app, so it is the moment to save the session.
        if Self.registry.count == 1, !App.shared.isQuitting { Self.saveSession() }
        closing = true
        gtk_window_close(c(window))
    }

    private func destroyed() {
        for tab in tabs {
            tab.monitor?.cancel()
            tab.typedSSHWatch?.cancel()
            tab.panes.forEach { $0.close() }
        }
        Self.registry.removeAll { $0 === self }
    }

    /// Each window's tabs with their folder, panes, explorer folder and name.
    static func saveSession() {
        guard !ParityScene.isActive else { return }
        guard TerminalProfile.shared.restoreSession else { SavedSession.clear(); return }
        SavedSession.write(sessionSnapshot)
    }

    /// Every window as session restore saves it.
    static var sessionSnapshot: [SavedWindow] {
        registry.map { workspace in
            // Editor tabs aren't reopened; the files stay where they were saved.
            let terminals = workspace.tabs.filter { $0.editor == nil }
            return SavedWindow(tabs: terminals.map { tab in
                SavedTab(directory: tab.shell.currentDirectory ?? tab.shell.startDirectory, layout: tab.state.layout.rawValue,
                         title: tab.customTitle, explorerPath: tab.state.directory.path, profile: tab.shell.profileID?.uuidString,
                         panes: tab.panes.count > 1 ? tab.root.saved : nil)
            }, selected: terminals.firstIndex { $0 === workspace.selected } ?? 0)
        }
    }

    // MARK: Zoom and size

    /// Bigger / Smaller change the selected tab's profile, so the size is kept across sessions and every tab with
    /// that profile follows. Default clears the zoom.
    func zoom(_ delta: Double) {
        TerminalProfile.shared.update(selected.focused.profileID) { $0.zoom += delta }
    }

    func resetZoom() { TerminalProfile.shared.update(selected.focused.profileID) { $0.zoom = 0 } }

    func useProfile(_ id: UUID) {
        selected.focused.profileID = id
        render()
    }

    private func profilesChanged() {
        allPanes.forEach { $0.applyProfile() }
        updateMenu()
    }

    private func sizeToDefaultOnce() {
        guard !sized else { return }
        sizeToDefault()
    }

    /// New windows open at the default columns × rows of the default profile's font.
    func sizeToDefault() {
        let profile = TerminalProfile.shared
        resize(columns: profile.windowColumns, rows: profile.windowRows)
    }

    /// Resizes the window so the focused terminal shows `columns` × `rows`: worked out from the font, then corrected
    /// against the terminal's own count, so the result matches the size badge.
    func resize(columns: Int, rows: Int, attempt: Int = 0) {
        let pane = selected.focused
        guard selected.editor == nil, gtk_widget_get_mapped(pane.terminal) != 0, pane.columns > 0 else {
            if attempt < 20 { after(milliseconds: 100) { [weak self] in self?.resize(columns: columns, rows: rows, attempt: attempt + 1) } }
            return
        }
        guard gtk_window_is_maximized(c(window)) == 0, gtk_window_is_fullscreen(c(window)) == 0 else { return }
        sized = true
        let cell = pane.cellSize
        let windowWidth = Int(gtk_widget_get_width(window)), windowHeight = Int(gtk_widget_get_height(window))
        let terminalWidth = Int(gtk_widget_get_width(pane.terminal)), terminalHeight = Int(gtk_widget_get_height(pane.terminal))
        // The grid without the part of a cell left over at the edges.
        let chromeWidth = windowWidth - pane.columns * cell.width, chromeHeight = windowHeight - pane.rows * cell.height
        _ = (terminalWidth, terminalHeight)
        let width = columns * cell.width + chromeWidth, height = rows * cell.height + chromeHeight
        gtk_window_set_default_size(c(window), Int32(width), Int32(height))
        if attempt < 3 {
            after(milliseconds: 150) { [weak self] in
                guard let self, pane.columns != columns || pane.rows != rows else { return }
                self.resize(columns: columns, rows: rows, attempt: attempt + 1)
            }
        }
    }

    /// Double-click on the title: the terminal goes back to the default columns × rows and the text to its
    /// profile's size, clearing zoom.
    func restoreDefaultSize() {
        TerminalProfile.shared.update(selected.shell.profileID) { $0.zoom = 0 }
        after(milliseconds: 60) { [weak self] in self?.sizeToDefault() }
    }

    /// Right-click on the title: the terminal's current columns × rows and text size, zoom included, become the
    /// defaults.
    func makeCurrentSizeDefault() {
        let profile = TerminalProfile.shared
        let pane = selected.focused
        if pane.columns > 0, pane.rows > 0 {
            profile.windowColumns = pane.columns
            profile.windowRows = pane.rows
        }
        profile.update(selected.shell.profileID) { $0.fontSize = $0.effectiveSize; $0.zoom = 0 }
    }

    // MARK: Export

    /// Export Session: the focused terminal's whole text, scrollback included, to a text file named after the tab
    /// and the time. In an editor tab, Ctrl+S saves.
    func exportSession() {
        if let editor = selected.editor { editor.save(); return }
        let text = selected.focused.sessionText()
        let name = sessionFileName(title: selected.title)
        Task {
            guard let path = await Dialogs.save(window, title: "Export Session", name: name) else { return }
            do { try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { await Dialogs.show(window, error, heading: "The session couldn't be exported") }
        }
    }

    /// Take Screenshot: a picture of this whole window as it looks now, header bar included, on the clipboard,
    /// ready to paste into a message, a document or an image editor.
    func takeScreenshot() {
        if herb_copy_widget_image(window) != 0 {
            toolbar.confirm("Screenshot copied\nPaste it anywhere with Ctrl+V.")
        } else {
            gtk_widget_error_bell(window)
        }
    }

    /// Parity checks: once the scene has settled, the same picture as Take Screenshot goes to a PNG file.
    func saveParityCapture(to path: String) {
        let seconds = Double(ProcessInfo.processInfo.environment["PARITY_SETTLE_SECS"] ?? "") ?? 4
        FileHandle.standardError.write(Data("parity: capture in \(seconds) s to \(path)\n".utf8))
        _ = after(milliseconds: UInt32(seconds * 1000)) { [weak self] in
            guard let self else { FileHandle.standardError.write(Data("parity: window gone before capture\n".utf8)); return }
            ParityScene.writeIdentifiers(to: path + ".ids.json")
            let saved = herb_save_widget_image(self.window, path) != 0
            FileHandle.standardError.write(Data((saved ? "parity: saved \(path)\n" : "parity: capture failed\n").utf8))
        }
    }

    // MARK: Rendering

    /// Rebuilds the window's content for the current tabs, selection and mode. Widgets are reused; only their
    /// arrangement changes.
    func render(toolbarOnly: Bool = false, keepContent: Bool = false) {
        toolbar.update()
        updateActions()
        if toolbarOnly { return }
        renderTabStrip()
        // Re-parenting a live terminal mid-click breaks GTK's pointer state, so the content is only rebuilt when
        // what it shows changes.
        let signature = contentSignature
        if signature == shownSignature { updateOutline(); return }
        // Moving widgets drops the keyboard focus; the terminal that had it gets it back.
        let typing = allPanes.first { gtk_widget_has_focus($0.terminal) != 0 }
        shownSignature = signature
        renderContent()
        if let typing, multiExec || selected.panes.contains(where: { $0 === typing }) { idle { typing.focus() } }
    }

    private var shownSignature = ""
    private var grid: MultiExecGrid?

    /// What the content area shows: the mode, the selected tab and its layout, the panes and how they're split.
    private var contentSignature: String {
        func tree(_ node: PaneNode) -> String {
            if let pane = node.pane { return pane.id.uuidString }
            return node.axis.rawValue + "(" + node.children.map(tree).joined(separator: ",") + ")"
        }
        if multiExec {
            return "multi:" + tabs.map { tree($0.root) }.joined(separator: ";")
        }
        let tab = selected
        if tab.editor != nil { return "editor:" + tab.id.uuidString }
        return "\(tab.id):\(tab.state.layout.rawValue):" + tree(tab.root)
    }

    /// The focused pane's outline, without moving anything.
    private func updateOutline() {
        if multiExec { grid?.update(); return }
        let outline = selected.panes.count > 1
        for pane in selected.panes {
            if outline, pane === selected.focused { gtk_widget_add_css_class(pane.view, "focused-pane") }
            else { gtk_widget_remove_css_class(pane.view, "focused-pane") }
        }
    }

    private func renderContent() {
        // Every reusable widget leaves its old place first.
        for tab in tabs {
            tab.panes.forEach { unparent($0.view) }
            if let editor = tab.editor { unparent(editor.view) }
            if let explorer = tab.explorer { unparent(explorer.view) }
        }
        removeChildren(content)
        grid = nil
        if multiExec {
            let grid = MultiExecGrid(self)
            self.grid = grid
            append(content, grid.view)
            return
        }
        let tab = selected
        if let editor = tab.editor {
            append(content, editor.view)
        } else if tab.state.layout == .explorer {
            let explorer = tab.explorer ?? ExplorerHost(tab: tab, workspace: self)
            tab.explorer = explorer
            append(content, explorer.view)
        } else {
            let tree = tab.root.build(focused: tab.focused, outline: tab.panes.count > 1)
            gtk_widget_set_vexpand(tree, 1)
            append(content, tree)
        }
    }

    private func renderTabStrip() {
        removeChildren(tabStripBox)
        setVisible(tabStrip, tabs.count > 1 && !multiExec)
        guard tabs.count > 1 else { return }
        for tab in tabs { append(tabStripBox, TabChip.build(tab, in: self, selected: tab === selected)) }
    }

    /// Switches the selected tab between its shell and its explorer.
    func setLayout(_ layout: SessionLayout) {
        guard selected.editor == nil else { return }
        selected.state.layout = layout
        render()
        if layout == .terminal { focusSelected() } else { selected.explorer?.focus() }
    }

    /// Search what fills the window: files when the explorer does, otherwise the terminal's scrollback.
    func find() {
        if let editor = selected.editor { editor.find(); return }
        if selected.state.layout == .explorer { selected.explorer?.find() } else { selected.focused.showFind() }
    }

    /// Runs a text field's own action (`text.undo`, `clipboard.copy`…) when one has the focus: the find bar or a
    /// dialog's field. Returns false when no text field has it.
    @discardableResult
    func editField(_ action: String) -> Bool {
        guard let focus = gtk_root_get_focus(c(window)),
              g_type_check_instance_is_a(c(focus), gtk_text_get_type()) != 0 else { return false }
        return gtk_widget_activate_action_variant(focus, action, nil) != 0
    }

    func findInTerminal() {
        guard selected.editor == nil else { return }
        if selected.state.layout == .explorer { setLayout(.terminal) }
        selected.focused.showFind()
    }

    // MARK: Actions

    static let accelerators: [(String, [String])] = [
        ("win.new-tab", ["<Control><Shift>t"]), ("win.close-tab", ["<Control><Shift>w"]), ("win.export-session", ["<Control><Shift>s"]),
        ("win.take-screenshot", ["<Control><Alt>s"]),
        ("win.split-vertical", ["<Control><Shift>e"]), ("win.split-horizontal", ["<Control><Shift>o"]),
        ("win.close-pane", ["<Control><Alt>w"]), ("win.next-pane", ["<Control><Alt>Right"]), ("win.previous-pane", ["<Control><Alt>Left"]),
        ("win.multiexec", ["<Control><Shift>m"]), ("win.connect", ["<Control><Shift>k"]),
        ("win.previous-tab", ["<Control>Page_Up"]), ("win.next-tab", ["<Control>Page_Down"]),
        ("win.move-tab-left", ["<Control><Shift>Page_Up"]), ("win.move-tab-right", ["<Control><Shift>Page_Down"]),
        ("win.rename-tab", ["<Control><Shift>i"]), ("win.reset", ["<Control><Alt>r"]), ("win.hard-reset", ["<Control><Alt><Shift>r"]),
        ("win.clear-to-start", ["<Control><Shift>l"]), ("win.clear-scrollback", ["<Control><Alt>k"]),
        ("win.zoom-in", ["<Control>plus", "<Control>equal", "<Control>KP_Add"]), ("win.zoom-out", ["<Control>minus", "<Control>KP_Subtract"]),
        ("win.zoom-reset", ["<Control>0", "<Control>KP_0"]), ("win.find", ["<Control><Shift>f"]), ("win.fullscreen", ["F11"]),
        ("win.copy", ["<Control><Shift>c"]), ("win.paste", ["<Control><Shift>v"]), ("win.paste-escaped", ["<Control><Alt>v"]),
        ("win.toggle-explorer", ["<Control><Shift>x"]),
    ] + (1...9).map { ("win.tab-\($0)", ["<Alt>\($0)"]) }

    private func installActions() {
        let map: OpaquePointer = c(window)
        func add(_ name: String, _ action: @escaping @MainActor (Workspace) -> Void) {
            actions[name] = addAction(map, name) { [weak self] in if let self { action(self) } }
        }
        add("new-tab") { $0.add() }
        add("close-tab") { workspace in
            // In MultiExec, the active terminal in the grid.
            if workspace.multiExec, workspace.allPanes.count > 1 { workspace.closePane(); return }
            workspace.close(workspace.selected)
        }
        add("export-session") { $0.exportSession() }
        add("take-screenshot") { $0.takeScreenshot() }
        add("split-vertical") { $0.split(.horizontal) }
        add("split-horizontal") { $0.split(.vertical) }
        add("close-pane") { $0.closePane() }
        add("next-pane") { $0.focusPane(offset: 1) }
        add("previous-pane") { $0.focusPane(offset: -1) }
        add("multiexec") { $0.setMultiExec(!$0.multiExec) }
        add("run-on-hosts") { MultiHostWindow.show($0) }
        add("connect") { $0.showConnect() }
        add("disconnect") { $0.disconnect() }
        add("previous-tab") { $0.selectTab(offset: -1) }
        add("next-tab") { $0.selectTab(offset: 1) }
        add("move-tab-left") { $0.moveSelected(by: -1) }
        add("move-tab-right") { $0.moveSelected(by: 1) }
        add("rename-tab") { $0.rename($0.selected) }
        add("reset") { $0.selected.editor == nil ? $0.selected.focused.reset(hard: false) : () }
        add("hard-reset") { $0.selected.editor == nil ? $0.selected.focused.reset(hard: true) : () }
        add("clear-to-start") { $0.selected.editor == nil ? $0.selected.focused.clearToStart() : () }
        add("clear-scrollback") { $0.selected.editor == nil ? $0.selected.focused.clearHistory() : () }
        add("zoom-in") { $0.zoom(1) }
        add("zoom-out") { $0.zoom(-1) }
        add("zoom-reset") { $0.resetZoom() }
        add("find") { $0.find() }
        add("find-in-terminal") { $0.findInTerminal() }
        add("fullscreen") { workspace in
            if gtk_window_is_fullscreen(c(workspace.window)) != 0 { gtk_window_unfullscreen(c(workspace.window)) }
            else { gtk_window_fullscreen(c(workspace.window)) }
        }
        add("undo") { $0.editField("text.undo") }
        add("redo") { $0.editField("text.redo") }
        add("cut") { $0.editField("clipboard.cut") }
        add("copy") { if !$0.editField("clipboard.copy"), $0.selected.editor == nil { $0.selected.focused.copy() } }
        add("paste") { if !$0.editField("clipboard.paste"), $0.selected.editor == nil { $0.selected.focused.paste() } }
        add("paste-escaped") { $0.selected.editor == nil ? $0.selected.focused.pasteEscaped() : () }
        add("select-all") { if !$0.editField("selection.select-all"), $0.selected.editor == nil { $0.selected.focused.selectAll() } }
        add("minimize") { gtk_window_minimize(c($0.window)) }
        add("maximize") { workspace in
            if gtk_window_is_maximized(c(workspace.window)) != 0 { gtk_window_unmaximize(c(workspace.window)) }
            else { gtk_window_maximize(c(workspace.window)) }
        }
        add("show-explorer") { $0.setLayout(.explorer) }
        add("toggle-explorer") { $0.setLayout($0.selected.state.layout == .explorer ? .terminal : .explorer) }
        add("tailcat") { TailcatWindow.show($0) }
        add("restore-size") { $0.restoreDefaultSize() }
        add("default-size") { $0.makeCurrentSizeDefault() }
        add("import-preset") { workspace in
            Task { if let name = await ThemeImport.run(workspace.window) { TerminalProfile.shared.update(workspace.selected.focused.profileID) { $0.theme = name } } }
        }
        add("restore-theming") { $0.restoreTheming() }
        add("close-all") { $0.closeAllTerminals() }
        for number in 1...9 { add("tab-\(number)") { $0.selectTab(number: number - 1) } }
        // Tab menu items name their tab.
        addParameterAction(map, "select-tab") { [weak self] id in self?.tab(id).map { self?.select($0) } }
        addParameterAction(map, "rename-tab-id") { [weak self] id in self?.tab(id).map { self?.rename($0) } }
        addParameterAction(map, "close-tab-id") { [weak self] id in self?.tab(id).map { self?.close($0) } }
        addParameterAction(map, "move-tab-left-id") { [weak self] id in
            guard let self, let tab = self.tab(id), let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.move(tab, to: index - 1)
        }
        addParameterAction(map, "move-tab-right-id") { [weak self] id in
            guard let self, let tab = self.tab(id), let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.move(tab, to: index + 1)
        }
        addParameterAction(map, "new-tab-profile") { [weak self] id in self?.add(profile: UUID(uuidString: id)) }
        actions["use-profile"] = addChoiceAction(map, "use-profile", state: selected.focused.profileID?.uuidString ?? TerminalProfile.shared.defaultProfileID.uuidString) { [weak self] id in
            UUID(uuidString: id).map { self?.useProfile($0) }
        }
        actions["color-scheme"] = addChoiceAction(map, "color-scheme", state: TerminalProfile.shared.appearance) { value in
            TerminalProfile.shared.appearance = value
        }
        actions["color-preset"] = addChoiceAction(map, "color-preset", state: selected.focused.settings.theme) { [weak self] name in
            guard let self else { return }
            TerminalProfile.shared.update(self.selected.focused.profileID) { $0.theme = name }
        }
        updateMenu()
    }

    private func tab(_ id: String) -> TerminalTab? { tabs.first { $0.id.uuidString == id } }

    private func updateActions() {
        let isTerminal = selected.editor == nil
        let connected: Bool = { if case .connected = selected.state.connection { true } else { false } }()
        setActionEnabled(actions["disconnect"], connected)
        for name in ["split-vertical", "split-horizontal", "reset", "hard-reset", "clear-to-start", "clear-scrollback",
                     "copy", "paste", "paste-escaped", "select-all", "show-explorer", "toggle-explorer", "find-in-terminal"] {
            setActionEnabled(actions[name], isTerminal)
        }
        setActionEnabled(actions["close-pane"], isTerminal)
        setActionState(actions["use-profile"], selected.focused.profileID?.uuidString ?? TerminalProfile.shared.defaultProfileID.uuidString)
        setActionState(actions["color-scheme"], TerminalProfile.shared.appearance)
        setActionState(actions["color-preset"], selected.focused.settings.theme)
        updateMenu()
    }

    private var menuSignature = ""
    /// The Main Menu as last built, for the feature tests.
    private(set) var mainMenuModel: OpaquePointer?

    /// The Main Menu, rebuilt when what it lists (tabs, profiles, presets) changes.
    func updateMenu() {
        let signature = tabs.map { $0.id.uuidString + $0.title }.joined() + TerminalProfile.shared.profiles.map { $0.id.uuidString + $0.name }.joined()
            + ThemeLibrary.shared.allNames.joined()
        guard signature != menuSignature else { return }
        menuSignature = signature
        let menu = MenuBuilder()
        menu.item("New Tab", "win.new-tab")
        menu.item("New Window", "app.new-window")
        menu.item("Connect via SSH…", "win.connect")
        menu.submenu("Open Tabs") { sub in
            for tab in tabs { sub.item(tab.title, "win.select-tab", target: tab.id.uuidString) }
        }
        menu.divider()
        menu.item("Find in Terminal…", "win.find-in-terminal")
        menu.submenu("Zoom") { sub in
            sub.item("Bigger", "win.zoom-in")
            sub.item("Smaller", "win.zoom-out")
            sub.item("Default", "win.zoom-reset")
        }
        menu.submenu("Appearance") { sub in
            for scheme in ["System", "Light", "Dark"] { sub.item(scheme, "win.color-scheme", target: scheme) }
            sub.divider()
            sub.item("macOS Terminal Basic", "win.color-preset", target: "")
            for name in ThemeLibrary.shared.allNames { sub.item(name, "win.color-preset", target: name) }
            sub.divider()
            sub.item("Import iTerm2 Color Preset…", "win.import-preset")
            sub.item("Restore Defaults", "win.restore-theming")
        }
        menu.item("Toggle Full Screen", "win.fullscreen")
        menu.divider()
        // Every menu is here, as on the Mac: Edit, Shell and Window. Edit's standard commands act on a text field that
        // has the focus (the find bar, say); Copy, Paste and Select All otherwise act on the terminal.
        menu.submenu("Edit") { sub in
            sub.item("Undo", "win.undo", accel: "<Control>z")
            sub.item("Redo", "win.redo", accel: "<Control><Shift>z")
            sub.divider()
            sub.item("Cut", "win.cut", accel: "<Control>x")
            sub.item("Copy", "win.copy")
            sub.item("Paste", "win.paste")
            sub.item("Select All", "win.select-all")
            sub.divider()
            sub.item("Clear to Start", "win.clear-to-start")
            sub.item("Clear Scrollback", "win.clear-scrollback")
        }
        menu.submenu("Shell") { sub in
            sub.item("New Tab", "win.new-tab")
            sub.item("Export Session…", "win.export-session")
            sub.item("Take Screenshot", "win.take-screenshot")
            sub.item("Split Vertically", "win.split-vertical")
            sub.item("Split Horizontally", "win.split-horizontal")
            sub.item("Close Pane", "win.close-pane")
            sub.item("Select Next Pane", "win.next-pane")
            sub.item("Select Previous Pane", "win.previous-pane")
            sub.divider()
            sub.item("MultiExec", "win.multiexec")
            sub.item("Run Command on Hosts…", "win.run-on-hosts")
            sub.submenu("New Tab with Profile") { profiles in
                for profile in TerminalProfile.shared.profiles { profiles.item(profile.name, "win.new-tab-profile", target: profile.id.uuidString) }
            }
            sub.submenu("Use Profile") { profiles in
                for profile in TerminalProfile.shared.profiles { profiles.item(profile.name, "win.use-profile", target: profile.id.uuidString) }
            }
            sub.item("New Remote Connection…", "win.connect")
            sub.item("Disconnect", "win.disconnect")
            sub.divider()
            sub.item("Show Previous Tab", "win.previous-tab")
            sub.item("Show Next Tab", "win.next-tab")
            sub.item("Rename Tab…", "win.rename-tab")
            sub.item("Move Tab Left", "win.move-tab-left")
            sub.item("Move Tab Right", "win.move-tab-right")
            sub.divider()
            sub.item("Reset", "win.reset")
            sub.item("Hard Reset", "win.hard-reset")
        }
        menu.submenu("Window") { sub in
            sub.item("Minimize", "win.minimize")
            sub.item("Zoom", "win.maximize")
            sub.divider()
            for number in 1...9 { sub.item(number == 9 ? "Show Last Tab" : "Show Tab \(number)", "win.tab-\(number)") }
        }
        menu.divider()
        menu.item("Settings…", "app.settings")
        menu.item("About Herb's Terminal", "app.about")
        menu.divider()
        menu.item("Quit Herb's Terminal", "app.quit")
        mainMenuModel = menu.menu
        toolbar.setMenu(menu.finish())
    }

    /// Main Menu ▸ Appearance ▸ Restore Defaults: asks first, then the profile's theming and the color scheme go back
    /// to the Basic look.
    private func restoreTheming() {
        let profile = selected.focused.profileID
        Task {
            let answer = await Dialogs.ask(window, "Restore theming defaults for “\(TerminalProfile.shared.name(of: profile))”?",
                                           "Font, size and zoom, cursor, color theme, transparency and appearance go back to the stock Basic look. Imported presets are kept.",
                                           choices: [.init("cancel", "Cancel"), .init("restore", "Restore Defaults", .suggested)], cancel: "cancel")
            guard answer == "restore" else { return }
            TerminalProfile.shared.update(profile) { $0.restoreTheming() }
            TerminalProfile.shared.appearance = "System"
        }
    }
}

/// A non-stateful action that takes a string, for menu items that name their tab or profile.
@MainActor
@discardableResult
func addParameterAction(_ map: OpaquePointer?, _ name: String, _ activate: @escaping @MainActor (String) -> Void) -> OpaquePointer {
    let action = g_simple_action_new(name, g_variant_type_new("s"))!
    on(action, "activate") { args in
        guard let parameter = args.pointer(1) else { return }
        activate(String(cString: g_variant_get_string(OpaquePointer(parameter), nil)))
    }
    g_action_map_add_action(map, c(action))
    g_object_unref(raw(action))
    return action
}

/// Import iTerm2 Color Preset…
@MainActor
enum ThemeImport {
    static func run(_ parent: Widget?) async -> String? {
        guard let path = await Dialogs.openFiles(parent, title: "Import iTerm2 Color Preset", accept: "Import", pattern: "*.itermcolors").first else { return nil }
        do { return try ThemeLibrary.shared.importFile(URL(fileURLWithPath: path)) }
        catch { await Dialogs.show(parent, error, heading: "That color preset couldn't be imported"); return nil }
    }
}
