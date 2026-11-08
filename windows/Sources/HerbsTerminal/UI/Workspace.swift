import Foundation
import WinSDK

/// A main window: a tab strip across the top and one terminal per tab below it.
@MainActor
final class Workspace: WindowObject {
    static let className = "HerbsTerminalWindow"
    private static let aboutCommand: UINT_PTR = 0x1000
    private static let settingsCommand: UINT_PTR = 0x1010

    private(set) var hwnd: HWND?
    private var tabs: [TerminalPane] = []
    private var active = 0
    private var hover: Hit = .none
    private var trackingMouse = false
    private var observers: [ObservationToken] = []

    private enum Hit: Equatable {
        case none, tab(Int), close(Int), newTab
    }

    init() {
        hwnd = createWindow(self, className: Self.className, title: "Herb's Terminal",
                            style: DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN))
        guard let hwnd else { return }
        setDarkTitleBar(hwnd, appIsDark)
        if let menu = GetSystemMenu(hwnd, false) {
            AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            withWide("Settings…\tCtrl+,") { _ = AppendMenuW(menu, UINT(MF_STRING), Self.settingsCommand, $0) }
            withWide("About Herb's Terminal") { _ = AppendMenuW(menu, UINT(MF_STRING), Self.aboutCommand, $0) }
        }
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

    func newTab() {
        guard let hwnd else { return }
        let pane = TerminalPane(parent: hwnd, settings: TerminalProfile.shared.settings(for: nil))
        pane.onTitleChange = { [weak self] _ in self?.refreshTitles() }
        pane.onExit = { [weak self] pane in self?.close(pane) }
        tabs.append(pane)
        layout()
        select(tabs.count - 1)
        pane.start()
    }

