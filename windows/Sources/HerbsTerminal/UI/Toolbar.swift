import Foundation
import WinSDK

/// The window's chrome, laid out as on the Mac and Linux: a toolbar with the Main Menu, New Tab and Connect via SSH
/// on the left, the tab's title and location in the middle, Export Session, the explorer switch, MultiExec,
/// Tailcat Peers and Search on the right, then minimize, maximize and close at the right end as on Windows; below
/// it, the tab strip. It is drawn in place of the standard title bar.
@MainActor
final class WindowChrome {
    enum Item: Hashable {
        case menu, newTab, connect, export, screenshot, explorer, multiExec, peers, search, title
        case minimize, maximize, close
        case tab(Int), tabClose(Int)

        var isCaptionButton: Bool { self == .minimize || self == .maximize || self == .close }
    }

    /// What the chrome shows; the workspace fills it in.
    struct State: Equatable {
        var tabNames: [String] = []
        var active = 0
        var title = ""
        var subtitle = ""
        var connected: String?
        var maximized = false
        var windowActive = true
        /// For a moment after Take Screenshot: its button shows a check mark and says so.
        var screenshotCopied = false
        /// The tab shows its file explorer instead of its terminal.
        var explorerShowing = false
        /// The tab's files can be browsed (this PC's for now; a host's come with SFTP).
        var explorerAvailable = true

        func isUnavailable(_ item: Item) -> Bool {
            WindowChrome.unavailable.contains(item) || (item == .explorer && !explorerAvailable)
        }
    }

    /// The parts of the toolbar not yet in the Windows version: drawn as on the Mac and Linux, but dimmed.
    static let unavailable: Set<Item> = [.multiExec, .peers, .search]

    private(set) var rects: [Item: RECT] = [:]
    var hover: Item?
    var pressed: Item?
    private var tooltip: HWND?
    private var tooltipIDs: [UINT_PTR] = []
    private var tooltipSignature = ""
    private var fonts: (ui: HFONT?, title: HFONT?, subtitle: HFONT?, tab: HFONT?, tabBold: HFONT?, glyph: HFONT?, caption: HFONT?) =
        (nil, nil, nil, nil, nil, nil, nil)
    private var fontDPI: UINT = 0

    func toolbarHeight(_ dpi: UINT) -> Int32 { scaled(40, dpi: dpi) }
    func stripHeight(_ dpi: UINT) -> Int32 { scaled(34, dpi: dpi) }
    func height(_ dpi: UINT) -> Int32 { toolbarHeight(dpi) + stripHeight(dpi) }

    // MARK: Fonts and colors

