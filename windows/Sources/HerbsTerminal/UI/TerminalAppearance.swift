import Foundation
import SwiftTerm
import WinSDK

/// The four faces of the terminal font and the cell size they give.
struct FontSet {
    /// Cascadia Mono ships with Windows 11 and Windows Terminal; Consolas with every Windows since Vista.
    static let stockFamily = "Cascadia Mono"

    private(set) var normal: HFONT?
    private var bold: HFONT?
    private var italic: HFONT?
    private var boldItalic: HFONT?
    private(set) var cellWidth: Int32 = 8
    private(set) var cellHeight: Int32 = 16

    init() {}

    init(family: String, points: Double, dpi: UINT) {
        let height = -Int32((points * Double(dpi) / 72).rounded())
        let face = Self.isInstalled(family) ? family : (Self.isInstalled(Self.stockFamily) ? Self.stockFamily : "Consolas")
        func make(_ weight: Int32, _ italic: Bool) -> HFONT? {
            withWide(face) {
                CreateFontW(height, 0, 0, 0, weight, italic ? 1 : 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS),
                            DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(FIXED_PITCH | FF_MODERN), $0)
            }
        }
        normal = make(Int32(FW_NORMAL), false)
        bold = make(Int32(FW_BOLD), false)
        italic = make(Int32(FW_NORMAL), true)
        boldItalic = make(Int32(FW_BOLD), true)

        let dc = GetDC(nil)
        let old = SelectObject(dc, normal)
        var metrics = TEXTMETRICW()
        GetTextMetricsW(dc, &metrics)
        var size = SIZE()
        var sample = Array("M".utf16)
        GetTextExtentPoint32W(dc, &sample, 1, &size)
        SelectObject(dc, old)
        ReleaseDC(nil, dc)
        cellWidth = max(1, size.cx)
        cellHeight = max(1, metrics.tmHeight + metrics.tmExternalLeading)
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> HFONT? {
        switch (isBold, isItalic) {
        case (true, true): boldItalic ?? normal
        case (true, false): bold ?? normal
        case (false, true): italic ?? normal
        case (false, false): normal
        }
    }

    mutating func release() {
        for font in [normal, bold, italic, boldItalic] where font != nil { DeleteObject(font) }
        normal = nil; bold = nil; italic = nil; boldItalic = nil
    }

    static func isInstalled(_ family: String) -> Bool {
        installedMonospacedFamilies().contains { $0.caseInsensitiveCompare(family) == .orderedSame }
    }

    /// The installed fixed-pitch font families, for Settings.
    static func installedMonospacedFamilies() -> [String] {
        final class Collector { var names = Set<String>() }
        let collector = Collector()
        var logFont = LOGFONTW()
        logFont.lfCharSet = BYTE(DEFAULT_CHARSET)
        let dc = GetDC(nil)
        defer { ReleaseDC(nil, dc) }
        withExtendedLifetime(collector) {
            _ = EnumFontFamiliesExW(dc, &logFont, { font, _, _, context in
                guard let font else { return 1 }
                let collector = Unmanaged<Collector>.fromOpaque(UnsafeRawPointer(bitPattern: Int(context))!).takeUnretainedValue()
                let logical = font.pointee
                if (logical.lfPitchAndFamily & 0x3) == BYTE(FIXED_PITCH) {
                    let name = withUnsafeBytes(of: logical.lfFaceName) { raw in
                        String(decoding: raw.bindMemory(to: WCHAR.self).prefix { $0 != 0 }, as: UTF16.self)
                    }
                    if !name.hasPrefix("@") { collector.names.insert(name) }
                }
                return 1
            }, LPARAM(Int(bitPattern: Unmanaged.passUnretained(collector).toOpaque())), 0)
        }
        return collector.names.sorted()
    }
}

/// The terminal's colors from the profile's theme, or Basic in the system's light or dark mode.
struct Colors {
    var foreground: COLORREF
    var background: COLORREF
    var cursor: COLORREF
    var cursorText: COLORREF
    var selection: COLORREF
    var selectedText: COLORREF?
    var palette: [COLORREF]

    init(theme: TerminalTheme? = nil, dark: Bool = systemPrefersDark) {
        let colors = theme?.colors ?? TerminalTheme.basic(dark: dark)
        let fallback = TerminalTheme.basic(dark: dark)
        func pick(_ key: String) -> COLORREF? { (colors[key] ?? fallback[key])?.colorRef }
        foreground = pick("Foreground Color") ?? colorRef(223, 223, 223)
        background = pick("Background Color") ?? colorRef(30, 30, 30)
        cursor = pick("Cursor Color") ?? foreground
        cursorText = colors["Cursor Text Color"]?.colorRef ?? background
        selection = pick("Selection Color") ?? blend(background, foreground, 0.3)
        selectedText = colors["Selected Text Color"]?.colorRef
        palette = (theme?.palette ?? TerminalTheme.basicPalette).map(\.colorRef)
    }

    struct Look {
        var foreground: COLORREF
        var background: COLORREF
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strike: Bool
        var invisible: Bool
    }

    func resolve(_ attribute: Attribute, selected: Bool) -> Look {
        let style = attribute.style
        var fg = color(attribute.fg, foreground: true, bold: style.contains(.bold))
        var bg = color(attribute.bg, foreground: false, bold: false)
        if style.contains(.inverse) { swap(&fg, &bg) }
        if style.contains(.dim) { fg = blend(fg, bg, 0.4) }
        if selected {
            bg = selection
            if let selectedText { fg = selectedText }
        }
        return Look(foreground: fg, background: bg, bold: style.contains(.bold), italic: style.contains(.italic),
                    underline: style.contains(.underline), strike: style.contains(.crossedOut), invisible: style.contains(.invisible))
    }

    private func color(_ color: Attribute.Color, foreground isForeground: Bool, bold: Bool) -> COLORREF {
        switch color {
        case .defaultColor:
            return isForeground ? foreground : background
        case .defaultInvertedColor:
            // The empty cell's background is "inverted default"; as a foreground it means reverse video.
            return isForeground ? background : background
        case .trueColor(let red, let green, let blue):
            return colorRef(red, green, blue)
        case .ansi256(let code):
            let index = Int(code)
            if index < 16 {
                // Bold text in one of the 8 basic colors uses the bright variant, as most terminals do.
                return palette[bold && index < 8 ? index + 8 : index]
            }
            if index < 232 {
                let cube = index - 16
                func level(_ v: Int) -> UInt8 { v == 0 ? 0 : UInt8(55 + v * 40) }
                return colorRef(level(cube / 36), level((cube / 6) % 6), level(cube % 6))
            }
            let gray = UInt8(8 + (index - 232) * 10)
            return colorRef(gray, gray, gray)
        }
    }
}
