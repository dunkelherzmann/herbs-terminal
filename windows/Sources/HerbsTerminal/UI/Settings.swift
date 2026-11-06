import Foundation
import WinSDK

/// Settings: the default profile's text, colors and shell, plus the app-wide window preferences. Every change
/// applies at once to open terminals and is saved, as on the Mac and Linux.
@MainActor
final class SettingsWindow: WindowObject {
    static let className = "HerbsTerminalSettings"
    private static var current: SettingsWindow?

    private(set) var hwnd: HWND?
    private var font: HFONT?
    private var controls: [Control: HWND] = [:]
    private var loading = false

    private enum Control: Int32, CaseIterable {
        case font = 100, size, cursor, blink, theme, importTheme, appearance, shell, scrollback, columns, rows, askBeforeClosing,
             restore, close
    }

    /// Opens Settings, or brings the open one to the front.
    static func show(owner: HWND?) {
        if let window = current?.hwnd {
            ShowWindow(window, SW_RESTORE)
            SetForegroundWindow(window)
            return
        }
        current = SettingsWindow(owner: owner)
    }

    static var openWindow: HWND? { current?.hwnd }

    /// Lets Tab and the arrow keys move between controls, as in a dialog.
    static func dialogMessage(_ message: inout MSG) -> Bool {
        guard let hwnd = current?.hwnd else { return false }
        return IsDialogMessageW(hwnd, &message)
    }

