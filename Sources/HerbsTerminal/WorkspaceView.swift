import Combine
import SwiftUI
import HerbsTerminalUI
import SwiftTerm

@MainActor
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    let number: Int
    let state = WindowState()
    /// The tab's first pane: its SSH connection, the explorer and the title follow this shell. If it is
    /// closed while other panes remain, the next pane takes over.
    private(set) var shell: LocalShell
    /// The tab's split panes; a single leaf until the tab is split.
    let root: PaneNode
    /// The pane that has keyboard focus; zoom, Clear, Reset and Find act on it.
    @Published var focusedShell: LocalShell
    var monitor: Task<Void, Never>?
    var typedSSHWatch: Task<Void, Never>?
    /// Set by Rename Tab; otherwise tabs are numbered.
    var customTitle: String?
    /// A text editor tab shows a file instead of a shell; its shell is never started.
    let editor: TextEditorModel?
    private var editorWatch: AnyCancellable?
    var title: String {
        if let editor { return (editor.isEdited ? "• " : "") + editor.source.name }
        return customTitle ?? "Terminal \(number)"
    }
    /// The tab's terminal panes; none for an editor tab.
    var shells: [LocalShell] { editor == nil ? root.leaves : [] }

    init(number: Int, directory: String? = nil, profile: UUID? = nil, panes: SavedPane? = nil, editor: TextEditorModel? = nil) {
        self.number = number
        self.editor = editor
        let main = LocalShell(profileID: profile)
        if let directory { main.startDirectory = directory }
        shell = main
        focusedShell = main
        if let panes, panes.children?.isEmpty == false {
            var first: LocalShell? = main
            root = PaneNode.restore(panes, first: &first, profile: profile)
        } else {
            root = PaneNode(shell: main)
        }
        // The tab title shows a dot while the file has unsaved changes.
        editorWatch = editor?.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// Hands the connection and explorer to another pane when the first one closes.
    func promote(_ next: LocalShell) {
        shell = next
        objectWillChange.send()
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selected: TerminalTab
    @Published var showingSSHConnect = false
    @Published var panel: WorkspacePanel?
    let multiHost = MultiHostModel()
    /// Keeps the window delegate proxy alive; AppKit holds delegates weakly.
    var closeGuard: WindowCloseGuard?
    weak var window: NSWindow?

    /// Every open window's workspace, for quitting and for saving the session.
    private static var registry: [WeakWorkspace] = []
    static var all: [Workspace] { registry.compactMap(\.value) }
    private struct WeakWorkspace { weak var value: Workspace? }

    /// MultiExec, like MobaXterm's: every pane of every tab in a grid, and what you type in an included
    /// pane goes to all included panes.
    @Published var multiExec = false { didSet { updateBroadcast() } }
    /// Panes (by shell) left out of MultiExec input; they still show in the grid and take their own typing.
    @Published var excludedFromMultiExec: Set<UUID> = [] { didSet { updateBroadcast() } }

    var allShells: [LocalShell] { tabs.flatMap(\.shells) }
    var multiExecTargets: [LocalShell] { allShells.filter { !excludedFromMultiExec.contains($0.id) } }

    func setIncluded(_ shell: LocalShell, _ included: Bool) {
        if included { excludedFromMultiExec.remove(shell.id) } else { excludedFromMultiExec.insert(shell.id) }
    }

    func setIncluded(_ tab: TerminalTab, _ included: Bool) { tab.shells.forEach { setIncluded($0, included) } }

    /// Wires each included pane to send its user input on to the other included panes' shells.
    func updateBroadcast() {
        for shell in allShells {
            guard multiExec, !excludedFromMultiExec.contains(shell.id) else {
                shell.view.broadcast = nil
                continue
            }
            shell.view.broadcast = { [weak self, weak shell] data in
                guard let self, let shell else { return }
                for other in self.multiExecTargets where other !== shell {
                    other.view.process.send(data: data)
                }
            }
        }
    }

    /// Saved logins plus this tab's live connection, for Multi-Host Commands.
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
    /// The lowest number no open tab uses, so closing tabs frees their numbers again.
    private var nextNumber: Int {
        let used = Set(tabs.filter { $0.editor == nil }.map(\.number))
        return (1...).first { !used.contains($0) }!
    }

    /// Reopened from the last session; such windows keep the size macOS restores.
    let isRestored: Bool

    /// A new window's workspace; it reopens the next window from the last session when there is one.
    init(restoring saved: SavedWindow? = SessionRestore.takeNext()) {
        isRestored = saved != nil
        let restored = (saved?.tabs ?? []).enumerated().map { index, tab -> TerminalTab in
            let item = TerminalTab(number: index + 1,
                                   directory: FileManager.default.fileExists(atPath: tab.directory) ? tab.directory : nil,
                                   profile: tab.profile.flatMap(UUID.init(uuidString:)), panes: tab.panes)
            item.customTitle = tab.title
            item.state.layout = SessionLayout(savedName: tab.layout)
            if FileManager.default.fileExists(atPath: tab.explorerPath) {
                item.state.directory = URL(fileURLWithPath: tab.explorerPath, isDirectory: true)
                item.state.localHistory = NavigationHistory(tab.explorerPath)
            }
            return item
        }
        let all = restored.isEmpty ? [TerminalTab(number: 1)] : restored
        tabs = all
        selected = all[min(max(saved?.selected ?? 0, 0), all.count - 1)]
        all.forEach(configure)
        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(WeakWorkspace(value: self))
    }

    /// Opens a tab with `profile` (default: the current tab's): in the profile's start folder when it has
    /// one, else in the current tab's folder when that's a local shell and Settings asks for it.
    func add(profile: UUID? = nil) {
        let profileID = profile ?? selected.shell.profileID
        let settings = TerminalProfile.shared.settings(for: profileID)
        var directory: String?
        if !settings.startDirectory.isEmpty {
            directory = (settings.startDirectory as NSString).expandingTildeInPath
        } else if TerminalProfile.shared.newTabsInSameFolder, case .local = selected.state.connection {
            directory = selected.shell.currentDirectory
        }
        let tab = TerminalTab(number: nextNumber, directory: directory, profile: profileID)
        tabs.append(tab)
        selected = tab
        configure(tab)
        updateBroadcast()
    }

    /// Opens `source` in an editor tab of the frontmost window, or selects the tab already showing it.
    static func openEditor(_ source: TextFileSource) {
        let workspace = all.first { $0.window?.isKeyWindow == true } ?? all.first { $0.window?.isVisible == true } ?? all.first
        workspace?.openEditor(source)
    }

    func openEditor(_ source: TextFileSource) {
        if let open = tabs.first(where: { $0.editor?.source.location == source.location }) {
            select(open)
            return
        }
        let model = TextEditorModel(source: source)
        let tab = TerminalTab(number: 0, editor: model)
        model.onFailure = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.remove(tab)
        }
        if let index = tabs.firstIndex(where: { $0 === selected }) { tabs.insert(tab, at: index + 1) } else { tabs.append(tab) }
        selected = tab
        Task { await model.load() }
    }

    /// Export Session (⌘S): the focused terminal's whole text, scrollback included, to a text file named
    /// after the tab and the time, for example "Terminal 2 2026-11-06 00-35.txt". In an editor tab, ⌘S saves.
    func exportSession() {
        if let editor = selected.editor { editor.save(); return }
        let text = Self.sessionText(selected.focusedShell)
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = Self.sessionFileName(title: selected.title)
        let write = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    /// Take Screenshot (⇧⌘S): a picture of this whole window as it looks now, toolbar and tabs included,
    /// on the clipboard as PNG and TIFF, ready to paste into a message, a document or an image editor.
    func takeScreenshot() {
        guard let window, let image = Self.windowImage(window), let png = image.representation(using: .png, properties: [:]) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        HintBubble.shared.confirm("Screenshot copied\nPaste it anywhere with ⌘V.")
    }

    /// The window drawn at the screen's resolution: its frame view, so the window buttons are in it too.
    /// Herb's Terminal draws its own window, so no Screen Recording permission is needed.
    static func windowImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let root = window.contentView?.superview ?? window.contentView,
              let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        // A terminal paints its background with its layer, which a cached drawing leaves out (and with it
        // the light text on a dark theme), so each visible terminal is drawn again over its background.
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return bitmap }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for terminal in terminals(in: root) where !terminal.isHiddenOrHasHiddenAncestor {
            let visible = terminal.visibleRect
            guard !visible.isEmpty, let tile = terminal.bitmapImageRepForCachingDisplay(in: visible) else { continue }
            terminal.cacheDisplay(in: visible, to: tile)
            var rect = terminal.convert(visible, to: root)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            terminal.nativeBackgroundColor.setFill()
            rect.fill()
            tile.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        return bitmap
    }

    private static func terminals(in view: NSView) -> [TerminalView] {
        view.subviews.flatMap { ($0 as? TerminalView).map { [$0] } ?? terminals(in: $0) }
    }

    /// Everything the terminal holds: the scrollback and the screen (the main screen even while a
    /// full-screen program such as vim shows its own), without the empty lines below the last output.
    static func sessionText(_ shell: LocalShell) -> String {
        var lines = String(decoding: shell.view.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
            .components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "<tab name> <yyyy-MM-dd HH-mm>.txt", with characters that can't be in a file name replaced.
    static func sessionFileName(title: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let name = title.map { "/:\\".contains($0) ? "-" : $0 }
        return String(name).trimmingCharacters(in: .whitespaces) + " " + formatter.string(from: date) + ".txt"
    }

    /// ⌘1–⌘9: the tab at that position; ⌘9 is the last tab, as in Terminal and Safari.
    func selectTab(number index: Int) {
        // In MultiExec the numbers are the grid's: one per terminal, as its caption shows.
        if multiExec {
            let cells = tabs.flatMap { tab in tab.shells.map { (tab, $0) } }
            guard !cells.isEmpty, index >= 0 else { return }
            let target = index == 8 ? cells.count - 1 : index
            guard cells.indices.contains(target) else { return }
            selected = cells[target].0
            cells[target].0.focusedShell = cells[target].1
            focusSelected()
            return
        }
        guard !tabs.isEmpty, index >= 0 else { return }
        let target = index == 8 ? tabs.count - 1 : index
        guard tabs.indices.contains(target) else { return }
        selected = tabs[target]
        focusSelected()
    }

    /// MultiExec ▸ Close All: ends every terminal in the grid after asking, then leaves MultiExec with one
    /// fresh terminal. Editor tabs stay open.
    func closeAllTerminals() {
        let terminals = tabs.filter { $0.editor == nil }
        let count = terminals.reduce(0) { $0 + $1.shells.count }
        let alert = NSAlert()
        alert.messageText = "Close all \(count) terminal\(count == 1 ? "" : "s")?"
        alert.informativeText = "Every shell and remote session in the grid ends. A new terminal opens in their place."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard Self.confirmClosing(terminals, scope: "these terminals") else { return }
        for tab in terminals {
            tab.monitor?.cancel()
            tab.typedSSHWatch?.cancel()
            for shell in tab.shells {
                shell.view.broadcast = nil
                shell.close()
            }
        }
        let fresh = TerminalTab(number: 1)
        tabs = tabs.filter { $0.editor != nil } + [fresh]
        excludedFromMultiExec = []
        selected = fresh
        configure(fresh)
        multiExec = false
        focusSelected()
    }

    func select(_ tab: TerminalTab) {
        selected = tab
        focusSelected()
    }

    /// Keyboard focus follows the selected tab, so typing goes to the tab that's shown.
    private func focusSelected() {
        let focus = selected.focusedShell
        DispatchQueue.main.async { focus.view.window?.makeFirstResponder(focus.view) }
    }

    /// Moves `tab` to `index` in the tab strip (drag to reorder, Move Tab Left/Right).
    func move(_ tab: TerminalTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let target = max(0, min(tabs.count - 1, index))
        guard target != from else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: target)
    }

    func moveSelected(by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === selected }) else { return }
        move(selected, to: index + offset)
    }

    /// Terminal's Edit Title: an empty name goes back to the numbered title.
    func rename(_ tab: TerminalTab) {
        guard tab.editor == nil else { return }   // an editor tab is named after its file
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to use the numbered name."
        let field = NSTextField(string: tab.customTitle ?? "")
        field.placeholderString = "Terminal \(tab.number)"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        tab.customTitle = name.isEmpty ? nil : name
        objectWillChange.send()
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === selected }), tabs.count > 1 else { return }
        selected = tabs[(index + offset + tabs.count) % tabs.count]
        focusSelected()
    }

    /// The workspace part of the terminal's right-click menu, and typed-ssh following.
    private func configure(_ tab: TerminalTab) {
        guard tab.editor == nil else { return }
        watchTypedSSH(tab)
        tab.shells.forEach { configurePane($0, in: tab) }
    }

    /// A pane's right-click menu, focus tracking, and closing it when its shell exits.
    private func configurePane(_ shell: LocalShell, in tab: TerminalTab) {
        shell.view.onFocus = { [weak tab, weak shell] in
            guard let tab, let shell, tab.focusedShell !== shell else { return }
            tab.focusedShell = shell
        }
        shell.legend.onResize = { [weak self] in self?.rememberChrome() }
        // Typing `exit` closes the pane, the tab when it was the tab's last pane, and the window when it was
        // the window's last terminal, or quits the app when it was the last window. An ssh session ends on its
        // own and leaves the local shell running.
        shell.legend.onExit = { [weak self, weak tab, weak shell] in
            guard let self, let tab, let shell else { return }
            self.shellExited(shell, in: tab)
        }
        shell.view.extraMenuItems = { [weak self, weak tab, weak shell] in
            guard let self, let tab, let shell else { return [] }
            let state = tab.state
            var items: [NSMenuItem] = [
                ActionMenuItem("Split Vertically", key: "d") { self.split(.horizontal, from: shell, in: tab) },
                ActionMenuItem("Split Horizontally", key: "d", modifiers: [.command, .shift]) { self.split(.vertical, from: shell, in: tab) },
            ]
            if tab.shells.count > 1 {
                items.append(ActionMenuItem("Close Pane", key: "w", modifiers: [.command, .option]) { self.closePane(shell, in: tab, confirm: true) })
            }
            items += [
                NSMenuItem.separator(),
                ActionMenuItem("New Tab", key: "t") { self.add() },
                ActionMenuItem("Show File Explorer") { state.layout = .explorer },
                NSMenuItem.separator(),
            ]
            if case .connected(let endpoint) = state.connection {
                items.append(ActionMenuItem("Disconnect from \(endpoint.label)") { self.disconnect() })
            }
            items.append(ActionMenuItem("Connect via SSH…", key: "k", modifiers: [.command, .shift]) { self.showingSSHConnect = true })
            items += [
                NSMenuItem.separator(),
                ActionMenuItem("Bigger", key: "+") { self.zoom(1) },
                ActionMenuItem("Smaller", key: "-") { self.zoom(-1) },
                ActionMenuItem("Settings…", key: ",") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
            ]
            return items
        }
    }

    func shellExited(_ shell: LocalShell, in tab: TerminalTab) {
        // Shells the app closed itself (a closed pane or tab) report their exit too; only a shell still showing counts.
        guard tabs.contains(where: { $0 === tab }), tab.shells.contains(where: { $0 === shell }) else { return }
        if tab.shells.count > 1 {
            closePane(shell, in: tab, confirm: false)
        } else if tabs.count > 1 {
            remove(tab)
            if multiExec, allShells.isEmpty { multiExec = false }
        } else if isLastWindow {
            // `exit` in the app's last terminal quits Herb's Terminal, as closing its last shell should.
            NSApp.terminate(nil)
        } else {
            window?.close()
        }
    }

    /// True when no other Herb's Terminal window is open.
    var isLastWindow: Bool {
        !Workspace.all.contains { $0 !== self && $0.window?.isVisible == true }
    }

    // MARK: Split panes

    /// Splits `shell`'s pane (default: the focused pane of the selected tab). The new pane gets the same
    /// profile and, per Settings, the same folder.
    func split(_ axis: PaneNode.Axis, from shell: LocalShell? = nil, in tab: TerminalTab? = nil) {
        let tab = tab ?? selected
        guard tab.editor == nil else { return }
        let source = shell ?? tab.focusedShell
        guard let leaf = tab.root.leaf(for: source) else { return }
        let pane = LocalShell(profileID: source.profileID)
        if TerminalProfile.shared.newTabsInSameFolder, let folder = source.currentDirectory { pane.startDirectory = folder }
        pane.view.focusWhenShown = true
        leaf.split(axis, adding: PaneNode(shell: pane))
        configurePane(pane, in: tab)
        tab.focusedShell = pane
        updateBroadcast()
        tab.objectWillChange.send()
    }

    /// Closes one pane; the last pane closes the tab instead.
    func closePane(_ shell: LocalShell? = nil, in tab: TerminalTab? = nil, confirm: Bool = true) {
        let tab = tab ?? selected
        guard tab.editor == nil else { close(tab); return }
        let shell = shell ?? tab.focusedShell
        guard tab.shells.count > 1 else { close(tab); return }
        if confirm, TerminalProfile.shared.askBeforeClosing, let program = shell.foregroundProgram {
            guard Self.confirmProcess(program, scope: "this pane") else { return }
        }
        guard let leaf = tab.root.leaf(for: shell) else { return }
        let order = tab.shells
        let index = order.firstIndex { $0 === shell } ?? 0
        leaf.removeFromParent()
        let remaining = tab.shells
        if shell === tab.shell, let next = remaining.first {
            // The connection belonged to this pane's shell; the next pane starts local.
            tab.monitor?.cancel()
            Self.detach(tab, message: nil)
            tab.promote(next)
        }
        tab.focusedShell = remaining[min(index, remaining.count - 1)]
        excludedFromMultiExec.remove(shell.id)
        shell.view.broadcast = nil
        shell.close()
        updateBroadcast()
        tab.objectWillChange.send()
        let focus = tab.focusedShell
        DispatchQueue.main.async { focus.view.window?.makeFirstResponder(focus.view) }
    }

    /// Next / previous pane in display order.
    func focusPane(offset: Int) {
        let tab = selected
        let order = tab.shells
        guard order.count > 1, let index = order.firstIndex(where: { $0 === tab.focusedShell }) else { return }
        let next = order[(index + offset + order.count) % order.count]
        tab.focusedShell = next
        next.view.window?.makeFirstResponder(next.view)
    }

    private static func confirmProcess(_ program: String, scope: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to terminate running processes in \(scope)?"
        alert.informativeText = "Closing \(scope) will terminate: \(program)."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func connectSSH(_ login: SSHLogin) {
        connect(RemoteEndpoint(host: login.host, port: login.port, username: login.username), password: login.password)
    }

    /// Starts the login in the selected tab's shell. The explorer follows only once the shared connection
    /// is verified, and returns to local files when the session ends or the link drops.
    func connect(_ endpoint: RemoteEndpoint, password: String?) {
        // A tab already in a remote session gets its own shell: typing a login there would nest it.
        switch selected.state.connection {
        case .connecting, .connected: add()
        default: break
        }
        let tab = selected
        tab.shell.connectSSH(endpoint, password: password)
        follow(tab, endpoint)
    }

    /// Tracks `endpoint` in `tab` until the shared connection is up, then attaches the explorer.
    private func follow(_ tab: TerminalTab, _ endpoint: RemoteEndpoint) {
        tab.monitor?.cancel()
        tab.state.connection = .connecting(endpoint)
        tab.shell.legend.setRemote(target: "Connecting to \(endpoint.label)…", location: "")
        tab.monitor = Task { [weak tab] in
            guard let tab else { return }
            await Workspace.watch(tab, endpoint)
        }
    }

    /// Picks up an `ssh` typed in a local tab: the shell integration announces where it is going.
    private func watchTypedSSH(_ tab: TerminalTab) {
        tab.typedSSHWatch = Task { [weak self, weak tab] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, let tab else { return }
                switch tab.state.connection {
                case .local, .failed: break
                default: continue
                }
                let pid = tab.shell.view.process.shellPid
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
            do { try await Task.sleep(for: .milliseconds(connected ? 2000 : 500)) } catch { return }
            let up = await Task.detached { SSHControl.isConnected(endpoint) }.value
            guard current else { return }
            if up && !connected {
                connected = true
                let home = await Task.detached { (try? SFTPClient(endpoint: endpoint).canonical(".")) ?? "/" }.value
                guard current else { return }
                tab.state.remoteViewModel = RemoteExplorerViewModel(endpoint: endpoint)
                tab.state.remoteDirectory = home
                tab.state.remoteHistory = NavigationHistory(home)
                tab.state.remoteHome = home
                tab.state.connectedAt = Date()
                tab.state.endpoint = .remote(endpoint)
                tab.state.connection = .connected(endpoint)
                tab.shell.legend.setRemote(target: endpoint.label, location: home)
            } else if !up && connected {
                detach(tab, message: nil)
                return
            } else if connected, !hasChildProcess(of: tab.shell.view.process.shellPid, named: "ssh") {
                // The session ended (`exit`): the shared connection lives on in the background for the
                // explorer's channels, so close it, unless another tab still uses it, and the tab returns
                // to this Mac.
                let shared = Workspace.all.flatMap(\.tabs).contains { $0 !== tab && $0.state.connection == .connected(endpoint) }
                if !shared { Task.detached { SSHControl.run(endpoint.sshArguments(["-O", "exit"])) } }
                detach(tab, message: nil)
                return
            } else if !up && Date().timeIntervalSince(started) > 2,
                      !hasChildProcess(of: tab.shell.view.process.shellPid, named: "ssh") {
                detach(tab, message: "Couldn't connect to \(endpoint.label). The terminal shows ssh's reason.")
                return
            }
        }
    }

    static func detach(_ tab: TerminalTab, message: String?) {
        // A root session on the host ends with the connection it ran over.
        if case .remote = tab.state.adminTarget {
            tab.state.adminViewModel = nil
            tab.state.adminTarget = nil
        }
        tab.state.endpoint = .local
        tab.state.remoteViewModel = nil
        tab.state.connection = message.map(ConnectionState.failed) ?? .local
        tab.state.connectedAt = nil
        tab.shell.legend.setRemote(target: nil)
    }

    /// Bigger / Smaller like Terminal's View menu: this tab only, until Default (⌘0) or a profile change.
    /// Terminal's rule: ask before ending tabs that run something other than their login shell.
    static func confirmClosing(_ tabs: [TerminalTab], scope: String = "this tab") -> Bool {
        let unsaved = tabs.compactMap(\.editor).filter(\.isEdited)
        if !unsaved.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "These files have changes that aren't saved: " + unsaved.map(\.source.name).joined(separator: ", ")
                + ". Cancel, then save them with ⌘S in their tabs, to keep them."
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        guard TerminalProfile.shared.askBeforeClosing else { return true }
        let running = tabs.flatMap { tab -> [String] in
            var programs = tab.shells.compactMap(\.foregroundProgram)
            if case .connected(let endpoint) = tab.state.connection {
                programs.removeAll { $0 == "ssh" }
                programs.append("ssh (\(endpoint.label))")
            }
            return programs
        }
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to terminate running processes in \(scope)?"
        alert.informativeText = "Closing \(scope) will terminate: " + running.joined(separator: ", ") + "."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Ends the selected tab's remote session by closing its shared connection; the shell returns to the Mac.
    func disconnect() {
        guard case .connected(let endpoint) = selected.state.connection else { return }
        Task.detached { SSHControl.run(endpoint.sshArguments(["-O", "exit"])) }
    }

    /// The SSH button: connection details while connected, otherwise the Connect sheet.
    func connectButton() {
        if case .connected = selected.state.connection { panel = .connection } else { showingSSHConnect = true }
    }

    /// Bigger / Smaller change the selected tab's profile, so the size is kept across sessions and every
    /// tab with that profile follows. Default (⌘0) clears the zoom.
    func zoom(_ delta: CGFloat) {
        TerminalProfile.shared.update(selected.focusedShell.profileID) { $0.zoom += Double(delta) }
    }

    func resetZoom() { TerminalProfile.shared.update(selected.focusedShell.profileID) { $0.zoom = 0 } }

    /// What this window adds around the selected terminal's grid: toolbar, tab strip and scroller. Measured
    /// from the live terminal; nil while it isn't showing a single terminal pane.
    func liveChrome() -> CGSize? {
        guard let window, selected.state.layout == .terminal, selected.shells.count == 1 else { return nil }
        let view = selected.focusedShell.view
        let terminal = view.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0, view.frame.width > 0 else { return nil }
        let content = window.contentRect(forFrameRect: window.frame).size
        let cell = ProfileSettings.cellSize(of: view.font)
        // The grid without the part of a cell left over at the right and bottom edges.
        let optimal = view.getOptimalFrameSize().size
        let scroller = max(0, optimal.width - CGFloat(terminal.cols) * cell.width)
        return CGSize(width: content.width - view.frame.width + scroller, height: content.height - view.frame.height)
    }

    /// One-tab windows teach new windows how much room goes around the grid.
    func rememberChrome() {
        guard tabs.count == 1, let window, !window.styleMask.contains(.fullScreen), let chrome = liveChrome() else { return }
        TerminalProfile.shared.windowChrome = chrome
    }

    /// Resizes the window so the selected terminal shows `columns` × `rows`, staying on its screen. The
    /// first size is worked out from the font; it is then corrected against the terminal's own count, so the
    /// result matches the resize badge exactly (unless the window's minimum size or the screen stops it).
    func resize(columns: Int, rows: Int) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let profile = TerminalProfile.shared
        let view = selected.focusedShell.view
        view.font = selected.focusedShell.settings.font
        var chrome = liveChrome() ?? profile.windowChrome
        if liveChrome() == nil, tabs.count > 1 { chrome.height += 28 }   // the tab strip
        var size = profile.contentSize(columns: columns, rows: rows, profile: selected.focusedShell.profileID, chrome: chrome)
        for _ in 0..<4 {
            setContentSize(size, of: window)
            guard selected.state.layout == .terminal, selected.shells.count == 1 else { break }
            let terminal = view.getTerminal()
            guard terminal.cols > 0, terminal.rows > 0 else { break }
            let (extraColumns, extraRows) = (columns - terminal.cols, rows - terminal.rows)
            guard extraColumns != 0 || extraRows != 0 else { break }
            let optimal = view.getOptimalFrameSize().size
            size.width += CGFloat(extraColumns) * optimal.width / CGFloat(terminal.cols)
            size.height += CGFloat(extraRows) * optimal.height / CGFloat(terminal.rows)
        }
        rememberChrome()
    }

    private func setContentSize(_ size: CGSize, of window: NSWindow) {
        let screen = window.screen?.visibleFrame ?? window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))))
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        if frame.minY < screen.minY { frame.origin.y = screen.minY }
        window.setFrame(frame, display: true)
        // Lay out now so the terminal reports its new columns and rows before the next correction.
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Double-click on the title: the terminal goes back to the default columns × rows and the text to its
    /// profile's size, clearing ⌘+ / ⌘− zoom.
    func restoreDefaultSize() {
        let profile = TerminalProfile.shared
        profile.update(selected.shell.profileID) { $0.zoom = 0 }
        resize(columns: profile.windowColumns, rows: profile.windowRows)
    }

    /// Right-click on the title: the terminal's current columns × rows and text size, zoom included,
    /// become the defaults.
    func makeCurrentSizeDefault() {
        let profile = TerminalProfile.shared
        rememberChrome()
        let terminal = selected.focusedShell.view.getTerminal()
        if terminal.cols > 0, terminal.rows > 0 {
            profile.windowColumns = terminal.cols
            profile.windowRows = terminal.rows
        }
        profile.update(selected.shell.profileID) { $0.fontSize = $0.effectiveSize; $0.zoom = 0 }
    }

    /// Shell ▸ Use Profile: switch the selected tab to another profile.
    func useProfile(_ id: UUID) {
        selected.focusedShell.profileID = id
        if let window { selected.focusedShell.settings.applyTransparency(to: window) }
        objectWillChange.send()
    }

    func close(_ tab: TerminalTab) {
        guard tabs.count > 1, tabs.contains(where: { $0 === tab }) else { return }
        if let editor = tab.editor {
            Task {
                guard await editor.confirmClose() else { return }
                remove(tab)
            }
            return
        }
        guard Self.confirmClosing([tab]) else { return }
        remove(tab)
    }

    /// Takes `tab` out of the window and ends its shells; asks nothing.
    private func remove(_ tab: TerminalTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if selected === tab { selected = tabs[index == 0 ? 1 : index - 1] }
        tabs.remove(at: index)
        focusSelected()
        tab.monitor?.cancel()
        tab.typedSSHWatch?.cancel()
        for shell in tab.shells {
            excludedFromMultiExec.remove(shell.id)
            shell.view.broadcast = nil
            shell.close()
        }
        updateBroadcast()
    }
}

