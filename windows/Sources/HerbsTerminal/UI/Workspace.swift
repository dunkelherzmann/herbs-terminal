import CHerbUIA
import Foundation
import WinSDK

/// What a tab shows: a terminal (with its explorer) or a text editor.
@MainActor
protocol WorkspaceTab: AnyObject {
    var number: Int { get set }
    var tabName: String { get }
    var title: String { get }
    func show(_ visible: Bool)
    func move(to rect: RECT)
}

extension TerminalPane: WorkspaceTab {}

/// A main window: the toolbar and tab strip across the top (see `WindowChrome`), and a terminal or a text editor
/// per tab below.
@MainActor
final class Workspace: WindowObject {
    static let className = "HerbsTerminalWindow"

    private(set) var hwnd: HWND?
    private var tabs: [WorkspaceTab] = []
    private var active = 0
    private let chrome = WindowChrome()
    private var trackingMouse = false
    private var trackingNonClient = false
    private var observers: [ObservationToken] = []
    /// A tab being dragged to a new place in the strip.
    private var dragging: Int?
    /// The placement to return to when leaving full screen.
    private var fullScreenRestore: WINDOWPLACEMENT?

    init(restoring saved: SavedWindow? = nil) {
        hwnd = createWindow(self, className: Self.className, title: "Herb's Terminal",
                            style: DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN))
        guard let hwnd else { return }
        setDarkTitleBar(hwnd, appIsDark)
        // The toolbar replaces the title bar: recalculate the frame now that WM_NCCALCSIZE draws none.
        SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER))
        // Settings changes reach open terminals at once.
        observers.append(TerminalProfile.shared.objectWillChange.observe { [weak self] in self?.applySettings() })
        observers.append(ThemeLibrary.shared.objectWillChange.observe { [weak self] in self?.applySettings() })
        if let saved, restore(saved) {} else { newTab() }
        sizeToGrid()
        ShowWindow(hwnd, TestScript.active || ParityScene.isActive ? SW_SHOWNOACTIVATE : SW_SHOWDEFAULT)
        // From here on, a change of grid is a resize the size badge shows.
        for pane in panes { pane.markSized() }
        if TestScript.active { SetTimer(hwnd, TestScript.timer, 1500, nil) }
        UpdateWindow(hwnd)
    }

    // MARK: Tabs

    var activeTab: WorkspaceTab? { tabs.indices.contains(active) ? tabs[active] : nil }
    /// The active tab's first pane: the tab itself, with its number, name, SSH connection and explorer.
    var activePane: TerminalPane? { activeTab as? TerminalPane }
    /// The pane with the keyboard focus in the active tab; Clear, Reset, Find and typing act on it.
    var focusedPane: TerminalPane? { activePane.map { $0.group?.focused ?? $0 } }
    var activeEditor: TextEditorPane? { activeTab as? TextEditorPane }
    /// Every shell in the window, split panes included.
    private var panes: [TerminalPane] { tabs.compactMap { $0 as? TerminalPane }.flatMap { $0.group?.panes ?? [$0] } }
    private var editors: [TextEditorPane] { tabs.compactMap { $0 as? TextEditorPane } }
    var activeIndex: Int { active }
    var tabNames: [String] { tabs.map(\.tabName) }
    /// The tabs in order, for the feature tests' bridge.
    var allTabs: [WorkspaceTab] { tabs }

    /// Opens a tab as on the Mac: in the profile's start folder when it has one, else in the current tab's folder
    /// when that's a local shell and Settings asks for it, else in the home folder.
    /// Opens a tab with `profile`, or the current tab's profile, as on the Mac.
    func newTab(profile: Foundation.UUID? = nil) {
        let chosen = profile ?? focusedPane?.profileID
        // Worked out before the new tab becomes the current one: it may start in the current tab's folder.
        let directory = newTabDirectory(chosen)
        if let pane = addPane(profile: chosen) { startShell(pane, in: directory) }
    }

    /// Starts a local shell in `directory` (the home folder when nil); a parity copy starts its own scene shell.
    private func startShell(_ pane: TerminalPane, in directory: String?) {
        if ParityScene.isActive {
            pane.start(commandLine: ParityScene.commandLine, directory: directory ?? ParityScene.home, environment: ParityScene.shellEnvironment)
        } else {
            pane.start(directory: directory)
        }
    }

    private func newTabDirectory(_ chosen: Foundation.UUID?) -> String? {
        let profile = TerminalProfile.shared
        let start = profile.settings(for: chosen).startDirectory.trimmingCharacters(in: .whitespaces)
        var candidate: String?
        if !start.isEmpty {
            let home = ProcessInfo.processInfo.environment["USERPROFILE"] ?? ""
            candidate = start.hasPrefix("~") ? home + start.dropFirst() : start
        } else if profile.newTabsInSameFolder, let pane = activePane, pane.remote == nil {
            candidate = pane.location
        }
        // Only a folder on this PC (a WSL shell can report a Linux path).
        var isFolder: ObjCBool = false
        guard let candidate, FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return candidate
    }

    /// A shell's window, wired to this workspace; the caller places it and starts its process.
    private func makePane(profile: Foundation.UUID?) -> TerminalPane? {
        guard let hwnd else { return nil }
        let pane = TerminalPane(parent: hwnd, profileID: profile)
        pane.onTitleChange = { [weak self] pane in
            self?.refreshChrome()
        }
        pane.onExit = { [weak self] pane in self?.shellExited(pane) }
        pane.onFocus = { [weak self] pane in self?.paneFocused(pane) }
        pane.onContextMenu = { [weak self] pane, point in self?.showContextMenu(for: pane, at: point) }
        pane.onRemoteChange = { [weak self] pane in self?.remoteChanged(pane) }
        return pane
    }

    /// A new, selected tab whose process the caller starts. It takes the lowest free number, as on the Mac.
    private func addPane(profile: Foundation.UUID? = nil) -> TerminalPane? {
        guard let pane = makePane(profile: profile ?? focusedPane?.profileID) else { return nil }
        let used = Set(tabs.map(\.number))
        pane.number = (1...).first { !used.contains($0) }!
        tabs.append(pane)
        layout()
        select(tabs.count - 1)
        return pane
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        active = index
        if multiExec {
            // Every terminal stays in the grid; the selected one takes the keyboard.
            if let head = tabs[index] as? TerminalPane, let window = (head.group?.focused ?? head).hwnd { SetFocus(window) }
            updateOutlines()
            refreshChrome()
            InvalidateRect(hwnd, nil, false)
            return
        }
        for (i, tab) in tabs.enumerated() where i != index {
            tab.show(false)
            (tab as? TerminalPane)?.explorer?.show(false)
        }
        guard let pane = tabs[index] as? TerminalPane else {
            tabs[index].show(true)
            refreshChrome()
            return
        }
        let shells = pane.group?.panes ?? [pane]
        if pane.showingExplorer, let explorer = pane.explorer {
            shells.forEach { $0.show(false) }
            explorer.show(true)
        } else {
            pane.explorer?.show(false)
            shells.forEach { $0.show(true) }
            // The focused pane keeps the keyboard.
            if let focused = pane.group?.focused, let window = focused.hwnd { SetFocus(window) }
        }
        updateOutlines()
        refreshChrome()
    }

    // MARK: Split panes

    /// Split Vertically (side by side) or Horizontally (stacked): a new shell beside the focused pane, in its folder
    /// when that's on this PC, as on the Mac.
    func split(_ axis: PaneNode.Axis) {
        guard let head = activePane, !head.showingExplorer, let current = focusedPane, let pane = makePane(profile: current.profileID) else { return }
        let group = head.group ?? PaneGroup(first: head)
        head.group = group
        group.split(current, axis, adding: pane)
        var isFolder: ObjCBool = false
        let folder = current.remote == nil ? current.location.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue ? $0 : nil
        } : nil
        layout()
        select(active)
        startShell(pane, in: folder)
    }

    /// Close Pane: asks first when a program is running in it, as closing a tab does.
    func closeFocusedPane() {
        guard let head = activePane, let group = head.group, group.isSplit, let pane = group.focused else { return }
        guard confirmClosing([pane], scope: "this pane") else { return }
        closePane(pane)
    }

    /// Select Next / Previous Pane.
    func cyclePane(_ step: Int) {
        guard let group = activePane?.group, group.isSplit else { return }
        group.cycle(step)
        if let window = group.focused?.hwnd { SetFocus(window) }
        updateOutlines()
        refreshChrome()
    }

    /// The tab whose panes include `pane`.
    private func tabIndex(holding pane: TerminalPane) -> Int? {
        tabs.firstIndex { tab in
            guard let head = tab as? TerminalPane else { return false }
            return head === pane || head.group?.panes.contains { $0 === pane } == true
        }
    }

    /// A shell ended (`exit`, or its program quit): its pane closes, then its tab, then the window.
    private func shellExited(_ pane: TerminalPane) {
        guard let index = tabIndex(holding: pane), let head = tabs[index] as? TerminalPane else { return }
        if head.group?.isSplit == true { closePane(pane) } else { close(head) }
    }

    /// Takes one pane out of a split tab. When it's the first pane, the next one takes over the tab: its number and
    /// name. The SSH connection was the closed pane's own program, so its explorer closes with it.
    private func closePane(_ pane: TerminalPane) {
        guard let index = tabIndex(holding: pane), let head = tabs[index] as? TerminalPane, let group = head.group, group.isSplit else { return }
        group.remove(pane)
        if pane === head, let next = group.panes.first {
            next.group = group
            head.group = nil
            next.number = head.number
            next.customName = head.customName
            head.explorer?.close()
            head.explorer = nil
            tabs[index] = next
        }
        pane.close()
        if let first = tabs[index] as? TerminalPane, first.group?.isSplit == false { first.group = nil }
        layout()
        if index == active { select(active) } else { refreshChrome() }
    }

    private func paneFocused(_ pane: TerminalPane) {
        if multiExec, let index = tabIndex(holding: pane), index != active {
            // Clicking a terminal in the grid makes its tab the current one.
            active = index
            (tabs[index] as? TerminalPane)?.group?.focused = pane
            updateOutlines()
            refreshChrome()
            InvalidateRect(hwnd, nil, false)
            return
        }
        guard let index = tabIndex(holding: pane), let group = (tabs[index] as? TerminalPane)?.group else { return }
        guard group.focused !== pane else { return }
        group.focused = pane
        updateOutlines()
        refreshChrome()
    }

    /// The focused pane of a split tab is outlined; a tab with one pane has no outline.
    private func updateOutlines() {
        if multiExec {
            let focused = focusedPane
            for pane in panes { pane.outlined = pane === focused }
            return
        }
        for case let head as TerminalPane in tabs {
            let group = head.group
            for pane in group?.panes ?? [head] { pane.outlined = group?.isSplit == true && pane === group?.focused }
        }
    }

    // MARK: MultiExec

    /// MultiExec, as on the Mac and Linux (after MobaXterm): every terminal of the window in a grid, and what you
    /// type into an included terminal goes to every included terminal.
    private(set) var multiExec = false
    private var excluded = Set<ObjectIdentifier>()
    private var multiControls: MultiExecControls?

    /// Every terminal in grid order (tabs in order, each tab's panes in order).
    var allPanes: [TerminalPane] { panes }
    /// The grid numbers of the terminals left out, for the feature tests' bridge.
    var excludedNumbers: [Int] { panes.enumerated().filter { excluded.contains(ObjectIdentifier($0.element)) }.map { $0.offset + 1 } }

    func setMultiExec(_ on: Bool) {
        guard multiExec != on, let hwnd else { return }
        multiExec = on
        if on {
            multiControls = MultiExecControls(owner: hwnd)
            // Every terminal is shown, even a tab that shows its explorer; editors and explorers step aside.
            for tab in tabs {
                if let head = tab as? TerminalPane { head.explorer?.show(false); (head.group?.panes ?? [head]).forEach { $0.show(true) } }
                else { tab.show(false) }
            }
        } else {
            multiControls?.destroy()
            multiControls = nil
            for pane in panes { pane.broadcast = nil }
        }
        updateBroadcast()
        layout()
        if on { select(active) } else { select(min(active, tabs.count - 1)) }
    }

    /// Includes or leaves out the terminal with this grid number (1 is the first).
    func setIncluded(number: Int, _ included: Bool) {
        let all = panes
        guard all.indices.contains(number - 1) else { return }
        if included { excluded.remove(ObjectIdentifier(all[number - 1])) } else { excluded.insert(ObjectIdentifier(all[number - 1])) }
        updateBroadcast()
        layout()
    }

    func includeAll() {
        excluded = []
        updateBroadcast()
        layout()
    }

    /// Wires each included terminal to send its user input on to the other included terminals.
    private func updateBroadcast() {
        let all = panes
        excluded = excluded.filter { id in all.contains { ObjectIdentifier($0) == id } }
        let targets = all.filter { !excluded.contains(ObjectIdentifier($0)) }
        for pane in all {
            guard multiExec, !excluded.contains(ObjectIdentifier(pane)) else { pane.broadcast = nil; continue }
            pane.broadcast = { [weak pane] bytes in
                for other in targets where other !== pane { other.sendQuietly(bytes) }
            }
        }
    }

    private func layoutMultiExec(_ controls: MultiExecControls, in rect: RECT) {
        let all = panes
        updateBroadcast()
        var titles: [String] = []
        for tab in tabs {
            guard let head = tab as? TerminalPane else { tab.show(false); continue }
            head.explorer?.show(false)
            let group = head.group?.panes ?? [head]
            for (index, pane) in group.enumerated() {
                // The tab's name, or its host, plus the pane's position when the tab is split.
                let base = pane.remote?.label ?? head.tabName
                titles.append(group.count > 1 ? "\(base) (pane \(index + 1))" : base)
            }
        }
        let included = all.map { !excluded.contains(ObjectIdentifier($0)) }
        let count = included.filter { $0 }.count
        controls.status = "MultiExec: typing goes to \(count) of \(all.count) terminal\(all.count == 1 ? "" : "s")"
        let frames = controls.layout(in: rect, titles: titles, included: included, includeAllEnabled: !excluded.isEmpty)
        for (pane, frame) in zip(all, frames) {
            pane.move(to: frame)
            pane.show(true)
        }
        if let focused = focusedPane?.hwnd, GetFocus() == nil || !all.contains(where: { $0.hwnd == GetFocus() }) {
            if !controls.owns(GetFocus()) { SetFocus(focused) }
        }
        updateOutlines()
    }

    /// A bar button or checkbox was pressed (WM_COMMAND).
    private func multiExecCommand(_ id: Int, control: HWND?) {
        if id >= MultiExecControls.checkboxBase {
            let checked = SendMessageW(control, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
            setIncluded(number: id - MultiExecControls.checkboxBase + 1, checked)
            return
        }
        switch MultiExecControls.Action(rawValue: id) {
        case .newTab?: newTab()
        case .connect?: showConnect()
        case .includeAll?: includeAll()
        case .closeAll?: closeAllTerminals()
        case .exit?: setMultiExec(false)
        case nil: break
        }
    }

    /// MultiExec ▸ Close All: ends every terminal after asking, then leaves MultiExec with one new terminal. Editor
    /// tabs stay open.
    func closeAllTerminals() {
        let terminals = tabs.compactMap { $0 as? TerminalPane }
        let shells = terminals.flatMap { $0.group?.panes ?? [$0] }
        let count = shells.count
        guard FormDialog.ask(owner: hwnd, title: "Close all \(count) terminal\(count == 1 ? "" : "s")?",
                             message: "Every shell and remote session in the grid ends. A new terminal opens in their place.",
                             buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Close All")]) == 1,
              confirmClosing(shells, scope: "these terminals") else { return }
        for head in terminals {
            head.explorer?.close()
            for shell in head.group?.panes ?? [head] { shell.broadcast = nil; shell.close() }
            head.group = nil
        }
        tabs.removeAll { $0 is TerminalPane }
        excluded = []
        multiControls?.destroy()
        multiControls = nil
        multiExec = false
        newTab()
        layout()
    }

    /// In MultiExec, Alt+1–Alt+9 pick a terminal by its grid number (9 is the last).
    private func selectGridTerminal(_ number: Int) {
        let all = panes
        guard !all.isEmpty else { return }
        let index = number == 9 ? all.count - 1 : number - 1
        guard all.indices.contains(index), let window = all[index].hwnd else { return }
        SetFocus(window)
    }

    // MARK: Session restore

    /// This window as session restore saves it: each terminal tab's folder, layout, name, explorer folder, profile
    /// and split panes. An SSH tab reopens as a local shell in the home folder; logins are never replayed. Editor
    /// tabs aren't reopened.
    var savedWindow: SavedWindow {
        let terminals = tabs.compactMap { $0 as? TerminalPane }
        let home = FileManager.default.homeDirectoryForCurrentUser.path.windowsPath
        return SavedWindow(tabs: terminals.map { head in
            let localExplorer = head.explorer.flatMap { $0.remote == nil ? $0.folder : nil }
            return SavedTab(directory: (head.remote == nil ? head.location : nil) ?? home,
                            layout: head.showingExplorer && localExplorer != nil ? "explorer" : "terminal",
                            title: head.customName, explorerPath: localExplorer ?? "", profile: head.profileID?.uuidString,
                            panes: head.group?.isSplit == true ? head.group?.root.saved : nil)
        }, selected: terminals.firstIndex { $0 === activeTab } ?? 0)
    }

    /// Saves every window (Settings ▸ Terminal ▸ Restore windows and tabs). Parity copies never touch the session.
    static func saveSession() {
        guard !ParityScene.isActive else { return }
        guard TerminalProfile.shared.restoreSession else { SavedSession.clear(); return }
        SavedSession.write(App.allWorkspaces.map(\.savedWindow).filter { !$0.tabs.isEmpty })
    }

    /// Reopens a saved window's tabs. Folders that no longer exist start in the home folder instead.
    private func restore(_ saved: SavedWindow) -> Bool {
        func folder(_ path: String?) -> String? {
            var isFolder: ObjCBool = false
            guard let path, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            return path
        }
        for tab in saved.tabs {
            let profile = tab.profile.flatMap(Foundation.UUID.init(uuidString:)).flatMap { id in
                TerminalProfile.shared.profiles.contains { $0.id == id } ? id : nil
            }
            guard let head = addPane(profile: profile) else { continue }
            head.customName = tab.title
            startShell(head, in: folder(tab.directory))
            if let shape = tab.panes {
                var first: TerminalPane? = head
                var others: [(TerminalPane, String?)] = []
                let root = PaneNode.restore(shape, first: &first) { directory in
                    guard let pane = self.makePane(profile: profile) else { return nil }
                    others.append((pane, directory))
                    return pane
                }
                if let root, root.leaves.count > 1 {
                    head.group = PaneGroup(root: root)
                    layout()
                    // Started once they have their size, so each shell starts with the right grid.
                    for (pane, directory) in others { startShell(pane, in: folder(directory)) }
                }
            }
            if tab.layout == "explorer" {
                select(tabs.count - 1)
                toggleExplorer()
                if let path = folder(tab.explorerPath) { head.explorer?.navigate(to: path) }
            }
        }
        layout()
        select(max(0, min(saved.selected, tabs.count - 1)))
        return !tabs.isEmpty
    }

    /// For the feature tests: sizes the window so its terminal shows `columns` × `rows`.
    func resize(columns: Int, rows: Int) { sizeToGrid(columns: columns, rows: rows) }

    // MARK: Right-click menu

    /// The terminal's right-click menu, item for item as on the Mac and Linux, with Windows' shortcuts. nil is a
    /// divider. The feature tests' bridge reads and chooses from this same list.
    func contextMenuEntries(for pane: TerminalPane) -> [(title: String, command: MenuCommand, enabled: Bool)?] {
        guard let index = tabIndex(holding: pane), let head = tabs[index] as? TerminalPane else { return [] }
        let canPaste = pane.hwnd.flatMap { clipboardText($0) }.map { !$0.isEmpty } ?? false
        var entries: [(title: String, command: MenuCommand, enabled: Bool)?] = [
            ("Copy\tCtrl+Shift+C", .copy, pane.hasSelection), ("Paste\tCtrl+Shift+V", .paste, canPaste),
            ("Paste Escaped Text\tCtrl+Alt+V", .pasteEscaped, canPaste), ("Select All\tCtrl+Shift+A", .selectAll, true), nil,
            ("Find…\tCtrl+Shift+F", .findInTerminal, true), ("Clear to Start\tCtrl+Shift+L", .clearToStart, true),
            ("Clear Scrollback\tCtrl+Alt+K", .clearScrollback, true), ("Reset\tCtrl+Alt+R", .reset, true), nil,
            ("Split Vertically\tCtrl+Shift+E", .splitVertical, true), ("Split Horizontally\tCtrl+Shift+O", .splitHorizontal, true),
        ]
        if head.group?.isSplit == true { entries.append(("Close Pane\tCtrl+Alt+W", .closePane, true)) }
        entries += [nil, ("New Tab\tCtrl+Shift+T", .newTab, true), ("Show File Explorer\tCtrl+Shift+X", .showExplorer, true), nil]
        if head.isConnected, let remote = head.remote { entries.append(("Disconnect from \(remote.label)", .disconnect, true)) }
        entries += [("Connect via SSH…\tCtrl+Shift+K", .connect, true), nil,
                    ("Bigger\tCtrl+=", .zoomIn, true), ("Smaller\tCtrl+-", .zoomOut, true), ("Settings…\tCtrl+,", .settings, true)]
        return entries
    }

    private func showContextMenu(for pane: TerminalPane, at point: POINT) {
        guard let hwnd else { return }
        paneFocused(pane)
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        for entry in contextMenuEntries(for: pane) {
            guard let entry else { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil); continue }
            _ = withWide(entry.title) { AppendMenuW(menu, UINT(MF_STRING) | (entry.enabled ? 0 : UINT(MF_GRAYED)), UINT_PTR(entry.command.rawValue), $0) }
        }
        let chosen = MainMenu.trackPopup(menu, at: point, owner: hwnd)
        if chosen != 0 { perform(chosen) }
    }

    /// A Tailcat peer's address for the explorer's own channel, with the shared local proxy started for it.
    private static func tailcatAddress(for endpoint: RemoteEndpoint) -> String? {
        guard let address = try? Tailcat.address(for: endpoint) else { return nil }
        Tailcat.startSocks()
        return address
    }

    // MARK: Run Command on Hosts

    /// Kept for the window's life, so the command and the chosen hosts are still there when it opens again.
    let multiHost = MultiHostRunner()

    /// The tab's live connection first, then every saved login (once each), as on the Mac and Linux.
    var hostTargets: [HostTarget] {
        var targets: [HostTarget] = []
        if let pane = activePane, pane.isConnected, let endpoint = pane.remote {
            targets.append(HostTarget(endpoint: endpoint, password: pane.remotePassword, source: "this tab's connection"))
        }
        for login in CredentialStore.shared?.logins ?? [] {
            let target = HostTarget(endpoint: RemoteEndpoint(host: login.host, port: login.port, username: login.username),
                                    password: login.password.isEmpty ? nil : login.password, source: "saved login")
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    func showRunOnHosts() {
        RunOnHostsWindow.show(owner: hwnd, runner: multiHost, targets: hostTargets)
    }

    // MARK: File explorer

    /// Show File Explorer / Show Terminal (Ctrl+Shift+X): the tab switches between its shell and its explorer,
    /// which keeps its folder while hidden.
    func toggleExplorer() {
        guard let hwnd, let pane = activePane else { return }
        if !pane.showingExplorer {
            if pane.explorer == nil {
                let explorer: ExplorerPane
                if let endpoint = pane.remote {
                    // An SSH tab's explorer shows that host, over its own SFTP channel with the tab's login.
                    explorer = ExplorerPane(parent: hwnd, start: ".", remote: RemoteSession(endpoint: endpoint, password: pane.remotePassword,
                                                                                         tailcatAddress: Self.tailcatAddress(for: endpoint)))
                } else {
                    explorer = ExplorerPane(parent: hwnd, start: FileManager.default.homeDirectoryForCurrentUser.path.windowsPath)
                }
                explorer.onOpenInTerminal = { [weak self] folder in self?.newTab(in: folder) }
                explorer.onLocationChange = { [weak self] in self?.refreshChrome() }
                explorer.onOpenInEditor = { [weak self] source in self?.openEditor(source) }
                pane.explorer = explorer
                layout()
            }
        }
        pane.showingExplorer.toggle()
        select(active)
    }

    /// A new tab whose shell starts in `folder` (the explorer's Open in New Terminal Tab).
    func newTab(in folder: String) {
        addPane()?.start(directory: folder)
    }

    // MARK: Text editor

    /// Opens `source` in an editor tab beside the current one, or selects the tab already showing it.
    func openEditor(_ source: TextFileSource) {
        guard let hwnd else { return }
        if let open = tabs.firstIndex(where: { ($0 as? TextEditorPane)?.source.location == source.location }) {
            select(open)
            return
        }
        let editor = TextEditorPane(parent: hwnd, source: source)
        editor.onFailure = { [weak self, weak editor] in if let editor { self?.close(editor) } }
        editor.onChange = { [weak self] in self?.refreshChrome() }
        let index = min(active + 1, tabs.count)
        tabs.insert(editor, at: index)
        layout()
        select(index)
    }

    /// Asks each editor with unsaved changes in turn; `done(true)` when all of them may close.
    private func confirmEditors(_ list: [TextEditorPane], _ done: @escaping (Bool) -> Void) {
        guard let editor = list.first else { done(true); return }
        if let index = tabs.firstIndex(where: { $0 === editor }), editor.isEdited { select(index) }
        editor.confirmClose { [weak self] ok in
            guard ok else { done(false); return }
            self?.confirmEditors(Array(list.dropFirst()), done)
        }
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let pane = tab as? TerminalPane {
            pane.explorer?.close()
            for shell in pane.group?.panes ?? [pane] { shell.close() }
            pane.group = nil
        }
        (tab as? TextEditorPane)?.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            if let hwnd { DestroyWindow(hwnd) }
            return
        }
        // The tab that was active stays active; closing the active tab moves to its neighbour.
        select(active > index ? active - 1 : min(active, tabs.count - 1))
        layout()
    }

    /// Ends every tab's shell without asking (the app is quitting).
    func closeAll() {
        for pane in panes { pane.close() }
        for editor in editors { editor.close() }
        tabs.removeAll()
    }

    private func closeTab(at index: Int, confirm: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        if let editor = tabs[index] as? TextEditorPane {
            editor.confirmClose { [weak self, weak editor] ok in if ok, let editor { self?.close(editor) } }
            return
        }
        guard let pane = tabs[index] as? TerminalPane else { return }
        if confirm, !confirmClosing(pane.group?.panes ?? [pane], scope: "this tab") { return }
        close(pane)
    }

    /// As on the Mac: asks only when a program is running in the foreground (or an SSH session is open), and names
    /// what would end. A shell waiting at its prompt closes without a question.
    private func confirmClosing(_ panes: [TerminalPane], scope: String) -> Bool {
        guard TerminalProfile.shared.askBeforeClosing else { return true }
        let running = panes.compactMap(\.runningProgram)
        guard !running.isEmpty else { return true }
        return FormDialog.ask(owner: hwnd, title: "Do you want to terminate running processes in \(scope)?",
                              message: "Closing \(scope) will terminate: " + running.joined(separator: ", ") + ".",
                              buttons: [.init(title: "Cancel"), .init(title: "Terminate", isDefault: true)]) == 1
    }

    private func move(from index: Int, to target: Int) {
        guard tabs.indices.contains(index), tabs.indices.contains(target), index != target else { return }
        let pane = tabs.remove(at: index)
        tabs.insert(pane, at: target)
        active = target
        refreshChrome()
    }

    private func rename(_ index: Int) {
        // Editor tabs show their file's name.
        guard tabs.indices.contains(index), let pane = tabs[index] as? TerminalPane else { return }
        guard let result = FormDialog.run(owner: hwnd, title: "Rename Tab", message: "Leave the name empty to go back to “Terminal \(pane.number)”.",
                                          fields: [.init(label: "Name", text: pane.customName ?? "")],
                                          buttons: [.init(title: "Cancel"), .init(title: "Rename", isDefault: true)]),
              result.button == 1 else { return }
        let name = result.values[0].trimmingCharacters(in: .whitespaces)
        pane.customName = name.isEmpty ? nil : name
        refreshChrome()
    }

    // MARK: SSH

    func showConnect() {
        ConnectDialog.run(owner: hwnd) { [weak self] login in self?.connectSSH(login) }
    }

    /// The toolbar's SSH button: connection details while the tab is connected, Connect via SSH otherwise.
    func connectButton() {
        guard let pane = activePane, pane.isConnected, let remote = pane.remote else { showConnect(); return }
        var lines = ["Account: \(remote.username)", "Host: \(remote.host)", "Port: \(remote.port)", "Route: Direct SSH (Windows OpenSSH)"]
        if let since = pane.connectedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            lines.append("Connected: " + formatter.string(from: since) + (minutes < 1 ? " (just now)" : " (\(minutes) min ago)"))
        }
        let answer = FormDialog.ask(owner: hwnd, title: "Connection", message: lines.joined(separator: "\n"),
                                    buttons: [.init(title: "New Connection…"), .init(title: "Close"), .init(title: "Disconnect", isDefault: true)],
                                    cancelIndex: 1)
        switch answer {
        case 0: showConnect()
        case 2: pane.disconnect()
        default: break
        }
    }

    /// Starts the login in the focused terminal's own shell, as on the Mac and Linux; a terminal already in an SSH
    /// session or running a program (or an editor tab) gets a new tab instead. A saved or typed password reaches ssh
    /// only through the password helper.
    func connectSSH(_ login: SSHLogin) {
        connect(RemoteEndpoint(host: login.host, port: login.port, username: login.username), password: login.password.isEmpty ? nil : login.password)
    }

    /// Connects to `endpoint` (a login, or a Tailcat peer) in the focused terminal or a new tab.
    func connect(_ endpoint: RemoteEndpoint, password: String?) {
        if let pane = focusedPane, activePane?.showingExplorer == false, pane.remote == nil, pane.isRunning, pane.runningProgram == nil {
            pane.connectSSH(endpoint, password: password)
        } else {
            newTab()
            focusedPane?.connectSSH(endpoint, password: password)
        }
    }

    /// The tab's connection started or ended: its explorer moves to the host or back to this PC, in the same place
    /// on screen. Only the tab's first pane owns the connection, as on the Mac.
    private func remoteChanged(_ pane: TerminalPane) {
        guard let index = tabIndex(holding: pane), let head = tabs[index] as? TerminalPane, head === pane else { return }
        guard let explorer = head.explorer, explorer.endpoint != head.remote else { refreshChrome(); return }
        let showing = head.showingExplorer
        explorer.close()
        head.explorer = nil
        head.showingExplorer = false
        if showing {
            select(index)
            toggleExplorer()
        } else if index == active {
            select(active)
        }
    }

    func showLogins() {
        ManageLoginsWindow.show(owner: hwnd)
    }

    // MARK: Commands

    func showSettings() {
        SettingsWindow.show(owner: hwnd)
    }

    private func zoom(_ step: Double) {
        TerminalProfile.shared.update(focusedPane?.profileID) { settings in settings.zoom = step == 0 ? 0 : settings.zoom + step }
    }

    /// Export Session: everything in the terminal, scrollback included, to a text file named after the tab and time.
    func exportSession() {
        guard let pane = focusedPane else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let safe = pane.tabName.map { "\\/:*?\"<>|".contains($0) ? "-" : $0 }
        let name = String(safe) + " " + formatter.string(from: Date()) + ".txt"
        guard let path = saveFile(owner: hwnd, title: "Export Session", name: name, filter: [("Text files (*.txt)", "*.txt")],
                                  defaultExtension: "txt") else { return }
        do {
            try Data(pane.exportText().replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            LoginVaultPrompts.show(error, owner: hwnd, heading: "The session couldn't be exported")
        }
    }

    /// Take Screenshot: a picture of this whole window as it looks now, toolbar and tabs included, on the clipboard,
    /// ready to paste. The button shows a check mark for a moment to confirm it.
    func takeScreenshot() {
        guard let hwnd, Self.copyWindowImage(hwnd) else { MessageBeep(UINT(MB_ICONWARNING)); return }
        screenshotCopied = true
        refreshChrome()
        SetTimer(hwnd, Self.screenshotTimer, 1500, nil)
    }

    private var screenshotCopied = false
    private static let screenshotTimer: UINT_PTR = 0x5C57

    /// The window drawn by PrintWindow (as the test hook's --capture does), on the clipboard as a bottom-up
    /// 32-bit CF_DIB, which every program that pastes images reads.
    private static func copyWindowImage(_ hwnd: HWND) -> Bool {
        var rect = RECT()
        GetWindowRect(hwnd, &rect)
        let width = rect.right - rect.left, height = rect.bottom - rect.top
        guard width > 0, height > 0 else { return false }
        let screen = GetDC(nil)
        defer { ReleaseDC(nil, screen) }
        let dc = CreateCompatibleDC(screen)
        defer { DeleteDC(dc) }
        guard let bitmap = CreateCompatibleBitmap(screen, width, height) else { return false }
        defer { DeleteObject(bitmap) }
        let old = SelectObject(dc, bitmap)
        PrintWindow(hwnd, dc, 2) // PW_RENDERFULLCONTENT
        SelectObject(dc, old)

        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = height
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        let headerSize = MemoryLayout<BITMAPINFOHEADER>.size, pixelSize = Int(width) * Int(height) * 4
        info.bmiHeader.biSizeImage = DWORD(pixelSize)
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(headerSize + pixelSize)) else { return false }
        guard let base = GlobalLock(memory) else { GlobalFree(memory); return false }
        base.storeBytes(of: info.bmiHeader, as: BITMAPINFOHEADER.self)
        let lines = GetDIBits(dc, bitmap, 0, UINT(height), base + headerSize, &info, UINT(DIB_RGB_COLORS))
        GlobalUnlock(memory)
        if TestClipboard.isActive {
            // The parity copy keeps its picture off the user's clipboard; the tests only need to know it was made.
            GlobalFree(memory)
            guard lines == height else { return false }
            TestClipboard.clear()
            TestClipboard.image = true
            return true
        }
        guard lines == height, OpenClipboard(hwnd) else { GlobalFree(memory); return false }
        EmptyClipboard()
        let placed = SetClipboardData(UINT(CF_DIB), memory) != nil
        CloseClipboard()
        if !placed { GlobalFree(memory) } // Once placed, the clipboard owns the memory.
        return placed
    }

    private func toggleFullScreen() {
        guard let hwnd else { return }
        let style = DWORD(bitPattern: Int32(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_STYLE)))
        if let placement = fullScreenRestore {
            SetWindowLongPtrW(hwnd, GWL_STYLE, LONG_PTR(Int32(bitPattern: style | DWORD(WS_OVERLAPPEDWINDOW))))
            var restore = placement
            SetWindowPlacement(hwnd, &restore)
            SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED))
            fullScreenRestore = nil
        } else {
            var placement = WINDOWPLACEMENT()
            placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
            GetWindowPlacement(hwnd, &placement)
            var monitor = MONITORINFO()
            monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
            fullScreenRestore = placement
            SetWindowLongPtrW(hwnd, GWL_STYLE, LONG_PTR(Int32(bitPattern: style & ~DWORD(WS_OVERLAPPEDWINDOW))))
            let r = monitor.rcMonitor
            SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOOWNERZORDER | SWP_FRAMECHANGED))
        }
        layout()
    }

    private func showAbout() {
        FormDialog.tell(owner: hwnd, title: "Herb's Terminal \(appVersion)",
                        message: "A terminal for administrators.\n\nBy dunkelherzmann — github.com/dunkelherzmann/herbs-terminal\nCopyright © 2026 Herbert Cisneros. MIT License.")
    }

    private func restoreTheming() {
        guard FormDialog.ask(owner: hwnd, title: "Restore theming defaults for “\(TerminalProfile.shared.name(of: nil))”?",
                             message: "Font, size and zoom, cursor, color theme, transparency and appearance go back to the stock Basic look. Imported presets are kept.",
                             buttons: [.init(title: "Cancel"), .init(title: "Restore Defaults", isDefault: true)]) == 1 else { return }
        TerminalProfile.shared.update(focusedPane?.profileID) { $0.restoreTheming() }
        TerminalProfile.shared.appearance = "System"
    }

    private func importPreset() {
        guard let path = openFile(owner: hwnd, title: "Import a Color Preset",
                                  filter: [("iTerm2 color presets (*.itermcolors)", "*.itermcolors")]) else { return }
        do {
            let name = try ThemeLibrary.shared.importFile(URL(fileURLWithPath: path))
            TerminalProfile.shared.update(focusedPane?.profileID) { $0.theme = name }
        } catch {
            LoginVaultPrompts.show(error, owner: hwnd, heading: "Couldn't import that preset")
        }
    }

    func perform(_ id: UINT) {
        if id >= MenuCommand.firstShowTab {
            let number = Int(id - MenuCommand.firstShowTab) + 1
            select(number == 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1))
            return
        }
        if id >= MenuCommand.firstPreset, id < MenuCommand.firstNewTabProfile {
            let names = ThemeLibrary.shared.allNames
            let index = Int(id - MenuCommand.firstPreset)
            if names.indices.contains(index) { TerminalProfile.shared.update(focusedPane?.profileID) { $0.theme = names[index] } }
            return
        }
        let profiles = TerminalProfile.shared.profiles
        if id >= MenuCommand.firstUseProfile, profiles.indices.contains(Int(id - MenuCommand.firstUseProfile)) {
            focusedPane?.use(profile: profiles[Int(id - MenuCommand.firstUseProfile)].id)
            refreshChrome()
            return
        }
        if id >= MenuCommand.firstNewTabProfile, profiles.indices.contains(Int(id - MenuCommand.firstNewTabProfile)) {
            newTab(profile: profiles[Int(id - MenuCommand.firstNewTabProfile)].id)
            return
        }
        if id >= MenuCommand.firstTab { select(Int(id - MenuCommand.firstTab)); return }
        guard let command = MenuCommand(rawValue: id) else { return }
        let pane = focusedPane
        switch command {
        case .newTab: newTab()
        case .newWindow: App.newWindow()
        case .connect, .newRemoteConnection: showConnect()
        case .zoomIn: zoom(1)
        case .zoomOut: zoom(-1)
        case .zoomReset: zoom(0)
        case .schemeSystem: TerminalProfile.shared.appearance = "System"
        case .schemeLight: TerminalProfile.shared.appearance = "Light"
        case .schemeDark: TerminalProfile.shared.appearance = "Dark"
        case .presetBasic: TerminalProfile.shared.update(focusedPane?.profileID) { $0.theme = "" }
        case .importPreset: importPreset()
        case .restoreTheming: restoreTheming()
        case .exportSession: exportSession()
        case .takeScreenshot: takeScreenshot()
        case .disconnect: activePane?.disconnect()
        case .previousTab: select((active - 1 + tabs.count) % tabs.count)
        case .nextTab: select((active + 1) % tabs.count)
        case .renameTab: rename(active)
        case .moveTabLeft: move(from: active, to: active - 1)
        case .moveTabRight: move(from: active, to: active + 1)
        case .clearToStart: pane?.clearToStart()
        case .clearScrollback: pane?.clearScrollback()
        case .reset: pane?.reset(hard: false)
        case .hardReset: pane?.reset(hard: true)
        case .fullScreen: toggleFullScreen()
        case .settings: showSettings()
        case .manageLogins: showLogins()
        case .about: showAbout()
        case .quit: App.quit()
        case .restoreDefaultSize:
            zoom(0)
            sizeToGrid()
        case .makeSizeDefault:
            if let pane {
                TerminalProfile.shared.windowColumns = pane.terminal.cols
                TerminalProfile.shared.windowRows = pane.terminal.rows
            }
        case .closeTab:
            // In MultiExec only the active terminal closes, as on the Mac.
            if multiExec, let head = activePane, head.group?.isSplit == true, let pane = focusedPane {
                if confirmClosing([pane], scope: "this terminal") { closePane(pane) }
            } else {
                closeTab(at: active)
            }
        case .splitVertical: split(.horizontal)
        case .splitHorizontal: split(.vertical)
        case .closePane: closeFocusedPane()
        case .nextPane: cyclePane(1)
        case .previousPane: cyclePane(-1)
        case .multiExec: setMultiExec(!multiExec)
        case .runOnHosts: showRunOnHosts()
        case .undo: if let field = MainMenu.focusedTextField() { SendMessageW(field, UINT(WM_UNDO), 0, 0) }
        case .redo: break  // Windows text fields keep one undo step, which Undo toggles
        case .cut: if let field = MainMenu.focusedTextField() { SendMessageW(field, UINT(WM_CUT), 0, 0) }
        case .copy:
            if let field = MainMenu.focusedTextField() { SendMessageW(field, UINT(WM_COPY), 0, 0) } else { pane?.copySelection() }
        case .paste:
            if let field = MainMenu.focusedTextField() { SendMessageW(field, UINT(WM_PASTE), 0, 0) } else { pane?.paste() }
        case .pasteEscaped: pane?.pasteEscaped()
        case .selectAll:
            if let field = MainMenu.focusedTextField() { SendMessageW(field, UINT(EM_SETSEL), 0, -1) } else { pane?.selectAll() }
        case .minimize: if let hwnd { ShowWindow(hwnd, SW_MINIMIZE) }
        case .maximize: if let hwnd { ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE) }
        case .showExplorer: if activePane?.showingExplorer == false { toggleExplorer() }
        case .findInTerminal:
            // In the explorer, Find filters the folder by name (the toolbar's Search does the same).
            if activePane?.showingExplorer == true { activePane?.explorer?.showFilter() } else { pane?.showFind() }
        }
    }

    /// Opens the Main Menu under its toolbar button.
    func openMainMenu() {
        guard let hwnd else { return }
        let rect = chrome.rects[.menu] ?? RECT()
        var screen = POINT(x: rect.left, y: rect.bottom + scaled(4, dpi: dpi))
        ClientToScreen(hwnd, &screen)
        let chosen = MainMenu.show(for: self, at: screen, owner: hwnd)
        if chosen != 0 { perform(chosen) }
    }

    /// Keyboard shortcuts, checked before the message reaches the focused terminal. Returns true when handled.
    func shortcut(_ message: MSG) -> Bool {
        if let pane = focusedPane, pane.handleFindKey(message) { return true }
        if let explorer = activePane?.explorer, activePane?.showingExplorer == true, explorer.handleKey(message) { return true }
        if let editor = activeEditor, editor.handleKey(message) { return true }
        let isKey = message.message == UINT(WM_KEYDOWN), isSystemKey = message.message == UINT(WM_SYSKEYDOWN)
        guard isKey || isSystemKey else { return false }
        let key = Int32(message.wParam)
        let control = isPressed(VK_CONTROL), shift = isPressed(VK_SHIFT), alt = isPressed(VK_MENU)
        func letter(_ c: Character) -> Bool { key == Int32(c.asciiValue!) }
        func run(_ command: MenuCommand) -> Bool { perform(command.rawValue); return true }

        if key == VK_F11 && !control && !shift && !alt { return run(.fullScreen) }
        if control && shift && !alt {
            if letter("T") { return run(.newTab) }
            if letter("W") { return run(.closeTab) }
            if letter("N") { return run(.newWindow) }
            if letter("K") { return run(.connect) }
            if letter("X") { toggleExplorer(); return true }
            if letter("S") { return run(.exportSession) }
            if letter("I") { return run(.renameTab) }
            if letter("L") { return run(.clearToStart) }
            if letter("E") { return run(.splitVertical) }
            if letter("M") { return run(.multiExec) }
            if letter("F") { return run(.findInTerminal) }
            if letter("A") { return run(.selectAll) }
            if letter("O") { return run(.splitHorizontal) }
            if letter("Q") { return run(.quit) }
            if key == VK_PRIOR { return run(.moveTabLeft) }
            if key == VK_NEXT { return run(.moveTabRight) }
            if key == VK_TAB { return run(.previousTab) }
        }
        if control && alt && !shift {
            if letter("W") { return run(.closePane) }
            if letter("V") { return run(.pasteEscaped) }
            if key == VK_RIGHT { return run(.nextPane) }
            if key == VK_LEFT { return run(.previousPane) }
            if letter("K") { return run(.clearScrollback) }
            if letter("R") { return run(.reset) }
            if letter("S") { return run(.takeScreenshot) }
        }
        if control && alt && shift && letter("R") { return run(.hardReset) }
        if control && !shift && !alt {
            if key == VK_TAB || key == VK_NEXT { return run(.nextTab) }
            if key == VK_PRIOR { return run(.previousTab) }
            if key == VK_OEM_PLUS || key == VK_ADD { return run(.zoomIn) }
            if key == VK_OEM_MINUS || key == VK_SUBTRACT { return run(.zoomOut) }
            if letter("0") || key == VK_NUMPAD0 { return run(.zoomReset) }
            if key == VK_OEM_COMMA { return run(.settings) }
        }
        // Esc on MultiExec's own buttons leaves it; in a terminal, Esc belongs to the program.
        if multiExec, key == VK_ESCAPE, !control, !shift, !alt, multiControls?.owns(message.hwnd) == true {
            setMultiExec(false)
            return true
        }
        // Alt+1–8 pick a tab; Alt+9 is always the last one. In MultiExec they pick a terminal in the grid.
        if alt && !control && !shift, key >= 0x31, key <= 0x39 {
            let number = Int(key - 0x30)
            if multiExec { selectGridTerminal(number); return true }
            select(number == 9 ? tabs.count - 1 : number - 1)
            return true
        }
        return false
    }

    /// Re-reads the profile into every terminal, and the light/dark choice into the window frame and menus.
    private func applySettings() {
        guard let hwnd else { return }
        setDarkTitleBar(hwnd, appIsDark)
        DarkMenus.apply(dark: appIsDark)
        for pane in panes {
            pane.apply(TerminalProfile.shared.settings(for: pane.profileID))
            pane.explorer?.applyTheme()
        }
        for editor in editors { editor.applyTheme() }
        InvalidateRect(hwnd, nil, false)
    }

    // MARK: Layout

    private var dpi: UINT { hwnd.map { GetDpiForWindow($0) } ?? 96 }
    private var isFullScreen: Bool { fullScreenRestore != nil }

    private var state: WindowChrome.State {
        var state = WindowChrome.State()
        state.tabNames = tabNames
        state.active = active
        if let pane = activePane {
            // The focused pane's title, as on the Mac; the connection is the tab's.
            state.title = (focusedPane ?? pane).title
            state.subtitle = (focusedPane ?? pane).subtitle
            state.connected = pane.isConnected ? pane.remote?.label : nil
            state.explorerShowing = pane.showingExplorer
            state.explorerAvailable = true
            if pane.showingExplorer, let explorer = pane.explorer {
                // As on the Mac: the folder's name, and where it is beside it.
                state.title = explorer.title
                state.subtitle = explorer.folder == explorer.title ? "" : explorer.folder
            }
        } else if let editor = activeEditor {
            // The file's name, and where it is beside it.
            state.title = editor.tabName
            state.subtitle = editor.source.location
            state.explorerAvailable = false
        }
        if let hwnd {
            state.maximized = IsZoomed(hwnd)
            state.windowActive = GetActiveWindow() == hwnd || GetForegroundWindow() == hwnd
        }
        state.screenshotCopied = screenshotCopied
        state.multiExecOn = multiExec
        return state
    }

    private func layout() {
        guard let hwnd else { return }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let state = state
        chrome.layout(width: rect.right, dpi: dpi, state: state)
        chrome.updateTooltips(owner: hwnd, state: state)
        chrome.updateAccessibility(owner: hwnd, dpi: dpi, state: state)
        rect.top = chrome.height(dpi)
        if multiExec, let controls = multiControls {
            layoutMultiExec(controls, in: rect)
            InvalidateRect(hwnd, nil, false)
            return
        }
        for tab in tabs {
            if let head = tab as? TerminalPane, let group = head.group {
                // Equal shares with a one-pixel hairline between panes, as on the Mac and Linux.
                for (pane, frame) in group.root.frames(in: rect, gap: max(1, scaled(1, dpi: dpi))) { pane.move(to: frame) }
            } else {
                tab.move(to: rect)
            }
            (tab as? TerminalPane)?.explorer?.move(to: rect)
        }
        InvalidateRect(hwnd, nil, false)
    }

    private func refreshChrome() {
        guard let hwnd else { return }
        let title = activeTab.map { "\($0.title) — Herb's Terminal" } ?? "Herb's Terminal"
        withWide(title) { _ = SetWindowTextW(hwnd, $0) } // Taskbar and Alt+Tab still show it.
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let state = state
        chrome.layout(width: rect.right, dpi: dpi, state: state)
        chrome.updateTooltips(owner: hwnd, state: state)
        chrome.updateAccessibility(owner: hwnd, dpi: dpi, state: state)
        rect.bottom = chrome.height(dpi)
        InvalidateRect(hwnd, &rect, false)
    }

    /// Sizes the window so the terminal shows the grid from Settings (default 100 × 30).
    private func sizeToGrid(columns: Int? = nil, rows: Int? = nil) {
        guard let hwnd, let pane = activePane else { return }
        if IsZoomed(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
        let cell = pane.cellSize
        let inset = TerminalPane.inset(hwnd)
        let profile = TerminalProfile.shared
        var window = RECT(), client = RECT()
        GetWindowRect(hwnd, &window)
        GetClientRect(hwnd, &client)
        let frameWidth = (window.right - window.left) - client.right, frameHeight = (window.bottom - window.top) - client.bottom
        var work = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
        let width = min(Int32(columns ?? profile.windowColumns) * cell.width + inset.left + inset.right + frameWidth, work.right - work.left)
        let height = min(Int32(rows ?? profile.windowRows) * cell.height + inset.top + inset.bottom + chrome.height(dpi) + frameHeight, work.bottom - work.top)
        SetWindowPos(hwnd, nil, 0, 0, width, height, UINT(SWP_NOMOVE | SWP_NOZORDER))
    }

    // MARK: Frame

    /// Resize border thickness at this DPI.
    private func frameSize(_ hwnd: HWND) -> (x: Int32, y: Int32) {
        let dpi = GetDpiForWindow(hwnd)
        let padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
        return (GetSystemMetricsForDpi(SM_CXFRAME, dpi) + padding, GetSystemMetricsForDpi(SM_CYFRAME, dpi) + padding)
    }

    private func nonClientHit(_ hwnd: HWND, _ lParam: LPARAM) -> LRESULT {
        var point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
        ScreenToClient(hwnd, &point)
        if !isFullScreen, !IsZoomed(hwnd) {
            let frame = frameSize(hwnd)
            var client = RECT()
            GetClientRect(hwnd, &client)
            if point.y < frame.y {
                if point.x < frame.x * 2 { return LRESULT(HTTOPLEFT) }
                if point.x >= client.right - frame.x * 2 { return LRESULT(HTTOPRIGHT) }
                return LRESULT(HTTOP)
            }
        }
        guard point.y < chrome.toolbarHeight(dpi) else { return LRESULT(HTCLIENT) }
        switch chrome.item(at: point) {
        case .minimize?: return LRESULT(HTMINBUTTON)
        case .maximize?: return LRESULT(HTMAXBUTTON) // Windows 11 shows its snap layouts on hover.
        case .close?: return LRESULT(HTCLOSE)
        case nil: return LRESULT(HTCAPTION)
        default: return LRESULT(HTCLIENT)
        }
    }

    private func captionItem(_ hit: WPARAM) -> WindowChrome.Item? {
        switch Int32(hit) {
        case HTMINBUTTON: .minimize
        case HTMAXBUTTON: .maximize
        case HTCLOSE: .close
        default: nil
        }
    }

    private func setHover(_ item: WindowChrome.Item?) {
        guard item != chrome.hover, let hwnd else { return }
        chrome.hover = item
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        rect.bottom = chrome.height(dpi)
        InvalidateRect(hwnd, &rect, false)
    }

    private func click(_ item: WindowChrome.Item, at point: POINT) {
        guard let hwnd else { return }
        if state.isUnavailable(item) { return }
        switch item {
        case .menu: openMainMenu()
        case .newTab: newTab()
        case .connect: connectButton()
        case .export: exportSession()
        case .explorer: toggleExplorer()
        case .multiExec: setMultiExec(!multiExec)
        case .peers: TailcatPeersWindow.show(owner: hwnd, workspace: self)
        case .search: perform(MenuCommand.findInTerminal.rawValue)
        case .screenshot: takeScreenshot()
        case .tab(let index): select(index)
        case .tabClose(let index): closeTab(at: index)
        case .minimize: ShowWindow(hwnd, SW_MINIMIZE)
        case .maximize: ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE)
        case .close: PostMessageW(hwnd, UINT(WM_CLOSE), 0, 0)
        default: break
        }
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_NCCALCSIZE where wParam != 0:
            // Keep the resize borders on the sides and bottom; the toolbar takes the title bar's place. A maximized
            // window hangs its frame off-screen, so its top is pushed down by that much.
            guard let params = UnsafeMutablePointer<NCCALCSIZE_PARAMS>(bitPattern: UInt(lParam)) else { return nil }
            let top = params.pointee.rgrc.0.top
            _ = DefWindowProcW(hwnd, message, wParam, lParam)
            params.pointee.rgrc.0.top = top + (IsZoomed(hwnd) && fullScreenRestore == nil ? frameSize(hwnd).y : 0)
            return 0
        case WM_NCHITTEST:
            let hit = DefWindowProcW(hwnd, message, wParam, lParam)
            if hit != LRESULT(HTCLIENT) { return hit }
            return nonClientHit(hwnd, lParam)
        case WM_NCMOUSEMOVE:
            if !trackingNonClient {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE | TME_NONCLIENT),
                                            hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                trackingNonClient = true
            }
            setHover(captionItem(wParam))
            return nil
        case WM_NCMOUSELEAVE:
            trackingNonClient = false
            chrome.pressed = nil
            setHover(nil)
            return 0
        case WM_NCLBUTTONDOWN:
            if let item = captionItem(wParam) {
                chrome.pressed = item
                setHover(item)
                InvalidateRect(hwnd, nil, false)
                return 0
            }
            return nil
        case WM_NCLBUTTONUP:
            if let item = captionItem(wParam), chrome.pressed == item {
                chrome.pressed = nil
                click(item, at: POINT())
                return 0
            }
            chrome.pressed = nil
            return nil
        case WM_ACTIVATE:
            refreshChrome()
            return nil
        case WM_SIZE:
            layout()
            return 0
        case WM_PAINT:
            var ps = PAINTSTRUCT()
            let screen = BeginPaint(hwnd, &ps)
            var client = RECT()
            GetClientRect(hwnd, &client)
            let height = chrome.height(dpi)
            let dc = CreateCompatibleDC(screen)
            let bitmap = CreateCompatibleBitmap(screen, client.right, height)
            let old = SelectObject(dc, bitmap)
            chrome.paint(dc, width: client.right, dpi: dpi, state: state)
            BitBlt(screen, 0, 0, client.right, height, dc, 0, 0, DWORD(SRCCOPY))
            // Under the panes: shows only as the hairlines between split panes.
            fill(screen, RECT(left: 0, top: height, right: client.right, bottom: client.bottom),
                 multiExec ? WindowChrome.Colors(dark: appIsDark).background : WindowChrome.Colors(dark: appIsDark).border)
            if multiExec, let controls = multiControls {
                controls.paint(screen, focusedIndex: panes.firstIndex { $0 === focusedPane })
            }
            SelectObject(dc, old)
            DeleteObject(bitmap)
            DeleteDC(dc)
            EndPaint(hwnd, &ps)
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SETFOCUS:
            if let editor = activeEditor { editor.focus() } else { activePane?.show(true) }
            return 0
        case WM_LBUTTONDOWN:
            let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            guard let item = chrome.item(at: point) else { return 0 }
            if case .tab(let index) = item {
                dragging = index
                SetCapture(hwnd)
            }
            chrome.pressed = item
            InvalidateRect(hwnd, nil, false)
            return 0
        case WM_LBUTTONUP:
            let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            let pressed = chrome.pressed
            chrome.pressed = nil
            if dragging != nil { dragging = nil; ReleaseCapture() }
            // A tab counts even if a drag moved it; anything else only if the press began on it.
            if let item = chrome.item(at: point) {
                var isTab = false
                if case .tab = item { isTab = true }
                if item == pressed || isTab { click(item, at: point) }
            }
            InvalidateRect(hwnd, nil, false)
            return 0
        case WM_LBUTTONDBLCLK:
            let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            switch chrome.item(at: point) {
            case .tab(let index)?: rename(index)
            case .title?: perform(MenuCommand.restoreDefaultSize.rawValue)
            default: break
            }
            return 0
        case WM_MBUTTONUP:
            if case .tab(let index)? = chrome.item(at: POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))) { closeTab(at: index) }
            return 0
        case WM_RBUTTONUP:
            let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            var screen = point
            ClientToScreen(hwnd, &screen)
            switch chrome.item(at: point) {
            case .tab(let index)?:
                select(index)
                if let command = MainMenu.popUp([("Rename Tab…", .renameTab), ("Move Tab Left", .moveTabLeft), ("Move Tab Right", .moveTabRight),
                                                 ("", nil), ("Close Tab", .closeTab)], at: screen, owner: hwnd) {
                    perform(command.rawValue)
                }
            case .title?:
                if let command = MainMenu.popUp([("Restore Default Size", .restoreDefaultSize), ("Make Current Size the Default", .makeSizeDefault)],
                                                at: screen, owner: hwnd) {
                    perform(command.rawValue)
                }
            default: break
            }
            return 0
        case WM_MOUSEMOVE:
            if !trackingMouse {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                trackingMouse = true
            }
            let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            let item = chrome.item(at: point)
            // Dragging a tab onto another puts it there.
            if let from = dragging, case .tab(let to)? = item, to != from {
                move(from: from, to: to)
                dragging = to
                chrome.pressed = .tab(to)
            }
            setHover(item)
            return 0
        case WM_MOUSELEAVE:
            trackingMouse = false
            setHover(nil)
            return 0
        case WM_DPICHANGED:
            if let suggested = UnsafePointer<RECT>(bitPattern: UInt(lParam))?.pointee {
                SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.right - suggested.left,
                             suggested.bottom - suggested.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            for pane in panes { pane.apply(TerminalProfile.shared.settings(for: pane.profileID)) }
            for editor in editors { editor.applyTheme() }
            layout()
            return 0
        case WM_SETTINGCHANGE:
            // Light/dark mode or the accent color changed in Windows Settings.
            applySettings()
            return nil
        case WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(lParam)) {
                info.pointee.ptMinTrackSize = POINT(x: scaled(520, dpi: GetDpiForWindow(hwnd)), y: scaled(240, dpi: GetDpiForWindow(hwnd)))
            }
            return 0
        case WM_QUERYENDSESSION:
            // Signing out or shutting down: keep the session, as Quit does.
            Self.saveSession()
            return 1
        case WM_CLOSE:
            // Unsaved files first: each asks, and saving finishes before the window closes.
            let unsaved = editors.filter(\.isEdited)
            if !unsaved.isEmpty {
                confirmEditors(unsaved) { [weak self] ok in
                    guard ok, let self, let hwnd = self.hwnd else { return }
                    for editor in self.editors { editor.close() }
                    self.tabs.removeAll { $0 is TextEditorPane }
                    PostMessageW(hwnd, UINT(WM_CLOSE), 0, 0)
                }
                return 0
            }
            if !confirmClosing(panes, scope: "this window") { return 0 }
            // The last window closing (and not the app quitting, which saved every window already) keeps its tabs.
            if App.allWorkspaces.count == 1 && !App.isQuitting { Self.saveSession() }
            closeAll()
            DestroyWindow(hwnd)
            return 0
        case WM_TIMER where wParam == Self.screenshotTimer:
            KillTimer(hwnd, Self.screenshotTimer)
            screenshotCopied = false
            refreshChrome()
            return 0
        case WM_GETOBJECT:
            var result: Int = 0
            return herb_uia_get_object(UnsafeMutableRawPointer(hwnd), UInt(wParam), Int(lParam), &result) != 0 ? LRESULT(result) : nil
        case Int32(HERB_UIA_INVOKE_MESSAGE):
            // A screen reader or the parity check pressed a toolbar, tab or window button.
            if let item = chrome.item(forTag: Int(wParam)) { click(item, at: POINT()) }
            return 0
        case WM_TIMER where wParam == TestScript.timer:
            if !TestScript.step(self) { KillTimer(hwnd, TestScript.timer) }
            return 0
        case WM_COMMAND:
            let id = Int(loWord(LPARAM(Int(bitPattern: UInt(wParam)))))
            if multiExec, id >= 1 { multiExecCommand(id, control: HWND(bitPattern: Int(lParam))); return 0 }
            return nil
        case WM_CTLCOLORBTN, WM_CTLCOLORSTATIC:
            if let result = multiControls?.colors(wParam, control: HWND(bitPattern: Int(lParam))) { return result }
            return nil
        case WM_DESTROY:
            herb_uia_window_destroyed(UnsafeMutableRawPointer(hwnd))
            chrome.release()
            self.hwnd = nil
            App.windowClosed(self)
            return 0
        default:
            return nil
        }
    }
}
