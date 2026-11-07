import Foundation
import WinSDK

/// A plain-text editor shown as a tab in the terminal window, as on the Mac and Linux: monospaced, with undo,
/// Find (Ctrl+F), Wrap Lines and a status line with line and column, line count, encoding and line endings.
/// Ctrl+S or Save writes the file back in its own encoding and line endings; closing the tab, the window or the
/// app with unsaved changes asks first. The text is a RichEdit control in plain-text mode.
@MainActor
final class TextEditorPane: WindowObject, WorkspaceTab {
    static let className = "HerbsTerminalEditor"

    let source: TextFileSource
    private(set) var hwnd: HWND?
    private var edit: HWND?
    private var findField: HWND?
    var number = 0
    private(set) var isEdited = false
    private var loaded = false
    private var saving = false
    /// A UTF-16 file's byte order, kept when saving (its mark tells which).
    private var bigEndian = false
    /// Counts edits, so a save only marks the file saved when nothing changed while it was being written.
    private var changes = 0
    private var encoding: String.Encoding = .utf8
    private var lineEnding = "\n"
    private var loadedVersion: TextFileSource.Version?
    private var wraps: Bool
    private var findVisible = false
    private var status = "Loading…"
    /// The text as RichEdit holds it (paragraphs end in CR), for the status line; nil after a change.
    private var cachedText: [UInt16]?
    private var buttons: [(rect: RECT, button: Button)] = []
    private var hover: Button?
    private var trackingMouse = false
    private var fonts: (ui: HFONT?, glyph: HFONT?) = (nil, nil)
    private var textFonts = FontSet()
    private let hints = HoverHints()

    /// The file couldn't be opened: the workspace closes the tab.
    var onFailure: (() -> Void)?
    /// The tab's name or the toolbar's title changed (unsaved changes, saved).
    var onChange: (() -> Void)?

    private enum Button: Hashable { case wrap, save, previous, next, done }
    private static let statusTimer: UINT_PTR = 0x57A7
    private static let editID = 1, findID = 2

    var title: String { source.name }
    var tabName: String { source.name + (isEdited ? " •" : "") }