struct WorkspaceView: View {
    @StateObject private var workspace: Workspace

    init(workspace: @autoclosure @escaping () -> Workspace = Workspace()) {
        _workspace = StateObject(wrappedValue: workspace())
    }
    var body: some View {
        ActiveWorkspace(workspace: workspace, state: workspace.selected.state, legend: workspace.selected.shell.legend)
            .onDisappear { workspace.tabs.forEach { $0.shells.forEach { $0.close() } } }
    }
}

private struct ActiveWorkspace: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    @ObservedObject var legend: SessionLegend
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        let tab = workspace.selected
        VStack(spacing: 0) {
            if workspace.multiExec {
                MultiExecGrid(workspace: workspace)
            } else {
                if workspace.tabs.count > 1 {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(workspace.tabs) { item in
                                TabChip(workspace: workspace, item: item, selected: item === tab)
                            }
                        }.buttonStyle(.plain)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let editor = tab.editor {
                    EditorPane(model: editor).id(tab.id)
                } else {
                    SessionView(state: tab.state, shell: tab.shell, tab: tab).id(tab.id)
                }
            }
        }
        // The toolbar sits in the titlebar as a safe-area inset, so content below sees exactly its height
        // as the top inset; a leftover titlebar inset made sidebars and fills paint over the toolbar.
        .safeAreaInset(edge: .top, spacing: 0) {
            SessionToolbar(layout: $state.layout, title: tab.editor.map { $0.source.name } ?? legend.title,
                           subtitle: tab.editor.map { $0.source.location } ?? legend.subtitle,
                           newTab: { workspace.add() },
                           connect: workspace.connectButton,
                           connectedTo: { if case .connected(let e) = state.connection { e.label } else { nil } }(),
                           restoreSize: workspace.restoreDefaultSize,
                           saveSizeAsDefault: workspace.makeCurrentSizeDefault,
                           multiHost: { workspace.multiExec.toggle() },
                           tailcat: { workspace.panel = .tailcat },
                           search: { if let editor = tab.editor { editor.find() } else { tab.state.find() } },
                           exportSession: { workspace.exportSession() },
                           takeScreenshot: { workspace.takeScreenshot() },
                           multiHostActive: workspace.multiExec) {
                Button("New Tab") { workspace.add() }.help("Open another local terminal in this window.")
                Button("New Window") { openWindow(id: "session") }.help("Open a new Herb's Terminal window.")
                Button("Connect via SSH…") { workspace.showingSSHConnect = true }
                    .help("Open a remote shell (⇧⌘K).")
                Menu("Open Tabs") {
                    ForEach(workspace.tabs) { item in
                        Button(item.title) { workspace.select(item) }
                    }
                }
                Divider()
                Button("Find in Terminal…") { tab.state.findInTerminal() }.help("Search this tab's scrollback.")
                Menu("Zoom") {
                    Button("Bigger") { workspace.zoom(1) }.help("Larger text in this tab (⌘+).")
                    Button("Smaller") { workspace.zoom(-1) }.help("Smaller text in this tab (⌘−).")
                    Button("Default") { workspace.resetZoom() }.help("Back to the Settings font size (⌘0).")
                }
                ThemeMenu(profileID: tab.shell.profileID)
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.help("Fill the screen with this window.")
                Divider()
                SettingsLink { Text("Settings…") }.help("Font, size, cursor, window size and color themes (⌘,).")
                Button("About Herb's Terminal") { AboutPanel.show() }
            }
        }
        .task(id: tab.id) {
            guard tab.editor == nil else { return }
            while !Task.isCancelled {
                tab.shell.legend.refresh(tab.shell.view)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // A view presents only one sheet on macOS, so the panels hang off their own background view;
        // sharing the Connect sheet's view left every panel silently unshown.
        .background(EmptyView().sheet(item: $workspace.panel) { panel in
            switch panel {
            case .multiHost:
                MultiHostView(model: workspace.multiHost, targets: workspace.hostTargets) { workspace.panel = nil }
            case .tailcat:
                TailcatPeersView(store: .shared, share: .shared, connect: { peer in
                    do {
                        workspace.connect(try TailcatPeerStore.shared.endpoint(for: peer), password: nil)
                        workspace.panel = nil
                    } catch { TailcatPeerStore.shared.error = error.localizedDescription }
                }) { workspace.panel = nil }
            case .connection:
                ConnectionDetailsView(state: tab.state,
                                      disconnect: { workspace.disconnect(); workspace.panel = nil },
                                      newConnection: { workspace.panel = nil; workspace.showingSSHConnect = true }) { workspace.panel = nil }
            }
        })
        .sheet(isPresented: $workspace.showingSSHConnect) {
            SSHConnectView(
                viewModel: SSHConnectViewModel(),
                onConnect: { login in
                    workspace.showingSSHConnect = false
                    workspace.connectSSH(login)
                },
                onDismiss: {
                    workspace.showingSSHConnect = false
                }
            )
        }
        .focusedSceneValue(\.workspace, workspace)
        // Each extra window from the last session opens its own workspace, which takes the next saved window.
        .onAppear { if SessionRestore.hasPending { openWindow(id: "session") } }
        .background(WindowAccessor { window in
            workspace.window = window
            workspace.selected.shell.settings.applyTransparency(to: window)
            guard workspace.closeGuard == nil else { return }
            workspace.closeGuard = WindowCloseGuard(window: window, workspace: workspace)
            // The scene opens near the default size; snap to the exact default columns × rows once the
            // terminal is laid out.
            guard !workspace.isRestored else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let profile = TerminalProfile.shared
                workspace.resize(columns: profile.windowColumns, rows: profile.windowRows)
            }
        })
        // The window is see-through when the selected tab's profile is.
        .onReceive(TerminalProfile.shared.objectWillChange) {
            DispatchQueue.main.async { if let window = workspace.window { workspace.selected.shell.settings.applyTransparency(to: window) } }
        }
        .onChange(of: tab.id) { if let window = workspace.window { tab.shell.settings.applyTransparency(to: window) } }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)

    }


}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