    private func ensureFonts(_ dpi: UINT) {
        guard fontDPI != dpi else { return }
        releaseFonts()
        fontDPI = dpi
        func font(_ face: String, _ pixels: Double, _ weight: Int32) -> HFONT? {
            withWide(face) {
                CreateFontW(-scaled(pixels, dpi: dpi), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0)
            }
        }
        let face = FontSet.isInstalledAny("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI"
        let icons = FontSet.isInstalledAny("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
        fonts = (font(face, 12, Int32(FW_NORMAL)), font(face, 12, Int32(FW_SEMIBOLD)), font(face, 10, Int32(FW_NORMAL)),
                 font(face, 13, Int32(FW_NORMAL)), font(face, 13, Int32(FW_SEMIBOLD)), font(icons, 16, Int32(FW_NORMAL)),
                 font(icons, 10, Int32(FW_NORMAL)))
    }

    private func releaseFonts() {
        for font in [fonts.ui, fonts.title, fonts.subtitle, fonts.tab, fonts.tabBold, fonts.glyph, fonts.caption] where font != nil {
            DeleteObject(font)
        }
        fonts = (nil, nil, nil, nil, nil, nil, nil)
    }

    struct Colors {
        var background, text, dim, glyphRest, glyphHover, glyphPressed, accent, accentText, border, closeHover: COLORREF

        init(dark: Bool) {
            background = dark ? colorRef(32, 32, 32) : colorRef(243, 243, 243)
            text = dark ? colorRef(242, 242, 242) : colorRef(26, 26, 26)
            dim = blend(text, background, 0.4)
            glyphRest = blend(background, text, 0.065)
            glyphHover = blend(background, text, 0.12)
            glyphPressed = blend(background, text, 0.18)
            accent = systemAccentColor
            accentText = dark ? blend(accent, colorRef(255, 255, 255), 0.45) : accent
            border = blend(background, text, 0.1)
            closeHover = colorRef(196, 43, 28)
        }
    }

    // MARK: Layout

    /// Lays the chrome out for a window `width` pixels wide.
    func layout(width: Int32, dpi: UINT, state: State) {
        ensureFonts(dpi)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        var rects: [Item: RECT] = [:]
        let barHeight = toolbarHeight(dpi)
        // Window buttons: full toolbar height, 46 px wide, at the right end.
        let captionWidth = s(46)
        var x = width
        for item in [Item.close, .maximize, .minimize] {
            rects[item] = RECT(left: x - captionWidth, top: 0, right: x, bottom: barHeight)
            x -= captionWidth
        }
        // Toolbar glyph buttons: 30 × 28, 4 px apart.
        let glyphWidth = s(30), glyphHeight = s(28), gap = s(4)
        let glyphTop = (barHeight - glyphHeight) / 2
        var left = s(8)
        for item in [Item.menu, .newTab, .connect] {
            rects[item] = RECT(left: left, top: glyphTop, right: left + glyphWidth, bottom: glyphTop + glyphHeight)
            left += glyphWidth + gap
        }
        var right = x - s(8)
        for item in [Item.search, .peers, .multiExec, .explorer, .screenshot, .export] {
            rects[item] = RECT(left: right - glyphWidth, top: glyphTop, right: right, bottom: glyphTop + glyphHeight)
            right -= glyphWidth + gap   // Search sits as close to Tailcat Peers as the other buttons, as on Linux.
        }
        // The title takes what the window can spare in the middle, centered on the window when it fits.
        let titleWidth = measure(state.title, fonts.title) + (state.subtitle.isEmpty ? 0 : s(5) + measure(state.subtitle, fonts.subtitle))
        let room = (left + s(12), right - s(12))
        let wanted = min(titleWidth, max(0, room.1 - room.0))
        var titleLeft = (width - wanted) / 2
        titleLeft = max(room.0, min(titleLeft, room.1 - wanted))
        rects[.title] = RECT(left: titleLeft, top: s(6), right: titleLeft + wanted, bottom: barHeight - s(6))

        // Tab chips: title plus a close button, up to 28 characters wide, then they shrink to fit.
        let stripTop = barHeight
        let chipTop = stripTop + s(4), chipBottom = stripTop + stripHeight(dpi) - s(4)
        let closeSize = s(20)
        let available = width - s(12)
        let natural = state.tabNames.enumerated().map { index, name in
            min(s(230), measure(name, index == state.active ? fonts.tabBold : fonts.tab) + s(12) + closeSize + s(10))
        }
        let total = natural.reduce(0, +) + s(6) * Int32(max(0, natural.count - 1))
        let squeeze = total > available ? Double(available) / Double(max(1, total)) : 1
        var chipLeft = s(6)
        for (index, wantedWidth) in natural.enumerated() {
            let chipWidth = max(s(70), Int32(Double(wantedWidth) * squeeze))
            let chip = RECT(left: chipLeft, top: chipTop, right: chipLeft + chipWidth, bottom: chipBottom)
            rects[.tab(index)] = chip
            let middle = (chip.top + chip.bottom) / 2
            rects[.tabClose(index)] = RECT(left: chip.right - closeSize - s(4), top: middle - closeSize / 2,
                                          right: chip.right - s(4), bottom: middle + closeSize / 2)
            chipLeft += chipWidth + s(6)
        }
        self.rects = rects
    }

    func item(at point: POINT) -> Item? {
        func inside(_ r: RECT) -> Bool { point.x >= r.left && point.x < r.right && point.y >= r.top && point.y < r.bottom }
        // Close buttons sit inside their chips, so they're checked first.
        for (item, rect) in rects {
            if case .tabClose = item, inside(rect) { return item }
        }
        return rects.first { inside($0.value) }?.key
    }

    private func measure(_ text: String, _ font: HFONT?) -> Int32 {
        guard !text.isEmpty else { return 0 }
        let dc = GetDC(nil)
        let old = SelectObject(dc, font)
        var size = SIZE()
        var units = Array(text.utf16)
        GetTextExtentPoint32W(dc, &units, Int32(units.count), &size)
        SelectObject(dc, old)
        ReleaseDC(nil, dc)
        return size.cx
    }

    // MARK: Painting

    func paint(_ dc: HDC?, width: Int32, dpi: UINT, state: State) {
        ensureFonts(dpi)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        let colors = Colors(dark: appIsDark)
        let barHeight = toolbarHeight(dpi), full = height(dpi)
        fill(dc, RECT(left: 0, top: 0, right: width, bottom: full), colors.background)
        // The strip's bottom border, as on Linux.
        fill(dc, RECT(left: 0, top: full - 1, right: width, bottom: full), colors.border)
        SetBkMode(dc, TRANSPARENT)
        let textColor = state.windowActive ? colors.text : colors.dim

        // Toolbar glyphs (Segoe Fluent Icons).
        let glyphs: [Item: String] = [
            .menu: "\u{E700}", .newTab: "\u{E710}", .connect: "\u{E703}", .export: "\u{E72D}",
            .screenshot: state.screenshotCopied ? "\u{E73E}" : "\u{E722}", // CheckMark, Camera
            .explorer: state.explorerShowing ? "\u{E756}" : "\u{E8B7}", .multiExec: "\u{E81E}", .peers: "\u{E716}", .search: "\u{E721}",
        ]
        for (item, glyph) in glyphs {
            guard let rect = rects[item] else { continue }
            let unavailable = state.isUnavailable(item)
            let isActive = item == .connect && state.connected != nil
            var background = isActive ? blend(colors.background, colors.accent, 0.18) : colors.glyphRest
            if unavailable { background = blend(colors.background, colors.text, 0.03) }
            if !unavailable {
                if pressed == item { background = isActive ? blend(colors.background, colors.accent, 0.3) : colors.glyphPressed }
                else if hover == item { background = isActive ? blend(colors.background, colors.accent, 0.24) : colors.glyphHover }
            }
            roundRect(dc, rect, radius: s(5), color: background)
            let foreground = unavailable ? blend(textColor, colors.background, 0.72) : (isActive ? colors.accentText : textColor)
            draw(dc, glyph, rect, font: fonts.glyph, color: foreground, flags: DT_CENTER)
        }

        // Title and location.
        if let rect = rects[.title], rect.right > rect.left {
            let titleWidth = measure(state.title, fonts.title)
            var titleRect = rect
            if !state.subtitle.isEmpty { titleRect.right = min(rect.right, rect.left + titleWidth) }
            draw(dc, state.title, titleRect, font: fonts.title, color: textColor, flags: DT_LEFT | DT_END_ELLIPSIS)
            if !state.subtitle.isEmpty, titleRect.right + s(5) < rect.right {
                let subtitleRect = RECT(left: titleRect.right + s(5), top: rect.top + s(1), right: rect.right, bottom: rect.bottom)
                draw(dc, state.subtitle, subtitleRect, font: fonts.subtitle, color: blend(textColor, colors.background, 0.4),
                     flags: DT_LEFT | DT_END_ELLIPSIS)
            }
        }

        // Window buttons, drawn as Windows 11 draws them.
        let captionGlyphs: [Item: String] = [.minimize: "\u{E921}", .maximize: state.maximized ? "\u{E923}" : "\u{E922}", .close: "\u{E8BB}"]
        for (item, glyph) in captionGlyphs {
            guard let rect = rects[item] else { continue }
            var foreground = textColor
            if item == .close, hover == item || pressed == item {
                fill(dc, rect, pressed == item ? blend(colors.closeHover, colorRef(0, 0, 0), 0.15) : colors.closeHover)
                foreground = colorRef(255, 255, 255)
            } else if pressed == item {
                fill(dc, rect, colors.glyphPressed)
            } else if hover == item {
                fill(dc, rect, colors.glyphHover)
            }
            draw(dc, glyph, rect, font: fonts.caption, color: foreground, flags: DT_CENTER)
        }
        _ = barHeight

        // Tab chips: the selected one tinted with the accent color and its title in semibold.
        for (index, name) in state.tabNames.enumerated() {
            guard let chip = rects[.tab(index)], let close = rects[.tabClose(index)] else { continue }
            let selected = index == state.active
            if selected {
                roundRect(dc, chip, radius: s(4), color: blend(colors.background, colors.accent, 0.18))
            } else if hover == .tab(index) || hover == .tabClose(index) {
                roundRect(dc, chip, radius: s(4), color: colors.glyphRest)
            }
            let label = RECT(left: chip.left + s(8), top: chip.top, right: close.left - s(2), bottom: chip.bottom)
            draw(dc, name, label, font: selected ? fonts.tabBold : fonts.tab, color: textColor, flags: DT_LEFT | DT_END_ELLIPSIS)
            if hover == .tabClose(index) { roundRect(dc, close, radius: s(3), color: colors.glyphHover) }
            draw(dc, "\u{E711}", close, font: fonts.caption, color: selected || hover == .tab(index) || hover == .tabClose(index) ? textColor : colors.dim,
                 flags: DT_CENTER)
        }
    }

    private func draw(_ dc: HDC?, _ text: String, _ rect: RECT, font: HFONT?, color: COLORREF, flags: Int32) {
        let old = SelectObject(dc, font)
        SetTextColor(dc, color)
        var r = rect
        var units = Array(text.utf16)
        DrawTextW(dc, &units, Int32(units.count), &r, UINT(flags | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX))
        SelectObject(dc, old)
    }

    private func roundRect(_ dc: HDC?, _ rect: RECT, radius: Int32, color: COLORREF) {
        let brush = CreateSolidBrush(color)
        let pen = CreatePen(PS_SOLID, 1, color)
        let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
        RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2)
        SelectObject(dc, oldBrush)
        SelectObject(dc, oldPen)
        DeleteObject(brush)
        DeleteObject(pen)
    }

    // MARK: Hover hints

    /// Hover hints, worded as on the Mac and Linux: what the control is, its shortcut, and what it does.
    static func hint(for item: Item, state: State) -> String? {
        let notYet = "\nNot in the Windows version yet."
        switch item {
        case .menu: return "Main Menu\nTabs, windows, zoom, themes, appearance and settings."
        case .newTab: return "New Tab (Ctrl+Shift+T)\nOpen another local terminal in this window."
        case .connect:
            if let label = state.connected {
                return "Connected to \(label)\nShow connection details, disconnect, or open a new connection (Ctrl+Shift+K)."
            }
            return "Connect via SSH (Ctrl+Shift+K)\nOpen a remote shell with a saved or new login."
        case .export: return "Export Session (Ctrl+Shift+S)\nSave everything in this terminal, scrollback included, to a text file."
        case .screenshot:
            if state.screenshotCopied { return "Screenshot copied\nPaste it anywhere with Ctrl+V." }
            return "Take Screenshot (Ctrl+Alt+S)\nCopy a picture of this whole window to the clipboard, ready to paste."
        case .explorer:
            if state.explorerShowing { return "Show Terminal (Ctrl+Shift+X)\nReplace the file explorer with this tab's shell." }
            if !state.explorerAvailable { return "Show File Explorer (Ctrl+Shift+X)\nFiles on SSH hosts aren't in the Windows version yet." }
            return "Show File Explorer (Ctrl+Shift+X)\nBrowse files on this PC in this tab."
        case .multiExec: return "MultiExec (Ctrl+Shift+M)" + notYet
        case .peers: return "Tailcat Peers" + notYet
        case .search: return "Search Terminal (Ctrl+Shift+F)" + notYet
        case .title:
            return [state.title, state.subtitle].filter { !$0.isEmpty }.joined(separator: " ")
                + "\nDouble-click to return the window and text to their default size; right-click to make the current size the default."
        case .tab(let index):
            guard state.tabNames.indices.contains(index) else { return nil }
            return "\(state.tabNames[index])\nClick to switch, double-click to rename, drag to reorder."
        case .tabClose(let index):
            guard state.tabNames.indices.contains(index) else { return nil }
            return "Close \(state.tabNames[index])\nEnd this tab's shell and release its resources."
        case .minimize, .maximize, .close: return nil
        }
    }

    /// Keeps the hint tool rectangles and texts in step with the layout.
    func updateTooltips(owner: HWND, state: State) {
        if tooltip == nil {
            tooltip = withWide("tooltips_class32") {
                CreateWindowExW(DWORD(WS_EX_TOPMOST), $0, nil, DWORD(WS_POPUP) | DWORD(TTS_ALWAYSTIP) | DWORD(TTS_NOPREFIX),
                                CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, owner, nil, GetModuleHandleW(nil), nil)
            }
            SendMessageW(tooltip, UINT(TTM_SETMAXTIPWIDTH), 0, LPARAM(scaled(340, dpi: GetDpiForWindow(owner))))
            // About half a second, as on the Mac.
            SendMessageW(tooltip, UINT(TTM_SETDELAYTIME), WPARAM(TTDT_INITIAL), 500)
            SendMessageW(tooltip, UINT(TTM_SETDELAYTIME), WPARAM(TTDT_AUTOPOP), 12_000)
            if appIsDark { withWide("DarkMode_Explorer") { _ = SetWindowTheme(tooltip, $0, nil) } }
        }
        let entries: [(UINT_PTR, RECT, String)] = rects.compactMap { item, rect in
            guard let text = Self.hint(for: item, state: state) else { return nil }
            return (Self.toolID(item), rect, text)
        }.sorted { $0.0 < $1.0 }
        let signature = entries.map { "\($0.0):\($0.1.left),\($0.1.top),\($0.1.right),\($0.1.bottom):\($0.2)" }.joined(separator: "|")
        guard signature != tooltipSignature else { return }
        tooltipSignature = signature
        for id in tooltipIDs {
            var info = TTTOOLINFOW()
            info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
            info.hwnd = owner
            info.uId = id
            _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_DELTOOLW), 0, LPARAM(Int(bitPattern: $0))) }
        }
        tooltipIDs = []
        for (id, rect, text) in entries {
            var units = text.wide
            units.withUnsafeMutableBufferPointer { pointer in
                var info = TTTOOLINFOW()
                info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
                info.uFlags = UINT(TTF_SUBCLASS)
                info.hwnd = owner
                info.uId = id
                info.rect = rect
                info.lpszText = pointer.baseAddress
                _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_ADDTOOLW), 0, LPARAM(Int(bitPattern: $0))) }
            }
            tooltipIDs.append(id)
        }
    }

    private static func toolID(_ item: Item) -> UINT_PTR {
        switch item {
        case .menu: 1
        case .newTab: 2
        case .connect: 3
        case .export: 4
        case .explorer: 5
        case .multiExec: 6
        case .peers: 7
        case .search: 8
        case .title: 9
        case .minimize: 10
        case .maximize: 11
        case .close: 12
        case .screenshot: 13
        case .tab(let index): UINT_PTR(100 + index)
        case .tabClose(let index): UINT_PTR(1000 + index)
        }
    }

    func release() {
        releaseFonts()
        if let tooltip { DestroyWindow(tooltip) }
        tooltip = nil
    }
}

