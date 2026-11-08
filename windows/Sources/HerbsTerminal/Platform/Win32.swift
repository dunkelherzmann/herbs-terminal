import Foundation
import WinSDK

// Small conveniences over the Win32 API: wide strings, colors, DPI and window-object lookup.

extension String {
    /// The string as a NUL-terminated UTF-16 array, for W functions.
    var wide: [WCHAR] { Array(utf16) + [0] }

    init(wide pointer: UnsafePointer<WCHAR>) {
        self = String(decodingCString: pointer, as: UTF16.self)
    }
}

/// Calls `body` with a NUL-terminated UTF-16 copy of `string`.
func withWide<R>(_ string: String, _ body: (UnsafePointer<WCHAR>) -> R) -> R {
    string.wide.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// A Win32 COLORREF (0x00BBGGRR).
func colorRef(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> COLORREF {
    COLORREF(red) | (COLORREF(green) << 8) | (COLORREF(blue) << 16)
}

extension RGB {
    var colorRef: COLORREF {
        func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        return HerbsTerminal.colorRef(byte(red), byte(green), byte(blue))
    }
}

/// Mixes two colors; `amount` 0 gives `a`, 1 gives `b`.
func blend(_ a: COLORREF, _ b: COLORREF, _ amount: Double) -> COLORREF {
    func channel(_ shift: COLORREF) -> COLORREF {
        let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
        return COLORREF((x + (y - x) * amount).rounded()) << shift
    }
    return channel(0) | channel(8) | channel(16)
}

func loWord(_ value: LPARAM) -> Int { Int(Int16(truncatingIfNeeded: value & 0xFFFF)) }
func hiWord(_ value: LPARAM) -> Int { Int(Int16(truncatingIfNeeded: (value >> 16) & 0xFFFF)) }
func hiWord(_ value: WPARAM) -> Int { Int(Int16(truncatingIfNeeded: (value >> 16) & 0xFFFF)) }

func isPressed(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

/// Pixels for `points` at the window's DPI.
func scaled(_ value: Double, dpi: UINT) -> Int32 { Int32((value * Double(dpi) / 96).rounded()) }

/// Whether Windows apps are set to dark mode (Settings ▸ Personalization ▸ Colors).
var systemPrefersDark: Bool {
    var value: DWORD = 1
    var size = DWORD(MemoryLayout<DWORD>.size)
    let status = withWide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize") { key in
        withWide("AppsUseLightTheme") { name in
            RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
        }
    }
    return status == ERROR_SUCCESS && value == 0
}

/// Dark or light title bar and frame, to match the app.
func setDarkTitleBar(_ hwnd: HWND, _ dark: Bool) {
    var value: Int32 = dark ? 1 : 0
    DwmSetWindowAttribute(hwnd, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &value, DWORD(MemoryLayout<Int32>.size))
}

/// Windows objects (panes, the main window) store a pointer to their Swift object in GWLP_USERDATA.
protocol WindowObject: AnyObject {
    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT?
}

/// The shared window procedure: finds the Swift object and lets it handle the message.
let windowProcedure: WNDPROC = { hwnd, message, wParam, lParam in
    guard let hwnd else { return 0 }
    if message == UINT(WM_NCCREATE), let create = UnsafePointer<CREATESTRUCTW>(bitPattern: UInt(lParam)) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: create.pointee.lpCreateParams)))
    }
    if let raw = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(hwnd, GWLP_USERDATA))) {
        let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as! WindowObject
        if let result = object.handle(hwnd, message, wParam, lParam) { return result }
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

/// Registers a window class that uses `windowProcedure`.
func registerClass(_ name: String, background: HBRUSH? = nil, style: UINT = UINT(CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS)) {
    let instance = GetModuleHandleW(nil)
    withWide(name) { className in
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = style
        wc.lpfnWndProc = windowProcedure
        wc.hInstance = instance
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
        wc.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))
        wc.hbrBackground = background
        wc.lpszClassName = className
        RegisterClassExW(&wc)
    }
}

/// Creates a window whose messages go to `object`. The object must outlive the window.
@discardableResult
func createWindow(_ object: WindowObject, className: String, title: String = "", style: DWORD, exStyle: DWORD = 0,
                  x: Int32 = CW_USEDEFAULT, y: Int32 = CW_USEDEFAULT, width: Int32 = CW_USEDEFAULT, height: Int32 = CW_USEDEFAULT,
                  parent: HWND? = nil) -> HWND? {
    let pointer = Unmanaged.passUnretained(object as AnyObject).toOpaque()
    return withWide(className) { cls in
        withWide(title) { text in
            CreateWindowExW(exStyle, cls, text, style, x, y, width, height, parent, nil, GetModuleHandleW(nil), pointer)
        }
    }
}

/// The clipboard's text, or nil.
func clipboardText(_ owner: HWND?) -> String? {
    guard OpenClipboard(owner) else { return nil }
    defer { CloseClipboard() }
    guard let data = GetClipboardData(UINT(CF_UNICODETEXT)), let locked = GlobalLock(data) else { return nil }
    defer { GlobalUnlock(data) }
    return String(wide: locked.assumingMemoryBound(to: WCHAR.self))
}

/// Puts `text` on the clipboard.
func setClipboardText(_ text: String, owner: HWND?) {
    guard OpenClipboard(owner) else { return }
    defer { CloseClipboard() }
    EmptyClipboard()
    let units = text.wide
    guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(units.count * 2)), let locked = GlobalLock(memory) else { return }
    units.withUnsafeBytes { locked.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    GlobalUnlock(memory)
    if SetClipboardData(UINT(CF_UNICODETEXT), memory) == nil { GlobalFree(memory) }
}

/// A message box owned by `owner`.
@discardableResult
func messageBox(_ owner: HWND?, _ text: String, title: String = "Herb's Terminal", flags: UINT = UINT(MB_OK | MB_ICONINFORMATION)) -> Int32 {
    withWide(text) { t in withWide(title) { c in MessageBoxW(owner, t, c, flags) } }
}