enum WorkspacePanel: String, Identifiable {
    case multiHost, tailcat, connection
    var id: String { rawValue }
}

/// Shown by the SSH button while the tab is connected.
struct ConnectionDetailsView: View {
    @ObservedObject var state: WindowState
    let disconnect: () -> Void
    let newConnection: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection").font(.headline)
            if case .connected(let endpoint) = state.connection {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Account", endpoint.username)
                    row("Host", endpoint.proxyCommand == nil ? endpoint.host : endpoint.host.replacingOccurrences(of: "tailcat-", with: ""))
                    row("Port", String(endpoint.port))
                    row("Route", endpoint.proxyCommand == nil ? "Direct SSH" : "Tailcat peer")
                    row("Remote home", state.remoteHome)
                    if let since = state.connectedAt {
                        row("Connected", since.formatted(date: .omitted, time: .shortened)
                            + " (" + since.formatted(.relative(presentation: .named)) + ")")
                    }
                    row("Explorer", "Following this host over the shared SSH connection")
                }
                .font(.callout)
            } else {
                Text("This tab isn't connected.").foregroundStyle(.secondary)
            }
            HStack {
                Button("New Connection…", action: newConnection)
                    .hint("New Connection (⇧⌘K)\nConnect to another host in a new tab; this session stays open.")
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                    .hint("Close (Esc)\nClose this panel and stay connected.")
                Button("Disconnect", role: .destructive, action: disconnect)
                    .keyboardShortcut(.defaultAction)
                    .hint("Disconnect (Return)\nEnd the remote session; this tab returns to the Mac's shell and local files.")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Hands the hosting NSWindow to SwiftUI code once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.found(window) } }
        }
    }
}