    private init(owner: HWND?) {
        let dpi = owner.map { GetDpiForWindow($0) } ?? 96
        var rect = RECT(left: 0, top: 0, right: scaled(460, dpi: dpi), bottom: scaled(468, dpi: dpi))
        let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_MINIMIZEBOX)
        AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (rect.right - rect.left)) / 2
            y = ownerRect.top + scaled(60, dpi: dpi)
        }
        hwnd = createWindow(self, className: Self.className, title: "Settings", style: style, exStyle: DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: owner)
        guard let hwnd else { return }
        // The form uses the standard light controls, so its frame stays light too.
        setDarkTitleBar(hwnd, false)
        build(hwnd, dpi: dpi)
        load()
        ShowWindow(hwnd, TestScript.active ? SW_SHOWNOACTIVATE : SW_SHOW)
    }

    // MARK: Layout

    private func build(_ hwnd: HWND, dpi: UINT) {
        func s(_ value: Double) -> Int32 { scaled(value, dpi: dpi) }
        font = withWide("Segoe UI") {
            CreateFontW(-s(12), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0)
        }
        let labelX = s(16), fieldX = s(160), fieldWidth = s(284), rowHeight = s(30)
        var y = s(14)

        func heading(_ text: String) {
            add("STATIC", text, style: DWORD(SS_LEFT), x: labelX, y: y, width: s(420), height: s(20), bold: true)
            y += s(24)
        }
        func label(_ text: String) {
            add("STATIC", text, style: DWORD(SS_LEFT), x: labelX + s(8), y: y + s(4), width: fieldX - labelX - s(8), height: s(20))
        }
        func combo(_ id: Control, editable: Bool = false, width: Int32? = nil) {
            label(Self.labels[id] ?? "")
            let style = DWORD(editable ? CBS_DROPDOWN | CBS_AUTOHSCROLL : CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL) | DWORD(WS_TABSTOP)
            controls[id] = add("COMBOBOX", "", style: style, x: fieldX, y: y, width: width ?? fieldWidth, height: s(300), id: id)
            y += rowHeight
        }
        func check(_ id: Control) {
            controls[id] = add("BUTTON", Self.labels[id] ?? "", style: DWORD(BS_AUTOCHECKBOX) | DWORD(WS_TABSTOP),
                               x: fieldX, y: y, width: fieldWidth, height: s(22), id: id)
            y += rowHeight
        }
        func number(_ id: Control, x: Int32, width: Int32) {
            controls[id] = add("EDIT", "", style: DWORD(ES_NUMBER) | DWORD(ES_AUTOHSCROLL) | DWORD(WS_TABSTOP) | DWORD(WS_BORDER),
                               x: x, y: y, width: width, height: s(23), id: id)
        }

        heading("Text")
        combo(.font)
        combo(.size, editable: true, width: s(90))
        combo(.cursor, width: s(140))
        check(.blink)

        heading("Colors")
        label("Theme")
        controls[.theme] = add("COMBOBOX", "", style: DWORD(CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL) | DWORD(WS_TABSTOP),
                               x: fieldX, y: y, width: fieldWidth - s(92), height: s(300), id: .theme)
        controls[.importTheme] = add("BUTTON", "Import…", style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP),
                                     x: fieldX + fieldWidth - s(84), y: y - s(1), width: s(84), height: s(26), id: .importTheme)
        y += rowHeight
        combo(.appearance, width: s(140))

        heading("Shell")
        combo(.shell, editable: true)
        label("Scrollback lines")
        number(.scrollback, x: fieldX, width: s(90))
        y += rowHeight

        heading("Window")
        label("New window size")
        number(.columns, x: fieldX, width: s(60))
        add("STATIC", "columns  ×", style: DWORD(SS_LEFT), x: fieldX + s(66), y: y + s(4), width: s(76), height: s(20))
        number(.rows, x: fieldX + s(144), width: s(60))
        add("STATIC", "rows", style: DWORD(SS_LEFT), x: fieldX + s(210), y: y + s(4), width: s(60), height: s(20))
        y += rowHeight
        check(.askBeforeClosing)

        y += s(6)
        controls[.restore] = add("BUTTON", "Restore Defaults", style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP),
                                 x: labelX, y: y, width: s(130), height: s(28), id: .restore)
        controls[.close] = add("BUTTON", "Close", style: DWORD(BS_DEFPUSHBUTTON) | DWORD(WS_TABSTOP),
                               x: s(460) - s(16) - s(90), y: y, width: s(90), height: s(28), id: .close)
    }

    private static let labels: [Control: String] = [
        .font: "Font", .size: "Size", .cursor: "Cursor", .blink: "Blinking cursor", .appearance: "Appearance",
        .shell: "Shell", .askBeforeClosing: "Ask before closing a running shell",
    ]

    @discardableResult
    private func add(_ className: String, _ text: String, style: DWORD, x: Int32, y: Int32, width: Int32, height: Int32,
                     id: Control? = nil, bold: Bool = false) -> HWND? {
        let control = withWide(className) { cls in
            withWide(text) { title in
                CreateWindowExW(0, cls, title, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style, x, y, width, height, hwnd,
                                HMENU(bitPattern: Int(id?.rawValue ?? 0)), GetModuleHandleW(nil), nil)
            }
        }
        var controlFont = font
        if bold, let hwnd {
            controlFont = withWide("Segoe UI Semibold") {
                CreateFontW(-scaled(12, dpi: GetDpiForWindow(hwnd)), 0, 0, 0, Int32(FW_SEMIBOLD), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0,
                            DWORD(CLEARTYPE_QUALITY), 0, $0)
            }
            boldFonts.append(controlFont)
        }
        SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(controlFont)))), 1)
        return control
    }

    private var boldFonts: [HFONT?] = []

    // MARK: Values

    private static let cursorShapes: [CursorShape] = [.block, .underline, .bar]
    private static let appearances = ["System", "Light", "Dark"]
    private static let basicTheme = "Basic (follows Appearance)"

    private func load() {
        loading = true
        defer { loading = false }
        let profile = TerminalProfile.shared
        let settings = profile.settings(for: nil)

        let families = FontSet.installedMonospacedFamilies()
        let family = settings.fontFamily.isEmpty ? FontSet.stockFamily : settings.fontFamily
        fillCombo(.font, families.contains(family) ? families : (families + [family]).sorted(), selected: family)
        fillCombo(.size, ["8", "9", "10", "11", "12", "13", "14", "16", "18", "20", "24", "28", "36"],
                  selected: settings.fontSize.formatted(), editable: true)
        fillCombo(.cursor, Self.cursorShapes.map(\.title), selected: settings.cursor.title)
        setCheck(.blink, settings.cursorBlinks)

        let themes = [Self.basicTheme] + ThemeLibrary.shared.allNames
        fillCombo(.theme, themes, selected: settings.theme.isEmpty ? Self.basicTheme : settings.theme)
        fillCombo(.appearance, Self.appearances, selected: profile.appearance)

        let choices = ShellChoice.available
        let current = ShellChoice.current
        fillCombo(.shell, choices.map(\.title), selected: choices.first { $0.commandLine == current }?.title ?? current, editable: true)
        setText(.scrollback, String(settings.scrollbackLines))
        setText(.columns, String(profile.windowColumns))
        setText(.rows, String(profile.windowRows))
        setCheck(.askBeforeClosing, profile.askBeforeClosing)
    }

    private func fillCombo(_ id: Control, _ items: [String], selected: String, editable: Bool = false) {
        guard let combo = controls[id] else { return }
        SendMessageW(combo, UINT(CB_RESETCONTENT), 0, 0)
        for item in items {
            withWide(item) { _ = SendMessageW(combo, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) }
        }
        if let index = items.firstIndex(of: selected) {
            SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(index), 0)
        } else if editable {
            withWide(selected) { _ = SetWindowTextW(combo, $0) }
        }
    }

    private func text(_ id: Control) -> String {
        guard let control = controls[id] else { return "" }
        let length = GetWindowTextLengthW(control)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(control, &buffer, length + 1)
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self).trimmingCharacters(in: .whitespaces)
    }

    /// A drop-down's selected item (an editable one's text is read with `text`).
    private func selection(_ id: Control) -> String {
        guard let combo = controls[id] else { return "" }
        let index = SendMessageW(combo, UINT(CB_GETCURSEL), 0, 0)
        guard index >= 0 else { return text(id) }
        let length = SendMessageW(combo, UINT(CB_GETLBTEXTLEN), WPARAM(index), 0)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        SendMessageW(combo, UINT(CB_GETLBTEXT), WPARAM(index), LPARAM(Int(bitPattern: buffer.withUnsafeMutableBufferPointer { $0.baseAddress! })))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private func setText(_ id: Control, _ value: String) {
        guard let control = controls[id] else { return }
        withWide(value) { _ = SetWindowTextW(control, $0) }
    }

    private func setCheck(_ id: Control, _ on: Bool) {
        SendMessageW(controls[id], UINT(BM_SETCHECK), WPARAM(on ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    private func isChecked(_ id: Control) -> Bool {
        SendMessageW(controls[id], UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
    }

    /// Saves one control's value. Open terminals pick the change up through the profile's change notification.
    private func commit(_ id: Control, fromList: Bool = false) {
        guard !loading else { return }
        let profile = TerminalProfile.shared
        switch id {
        case .font:
            let family = selection(.font)
            profile.update(nil) { $0.fontFamily = family == FontSet.stockFamily ? "" : family }
        case .size:
            let value = fromList ? selection(.size) : text(.size)
            if let size = Double(value.replacingOccurrences(of: ",", with: ".")) {
                profile.update(nil) { $0.fontSize = size; $0.zoom = 0 }
            }
        case .cursor:
            let title = selection(.cursor)
            if let shape = Self.cursorShapes.first(where: { $0.title == title }) { profile.update(nil) { $0.cursor = shape } }
        case .blink:
            let on = isChecked(.blink)
            profile.update(nil) { $0.cursorBlinks = on }
        case .theme:
            let name = selection(.theme)
            profile.update(nil) { $0.theme = name == Self.basicTheme ? "" : name }
        case .appearance:
            profile.appearance = selection(.appearance)
        case .shell:
            let value = fromList ? selection(.shell) : text(.shell)
            ShellChoice.current = ShellChoice.available.first { $0.title == value }?.commandLine ?? value
        case .scrollback:
            if let lines = Int(text(.scrollback)) { profile.update(nil) { $0.scrollbackLines = lines } }
            setText(.scrollback, String(profile.settings(for: nil).scrollbackLines))
        case .columns, .rows:
            let range = id == .columns ? TerminalProfile.gridRange.columns : TerminalProfile.gridRange.rows
            guard let value = Int(text(id)) else { return }
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            if id == .columns { profile.windowColumns = clamped } else { profile.windowRows = clamped }
            setText(id, String(clamped))
        case .askBeforeClosing:
            profile.askBeforeClosing = isChecked(.askBeforeClosing)
        case .importTheme:
            importTheme()
        case .restore:
            profile.update(nil) { $0.restoreTheming() }
            profile.appearance = "System"
            load()
        case .close:
            if let hwnd { DestroyWindow(hwnd) }
        }
    }

    private func importTheme() {
        guard let path = openFile(owner: hwnd, title: "Import a Color Preset",
                                  filter: [("iTerm2 color presets (*.itermcolors)", "*.itermcolors")]) else { return }
        do {
            let name = try ThemeLibrary.shared.importFile(URL(fileURLWithPath: path))
            TerminalProfile.shared.update(nil) { $0.theme = name }
            load()
        } catch {
            messageBox(hwnd, "Couldn't import that preset: \(error.localizedDescription)", flags: UINT(MB_OK | MB_ICONWARNING))
        }
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_COMMAND:
            let code = Int32(hiWord(wParam)), rawID = Int32(wParam & 0xFFFF)
            if rawID == IDCANCEL || rawID == IDOK { DestroyWindow(hwnd); return 0 }
            guard let id = Control(rawValue: rawID) else { return nil }
            switch code {
            case CBN_SELCHANGE: commit(id, fromList: true)
            case BN_CLICKED where [.blink, .askBeforeClosing, .importTheme, .restore, .close].contains(id): commit(id)
            case CBN_KILLFOCUS where id == .size || id == .shell: commit(id)
            case EN_KILLFOCUS: commit(id)
            default: break
            }
            return 0
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN:
            SetBkMode(HDC(bitPattern: UInt(wParam)), TRANSPARENT)
            return LRESULT(Int(bitPattern: UnsafeRawPointer(GetSysColorBrush(COLOR_WINDOW))))
        case WM_CLOSE:
            DestroyWindow(hwnd)
            return 0
        case WM_DESTROY:
            if let font { DeleteObject(font) }
            for bold in boldFonts { DeleteObject(bold) }
            self.hwnd = nil
            Self.current = nil
            return 0
        default:
            return nil
        }
    }
}

/// The shells new tabs can start. The choice is a Windows-only preference, so it lives beside the shared profile.
struct ShellChoice {
    let title: String
    let commandLine: String

    static let automatic = ShellChoice(title: "Automatic", commandLine: "")

    static var available: [ShellChoice] {
        var choices = [automatic]
        if let pwsh = DefaultShell.find("pwsh.exe") { choices.append(ShellChoice(title: "PowerShell 7", commandLine: "\"\(pwsh)\" -NoLogo")) }
        if let powershell = DefaultShell.find("powershell.exe") {
            choices.append(ShellChoice(title: "Windows PowerShell", commandLine: "\"\(powershell)\" -NoLogo"))
        }
        if let cmd = DefaultShell.find("cmd.exe") { choices.append(ShellChoice(title: "Command Prompt", commandLine: "\"\(cmd)\"")) }
        if let wsl = DefaultShell.find("wsl.exe") { choices.append(ShellChoice(title: "WSL (default distribution)", commandLine: "\"\(wsl)\"")) }
        let gitBash = (ProcessInfo.processInfo.environment["ProgramFiles"] ?? "C:\\Program Files") + "\\Git\\bin\\bash.exe"
        if FileManager.default.fileExists(atPath: gitBash) {
            choices.append(ShellChoice(title: "Git Bash", commandLine: "\"\(gitBash)\" --login -i"))
        }
        return choices
    }

    /// The command line new tabs start; empty means automatic.
    static var current: String {
        get { Preferences.shared.string("windowsShell") ?? "" }
        set { Preferences.shared.set(newValue.trimmingCharacters(in: .whitespaces), "windowsShell") }
    }

    static var commandLine: String {
        let chosen = current
        return chosen.isEmpty ? DefaultShell.commandLine : chosen
    }
}

/// Light or dark, from Settings ▸ Appearance (System follows Windows).
@MainActor
var appIsDark: Bool {
    switch TerminalProfile.shared.appearance {
    case "Light": false
    case "Dark": true
    default: systemPrefersDark
    }
}

/// The Open dialog; returns the chosen file's path.
func openFile(owner: HWND?, title: String, filter: [(String, String)]) -> String? {
    var buffer = [WCHAR](repeating: 0, count: 4096)
    // Filter pairs separated by NULs, ending with two.
    var filterUnits: [WCHAR] = []
    for (name, pattern) in filter { filterUnits += Array(name.utf16) + [0] + Array(pattern.utf16) + [0] }
    filterUnits.append(0)
    return filterUnits.withUnsafeBufferPointer { (filterPointer: UnsafeBufferPointer<WCHAR>) -> String? in
        withWide(title) { titlePointer in
            buffer.withUnsafeMutableBufferPointer { file in
                var dialog = OPENFILENAMEW()
                dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                dialog.hwndOwner = owner
                dialog.lpstrFilter = filterPointer.baseAddress
                dialog.lpstrFile = file.baseAddress
                dialog.nMaxFile = DWORD(file.count)
                dialog.lpstrTitle = titlePointer
                dialog.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER)
                guard GetOpenFileNameW(&dialog) else { return nil }
                return String(decoding: file.prefix { $0 != 0 }, as: UTF16.self)
            }
        }
    }
}
