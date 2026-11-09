import Foundation
import WinSDK

/// Settings: the named profiles (add, duplicate, rename, delete, the default, each one's startup command and start
/// folder), the chosen profile's text, colors and scrollback, and the app-wide shell and window preferences. Every
/// change applies at once to open terminals and is saved, as on the Mac and Linux.
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
             restore, close, newTabs, profile, newProfile, duplicateProfile, renameProfile, deleteProfile, defaultProfile,
             startupCommand, startDirectory, restoreSession, sizeBadge
    }

    /// The profile this page edits (Settings ▸ Profiles on the Mac).
    private var editing: Foundation.UUID { TerminalProfile.shared.editingID }

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
        var rect = RECT(left: 0, top: 0, right: scaled(460, dpi: dpi), bottom: scaled(720, dpi: dpi))
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
        build(hwnd, dpi: dpi)
        load()
        DialogTheme.apply(to: hwnd)
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

        heading("Profile")
        combo(.profile)
        let buttons: [(Control, String, Double)] = [(.newProfile, "New", 56), (.duplicateProfile, "Duplicate", 76),
                                                    (.renameProfile, "Rename…", 70), (.deleteProfile, "Delete…", 64)]
        var x = fieldX
        for (id, title, width) in buttons {
            controls[id] = add("BUTTON", title, style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), x: x, y: y - s(2), width: s(width), height: s(26), id: id)
            x += s(width) + s(4)
        }
        y += rowHeight
        controls[.defaultProfile] = add("BUTTON", "Use as Default", style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP),
                                        x: fieldX, y: y - s(2), width: s(120), height: s(26), id: .defaultProfile)
        y += rowHeight
        label("Run command")
        controls[.startupCommand] = add("EDIT", "", style: DWORD(ES_AUTOHSCROLL) | DWORD(WS_TABSTOP) | DWORD(WS_BORDER),
                                        x: fieldX, y: y, width: fieldWidth, height: s(23), id: .startupCommand)
        y += rowHeight
        label("Start in")
        controls[.startDirectory] = add("EDIT", "", style: DWORD(ES_AUTOHSCROLL) | DWORD(WS_TABSTOP) | DWORD(WS_BORDER),
                                        x: fieldX, y: y, width: fieldWidth, height: s(23), id: .startDirectory)
        y += rowHeight

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
        combo(.newTabs, width: s(240))
        label("Scrollback lines")
        number(.scrollback, x: fieldX, width: s(90))
        y += rowHeight
        check(.restoreSession)

        heading("Window")
        label("New window size")
        number(.columns, x: fieldX, width: s(60))
        add("STATIC", "columns  ×", style: DWORD(SS_LEFT), x: fieldX + s(66), y: y + s(4), width: s(76), height: s(20))
        number(.rows, x: fieldX + s(144), width: s(60))
        add("STATIC", "rows", style: DWORD(SS_LEFT), x: fieldX + s(210), y: y + s(4), width: s(60), height: s(20))
        y += rowHeight
        check(.sizeBadge)
        check(.askBeforeClosing)

        y += s(6)
        controls[.restore] = add("BUTTON", "Restore Defaults", style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP),
                                 x: labelX, y: y, width: s(130), height: s(28), id: .restore)
        controls[.close] = add("BUTTON", "Close", style: DWORD(BS_DEFPUSHBUTTON) | DWORD(WS_TABSTOP),
                               x: s(460) - s(16) - s(90), y: y, width: s(90), height: s(28), id: .close)
    }

    /// Where a new local tab's shell starts, as on the Mac.
    private static let newTabPlaces = ["Same folder as the current tab", "Home folder"]

    private static let labels: [Control: String] = [
        .font: "Font", .size: "Size", .cursor: "Cursor", .blink: "Blinking cursor", .appearance: "Appearance",
        .shell: "Shell", .newTabs: "New tabs open in", .askBeforeClosing: "Ask before closing a tab with running processes",
        .profile: "Edit profile", .restoreSession: "Restore windows and tabs when Herb's Terminal opens",
        .sizeBadge: "Show columns × rows while resizing",
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
        let settings = profile.settings(for: editing)

        // "(default)" marks the profile new windows use.
        let names = profile.profiles.map { $0.name + ($0.id == profile.defaultProfileID ? " (default)" : "") }
        let editingIndex = profile.profiles.firstIndex { $0.id == editing } ?? 0
        fillCombo(.profile, names, selected: names[editingIndex])
        EnableWindow(controls[.deleteProfile], profile.profiles.count > 1)
        EnableWindow(controls[.defaultProfile], editing != profile.defaultProfileID)
        setText(.startupCommand, settings.startupCommand)
        setText(.startDirectory, settings.startDirectory)
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
        fillCombo(.newTabs, Self.newTabPlaces, selected: Self.newTabPlaces[profile.newTabsInSameFolder ? 0 : 1])
        setText(.scrollback, String(settings.scrollbackLines))
        setText(.columns, String(profile.windowColumns))
        setText(.rows, String(profile.windowRows))
        setCheck(.askBeforeClosing, profile.askBeforeClosing)
        setCheck(.restoreSession, profile.restoreSession)
        setCheck(.sizeBadge, profile.showSizeWhileResizing)
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
            profile.update(editing) { $0.fontFamily = family == FontSet.stockFamily ? "" : family }
        case .size:
            let value = fromList ? selection(.size) : text(.size)
            if let size = Double(value.replacingOccurrences(of: ",", with: ".")) {
                profile.update(editing) { $0.fontSize = size; $0.zoom = 0 }
            }
        case .cursor:
            let title = selection(.cursor)
            if let shape = Self.cursorShapes.first(where: { $0.title == title }) { profile.update(editing) { $0.cursor = shape } }
        case .blink:
            let on = isChecked(.blink)
            profile.update(editing) { $0.cursorBlinks = on }
        case .theme:
            let name = selection(.theme)
            profile.update(editing) { $0.theme = name == Self.basicTheme ? "" : name }
        case .appearance:
            profile.appearance = selection(.appearance)
            if let hwnd { DialogTheme.apply(to: hwnd) }
        case .newTabs:
            profile.newTabsInSameFolder = selection(.newTabs) == Self.newTabPlaces[0]
        case .shell:
            let value = fromList ? selection(.shell) : text(.shell)
            ShellChoice.current = ShellChoice.available.first { $0.title == value }?.commandLine ?? value
        case .scrollback:
            if let lines = Int(text(.scrollback)) { profile.update(editing) { $0.scrollbackLines = lines } }
            setText(.scrollback, String(profile.settings(for: editing).scrollbackLines))
        case .columns, .rows:
            let range = id == .columns ? TerminalProfile.gridRange.columns : TerminalProfile.gridRange.rows
            guard let value = Int(text(id)) else { return }
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            if id == .columns { profile.windowColumns = clamped } else { profile.windowRows = clamped }
            setText(id, String(clamped))
        case .askBeforeClosing:
            profile.askBeforeClosing = isChecked(.askBeforeClosing)
        case .restoreSession:
            profile.restoreSession = isChecked(.restoreSession)
            // Off forgets the saved session at once.
            if !profile.restoreSession { SavedSession.clear() }
        case .sizeBadge:
            profile.showSizeWhileResizing = isChecked(.sizeBadge)
        case .importTheme:
            importTheme()
        case .restore:
            profile.update(editing) { $0.restoreTheming() }
            profile.appearance = "System"
            load()
        case .close:
            if let hwnd { DestroyWindow(hwnd) }
        case .profile:
            let index = Int(SendMessageW(controls[.profile], UINT(CB_GETCURSEL), 0, 0))
            if profile.profiles.indices.contains(index) { profile.editingID = profile.profiles[index].id }
            load()
        case .startupCommand:
            let value = text(.startupCommand)
            profile.update(editing) { $0.startupCommand = value }
        case .startDirectory:
            let value = text(.startDirectory)
            profile.update(editing) { $0.startDirectory = value }
        case .newProfile, .duplicateProfile:
            let id = profile.addProfile(named: id == .newProfile ? "New Profile" : profile.name(of: editing),
                                        copying: id == .duplicateProfile ? editing : nil)
            profile.editingID = id
            load()
        case .renameProfile:
            guard let answer = FormDialog.run(owner: hwnd, title: "Rename Profile", message: "A name for the profile “\(profile.name(of: editing))”.",
                                              fields: [.init(label: "Name", text: profile.name(of: editing))],
                                              buttons: [.init(title: "Cancel"), .init(title: "Rename", isDefault: true)]),
                  answer.button == 1 else { return }
            let name = answer.values[0].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { profile.rename(editing, to: name) }
            load()
        case .deleteProfile:
            guard profile.profiles.count > 1,
                  FormDialog.ask(owner: hwnd, title: "Delete the profile “\(profile.name(of: editing))”?",
                                 message: "Tabs using it switch to the default profile. This can't be undone.",
                                 buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Delete")]) == 1 else { return }
            profile.removeProfile(editing)
            load()
        case .defaultProfile:
            profile.defaultProfileID = editing
            load()
        }
    }

    private func importTheme() {
        guard let path = openFile(owner: hwnd, title: "Import a Color Preset",
                                  filter: [("iTerm2 color presets (*.itermcolors)", "*.itermcolors")]) else { return }
        do {
            let name = try ThemeLibrary.shared.importFile(URL(fileURLWithPath: path))
            TerminalProfile.shared.update(editing) { $0.theme = name }
            load()
        } catch {
            FormDialog.tell(owner: hwnd, title: "Couldn't import that preset", message: error.localizedDescription)
        }
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if let themed = DialogTheme.handle(hwnd, message, wParam) { return themed }
        switch Int32(message) {
        case WM_COMMAND:
            let code = Int32(hiWord(wParam)), rawID = Int32(wParam & 0xFFFF)
            if rawID == IDCANCEL || rawID == IDOK { DestroyWindow(hwnd); return 0 }
            guard let id = Control(rawValue: rawID) else { return nil }
            switch code {
            case CBN_SELCHANGE: commit(id, fromList: true)
            case BN_CLICKED where [.blink, .askBeforeClosing, .restoreSession, .sizeBadge, .importTheme, .restore, .close, .newProfile, .duplicateProfile,
                                   .renameProfile, .deleteProfile, .defaultProfile].contains(id): commit(id)
            case CBN_KILLFOCUS where id == .size || id == .shell: commit(id)
            case EN_KILLFOCUS: commit(id)
            default: break
            }
            return 0
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