/// Sits in front of SwiftUI's window delegate to ask before closing a window with running processes,
/// as Terminal does, and forwards every other delegate message unchanged.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    // AppKit asks responds(to:) and forwardingTarget(for:) from nonisolated overrides, always on the main thread.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private weak var workspace: Workspace?

    init(window: NSWindow, workspace: Workspace) {
        original = window.delegate
        self.workspace = workspace
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if original?.windowShouldClose?(sender) == false { return false }
        guard let workspace else { return true }
        // ⌘W (File ▸ Close) closes the current tab while there are others; the close button and the last
        // tab close the window.
        if NSApp.currentEvent?.type == .keyDown {
            if workspace.multiExec, workspace.allShells.count > 1 {
                // In MultiExec, the active terminal in the grid.
                workspace.closePane()
                return false
            }
            if !workspace.multiExec, workspace.tabs.count > 1 {
                workspace.close(workspace.selected)
                return false
            }
        }
        return Workspace.confirmClosing(workspace.tabs, scope: "this window")
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// One tab in the tab strip: click to switch, double-click to rename, drag to reorder.
private struct TabChip: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var item: TerminalTab
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { workspace.select(item) } label: {
                // Selection shows in weight too, not only in the faint background colour.
                Text(item.title).fontWeight(selected ? .semibold : .regular)
            }
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.rename(item) })
                .hint("\(item.title)\nClick to switch, double-click to rename, drag to reorder.")
            Button { workspace.close(item) } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close \(item.title)")
                .hint("Close \(item.title)\nEnd this tab's shell and release its resources.")
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contextMenu {
            Button("Rename Tab…") { workspace.rename(item) }
            Button("Move Tab Left") { workspace.move(item, to: index - 1) }
            Button("Move Tab Right") { workspace.move(item, to: index + 1) }
            Divider()
            Button("Close Tab") { workspace.close(item) }
        }
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in drop(ids) }
    }

    private var index: Int { workspace.tabs.firstIndex { $0 === item } ?? 0 }

    private func drop(_ ids: [String]) -> Bool {
        guard let moved = workspace.tabs.first(where: { $0.id.uuidString == ids.first }) else { return false }
        workspace.move(moved, to: index)
        return true
    }
}