/// The accent color from Settings ▸ Personalization ▸ Colors.
var systemAccentColor: COLORREF {
    var value: DWORD = 0
    var size = DWORD(MemoryLayout<DWORD>.size)
    let status = withWide("Software\\Microsoft\\Windows\\DWM") { key in
        withWide("AccentColor") { name in RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size) }
    }
    // Stored as 0xAABBGGRR; COLORREF is 0x00BBGGRR.
    return status == ERROR_SUCCESS ? COLORREF(value & 0x00FF_FFFF) : colorRef(0, 120, 212)
}

extension FontSet {
    /// Whether a font family is installed, monospaced or not.
    static func isInstalledAny(_ family: String) -> Bool {
        final class Found { var yes = false }
        let found = Found()
        var logFont = LOGFONTW()
        logFont.lfCharSet = BYTE(DEFAULT_CHARSET)
        let units = Array(family.utf16.prefix(31))
        withUnsafeMutableBytes(of: &logFont.lfFaceName) { raw in
            let face = raw.bindMemory(to: WCHAR.self)
            for (index, unit) in units.enumerated() { face[index] = unit }
            face[units.count] = 0
        }
        let dc = GetDC(nil)
        defer { ReleaseDC(nil, dc) }
        withExtendedLifetime(found) {
            _ = EnumFontFamiliesExW(dc, &logFont, { _, _, _, context in
                Unmanaged<Found>.fromOpaque(UnsafeRawPointer(bitPattern: Int(context))!).takeUnretainedValue().yes = true
                return 0
            }, LPARAM(Int(bitPattern: Unmanaged.passUnretained(found).toOpaque())), 0)
        }
        return found.yes
    }
}
