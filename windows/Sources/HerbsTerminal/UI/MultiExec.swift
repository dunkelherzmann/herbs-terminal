import Foundation
import WinSDK

/// MultiExec's controls in a main window, as on the Mac and Linux (after MobaXterm): a bar across the top with
/// how many terminals receive typing and New Tab, Connect via SSH…, Include All, Close All and Exit MultiExec,
/// then every terminal in a grid, each with a caption holding its include checkbox ("1. Terminal 1"). The bar and
/// checkboxes are standard Windows buttons, so screen readers and the keyboard reach them as usual.
@MainActor
final class MultiExecControls {
    enum Action: Int {
        case newTab = 1, connect, includeAll, closeAll, exit
        var title: String {
            switch self {
            case .newTab: "New Tab"
            case .connect: "Connect via SSH…"
            case .includeAll: "Include All"
            case .closeAll: "Close All"
            case .exit: "Exit MultiExec"
            }
        }
        var hint: String {
            switch self {
            case .newTab: "New Tab\nAdd a local terminal to the grid; it's included in MultiExec."
            case .connect: "Connect via SSH\nOpen a session to another host in a new tab of the grid."
            case .includeAll: "Include All\nSend typing to every terminal again."
            case .closeAll: "Close All\nEnd every terminal in the grid and leave MultiExec with one new terminal."
            case .exit: "Exit MultiExec (Esc)\nBack to one tab at a time."
            }
        }
    }

    /// Button ids: the bar's are the actions; a checkbox is `checkboxBase` plus its terminal's index.
    static let checkboxBase = 0x4D00

    private let owner: HWND
    private var buttons: [Action: HWND] = [:]
    private var checkboxes: [HWND] = []
    private var font: HFONT?
    private let hints = HoverHints()
    /// Where the status text and the captions are drawn by the window.
    private(set) var barRect = RECT()
    private(set) var captionRects: [RECT] = []
    var status = ""

    init(owner: HWND) {
        self.owner = owner
        let dpi = GetDpiForWindow(owner)
        font = withWide("Segoe UI") { CreateFontW(-scaled(12, dpi: dpi), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0,
                                                  DWORD(CLEARTYPE_QUALITY), 0, $0) }
        for action in [Action.newTab, .connect, .includeAll, .closeAll, .exit] {
            buttons[action] = makeButton(action.title, id: action.rawValue, style: DWORD(BS_PUSHBUTTON))
        }
    }

    func destroy() {
        for window in Array(buttons.values) + checkboxes { DestroyWindow(window) }
        buttons = [:]
        checkboxes = []
        hints.release()
        if let font { DeleteObject(font) }
    }

