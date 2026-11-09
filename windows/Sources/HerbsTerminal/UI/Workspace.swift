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

    init() {
        hwnd = createWindow(self, className: Self.className, title: "Herb's Terminal",
                            style: DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN))
        guard let hwnd else { return }
        setDarkTitleBar(hwnd, appIsDark)
        // The toolbar replaces the title bar: recalculate the frame now that WM_NCCALCSIZE draws none.
        SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER))
        // Settings changes reach open terminals at once.
        observers.append(TerminalProfile.shared.objectWillChange.observe { [weak self] in self?.applySettings() })
        observers.append(ThemeLibrary.shared.objectWillChange.observe { [weak self] in self?.applySettings() })
        newTab()
        sizeToGrid()
        ShowWindow(hwnd, TestScript.active || ParityScene.isActive ? SW_SHOWNOACTIVATE : SW_SHOWDEFAULT)
        if TestScript.active { SetTimer(hwnd, TestScript.timer, 1500, nil) }
        UpdateWindow(hwnd)
    }

    // MARK: Tabs

    var activeTab: WorkspaceTab? { tabs.indices.contains(active) ? tabs[active] : nil }
    var activePane: TerminalPane? { activeTab as? TerminalPane }
    var activeEditor: TextEditorPane? { activeTab as? TextEditorPane }
    private var panes: [TerminalPane] { tabs.compactMap { $0 as? TerminalPane } }
    private var editors: [TextEditorPane] { tabs.compactMap { $0 as? TextEditorPane } }
    var activeIndex: Int { active }
    var tabNames: [String] { tabs.map(\.tabName) }
    /// The tabs in order, for the feature tests' bridge.
    var allTabs: [WorkspaceTab] { tabs }

    /// Opens a tab as on the Mac: in the profile's start folder when it has one, else in the current tab's folder
    /// when that's a local shell and Settings asks for it, else in the home folder.
    func newTab() {
        let directory = newTabDirectory()
        if ParityScene.isActive {
            addPane()?.start(commandLine: ParityScene.commandLine, directory: directory ?? ParityScene.home, environment: ParityScene.shellEnvironment)
        } else {
            addPane()?.start(directory: directory)
        }
    }

    private func newTabDirectory() -> String? {
        let profile = TerminalProfile.shared
        let start = profile.settings(for: nil).startDirectory.trimmingCharacters(in: .whitespaces)
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

    /// A new, selected tab whose process the caller starts. It takes the lowest free number, as on the Mac.
    private func addPane() -> TerminalPane? {
        guard let hwnd else { return nil }
        let pane = TerminalPane(parent: hwnd, settings: TerminalProfile.shared.settings(for: nil))
        let used = Set(tabs.map(\.number))
        pane.number = (1...).first { !used.contains($0) }!
        pane.onTitleChange = { [weak self] pane in
            // Administrator mode on a host ends with the tab's SSH session.
            if pane.remote != nil, !pane.isConnected { pane.explorer?.leaveAdministrator() }
            self?.refreshChrome()
        }
        pane.onExit = { [weak self] pane in self?.close(pane) }
        tabs.append(pane)
        layout()
        select(tabs.count - 1)
        return pane
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        active = index
        for (i, tab) in tabs.enumerated() where i != index {
            tab.show(false)
            (tab as? TerminalPane)?.explorer?.show(false)
        }
        guard let pane = tabs[index] as? TerminalPane else {
            tabs[index].show(true)
            refreshChrome()
            return
        }
        if pane.showingExplorer, let explorer = pane.explorer {
            pane.show(false)
            explorer.show(true)
        } else {
            pane.explorer?.show(false)
            pane.show(true)
        }
        refreshChrome()
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
                    explorer = ExplorerPane(parent: hwnd, start: ".", remote: RemoteSession(endpoint: endpoint, password: pane.remotePassword))
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
            pane.close()
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
        if confirm, !confirmClosing([pane], scope: "this tab") { return }
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

    /// Opens the login in a new tab running Windows' ssh. A saved or typed password reaches ssh only through the
    /// askpass broker.
    func connectSSH(_ login: SSHLogin) {
        let endpoint = RemoteEndpoint(host: login.host, port: login.port, username: login.username)
        addPane()?.startSSH(endpoint, password: login.password.isEmpty ? nil : login.password)
    }

    func showLogins() {
        ManageLoginsWindow.show(owner: hwnd)
    }

    // MARK: Commands

    func showSettings() {
        SettingsWindow.show(owner: hwnd)
    }

    private func zoom(_ step: Double) {
        TerminalProfile.shared.update(nil) { settings in settings.zoom = step == 0 ? 0 : settings.zoom + step }
    }

    /// Export Session: everything in the terminal, scrollback included, to a text file named after the tab and time.
    func exportSession() {
        guard let pane = activePane else { return }
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
        TerminalProfile.shared.update(nil) { $0.restoreTheming() }
        TerminalProfile.shared.appearance = "System"
    }

    private func importPreset() {
        guard let path = openFile(owner: hwnd, title: "Import a Color Preset",
                                  filter: [("iTerm2 color presets (*.itermcolors)", "*.itermcolors")]) else { return }
        do {
            let name = try ThemeLibrary.shared.importFile(URL(fileURLWithPath: path))
            TerminalProfile.shared.update(nil) { $0.theme = name }
        } catch {
            LoginVaultPrompts.show(error, owner: hwnd, heading: "Couldn't import that preset")
        }
    }

    func perform(_ id: UINT) {
        if id >= MenuCommand.firstPreset {
            let names = ThemeLibrary.shared.allNames
            let index = Int(id - MenuCommand.firstPreset)
            if names.indices.contains(index) { TerminalProfile.shared.update(nil) { $0.theme = names[index] } }
            return
        }
        if id >= MenuCommand.firstTab { select(Int(id - MenuCommand.firstTab)); return }
        guard let command = MenuCommand(rawValue: id) else { return }
        let pane = activePane
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
        case .presetBasic: TerminalProfile.shared.update(nil) { $0.theme = "" }
        case .importPreset: importPreset()
        case .restoreTheming: restoreTheming()
        case .exportSession: exportSession()
        case .takeScreenshot: takeScreenshot()
        case .disconnect: pane?.disconnect()
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
        case .closeTab: closeTab(at: active)
        case .findInTerminal, .splitVertical, .splitHorizontal, .closePane, .nextPane, .previousPane, .multiExec, .runOnHosts:
            break // Not in the Windows version yet; shown greyed out.
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
            if letter("Q") { return run(.quit) }
            if key == VK_PRIOR { return run(.moveTabLeft) }
            if key == VK_NEXT { return run(.moveTabRight) }
            if key == VK_TAB { return run(.previousTab) }
        }
        if control && alt && !shift {
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
        // Alt+1–8 pick a tab; Alt+9 is always the last one.
        if alt && !control && !shift, key >= 0x31, key <= 0x39 {
            let number = Int(key - 0x30)
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
        let settings = TerminalProfile.shared.settings(for: nil)
        for pane in panes {
            pane.apply(settings)
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
            state.title = pane.title
            state.subtitle = pane.subtitle
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
        for tab in tabs {
            tab.move(to: rect)
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
    private func sizeToGrid() {
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
        let width = min(Int32(profile.windowColumns) * cell.width + inset.left + inset.right + frameWidth, work.right - work.left)
        let height = min(Int32(profile.windowRows) * cell.height + inset.top + inset.bottom + chrome.height(dpi) + frameHeight, work.bottom - work.top)
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
            let settings = TerminalProfile.shared.settings(for: nil)
            for pane in panes { pane.apply(settings) }
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