    init(parent: HWND, source: TextFileSource) {
        self.source = source
        wraps = Preferences.shared.bool("editorWrapsLines") ?? true
        hwnd = createWindow(self, className: Self.className, style: DWORD(WS_CHILD) | DWORD(WS_CLIPCHILDREN), parent: parent)
        guard let hwnd else { return }
        _ = withWide("Msftedit.dll") { LoadLibraryW($0) }
        edit = withWide("RICHEDIT50W") { cls in
            CreateWindowExW(0, cls, nil, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_VSCROLL) | DWORD(WS_HSCROLL) | DWORD(WS_TABSTOP) |
                            DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL) | DWORD(ES_AUTOHSCROLL) | DWORD(ES_NOHIDESEL),
                            0, 0, 10, 10, hwnd, HMENU(bitPattern: Self.editID), GetModuleHandleW(nil), nil)
        }
        // Plain text with multi-level undo; set while the control is still empty, as RichEdit requires.
        SendMessageW(edit, RE.setTextMode, WPARAM(RE.plainText | RE.multiLevelUndo), 0)
        SendMessageW(edit, RE.exLimitText, 0, LPARAM(Int32.max - 1))
        SendMessageW(edit, UINT(EM_SETREADONLY), 1, 0)
        SendMessageW(edit, RE.setEventMask, 0, LPARAM(RE.notifyChange | RE.notifySelection))
        findField = withWide("EDIT") { cls in
            CreateWindowExW(0, cls, nil, DWORD(WS_CHILD) | DWORD(ES_AUTOHSCROLL) | DWORD(WS_TABSTOP),
                            0, 0, 10, 10, hwnd, HMENU(bitPattern: Self.findID), GetModuleHandleW(nil), nil)
        }
        withWide("Find") { _ = SendMessageW(findField, UINT(EM_SETCUEBANNER), 1, LPARAM(Int(bitPattern: $0))) }
        applyTheme()
        load()
    }

    func close() {
        hints.release()
        if let hwnd { KillTimer(hwnd, Self.statusTimer); DestroyWindow(hwnd) }
        hwnd = nil
        for font in [fonts.ui, fonts.glyph] where font != nil { DeleteObject(font) }
        textFonts.release()
    }

    func show(_ visible: Bool) {
        guard let hwnd else { return }
        ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE)
        if visible { focus() }
    }

    func focus() {
        SetFocus(findVisible && GetFocus() == findField ? findField : edit)
    }

    func move(to rect: RECT) {
        guard let hwnd else { return }
        MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, true)
    }

    // MARK: Look

    private var dpi: UINT { hwnd.map { GetDpiForWindow($0) } ?? 96 }
    private var colors: WindowChrome.Colors { WindowChrome.Colors(dark: appIsDark) }
    private var textBackground: COLORREF { appIsDark ? colorRef(28, 28, 28) : colorRef(255, 255, 255) }
    private var barBackground: COLORREF { appIsDark ? colorRef(32, 32, 32) : colorRef(243, 243, 243) }

    /// Light or dark like the window, in the terminal's font (at least 12 points).
    func applyTheme() {
        guard let hwnd else { return }
        let dpi = GetDpiForWindow(hwnd)
        for font in [fonts.ui, fonts.glyph] where font != nil { DeleteObject(font) }
        func font(_ face: String, _ pixels: Double) -> HFONT? {
            withWide(face) { CreateFontW(-scaled(pixels, dpi: dpi), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0) }
        }
        let face = FontSet.isInstalledAny("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI"
        let icons = FontSet.isInstalledAny("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
        fonts = (font(face, 13), font(icons, 14))
        SendMessageW(findField, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(fonts.ui)))), 1)

        let settings = TerminalProfile.shared.settings(for: nil)
        textFonts.release()
        textFonts = FontSet(family: settings.fontFamily.isEmpty ? FontSet.stockFamily : settings.fontFamily,
                            points: max(12, settings.effectiveSize), dpi: dpi)
        SendMessageW(edit, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(textFonts.normal)))), 1)
        SendMessageW(edit, RE.setBackgroundColor, 0, LPARAM(textBackground))
        var format = CHARFORMATW()
        format.cbSize = UINT(MemoryLayout<CHARFORMATW>.size)
        format.dwMask = DWORD(CFM_COLOR)
        format.crTextColor = colors.text
        _ = withUnsafeMutablePointer(to: &format) { SendMessageW(edit, RE.setCharFormat, WPARAM(RE.allText), LPARAM(Int(bitPattern: $0))) }
        applyWrap()
        withWide(appIsDark ? "DarkMode_Explorer" : "Explorer") { _ = SetWindowTheme(edit, $0, nil) }
        withWide(appIsDark ? "DarkMode_CFD" : "CFD") { _ = SetWindowTheme(findField, $0, nil) }
        layout()
        InvalidateRect(hwnd, nil, true)
    }

    private func applyWrap() {
        // A target width of 0 wraps at the window's edge; 1 doesn't wrap.
        SendMessageW(edit, RE.setTargetDevice, 0, wraps ? 0 : 1)
    }

    // MARK: Layout

    private func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
    private var barHeight: Int32 { s(32) }
    private var findHeight: Int32 { findVisible ? s(40) : 0 }

    private func layout() {
        guard let hwnd else { return }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let margin = s(6)
        MoveWindow(edit, margin, findHeight + margin, client.right - 2 * margin, client.bottom - findHeight - barHeight - 2 * margin, true)
        var rects: [(RECT, Button)] = []
        // The bottom bar: status on the left, then Wrap Lines and Save on the right.
        let barTop = client.bottom - barHeight
        let save = RECT(left: client.right - s(80), top: barTop + s(4), right: client.right - s(10), bottom: client.bottom - s(4))
        let wrap = RECT(left: save.left - s(118), top: save.top, right: save.left - s(10), bottom: save.bottom)
        rects += [(wrap, .wrap), (save, .save)]
        if findVisible {
            let top = s(6), bottom = findHeight - s(6)
            let done = RECT(left: client.right - s(40), top: top, right: client.right - s(10), bottom: bottom)
            let next = RECT(left: done.left - s(34), top: top, right: done.left - s(4), bottom: bottom)
            let previous = RECT(left: next.left - s(34), top: top, right: next.left - s(4), bottom: bottom)
            rects += [(previous, .previous), (next, .next), (done, .done)]
            let fieldRight = previous.left - s(8)
            let fieldLeft = max(s(10), fieldRight - s(300))
            MoveWindow(findField, fieldLeft, top + s(3), fieldRight - fieldLeft, bottom - top - s(6), true)
        }
        ShowWindow(findField, findVisible ? SW_SHOW : SW_HIDE)
        buttons = rects.map { (rect: $0.0, button: $0.1) }
        updateHints()
        InvalidateRect(hwnd, nil, false)
    }

    private func updateHints() {
        guard let hwnd else { return }
        let text: [Button: String] = [
            .wrap: "Wrap Lines\nWrap long lines at the edge instead of scrolling sideways.",
            .save: "Save (Ctrl+S)\nWrite your changes to the file.",
            .previous: "Previous (Shift+Enter)\nFind the match above.",
            .next: "Next (Enter)\nFind the match below.",
            .done: "Done (Esc)\nClose Find and go back to editing.",
        ]
        hints.update(owner: hwnd, buttons.enumerated().map { (UINT_PTR($0.offset + 1), $0.element.rect, text[$0.element.button] ?? "") })
    }

    private func paint(_ hwnd: HWND) {
        var ps = PAINTSTRUCT()
        guard let screen = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let dc = CreateCompatibleDC(screen)
        let bitmap = CreateCompatibleBitmap(screen, client.right, client.bottom)
        let old = SelectObject(dc, bitmap)
        defer { SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc) }
        let colors = self.colors
        fill(dc, client, textBackground)
        SetBkMode(dc, TRANSPARENT)
        if findVisible {
            fill(dc, RECT(left: 0, top: 0, right: client.right, bottom: findHeight), barBackground)
            fill(dc, RECT(left: 0, top: findHeight - 1, right: client.right, bottom: findHeight), colors.border)
        }
        let barTop = client.bottom - barHeight
        fill(dc, RECT(left: 0, top: barTop, right: client.right, bottom: client.bottom), barBackground)
        fill(dc, RECT(left: 0, top: barTop, right: client.right, bottom: barTop + 1), colors.border)
        let wrapLeft = buttons.first { $0.button == .wrap }?.rect.left ?? client.right
        draw(dc, status, RECT(left: s(10), top: barTop, right: wrapLeft - s(10), bottom: client.bottom), font: fonts.ui, color: colors.dim, ellipsis: true)
        for (rect, button) in buttons {
            let hovered = hover == button
            switch button {
            case .wrap:
                if hovered { roundFill(dc, rect, blend(barBackground, colors.text, 0.08)) }
                draw(dc, wraps ? "\u{E73A}" : "\u{E739}", RECT(left: rect.left + s(4), top: rect.top, right: rect.left + s(24), bottom: rect.bottom),
                     font: fonts.glyph, color: wraps ? colors.accentText : colors.text, center: true)
                draw(dc, "Wrap Lines", RECT(left: rect.left + s(28), top: rect.top, right: rect.right, bottom: rect.bottom), font: fonts.ui, color: colors.text)
            case .save:
                let enabled = loaded && isEdited && !saving
                let background = enabled ? (hovered ? blend(colors.accent, colors.text, 0.12) : colors.accent) : blend(barBackground, colors.text, 0.08)
                roundFill(dc, rect, background)
                draw(dc, "Save", rect, font: fonts.ui, color: enabled ? colorRef(255, 255, 255) : blend(colors.text, barBackground, 0.55), center: true)
            case .previous, .next, .done:
                if hovered { roundFill(dc, rect, blend(barBackground, colors.text, 0.1)) }
                let glyph = button == .previous ? "\u{E70E}" : button == .next ? "\u{E70D}" : "\u{E711}"
                draw(dc, glyph, rect, font: fonts.glyph, color: colors.text, center: true)
            }
        }
        BitBlt(screen, 0, 0, client.right, client.bottom, dc, 0, 0, DWORD(SRCCOPY))
    }

    private func draw(_ dc: HDC?, _ text: String, _ rect: RECT, font: HFONT?, color: COLORREF, center: Bool = false, ellipsis: Bool = false) {
        let old = SelectObject(dc, font)
        SetTextColor(dc, color)
        var r = rect
        var units = Array(text.utf16)
        var flags = DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX
        if center { flags |= DT_CENTER }
        if ellipsis { flags |= DT_END_ELLIPSIS }
        DrawTextW(dc, &units, Int32(units.count), &r, UINT(flags))
        SelectObject(dc, old)
    }

    private func roundFill(_ dc: HDC?, _ rect: RECT, _ color: COLORREF) {
        let radius = s(4)
        let brush = CreateSolidBrush(color), pen = CreatePen(PS_SOLID, 1, color)
        let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
        RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2)
        SelectObject(dc, oldBrush); SelectObject(dc, oldPen)
        DeleteObject(brush); DeleteObject(pen)
    }

    private func button(at point: POINT) -> Button? {
        buttons.first { point.x >= $0.rect.left && point.x < $0.rect.right && point.y >= $0.rect.top && point.y < $0.rect.bottom }?.button
    }

    private func press(_ button: Button) {
        switch button {
        case .wrap:
            wraps.toggle()
            Preferences.shared.set(wraps, "editorWrapsLines")
            applyWrap()
            layout()
        case .save: save()
        case .previous: step(forward: false)
        case .next: step(forward: true)
        case .done: closeFind()
        }
    }

    // MARK: Text

    /// The text with paragraphs ending in CR, as RichEdit keeps it.
    private var richText: [UInt16] {
        if let cachedText { return cachedText }
        var length = GETTEXTLENGTHEX(flags: DWORD(GTL_NUMCHARS | GTL_PRECISE), codepage: 1200)
        let count = Int(withUnsafeMutablePointer(to: &length) { SendMessageW(edit, RE.getTextLength, WPARAM(UInt(bitPattern: $0)), 0) })
        var buffer = [UInt16](repeating: 0, count: count + 1)
        let copied = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            var request = GETTEXTEX(cb: DWORD(pointer.count * 2), flags: DWORD(GT_DEFAULT), codepage: 1200, lpDefaultChar: nil, lpUsedDefChar: nil)
            return Int(withUnsafeMutablePointer(to: &request) {
                SendMessageW(edit, RE.getText, WPARAM(UInt(bitPattern: $0)), LPARAM(Int(bitPattern: pointer.baseAddress)))
            })
        }
        let text = Array(buffer.prefix(copied))
        cachedText = text
        return text
    }

    /// The text as the file will hold it, in the line endings it had.
    private var fileText: String {
        let text = String(decoding: richText, as: UTF16.self)
        return lineEnding == "\r" ? text : text.replacingOccurrences(of: "\r", with: lineEnding)
    }

    private func load() {
        let source = self.source
        MainThread.background({ () throws -> (String, String.Encoding, String, Bool, TextFileSource.Version?) in
            let data = try source.read()
            guard data.count <= TextCodec.sizeLimit else { throw TextCodec.tooLarge(source.name) }
            guard let decoded = TextCodec.decode(data) else {
                throw FileIssue("“\(source.name)” doesn't look like a text file, so it wasn't opened for editing.")
            }
            var text = decoded.text
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() } // The UTF-16 mark goes back on when saving.
            return (text, decoded.encoding, TextCodec.lineEnding(of: text), data.starts(with: [0xFE, 0xFF]), try? source.version())
        }) { [weak self] result in
            guard let self, self.hwnd != nil else { return }
            switch result {
            case .success(let (text, encoding, ending, bigEndian, version)):
                self.encoding = encoding
                self.bigEndian = bigEndian
                self.lineEnding = ending
                self.loadedVersion = version
                // RichEdit keeps paragraphs as CR; every kind of line break becomes one.
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
                withWide(normalized) { _ = SendMessageW(self.edit, UINT(WM_SETTEXT), 0, LPARAM(Int(bitPattern: $0))) }
                SendMessageW(self.edit, UINT(EM_EMPTYUNDOBUFFER), 0, 0)
                SendMessageW(self.edit, UINT(EM_SETMODIFY), 0, 0)
                SendMessageW(self.edit, UINT(EM_SETREADONLY), 0, 0)
                var start = CHARRANGE(cpMin: 0, cpMax: 0)
                _ = withUnsafeMutablePointer(to: &start) { SendMessageW(self.edit, RE.exSetSelection, 0, LPARAM(Int(bitPattern: $0))) }
                self.cachedText = nil
                self.loaded = true
                self.setEdited(false)
                self.updateStatus()
                if let hwnd = self.hwnd, IsWindowVisible(hwnd) { SetFocus(self.edit) }
            case .failure(let error):
                self.status = error.localizedDescription
                FormDialog.tell(owner: self.root, title: "The file couldn't be opened", message: error.localizedDescription)
                self.onFailure?()
            }
        }
    }

    private var root: HWND? { hwnd.flatMap { GetAncestor($0, UINT(GA_ROOT)) } }

    private func setEdited(_ edited: Bool) {
        if let hwnd { InvalidateRect(hwnd, nil, false) }
        guard isEdited != edited else { return }
        isEdited = edited
        onChange?()
    }

    private func updateStatus() {
        guard loaded else { return }
        let text = richText
        var selection = CHARRANGE()
        _ = withUnsafeMutablePointer(to: &selection) { SendMessageW(edit, RE.exGetSelection, 0, LPARAM(Int(bitPattern: $0))) }
        let caret = min(max(0, Int(selection.cpMin)), text.count)
        var line = 1, lineStart = 0
        for index in 0..<caret where text[index] == 13 { line += 1; lineStart = index + 1 }
        var lines = line
        for index in caret..<text.count where text[index] == 13 { lines += 1 }
        let column = caret - lineStart + 1
        status = "Line \(line), Column \(column) · \(lines) line\(lines == 1 ? "" : "s") · \(TextCodec.name(of: encoding)) · \(TextCodec.name(ofEnding: lineEnding))"
        if let hwnd {
            var client = RECT()
            GetClientRect(hwnd, &client)
            client.top = client.bottom - barHeight
            InvalidateRect(hwnd, &client, false)
        }
    }

    // MARK: Find

    func find() {
        guard loaded else { return }
        findVisible = true
        layout()
        SetFocus(findField)
        SendMessageW(findField, UINT(EM_SETSEL), 0, -1)
    }

    private func closeFind() {
        findVisible = false
        layout()
        SetFocus(edit)
    }

    /// Finds the next (or previous) match of the Find field, wrapping around at the end; ignores case.
    private func step(forward: Bool, fromStart: Bool = false) {
        let query = findField.map { String(windowText: $0) } ?? ""
        guard !query.isEmpty else { return }
        var selection = CHARRANGE()
        _ = withUnsafeMutablePointer(to: &selection) { SendMessageW(edit, RE.exGetSelection, 0, LPARAM(Int(bitPattern: $0))) }
        let end = Int32(richText.count)
        func search(from: Int32, to: Int32) -> CHARRANGE? {
            withWide(query) { pointer in
                var request = FINDTEXTEXW(chrg: CHARRANGE(cpMin: from, cpMax: to), lpstrText: pointer, chrgText: CHARRANGE())
                let found = withUnsafeMutablePointer(to: &request) {
                    SendMessageW(edit, RE.findText, WPARAM(forward ? RE.findDown : 0), LPARAM(Int(bitPattern: $0)))
                }
                return found < 0 ? nil : request.chrgText
            }
        }
        let match: CHARRANGE?
        if forward {
            let start = fromStart ? selection.cpMin : selection.cpMax
            match = search(from: start, to: -1) ?? search(from: 0, to: -1)
        } else {
            match = search(from: selection.cpMin, to: 0) ?? search(from: end, to: 0)
        }
        guard var match else { MessageBeep(UINT(MB_OK)); return }
        _ = withUnsafeMutablePointer(to: &match) { SendMessageW(edit, RE.exSetSelection, 0, LPARAM(Int(bitPattern: $0))) }
        SendMessageW(edit, UINT(EM_SCROLLCARET), 0, 0)
    }

    // MARK: Saving

    /// Ctrl+S or Save: writes the file, after checking nobody changed it since it was opened or last saved.
    func save(then done: ((Bool) -> Void)? = nil) {
        guard loaded, !saving else { done?(false); return }
        let text = fileText
        let encoded: Data?
        if encoding == .utf16 {
            // The byte-order mark, then the text in the file's own byte order.
            encoded = text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian).map { Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + $0 }
        } else {
            encoded = text.data(using: encoding)
        }
        guard let data = encoded else {
            FormDialog.tell(owner: root, title: "The file couldn't be saved",
                            message: "Some characters can't be saved in \(TextCodec.name(of: encoding)). Remove them, or save a copy in UTF-8.")
            done?(false)
            return
        }
        saving = true
        let savedChanges = changes
        let source = self.source, loadedVersion = self.loadedVersion
        MainThread.background({ try? source.version() }) { [weak self] result in
            guard let self else { return }
            if case .success(let current?) = result, let loadedVersion, current != loadedVersion,
               FormDialog.ask(owner: self.root, title: "“\(source.name)” changed since you opened it.",
                              message: "Saving replaces those changes with yours.",
                              buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Save Anyway")]) != 1 {
                self.saving = false
                done?(false)
                return
            }
            MainThread.background({ () throws -> TextFileSource.Version? in
                try source.write(data)
                return try? source.version()
            }) { [weak self] result in
                guard let self else { return }
                self.saving = false
                switch result {
                case .success(let version):
                    self.loadedVersion = version
                    if self.changes == savedChanges {
                        SendMessageW(self.edit, UINT(EM_SETMODIFY), 0, 0)
                        self.setEdited(false)
                    }
                    self.updateStatus()
                    done?(true)
                case .failure(let error):
                    FormDialog.tell(owner: self.root, title: "The file couldn't be saved", message: error.localizedDescription)
                    if let hwnd = self.hwnd { InvalidateRect(hwnd, nil, false) }
                    done?(false)
                }
            }
        }
    }

    /// Before the tab closes: `done(true)` when it may close (saved, nothing to save, or changes discarded).
    func confirmClose(_ done: @escaping (Bool) -> Void) {
        guard isEdited else { done(true); return }
        let answer = FormDialog.ask(owner: root, title: "Do you want to save the changes to “\(source.name)”?",
                                    message: "Your changes will be lost if you don't save them.",
                                    buttons: [.init(title: "Don't Save"), .init(title: "Cancel"), .init(title: "Save", isDefault: true)],
                                    cancelIndex: 1)
        switch answer {
        case 2?: save(then: done)
        case 0?: done(true)
        default: done(false)
        }
    }

    // MARK: Keys and messages

    /// Ctrl+S, Ctrl+F, and Enter, Shift+Enter and Esc in the Find field. Returns true when handled.
    func handleKey(_ message: MSG) -> Bool {
        guard message.message == UINT(WM_KEYDOWN) else { return false }
        let key = Int32(message.wParam)
        let control = isPressed(VK_CONTROL), shift = isPressed(VK_SHIFT), alt = isPressed(VK_MENU)
        if control && !shift && !alt && key == Int32(Character("S").asciiValue!) { save(); return true }
        if control && !shift && !alt && key == Int32(Character("F").asciiValue!) { find(); return true }
        if message.hwnd == findField {
            if key == VK_RETURN { step(forward: !shift); return true }
            if key == VK_ESCAPE { closeFind(); return true }
        }
        return false
    }

    /// For the test hook: types text at the caret (`\r` is a line break).
    func type(_ text: String) {
        guard loaded, !text.isEmpty else { return } // An empty step is a pause; it mustn't replace the selection.
        withWide(text.replacingOccurrences(of: "\n", with: "\r")) { _ = SendMessageW(edit, UINT(EM_REPLACESEL), 1, LPARAM(Int(bitPattern: $0))) }
    }

    /// For the test hook: save, wrap, find=TEXT, next, previous, done, end (caret to the end).
    func perform(named name: String) {
        if name.hasPrefix("find=") {
            find()
            withWide(String(name.dropFirst(5))) { _ = SetWindowTextW(findField, $0) }
            return
        }
        switch name {
        case "save": save()
        case "wrap": press(.wrap)
        case "next": step(forward: true)
        case "previous": step(forward: false)
        case "done": closeFind()
        case "end":
            var end = CHARRANGE(cpMin: -1, cpMax: -1)
            _ = withUnsafeMutablePointer(to: &end) { SendMessageW(edit, RE.exSetSelection, 0, LPARAM(Int(bitPattern: $0))) }
        default: break
        }
    }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_SIZE:
            layout()
            return 0
        case WM_PAINT:
            paint(hwnd)
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SETFOCUS:
            focus()
            return 0
        case WM_COMMAND:
            let id = Int(loWord(LPARAM(Int(bitPattern: UInt(wParam))))), code = Int32(hiWord(LPARAM(Int(bitPattern: UInt(wParam)))))
            if id == Self.editID, code == EN_CHANGE, loaded {
                cachedText = nil
                // RichEdit's own flag tells real edits from late notices.
                if SendMessageW(edit, UINT(EM_GETMODIFY), 0, 0) != 0 {
                    changes += 1
                    setEdited(true)
                }
                SetTimer(hwnd, Self.statusTimer, 120, nil)
            } else if id == Self.findID, code == EN_CHANGE {
                step(forward: true, fromStart: true) // Find as you type, from the current match.
            }
            return 0
        case WM_NOTIFY:
            if let header = UnsafePointer<NMHDR>(bitPattern: UInt(lParam))?.pointee, header.hwndFrom == edit, header.code == RE.selectionChanged {
                SetTimer(hwnd, Self.statusTimer, 120, nil)
            }
            return 0
        case WM_TIMER where wParam == Self.statusTimer:
            KillTimer(hwnd, Self.statusTimer)
            updateStatus()
            return 0
        case WM_LBUTTONDOWN:
            if let button = button(at: POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))) { press(button) }
            return 0
        case WM_MOUSEMOVE:
            if !trackingMouse {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                trackingMouse = true
            }
            let item = button(at: POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam))))
            if item != hover { hover = item; InvalidateRect(hwnd, nil, false) }
            return 0
        case WM_MOUSELEAVE:
            trackingMouse = false
            if hover != nil { hover = nil; InvalidateRect(hwnd, nil, false) }
            return 0
        case WM_CTLCOLOREDIT:
            let dc = HDC(bitPattern: UInt(wParam))
            let background = appIsDark ? colorRef(43, 43, 43) : colorRef(255, 255, 255)
            SetTextColor(dc, colors.text)
            SetBkColor(dc, background)
            SetDCBrushColor(dc, background)
            return LRESULT(Int(bitPattern: UnsafeRawPointer(GetStockObject(DC_BRUSH))))
        default:
            return nil
        }
    }
}

/// RichEdit messages and flags (Richedit.h), as plain numbers.
private enum RE {
    static let exGetSelection = UINT(WM_USER + 52)
    static let exLimitText = UINT(WM_USER + 53)
    static let exSetSelection = UINT(WM_USER + 55)
    static let setBackgroundColor = UINT(WM_USER + 67)
    static let setCharFormat = UINT(WM_USER + 68)
    static let setEventMask = UINT(WM_USER + 69)
    static let setTargetDevice = UINT(WM_USER + 72)
    static let setTextMode = UINT(WM_USER + 89)
    static let getText = UINT(WM_USER + 94)
    static let getTextLength = UINT(WM_USER + 95)
    static let findText = UINT(WM_USER + 124)
    static let plainText = 1, multiLevelUndo = 8
    static let allText = 4
    static let notifyChange = 0x1, notifySelection = 0x80000
    static let selectionChanged = UINT(0x0702)
    static let findDown = 1
}