/// "100 × 30" over the terminal while it is being resized (Settings ▸ Window).
struct SizeBadge: View {
    @ObservedObject var legend: SessionLegend
    @ObservedObject private var profile = TerminalProfile.shared

    var body: some View {
        if profile.showSizeWhileResizing && legend.showingSize {
            Text("\(legend.columns) × \(legend.rows)")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("\(legend.columns) columns by \(legend.rows) rows")
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// MultiExec, after MobaXterm's: every tab as a live terminal in a grid, each with a caption bar. Typing in
/// an included terminal goes to every included terminal; uncheck a caption's box to leave that tab out.
struct MultiExecGrid: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var profiles = TerminalProfile.shared
    @ObservedObject private var themes = ThemeLibrary.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            bar
            GeometryReader { geometry in
                let cells = workspace.tabs.flatMap { tab in tab.shells.map { (tab, $0) } }
                let count = cells.count
                let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
                let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
                let gap: CGFloat = 6
                let width = (geometry.size.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
                let height = (geometry.size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                if index < count {
                                    cell(cells[index].0, cells[index].1, number: index + 1).frame(width: width, height: height)
                                } else {
                                    Color.clear.frame(width: width, height: height)
                                }
                            }
                        }
                    }
                }
                .padding(gap)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.3.layers.3d").foregroundStyle(.orange)
            Text("MultiExec: typing goes to \(workspace.multiExecTargets.count) of \(workspace.allShells.count) terminal\(workspace.allShells.count == 1 ? "" : "s")")
                .font(.callout.weight(.semibold))
            Spacer()
            Button("New Tab") { workspace.add() }
                .hint("New Tab\nAdd a local terminal to the grid; it's included in MultiExec.")
            Button("Connect via SSH…") { workspace.showingSSHConnect = true }
                .hint("Connect via SSH\nOpen a session to another host in a new tab of the grid.")
            Button("Include All") { workspace.excludedFromMultiExec = [] }
                .disabled(workspace.excludedFromMultiExec.isEmpty)
                .hint("Include All\nSend typing to every terminal again.")
            Button("Close All") { workspace.closeAllTerminals() }
                .hint("Close All\nEnd every terminal in the grid and leave MultiExec with one new terminal.")
            Button("Exit MultiExec") { workspace.multiExec = false }
                .keyboardShortcut(.cancelAction)
                .hint("Exit MultiExec (Esc)\nBack to one tab at a time.")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.orange.opacity(0.14))
    }

    private func cell(_ tab: TerminalTab, _ shell: LocalShell, number: Int) -> some View {
        let included = !workspace.excludedFromMultiExec.contains(shell.id)
        let focused = tab === workspace.selected && tab.focusedShell === shell
        let settings = profiles.settings(for: shell.profileID)
        let background = themes.theme(named: settings.theme)?.colors["Background Color"] ?? TerminalTypeface.background(dark: colorScheme == .dark)
        return VStack(spacing: 0) {
            ShellPane(session: shell)
                .padding(.leading, 6).padding(.top, 4)
                .background(Color(nsColor: background))
            MultiExecCaption(workspace: workspace, tab: tab, shell: shell, number: number, included: included)
        }
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(focused ? Color.accentColor : included ? Color.orange.opacity(0.55) : Color.secondary.opacity(0.3),
                    lineWidth: focused ? 2 : 1))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { workspace.selected = tab; tab.focusedShell = shell })
        // Each cell is its terminal: keyed by shell, so closing one never leaves another's view in its place.
        .id(shell.id)
    }
}

private struct MultiExecCaption: View {
    @ObservedObject var workspace: Workspace
    let tab: TerminalTab
    let shell: LocalShell
    let number: Int
    let included: Bool
    @ObservedObject private var legend: SessionLegend

    init(workspace: Workspace, tab: TerminalTab, shell: LocalShell, number: Int, included: Bool) {
        self.workspace = workspace
        self.tab = tab
        self.shell = shell
        self.number = number
        self.included = included
        legend = shell.legend
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { included }, set: { workspace.setIncluded(shell, $0) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Include \(number). \(paneTitle) in MultiExec")
                .hint(included ? "Included\nTyping in MultiExec goes to this terminal. Uncheck to leave it out."
                               : "Left out\nThis terminal only takes what you type into it. Check to include it.")
            Image(systemName: { if shell === tab.shell, case .connected = tab.state.connection { "network" } else { "terminal" } }())
                .foregroundStyle(.secondary)
            Text("\(number). \(paneTitle)")
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The tab's name, plus the pane's position when the tab is split.
    private var paneTitle: String {
        let base = tab.customTitle ?? legend.title
        let panes = tab.shells
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === shell }) else { return base }
        return "\(base) (pane \(index + 1))"
    }
}