    private func makeButton(_ title: String, id: Int, style: DWORD) -> HWND? {
        let window = withWide("BUTTON") { cls in
            withWide(title) { text in
                CreateWindowExW(0, cls, text, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_TABSTOP) | style, 0, 0, 10, 10, owner,
                                HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
            }
        }
        SendMessageW(window, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(font)))), 1)
        if let window { withWide(appIsDark ? "DarkMode_Explorer" : "Explorer") { _ = SetWindowTheme(window, $0, nil) } }
        return window
    }

    /// Lays out the bar at the top of `area` and one cell per terminal in a grid below it; returns each terminal's
    /// rectangle (above its caption).
    func layout(in area: RECT, titles: [String], included: [Bool], includeAllEnabled: Bool) -> [RECT] {
        let dpi = GetDpiForWindow(owner)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        // The bar: buttons from the right.
        barRect = RECT(left: area.left, top: area.top, right: area.right, bottom: area.top + s(40))
        var x = area.right - s(10)
        for action in [Action.exit, .closeAll, .includeAll, .connect, .newTab] {
            guard let button = buttons[action] else { continue }
            let width = textWidth(action.title) + s(24)
            x -= width
            MoveWindow(button, x, area.top + s(7), width, s(26), true)
            x -= s(6)
        }
        if let include = buttons[.includeAll] { EnableWindow(include, includeAllEnabled) }

        // The checkboxes: one per terminal, made or removed as terminals come and go.
        while checkboxes.count < titles.count {
            checkboxes.append(makeButton("", id: Self.checkboxBase + checkboxes.count, style: DWORD(BS_AUTOCHECKBOX))!)
        }
        while checkboxes.count > titles.count { DestroyWindow(checkboxes.removeLast()) }

        let count = max(1, titles.count)
        let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
        let rows = (count + columns - 1) / columns
        let gap = s(6), caption = s(26)
        let top = barRect.bottom + gap
        let cellWidth = (area.right - area.left - gap * Int32(columns + 1)) / Int32(columns)
        let cellHeight = (area.bottom - top - gap * Int32(rows)) / Int32(rows)
        var frames: [RECT] = []
        captionRects = []
        for (index, title) in titles.enumerated() {
            let column = Int32(index % columns), row = Int32(index / columns)
            let left = area.left + gap + column * (cellWidth + gap), cellTop = top + row * (cellHeight + gap)
            frames.append(RECT(left: left, top: cellTop, right: left + cellWidth, bottom: cellTop + cellHeight - caption))
            let captionRect = RECT(left: left, top: cellTop + cellHeight - caption, right: left + cellWidth, bottom: cellTop + cellHeight)
            captionRects.append(captionRect)
            let box = checkboxes[index]
            let text = "\(index + 1). \(title)"
            withWide(text) { _ = SetWindowTextW(box, $0) }
            MoveWindow(box, captionRect.left + s(8), captionRect.top + s(3), captionRect.right - captionRect.left - s(16), caption - s(6), true)
            SendMessageW(box, UINT(BM_SETCHECK), WPARAM(included[index] ? BST_CHECKED : BST_UNCHECKED), 0)
        }
        for (action, button) in buttons { hints.set(button, action.hint, owner: owner) }
        for (index, box) in checkboxes.enumerated() {
            hints.set(box, included[index] ? "Included\nTyping in MultiExec goes to this terminal. Uncheck to leave it out."
                                           : "Left out\nThis terminal only takes what you type into it. Check to include it.", owner: owner)
        }
        return frames
    }

    /// Whether `window` is one of the bar's buttons or a checkbox (Esc leaves MultiExec from there).
    func owns(_ window: HWND?) -> Bool {
        guard let window else { return false }
        return buttons.values.contains(window) || checkboxes.contains(window)
    }

    /// The bar's background and status, and the captions' background, drawn by the window under the controls.
    func paint(_ dc: HDC?, focusedIndex: Int?) {
        let dpi = GetDpiForWindow(owner)
        let colors = WindowChrome.Colors(dark: appIsDark)
        // The Mac's orange bar, at the same strength.
        fill(dc, barRect, blend(colors.background, colorRef(255, 149, 0), 0.14))
        var textRect = barRect
        textRect.left += scaled(12, dpi: dpi)
        let old = SelectObject(dc, font)
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, colors.text)
        var text = status.wide
        DrawTextW(dc, &text, -1, &textRect, UINT(DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS))
        SelectObject(dc, old)
        for (index, rect) in captionRects.enumerated() {
            fill(dc, rect, index == focusedIndex ? blend(colors.background, colors.accent, 0.22) : blend(colors.background, colors.text, 0.06))
        }
    }

    /// Colors for the checkboxes' labels (WM_CTLCOLORBTN / WM_CTLCOLORSTATIC).
    private var captionBrush: HBRUSH?
    func colors(_ wParam: WPARAM, control: HWND?) -> LRESULT? {
        guard let control, checkboxes.contains(control) || buttons.values.contains(control) else { return nil }
        let dc = HDC(bitPattern: UInt(wParam))
        let colors = WindowChrome.Colors(dark: appIsDark)
        SetTextColor(dc, colors.text)
        SetBkMode(dc, TRANSPARENT)
        if let captionBrush { DeleteObject(captionBrush) }
        captionBrush = CreateSolidBrush(blend(colors.background, colors.text, 0.06))
        return LRESULT(Int(bitPattern: UnsafeRawPointer(captionBrush)))
    }

    private func textWidth(_ text: String) -> Int32 {
        let dc = GetDC(owner)
        defer { ReleaseDC(owner, dc) }
        let old = SelectObject(dc, font)
        defer { SelectObject(dc, old) }
        var size = SIZE()
        _ = withWide(text) { GetTextExtentPoint32W(dc, $0, Int32(text.utf16.count), &size) }
        return size.cx
    }
}