    /// Ends every tab's shell without asking (the app is quitting).
    func closeAll() {
        for pane in tabs { pane.close() }
        tabs.removeAll()
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        active = index
        for (i, pane) in tabs.enumerated() where i != index { pane.show(false) }
        tabs[index].show(true)
        refreshTitles()
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

    private func closeTab(at index: Int, confirm: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        let pane = tabs[index]
        if confirm, TerminalProfile.shared.askBeforeClosing, pane.isRunning,
           messageBox(hwnd, "Close this tab? Its shell is still running.", flags: UINT(MB_OKCANCEL | MB_ICONQUESTION)) != IDOK {
            return
        }
        close(pane)
    }

    private func refreshTitles() {
        if let hwnd {
            let title = activePane.map { "\($0.title) — Herb's Terminal" } ?? "Herb's Terminal"
            withWide(title) { _ = SetWindowTextW(hwnd, $0) }
            var strip = stripRect
            InvalidateRect(hwnd, &strip, false)
        }
    }

    /// Keyboard shortcuts, checked before the message reaches the focused terminal. Returns true when handled.
    func shortcut(_ message: MSG) -> Bool {
        let isKey = message.message == UINT(WM_KEYDOWN), isSystemKey = message.message == UINT(WM_SYSKEYDOWN)
        guard isKey || isSystemKey else { return false }
        let key = Int32(message.wParam)
        let control = isPressed(VK_CONTROL), shift = isPressed(VK_SHIFT), alt = isPressed(VK_MENU)
        func letter(_ c: Character) -> Bool { key == Int32(c.asciiValue!) }

        if control && shift && !alt {
            if letter("T") { newTab(); return true }
            if letter("W") { closeTab(at: active); return true }
            if letter("N") { App.newWindow(); return true }
            if key == VK_TAB { select((active - 1 + tabs.count) % tabs.count); return true }
        }
        if control && !shift && !alt {
            if key == VK_TAB { select((active + 1) % tabs.count); return true }
            if key == VK_PRIOR { select((active - 1 + tabs.count) % tabs.count); return true }
            if key == VK_NEXT { select((active + 1) % tabs.count); return true }
            if key == VK_OEM_PLUS || key == VK_ADD { zoom(1); return true }
            if key == VK_OEM_MINUS || key == VK_SUBTRACT { zoom(-1); return true }
            if letter("0") || key == VK_NUMPAD0 { zoom(0); return true }
            if key == VK_OEM_COMMA { showSettings(); return true }
        }
        // Alt+1–9 picks a tab; Alt+9 is always the last one.
        if alt && !control && !shift, key >= 0x31, key <= 0x39 {
            let number = Int(key - 0x30)
            select(number == 9 ? tabs.count - 1 : number - 1)
            return true
        }
        return false
    }

    private func zoom(_ step: Double) {
        TerminalProfile.shared.update(nil) { settings in settings.zoom = step == 0 ? 0 : settings.zoom + step }
        let settings = TerminalProfile.shared.settings(for: nil)
        for pane in tabs { pane.apply(settings) }
        if let hwnd { InvalidateRect(hwnd, nil, false) }
    }

    func showSettings() {
        SettingsWindow.show(owner: hwnd)
    }

    /// Re-reads the profile into every terminal, and the light/dark choice into the window frame.
    private func applySettings() {
        guard let hwnd else { return }
        setDarkTitleBar(hwnd, appIsDark)
        let settings = TerminalProfile.shared.settings(for: nil)
        for pane in tabs { pane.apply(settings) }
        InvalidateRect(hwnd, nil, false)
    }

    // MARK: Layout

    private var dpi: UINT { hwnd.map { GetDpiForWindow($0) } ?? 96 }
    private var stripHeight: Int32 { scaled(34, dpi: dpi) }

    private var stripRect: RECT {
        var rect = RECT()
        if let hwnd { GetClientRect(hwnd, &rect) }
        rect.bottom = stripHeight
        return rect
    }

    private func layout() {
        guard let hwnd else { return }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        rect.top = stripHeight
        for pane in tabs { pane.move(to: rect) }
        InvalidateRect(hwnd, nil, false)
    }

    /// Sizes the window so the terminal shows the grid from Settings (default 120 × 32).
    private func sizeToGrid() {
        guard let hwnd, let pane = activePane else { return }
        let cell = pane.cellSize
        let padding = TerminalPane.padding(hwnd)
        let profile = TerminalProfile.shared
        var rect = RECT(left: 0, top: 0, right: Int32(profile.windowColumns) * cell.width + 2 * padding,
                        bottom: Int32(profile.windowRows) * cell.height + 2 * padding + stripHeight)
        AdjustWindowRectExForDpi(&rect, DWORD(WS_OVERLAPPEDWINDOW), false, 0, dpi)
        var work = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
        let width = min(rect.right - rect.left, work.right - work.left)
        let height = min(rect.bottom - rect.top, work.bottom - work.top)
        SetWindowPos(hwnd, nil, 0, 0, width, height, UINT(SWP_NOMOVE | SWP_NOZORDER))
    }

    // MARK: Tab strip

    private struct TabGeometry {
        var tabs: [RECT]
        var closes: [RECT]
        var newTab: RECT
    }

    private var geometry: TabGeometry {
        let strip = stripRect
        let margin = scaled(6, dpi: dpi), gap = scaled(2, dpi: dpi)
        let plusWidth = scaled(32, dpi: dpi)
        let available = strip.right - 2 * margin - plusWidth
        let count = Int32(max(1, tabs.count))
        let width = max(scaled(60, dpi: dpi), min(scaled(220, dpi: dpi), (available - gap * (count - 1)) / count))
        var rects: [RECT] = [], closes: [RECT] = []
        var x = margin
        let top = scaled(4, dpi: dpi)
        let closeSize = scaled(18, dpi: dpi)
        for _ in tabs {
            let rect = RECT(left: x, top: top, right: x + width, bottom: strip.bottom)
            rects.append(rect)
            let middle = (rect.top + rect.bottom) / 2
            closes.append(RECT(left: rect.right - closeSize - scaled(6, dpi: dpi), top: middle - closeSize / 2,
                               right: rect.right - scaled(6, dpi: dpi), bottom: middle + closeSize / 2))
            x += width + gap
        }
        return TabGeometry(tabs: rects, closes: closes,
                           newTab: RECT(left: x + gap, top: top, right: x + gap + plusWidth, bottom: strip.bottom))
    }

    private func hitTest(_ lParam: LPARAM) -> Hit {
        let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
        let g = geometry
        func inside(_ r: RECT) -> Bool { point.x >= r.left && point.x < r.right && point.y >= r.top && point.y < r.bottom }
        for index in g.tabs.indices.reversed() {
            if inside(g.closes[index]) { return .close(index) }
            if inside(g.tabs[index]) { return .tab(index) }
        }
        return inside(g.newTab) ? .newTab : .none
    }

    private func paintStrip(_ dc: HDC?) {
        let strip = stripRect
        let terminalBackground = activePane?.background ?? colorRef(30, 30, 30)
        let dark = appIsDark
        let chrome = blend(terminalBackground, dark ? colorRef(0, 0, 0) : colorRef(255, 255, 255), dark ? 0.35 : 0.5)
        let text = dark ? colorRef(230, 230, 230) : colorRef(30, 30, 30)
        let dimText = blend(text, chrome, 0.4)
        fill(dc, strip, chrome)

        let font = withWide("Segoe UI") {
            CreateFontW(-scaled(9, dpi: dpi) * 4 / 3, 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0,
                        DWORD(CLEARTYPE_QUALITY), 0, $0)
        }
        let oldFont = SelectObject(dc, font)
        defer { SelectObject(dc, oldFont); DeleteObject(font) }
        SetBkMode(dc, TRANSPARENT)

        let g = geometry
        for (index, pane) in tabs.enumerated() {
            let rect = g.tabs[index]
            let isActive = index == active
            if isActive {
                fill(dc, rect, terminalBackground)
            } else if hover == .tab(index) || hover == .close(index) {
                fill(dc, rect, blend(chrome, terminalBackground, 0.5))
            }
            SetTextColor(dc, isActive ? text : dimText)
            var label = RECT(left: rect.left + scaled(10, dpi: dpi), top: rect.top, right: g.closes[index].left - scaled(4, dpi: dpi), bottom: rect.bottom)
            var title = Array(pane.title.utf16)
            DrawTextW(dc, &title, Int32(title.count), &label, UINT(DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX))
            if isActive || hover == .tab(index) || hover == .close(index) {
                var close = g.closes[index]
                if hover == .close(index) { fill(dc, close, blend(chrome, text, 0.2)) }
                var glyph = Array("✕".utf16)
                DrawTextW(dc, &glyph, Int32(glyph.count), &close, UINT(DT_SINGLELINE | DT_VCENTER | DT_CENTER))
            }
        }
        var plus = g.newTab
        if hover == .newTab { fill(dc, plus, blend(chrome, text, 0.15)) }
        SetTextColor(dc, text)
        var glyph = Array("+".utf16)
        DrawTextW(dc, &glyph, Int32(glyph.count), &plus, UINT(DT_SINGLELINE | DT_VCENTER | DT_CENTER))
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_SIZE:
            layout()
            return 0
        case WM_PAINT:
            var ps = PAINTSTRUCT()
            let screen = BeginPaint(hwnd, &ps)
            let strip = stripRect
            let dc = CreateCompatibleDC(screen)
            let bitmap = CreateCompatibleBitmap(screen, strip.right, strip.bottom)
            let old = SelectObject(dc, bitmap)
            paintStrip(dc)
            BitBlt(screen, 0, 0, strip.right, strip.bottom, dc, 0, 0, DWORD(SRCCOPY))
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
            switch hitTest(lParam) {
            case .tab(let index): select(index)
            case .close(let index): closeTab(at: index)
            case .newTab: newTab()
            case .none: break
            }
            return 0
        case WM_LBUTTONDBLCLK:
            if hitTest(lParam) == .none { newTab() }
            return 0
        case WM_MBUTTONUP:
            if case .tab(let index) = hitTest(lParam) { closeTab(at: index) }
            return 0
        case WM_MOUSEMOVE:
            if !trackingMouse {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                trackingMouse = true
            }
            let hit = hitTest(lParam)
            if hit != hover {
                hover = hit
                var strip = stripRect
                InvalidateRect(hwnd, &strip, false)
            }
            return 0
        case WM_MOUSELEAVE:
            trackingMouse = false
            hover = .none
            var strip = stripRect
            InvalidateRect(hwnd, &strip, false)
            return 0
        case WM_SYSCOMMAND:
            if wParam & 0xFFF0 == Self.settingsCommand {
                showSettings()
                return 0
            }
            if wParam & 0xFFF0 == Self.aboutCommand {
                messageBox(hwnd, "Herb's Terminal \(appVersion)\nA terminal for administrators.\n\nCopyright © 2026 Herbert Cisneros. MIT License.")
                return 0
            }
            return nil
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
            // Light/dark mode switched in Windows Settings.
            applySettings()
            return nil
        case WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(lParam)) {
                info.pointee.ptMinTrackSize = POINT(x: scaled(360, dpi: dpi), y: scaled(220, dpi: dpi))
            }
            return 0
        case WM_CLOSE:
            let running = tabs.filter(\.isRunning).count
            if TerminalProfile.shared.askBeforeClosing, running > 0,
               messageBox(hwnd, running == 1 ? "Close this window? A shell is still running." : "Close this window? \(running) shells are still running.",
                          flags: UINT(MB_OKCANCEL | MB_ICONQUESTION)) != IDOK {
                return 0
            }
            closeAll()
            DestroyWindow(hwnd)
            return 0
        case WM_TIMER where wParam == TestScript.timer:
            if !TestScript.step(self) { KillTimer(hwnd, TestScript.timer) }
            return 0
        case WM_DESTROY:
            self.hwnd = nil
            App.windowClosed(self)
            return 0
        default:
            return nil
        }
    }
}
