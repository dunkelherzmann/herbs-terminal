import Foundation
import WinSDK

/// Settings, Manage Logins, Get Info and the app's dialogs in its light or dark appearance, as on the Mac and
/// Linux. Windows has no switch for this in classic dialogs: the frame turns dark through DWM, the standard
/// controls take Windows' own dark styles (the ones File Explorer uses), and labels, fields and the window's
/// background get their colors from the WM_CTLCOLOR messages.
@MainActor
enum DialogTheme {
    static var dark: Bool { appIsDark }

    // Windows 11's dark dialog colors.
    static var background: COLORREF { dark ? colorRef(32, 32, 32) : GetSysColor(COLOR_WINDOW) }
    static var text: COLORREF { dark ? colorRef(255, 255, 255) : GetSysColor(COLOR_WINDOWTEXT) }
    static var secondaryText: COLORREF { dark ? colorRef(160, 160, 160) : GetSysColor(COLOR_GRAYTEXT) }
    static var errorText: COLORREF { dark ? colorRef(255, 153, 164) : colorRef(196, 43, 28) }
    static var field: COLORREF { dark ? colorRef(45, 45, 45) : GetSysColor(COLOR_WINDOW) }

    private static let darkBackgroundBrush = CreateSolidBrush(colorRef(32, 32, 32))
    private static let darkFieldBrush = CreateSolidBrush(colorRef(45, 45, 45))
    static var backgroundBrush: HBRUSH? { dark ? darkBackgroundBrush : GetSysColorBrush(COLOR_WINDOW) }
    static var fieldBrush: HBRUSH? { dark ? darkFieldBrush : GetSysColorBrush(COLOR_WINDOW) }

    // MARK: Windows' dark mode for controls

    /// uxtheme's unnamed exports (by ordinal) that let a Win32 app's controls draw dark, as File Explorer's do.
    private typealias SetPreferredAppMode = @convention(c) (Int32) -> Int32
    private typealias AllowDarkModeForWindow = @convention(c) (HWND?, Bool) -> Bool
    private static let uxtheme = LoadLibraryExW("uxtheme.dll".wide, nil, DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32))
    private static func export<T>(_ ordinal: UInt, as type: T.Type) -> T? {
        guard let uxtheme, let address = GetProcAddress(uxtheme, UnsafePointer<CChar>(bitPattern: ordinal)) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    private static let allowDarkModeForWindow = export(133, as: AllowDarkModeForWindow.self)
    private static let setPreferredAppMode = export(135, as: SetPreferredAppMode.self)
    private static var preparedMode: Bool?

    /// Lets the app's controls (and their scroll bars and drop-down lists) follow the appearance.
    private static func prepare() {
        guard preparedMode != dark else { return }
        preparedMode = dark
        _ = setPreferredAppMode?(dark ? 1 /* AllowDark */ : 0 /* Default */)
    }

    /// Call once the window's controls exist (and again when the appearance changes).
    static func apply(to hwnd: HWND) {
        prepare()
        setDarkTitleBar(hwnd, dark)
        _ = allowDarkModeForWindow?(hwnd, dark)
        var children: [HWND] = []
        withUnsafeMutablePointer(to: &children) { pointer in
            _ = EnumChildWindows(hwnd, { child, parameter in
                guard let child, let list = UnsafeMutableRawPointer(bitPattern: Int(parameter)) else { return true }
                list.assumingMemoryBound(to: [HWND].self).pointee.append(child)
                return true
            }, LPARAM(Int(bitPattern: UnsafeMutableRawPointer(pointer))))
        }
        for child in children { theme(child) }
        InvalidateRect(hwnd, nil, true)
    }

    private static func theme(_ control: HWND) {
        var buffer = [WCHAR](repeating: 0, count: 64)
        let length = GetClassNameW(control, &buffer, Int32(buffer.count))
        let className = String(decoding: buffer.prefix(Int(max(0, length))), as: UTF16.self).lowercased()
        _ = allowDarkModeForWindow?(control, dark)
        let name: String
        switch className {
        case "edit", "combobox": name = dark ? "DarkMode_CFD" : "CFD"
        case "syslistview32":
            name = dark ? "DarkMode_ItemsView" : "ItemsView"
            SendMessageW(control, UINT(LVM_SETBKCOLOR), 0, LPARAM(field))
            SendMessageW(control, UINT(LVM_SETTEXTBKCOLOR), 0, LPARAM(field))
            SendMessageW(control, UINT(LVM_SETTEXTCOLOR), 0, LPARAM(text))
            if let header = HWND(bitPattern: UInt(SendMessageW(control, UINT(LVM_GETHEADER), 0, 0))) {
                _ = allowDarkModeForWindow?(header, dark)
                withWide(name) { _ = SetWindowTheme(header, $0, nil) }
            }
        default: name = dark ? "DarkMode_Explorer" : "Explorer"
        }
        withWide(name) { _ = SetWindowTheme(control, $0, nil) }
        SendMessageW(control, UINT(WM_THEMECHANGED), 0, 0)
    }

    // MARK: Messages

    /// Paints the window's background; for WM_ERASEBKGND.
    static func erase(_ hwnd: HWND, _ wParam: WPARAM) -> LRESULT {
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        FillRect(HDC(bitPattern: UInt(wParam)), &rect, backgroundBrush)
        return 1
    }

    /// Sets a label's or field's colors for a WM_CTLCOLOR message and returns the brush to answer with. Callers
    /// that color some labels differently (errors, headers) set their color after this.
    static func colors(_ message: UINT, _ wParam: WPARAM) -> LRESULT {
        let dc = HDC(bitPattern: UInt(wParam))
        let isField = Int32(message) == WM_CTLCOLOREDIT || Int32(message) == WM_CTLCOLORLISTBOX
        SetTextColor(dc, text)
        SetBkColor(dc, isField ? field : background)
        if !isField { SetBkMode(dc, TRANSPARENT) }
        return LRESULT(Int(bitPattern: UnsafeRawPointer(isField ? fieldBrush : backgroundBrush)))
    }

    /// For a window procedure: the background and the WM_CTLCOLOR messages, or nil for anything else.
    static func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_ERASEBKGND: return erase(hwnd, wParam)
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX, WM_CTLCOLORDLG: return colors(message, wParam)
        default: return nil
        }
    }
}
