import Foundation
import WinSDK

/// See-through terminals (Settings ▸ Text ▸ Background opacity and Blur), as on the Mac: only the terminal's
/// background lets the desktop through; text, the toolbar and the rest of the window stay solid. GDI draws with no
/// alpha, so each surface is drawn into a 32-bit bitmap whose alpha is set before it reaches the screen
/// (`AlphaSurface`), and DWM is told to honor the window's alpha. Blur uses Windows 11's acrylic backdrop.
@MainActor
enum Translucency {
    /// Main windows whose terminal area is see-through right now.
    private static var windows = Set<UInt>()

    static func isOn(for child: HWND?) -> Bool {
        guard let root = GetAncestor(child, UINT(GA_ROOT)) else { return false }
        return windows.contains(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(root))))
    }

    /// Windows 11 22H2 (build 22621) or later: the system backdrops, acrylic among them.
    static let canBlur: Bool = {
        var size = DWORD(64 * 2)
        var buffer = [WCHAR](repeating: 0, count: 64)
        let status = withWide("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion") { key in
            withWide("CurrentBuildNumber") { name in
                RegGetValueW(HKEY_LOCAL_MACHINE, key, name, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size)
            }
        }
        guard status == ERROR_SUCCESS else { return false }
        return (Int(String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)) ?? 0) >= 22621
    }()

    /// Something in `child`'s window changed what it shows (the find bar opened or closed): its main window decides again.
    static let changedMessage = UINT(WM_APP + 0x51)
    static func changed(_ child: HWND?) {
        guard let root = GetAncestor(child, UINT(GA_ROOT)) else { return }
        PostMessageW(root, changedMessage, 0, 0)
    }

    /// Turns the window's see-through terminal area on or off; `blur` adds the acrylic backdrop.
    static func apply(_ hwnd: HWND, on: Bool, blur: Bool) {
        let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(hwnd)))
        let was = windows.contains(key)
        if on { windows.insert(key) } else { windows.remove(key) }
        // The whole window honors its alpha; everything but terminal backgrounds is drawn solid.
        var blurBehind = DWM_BLURBEHIND()
        blurBehind.dwFlags = DWORD(DWM_BB_ENABLE) | DWORD(DWM_BB_BLURREGION)
        blurBehind.fEnable = WindowsBool(on)
        let region = CreateRectRgn(0, 0, -1, -1)
        blurBehind.hRgnBlur = region
        DwmEnableBlurBehindWindow(hwnd, &blurBehind)
        DeleteObject(region)
        if canBlur {
            var backdrop: Int32 = on && blur ? 3 /* DWMSBT_TRANSIENTWINDOW: acrylic */ : 1 /* DWMSBT_NONE */
            DwmSetWindowAttribute(hwnd, DWORD(38) /* DWMWA_SYSTEMBACKDROP_TYPE */, &backdrop, DWORD(MemoryLayout<Int32>.size))
        }
        if was != on { RedrawWindow(hwnd, nil, nil, UINT(RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE)) }
    }
}

/// A 32-bit drawing surface for one paint: GDI draws into it, then its alpha is set (everything solid, or a
/// terminal's background see-through) and it's copied to the window.
@MainActor
final class AlphaSurface {
    let dc: HDC?
    private let bitmap: HBITMAP?
    private let old: HGDIOBJ?
    private var bits: UnsafeMutableRawPointer?
    let width: Int32, height: Int32

    init(compatibleWith screen: HDC?, width: Int32, height: Int32) {
        self.width = width
        self.height = height
        dc = CreateCompatibleDC(screen)
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height  // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var pointer: UnsafeMutableRawPointer?
        bitmap = CreateDIBSection(screen, &info, UINT(DIB_RGB_COLORS), &pointer, nil, 0)
        bits = pointer
        old = SelectObject(dc, bitmap)
    }

    /// Every pixel solid.
    func makeOpaque() {
        guard let pixels = pixels() else { return }
        for index in 0..<pixels.count { pixels[index] |= 0xFF00_0000 }
    }

    /// Pixels in `background` get `opacity`, premultiplied as DWM expects; all others are solid.
    func makeBackgroundTranslucent(_ background: COLORREF, opacity: Double) {
        guard let pixels = pixels() else { return }
        let red = UInt32(background & 0xFF), green = UInt32((background >> 8) & 0xFF), blue = UInt32((background >> 16) & 0xFF)
        let key = (red << 16) | (green << 8) | blue
        let alpha = UInt32((max(0, min(1, opacity)) * 255).rounded())
        let clear = (alpha << 24) | ((red * alpha / 255) << 16) | ((green * alpha / 255) << 8) | (blue * alpha / 255)
        for index in 0..<pixels.count {
            let color = pixels[index] & 0x00FF_FFFF
            pixels[index] = color == key ? clear : color | 0xFF00_0000
        }
    }

    private func pixels() -> UnsafeMutableBufferPointer<UInt32>? {
        GdiFlush()
        guard let bits else { return nil }
        return UnsafeMutableBufferPointer(start: bits.assumingMemoryBound(to: UInt32.self), count: Int(width) * Int(height))
    }

    func copy(to screen: HDC?, x: Int32 = 0, y: Int32 = 0) {
        BitBlt(screen, x, y, width, height, dc, 0, 0, DWORD(SRCCOPY))
    }

    /// Frees the surface; call once its paint is done.
    func release() {
        SelectObject(dc, old)
        DeleteObject(bitmap)
        DeleteDC(dc)
    }
}
