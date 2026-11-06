import Foundation
import WinSDK

/// A main window: the toolbar and tab strip across the top (see `WindowChrome`), and one terminal per tab below.
@MainActor
final class Workspace: WindowObject {
    static let className = "HerbsTerminalWindow"

    private(set) var hwnd: HWND?
    private var tabs: [TerminalPane] = []
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
        ShowWindow(hwnd, TestScript.active ? SW_SHOWNOACTIVATE : SW_SHOWDEFAULT)
        if TestScript.active { SetTimer(hwnd, TestScript.timer, 1500, nil) }
        UpdateWindow(hwnd)
    }

    // MARK: Tabs

    var activePane: TerminalPane? { tabs.indices.contains(active) ? tabs[active] : nil }
    var activeIndex: Int { active }
    var tabNames: [String] { tabs.map(\.tabName) }

    func newTab() {
        addPane()?.start()
    }

    /// A new, selected tab whose process the caller starts. It takes the lowest free number, as on the Mac.
    private func addPane() -> TerminalPane? {
        guard let hwnd else { return nil }
        let pane = TerminalPane(parent: hwnd, settings: TerminalProfile.shared.settings(for: nil))
        let used = Set(tabs.map(\.number))
        pane.number = (1...).first { !used.contains($0) }!
        pane.onTitleChange = { [weak self] _ in self?.refreshChrome() }
        pane.onExit = { [weak self] pane in self?.close(pane) }
        tabs.append(pane)
        layout()
        select(tabs.count - 1)
        return pane
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        active = index
        for (i, pane) in tabs.enumerated() where i != index { pane.show(false) }
        tabs[index].show(true)
        refreshChrome()
    }

    func close(_ pane: TerminalPane) {
        guard let index = tabs.firstIndex(where: { $0 === pane }) else { return }
        pane.close()
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
        for pane in tabs { pane.close() }
        tabs.removeAll()
    }

    private func closeTab(at index: Int, confirm: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        let pane = tabs[index]
        if confirm, TerminalProfile.shared.askBeforeClosing, pane.isRunning,
           FormDialog.ask(owner: hwnd, title: "Close \(pane.tabName)?",
                          message: pane.isConnected ? "Its SSH session to \(pane.remote!.label) will end." : "Its shell is still running and will end.",
                          buttons: [.init(title: "Cancel"), .init(title: "Close Tab", isDefault: true)]) != 1 {
            return
        }
        close(pane)
    }

    private func move(from index: Int, to target: Int) {
        guard tabs.indices.contains(index), tabs.indices.contains(target), index != target else { return }
        let pane = tabs.remove(at: index)
        tabs.insert(pane, at: target)
        active = target
        refreshChrome()
    }

    private func rename(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let pane = tabs[index]
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
    private func connectButton() {
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
        for pane in tabs { pane.apply(settings) }
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
            state.connected = pane.isConnected ? pane.remote?.label : nil
        }
        if let hwnd {
            state.maximized = IsZoomed(hwnd)
            state.windowActive = GetActiveWindow() == hwnd || GetForegroundWindow() == hwnd
        }
        return state
    }

    private func layout() {
        guard let hwnd else { return }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        chrome.layout(width: rect.right, dpi: dpi, state: state)
        chrome.updateTooltips(owner: hwnd, state: state)
        rect.top = chrome.height(dpi)
        for pane in tabs { pane.move(to: rect) }
        InvalidateRect(hwnd, nil, false)
    }

    private func refreshChrome() {
        guard let hwnd else { return }
        let title = activePane.map { "\($0.title) — Herb's Terminal" } ?? "Herb's Terminal"
        withWide(title) { _ = SetWindowTextW(hwnd, $0) } // Taskbar and Alt+Tab still show it.
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        chrome.layout(width: rect.right, dpi: dpi, state: state)
        chrome.updateTooltips(owner: hwnd, state: state)
        rect.bottom = chrome.height(dpi)
        InvalidateRect(hwnd, &rect, false)
    }

    /// Sizes the window so the terminal shows the grid from Settings (default 120 × 32).
    private func sizeToGrid() {
        guard let hwnd, let pane = activePane else { return }
        if IsZoomed(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
        let cell = pane.cellSize
        let padding = TerminalPane.padding(hwnd)
        let profile = TerminalProfile.shared
        var window = RECT(), client = RECT()
        GetWindowRect(hwnd, &window)
        GetClientRect(hwnd, &client)
        let frameWidth = (window.right - window.left) - client.right, frameHeight = (window.bottom - window.top) - client.bottom
        var work = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
        let width = min(Int32(profile.windowColumns) * cell.width + 2 * padding + frameWidth, work.right - work.left)
        let height = min(Int32(profile.windowRows) * cell.height + 2 * padding + chrome.height(dpi) + frameHeight, work.bottom - work.top)
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
        if WindowChrome.unavailable.contains(item) { return }
        switch item {
        case .menu: openMainMenu()
        case .newTab: newTab()
        case .connect: connectButton()
        case .export: exportSession()
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
            activePane?.show(true)
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
            for pane in tabs { pane.apply(settings) }
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
            let running = tabs.filter(\.isRunning).count
            if TerminalProfile.shared.askBeforeClosing, running > 0,
               FormDialog.ask(owner: hwnd, title: "Close this window?",
                              message: running == 1 ? "A shell is still running and will end." : "\(running) shells are still running and will end.",
                              buttons: [.init(title: "Cancel"), .init(title: "Close Window", isDefault: true)]) != 1 {
                return 0
            }
            closeAll()
            DestroyWindow(hwnd)
            return 0
        case WM_TIMER where wParam == TestScript.timer:
            if !TestScript.step(self) { KillTimer(hwnd, TestScript.timer) }
            return 0
        case WM_DESTROY:
            chrome.release()
            self.hwnd = nil
            App.windowClosed(self)
            return 0
        default:
            return nil
        }
    }
}
