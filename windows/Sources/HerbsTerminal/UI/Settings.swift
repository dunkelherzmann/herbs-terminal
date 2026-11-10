import Foundation
import WinSDK

/// Settings (Ctrl+,): the profiles every terminal tab follows, on the Mac's five pages: Profiles, Text, Terminal,
/// Window and Colors, picked with the buttons along the top. Every change applies at once to open terminals and is
/// saved, as on the Mac and Linux.
@MainActor
final class SettingsWindow: WindowObject {
    static let className = "HerbsTerminalSettings"
    private static var current: SettingsWindow?

    private(set) var hwnd: HWND?
    private var controls: [Control: HWND] = [:]
    private var pageControls: [Page: [HWND]] = [:]
    private var captions: [HWND] = []
    private var building: Page = .profiles
    private(set) var page: Page = .profiles
    private var loading = false
    private let hints = HoverHints()
    private var fonts: (text: HFONT?, glyph: HFONT?, pageGlyph: HFONT?) = (nil, nil, nil)
    private var tokens: [ObservationToken] = []
    private var dpi: UINT = 96

    enum Page: Int, CaseIterable {
        case profiles, text, terminal, window, colors
        var title: String { ["Profiles", "Text", "Terminal", "Window", "Colors"][rawValue] }
        /// Segoe Fluent Icons / MDL2 glyphs: People, Font, CommandPrompt, OpenInNewWindow, Color.
        var glyph: String { ["\u{E716}", "\u{E8D2}", "\u{E756}", "\u{E8A7}", "\u{E790}"][rawValue] }
        var hint: String {
            ["Profiles\nNamed profiles: pick one to edit it on the other pages.", "Text\nFont, size, cursor and the preview.",
             "Terminal\nScrollback, the bell, where new tabs open and the shell.", "Window\nThe size of new windows.",
             "Colors\nLight or dark, and the color theme."][rawValue]
        }
        var id: Int32 { 900 + Int32(rawValue) }
    }

    private enum Control: Int32 {
        case profileList = 100, newProfile, duplicateProfile, deleteProfile, name, startupCommand, startDirectory, defaultProfile,
             font, size, sizeSpin, zoom, zoomReset, cursorBlock, cursorUnderline, cursorBar, blink, preview, restoreText,
             scrollback, scrollbackSpin, bell, newTabs, shell, restoreSession, askBeforeClosing,
             sizeBadge, columns, columnsSpin, rows, rowsSpin, apply, useFront, resetSize,
             appearanceSystem, appearanceLight, appearanceDark, themeList, importTheme, removeTheme
    }

    /// The profile the Text, Terminal and Colors pages edit, chosen on the Profiles page.
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

    /// For the feature tests' bridge: the pages' titles, and showing one by its title.
    static var pageTitles: [String] { Page.allCases.map(\.title) }
    static func showPage(_ title: String) -> Bool {
        guard let window = current, let page = Page.allCases.first(where: { $0.title == title }) else { return false }
        window.select(page)
        return true
    }
    static func isPageButton(_ hwnd: HWND) -> Bool { (900..<905).contains(GetDlgCtrlID(hwnd)) }

    /// Lets Tab and the arrow keys move between controls, as in a dialog.
    static func dialogMessage(_ message: inout MSG) -> Bool {
        guard let hwnd = current?.hwnd else { return false }
        return IsDialogMessageW(hwnd, &message)
    }

    private init(owner: HWND?) {
        dpi = owner.map { GetDpiForWindow($0) } ?? 96
        var rect = RECT(left: 0, top: 0, right: s(560), bottom: s(470))
        let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_MINIMIZEBOX)
        AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (rect.right - rect.left)) / 2
            y = ownerRect.top + s(60)
        }
        hwnd = createWindow(self, className: Self.className, title: "Settings", style: style, exStyle: DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: owner)
        guard let hwnd else { return }
        makeFonts()
        build(hwnd)
        load()
        select(.profiles)
        DialogTheme.apply(to: hwnd)
        tokens = [TerminalProfile.shared.objectWillChange.observe { [weak self] in self?.load() },
                  ThemeLibrary.shared.objectWillChange.observe { [weak self] in self?.load() }]
        ShowWindow(hwnd, TestScript.active ? SW_SHOWNOACTIVATE : SW_SHOW)
    }

    private func s(_ value: Double) -> Int32 { scaled(value, dpi: dpi) }

    private func makeFonts() {
        func font(_ face: String, _ pixels: Double, _ weight: Int32 = Int32(FW_NORMAL)) -> HFONT? {
            withWide(face) { CreateFontW(-s(pixels), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0) }
        }
        let icons = FontSet.isInstalledAny("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
        fonts = (font("Segoe UI", 12), font(icons, 14), font(icons, 20))
    }

    // MARK: Layout

    private func build(_ hwnd: HWND) {
        // The page buttons, centered along the top like the Mac's Settings toolbar.
        let buttonWidth = s(80), gap = s(4)
        var x = (s(560) - (buttonWidth * 5 + gap * 4)) / 2
        for page in Page.allCases {
            let button = add("BUTTON", page.title, style: DWORD(BS_OWNERDRAW) | DWORD(WS_TABSTOP), x: x, y: s(8), width: buttonWidth,
                             height: s(56), rawID: page.id, onPage: false)
            hints.set(button, page.hint, owner: hwnd)
            x += buttonWidth + gap
        }
        building = .profiles; buildProfiles()
        building = .text; buildText()
        building = .terminal; buildTerminal()
        building = .window; buildWindow()
        building = .colors; buildColors()
    }

    private let labelX: Double = 20, labelWidth: Double = 130, fieldX: Double = 160

    /// A label right-aligned before its field, as in the Mac's forms.
    private func label(_ text: String, y: Double, x: Double? = nil, width: Double? = nil) {
        add("STATIC", text, style: DWORD(SS_RIGHT), x: s(x ?? labelX), y: s(y + 4), width: s(width ?? labelWidth), height: s(20))
    }

    private func editingCaption(y: Double) {
        if let caption = add("STATIC", "", style: DWORD(SS_LEFT) | DWORD(SS_NOTIFY), x: s(labelX), y: s(y), width: s(520), height: s(18)) {
            captions.append(caption)
            hints.set(caption, "Editing profile\nChoose another profile on the Profiles page.", owner: hwnd!)
        }
    }

    private func edit(_ id: Control, x: Double, y: Double, width: Double, cue: String = "", hint: String) {
        let edit = add("EDIT", "", style: DWORD(ES_AUTOHSCROLL) | DWORD(WS_TABSTOP) | DWORD(WS_BORDER), x: s(x), y: s(y), width: s(width), height: s(24), id: id)
        if !cue.isEmpty { withWide(cue) { _ = SendMessageW(edit, UINT(EM_SETCUEBANNER), 1, LPARAM(Int(bitPattern: $0))) } }
        hints.set(edit, hint, owner: hwnd!)
    }

    /// A number field with up and down arrows, kept within `range`.
    private func number(_ id: Control, spin: Control, x: Double, y: Double, width: Double, range: ClosedRange<Int>, hint: String) {
        edit(id, x: x, y: y, width: width, hint: hint)
        let arrows = add("msctls_updown32", "", style: DWORD(UDS_SETBUDDYINT) | DWORD(UDS_ALIGNRIGHT) | DWORD(UDS_ARROWKEYS) | DWORD(UDS_NOTHOUSANDS),
                         x: 0, y: 0, width: 0, height: 0, id: spin)
        SendMessageW(arrows, UINT(UDM_SETBUDDY), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(controls[id])))), 0)
        SendMessageW(arrows, UINT(UDM_SETRANGE32), WPARAM(UInt(bitPattern: range.lowerBound)), LPARAM(range.upperBound))
        hints.set(arrows, hint, owner: hwnd!)
    }

    private func combo(_ id: Control, x: Double, y: Double, width: Double, editable: Bool = false, hint: String) {
        let style = DWORD(editable ? CBS_DROPDOWN | CBS_AUTOHSCROLL : CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL) | DWORD(WS_TABSTOP)
        let combo = add("COMBOBOX", "", style: style, x: s(x), y: s(y), width: s(width), height: s(300), id: id)
        hints.set(combo, hint, owner: hwnd!)
    }

    private func check(_ id: Control, _ title: String, x: Double, y: Double, width: Double = 380, hint: String) {
        let box = add("BUTTON", title, style: DWORD(BS_AUTOCHECKBOX) | DWORD(WS_TABSTOP), x: s(x), y: s(y), width: s(width), height: s(22), id: id)
        hints.set(box, hint, owner: hwnd!)
    }

    private func push(_ id: Control, _ title: String, x: Double, y: Double, width: Double, hint: String) {
        let button = add("BUTTON", title, style: DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), x: s(x), y: s(y), width: s(width), height: s(28), id: id)
        hints.set(button, hint, owner: hwnd!)
    }

    /// Linked buttons with one pressed, like the Mac's segmented controls.
    private func segments(_ ids: [Control], _ titles: [String], x: Double, y: Double, width: Double = 80, hint: String) {
        for (index, id) in ids.enumerated() {
            let style = DWORD(BS_AUTORADIOBUTTON) | DWORD(BS_PUSHLIKE) | (index == 0 ? DWORD(WS_GROUP) | DWORD(WS_TABSTOP) : 0)
            let button = add("BUTTON", titles[index], style: style, x: s(x + Double(index) * width), y: s(y), width: s(width), height: s(26), id: id)
            hints.set(button, hint, owner: hwnd!)
        }
    }

    private func list(_ id: Control, title: String, x: Double, y: Double, width: Double, height: Double, itemHeight: Double, hint: String) {
        let style = DWORD(LBS_OWNERDRAWFIXED) | DWORD(LBS_HASSTRINGS) | DWORD(LBS_NOTIFY) | DWORD(LBS_NOINTEGRALHEIGHT) | DWORD(WS_VSCROLL)
            | DWORD(WS_BORDER) | DWORD(WS_TABSTOP)
        let list = add("LISTBOX", title, style: style, x: s(x), y: s(y), width: s(width), height: s(height), id: id)
        SendMessageW(list, UINT(LB_SETITEMHEIGHT), 0, LPARAM(s(itemHeight)))
        hints.set(list, hint, owner: hwnd!)
    }

    private func buildProfiles() {
        list(.profileList, title: "Profiles", x: 20, y: 80, width: 190, height: 236, itemHeight: 26,
             hint: "Profiles\nSelect a profile to edit it here and on the Text, Terminal and Colors pages.")
        let small: [(Control, String, String)] = [
            (.newProfile, "New Profile", "New Profile\nAdd a profile with the stock Basic settings."),
            (.duplicateProfile, "Duplicate", "Duplicate\nCopy the selected profile."),
            (.deleteProfile, "Delete Profile", "Delete Profile\nRemove the selected profile; tabs using it switch to the default."),
        ]
        for (index, (id, title, hint)) in small.enumerated() {
            let button = add("BUTTON", title, style: DWORD(BS_OWNERDRAW) | DWORD(WS_TABSTOP), x: s(20 + Double(index) * 34), y: s(322),
                             width: s(30), height: s(26), id: id)
            hints.set(button, hint, owner: hwnd!)
        }
        let formLabel = 226.0, formField = 324.0
        label("Name:", y: 80, x: formLabel, width: 90)
        edit(.name, x: formField, y: 80, width: 216, hint: "Name\nHow this profile appears in Main Menu ▸ Shell ▸ New Tab with Profile.")
        label("Run command:", y: 114, x: formLabel, width: 90)
        edit(.startupCommand, x: formField, y: 114, width: 216, cue: "none",
             hint: "Startup command\nTyped into the shell when a tab with this profile opens, e.g. `ssh build-box` or `cd ~\\src`.")
        label("Start in:", y: 148, x: formLabel, width: 90)
        edit(.startDirectory, x: formField, y: 148, width: 216, cue: "Settings ▸ Terminal ▸ New tabs open in",
             hint: "Start folder\nWhere new tabs with this profile start, e.g. ~\\Projects. Empty uses the New tabs setting.")
        push(.defaultProfile, "Use as Default", x: formField, y: 184, width: 130,
             hint: "Use as Default\nNew windows, and new tabs from the New Tab button, start with this profile.")
    }

    private func buildText() {
        editingCaption(y: 80)
        label("Font:", y: 104)
        combo(.font, x: fieldX, y: 104, width: 300, hint: "Font\nThe monospaced typeface used by every terminal tab.")
        label("Size:", y: 138)
        number(.size, spin: .sizeSpin, x: fieldX, y: 138, width: 70, range: Int(ProfileSettings.sizeRange.lowerBound)...Int(ProfileSettings.sizeRange.upperBound),
               hint: "Font size\nPoints, \(Int(ProfileSettings.sizeRange.lowerBound))–\(Int(ProfileSettings.sizeRange.upperBound)). Ctrl+Plus / Ctrl+Minus / Ctrl+0 zoom.")
        add("STATIC", "pt", style: DWORD(SS_LEFT), x: s(236), y: s(142), width: s(20), height: s(20))
        if let zoom = add("STATIC", "", style: DWORD(SS_LEFT), x: s(262), y: s(142), width: s(130), height: s(20), id: .zoom) { captions.append(zoom) }
        push(.zoomReset, "Reset", x: 396, y: 136, width: 64,
             hint: "Reset zoom\nClear the Ctrl+Plus / Ctrl+Minus zoom kept for this profile (same as Ctrl+0).")
        label("Cursor:", y: 172)
        segments([.cursorBlock, .cursorUnderline, .cursorBar], CursorShape.allCases.map(\.title), x: fieldX, y: 172,
                 hint: "Cursor shape\nHow the text cursor is drawn in the terminal.")
        check(.blink, "Blinking cursor", x: fieldX, y: 208, hint: "Blinking cursor\nBlink the cursor while the terminal has focus.")
        let preview = add("STATIC", "Preview", style: DWORD(SS_OWNERDRAW) | DWORD(SS_NOTIFY), x: s(20), y: s(240), width: s(520), height: s(70), id: .preview)
        hints.set(preview, "Preview\nHow terminal text looks with this font and color theme.", owner: hwnd!)
        push(.restoreText, "Restore Defaults", x: 20, y: 322, width: 140, hint: "Restore Defaults\nGo back to the stock Basic font, size and cursor.")
    }

    private func buildTerminal() {
        editingCaption(y: 80)
        label("Scrollback:", y: 104)
        number(.scrollback, spin: .scrollbackSpin, x: fieldX, y: 104, width: 110, range: 100...1_000_000,
               hint: "Scrollback\nHow many lines each tab keeps above the screen (100–1,000,000).")
        add("STATIC", "lines", style: DWORD(SS_LEFT), x: s(278), y: s(108), width: s(60), height: s(20))
        label("Bell:", y: 138)
        combo(.bell, x: fieldX, y: 138, width: 220, hint: "Bell\nWhat happens when a program rings the terminal bell.")
        label("New tabs open in:", y: 172)
        combo(.newTabs, x: fieldX, y: 172, width: 260, hint: "New tabs\nWhere a new local tab's shell starts.")
        label("Shell:", y: 206)
        combo(.shell, x: fieldX, y: 206, width: 300, editable: true,
              hint: "Shell\nWhat new tabs run: PowerShell, Command Prompt, WSL, Git Bash or any command line.")
        check(.restoreSession, "Restore windows and tabs when Herb's Terminal opens", x: fieldX, y: 244,
              hint: "Restore session\nReopen your windows and tabs, with their folders, layouts and names, at launch.")
        check(.askBeforeClosing, "Ask before closing a tab with running processes", x: fieldX, y: 274,
              hint: "Ask before closing\nConfirm before ending a program or SSH session by closing its tab.")
    }

    private func buildWindow() {
        check(.sizeBadge, "Show columns × rows while resizing", x: fieldX, y: 80,
              hint: "Size while resizing\nShow the terminal's size, like 100 × 30, while you resize the window.")
        let range = TerminalProfile.gridRange
        label("Columns:", y: 112)
        number(.columns, spin: .columnsSpin, x: fieldX, y: 112, width: 80, range: range.columns,
               hint: "Columns\nCharacters per line in new windows: the first number the size badge shows.")
        label("Rows:", y: 146)
        number(.rows, spin: .rowsSpin, x: fieldX, y: 146, width: 80, range: range.rows,
               hint: "Rows\nLines of text in new windows: the second number the size badge shows.")
        push(.apply, "Apply to Open Windows", x: fieldX, y: 184, width: 160,
             hint: "Apply to Open Windows\nResize every open terminal window to this many columns and rows now.")
        push(.useFront, "Use Front Window's Size", x: fieldX + 166, y: 184, width: 160,
             hint: "Use Front Window's Size\nCopy the columns and rows of the most recently used terminal window.")
        push(.resetSize, "Reset", x: fieldX + 332, y: 184, width: 54,
             hint: "Reset\nGo back to \(TerminalProfile.defaultGrid.columns) × \(TerminalProfile.defaultGrid.rows).")
    }

    private func buildColors() {
        editingCaption(y: 80)
        label("Appearance:", y: 104)
        segments([.appearanceSystem, .appearanceLight, .appearanceDark], Self.appearances, x: fieldX, y: 104,
                 hint: "Appearance\nLight or dark windows; System follows Windows.")
        list(.themeList, title: "Color theme", x: 20, y: 140, width: 520, height: 260, itemHeight: 28,
             hint: "Color theme\nClick a theme to use it in this profile; every tab with the profile follows. Right-click an imported one to remove it.")
        push(.importTheme, "Import iTerm2 Preset…", x: 20, y: 410, width: 170, hint: "Import iTerm2 Preset\nAdd colors from an .itermcolors file.")
        push(.removeTheme, "Remove", x: 196, y: 410, width: 90, hint: "Remove\nDelete the selected imported preset. Built-in themes cannot be removed.")
    }

    @discardableResult
    private func add(_ className: String, _ text: String, style: DWORD, x: Int32, y: Int32, width: Int32, height: Int32,
                     id: Control? = nil, rawID: Int32? = nil, onPage: Bool = true) -> HWND? {
        let control = withWide(className) { cls in
            withWide(text) { title in
                CreateWindowExW(0, cls, title, DWORD(WS_CHILD) | style, x, y, width, height, hwnd,
                                HMENU(bitPattern: Int(rawID ?? id?.rawValue ?? 0)), GetModuleHandleW(nil), nil)
            }
        }
        SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(fonts.text)))), 1)
        if let id { controls[id] = control }
        if let control {
            if onPage { pageControls[building, default: []].append(control) } else { ShowWindow(control, SW_SHOW) }
        }
        return control
    }

    private func select(_ page: Page) {
        self.page = page
        for (owner, list) in pageControls {
            for control in list { ShowWindow(control, owner == page ? SW_SHOW : SW_HIDE) }
        }
        // Reset zoom shows only while the profile is zoomed.
        if page == .text { ShowWindow(controls[.zoomReset], TerminalProfile.shared.settings(for: editing).zoom != 0 ? SW_SHOW : SW_HIDE) }
        for page in Page.allCases { if let button = GetDlgItem(hwnd, page.id) { InvalidateRect(button, nil, true) } }
    }

    // MARK: Values

    private static let appearances = ["System", "Light", "Dark"]
    private static let basicTheme = "macOS Terminal Basic"
    /// Where a new local tab's shell starts, as on the Mac.
    private static let newTabPlaces = ["Same folder as the current tab", "Home folder"]
    private var themeNames: [String] = []
    private var families: [String] = []

    private func load() {
        guard hwnd != nil else { return }
        loading = true
        defer { loading = false }
        let profile = TerminalProfile.shared
        let settings = profile.settings(for: editing)
        let editingName = profile.name(of: editing)
        for caption in captions where caption != controls[.zoom] { setText(caption, "Editing profile: \(editingName)") }

        fillList(.profileList, profile.profiles.map(\.name), selected: profile.profiles.firstIndex { $0.id == editing })
        EnableWindow(controls[.deleteProfile], profile.profiles.count > 1)
        EnableWindow(controls[.defaultProfile], editing != profile.defaultProfileID)
        if GetFocus() != controls[.name] { setTextIfChanged(.name, editingName) }
        setTextIfChanged(.startupCommand, settings.startupCommand)
        setTextIfChanged(.startDirectory, settings.startDirectory)

        families = FontSet.installedMonospacedFamilies().filter { $0 != FontSet.stockFamily }
        let fontItems = ["\(FontSet.stockFamily) (Basic)"] + families
        fillCombo(.font, fontItems, selected: settings.fontFamily.isEmpty ? 0 : families.firstIndex(of: settings.fontFamily).map { $0 + 1 })
        setSpin(.sizeSpin, Int(settings.fontSize.rounded()))
        if GetFocus() != controls[.size] { setTextIfChanged(.size, settings.fontSize.formatted()) }
        setText(controls[.zoom], settings.zoom == 0 ? "" : "zoomed \(settings.zoom > 0 ? "+" : "")\(Int(settings.zoom)) pt")
        if page == .text { ShowWindow(controls[.zoomReset], settings.zoom != 0 ? SW_SHOW : SW_HIDE) }
        let cursors: [Control] = [.cursorBlock, .cursorUnderline, .cursorBar]
        for (index, shape) in CursorShape.allCases.enumerated() { setCheck(cursors[index], shape == settings.cursor) }
        setCheck(.blink, settings.cursorBlinks)
        setText(controls[.preview], "Preview: \(settings.fontFamily.isEmpty ? FontSet.stockFamily : settings.fontFamily) \(settings.fontSize.formatted()) pt")
        if let preview = controls[.preview] { InvalidateRect(preview, nil, true) }

        setSpin(.scrollbackSpin, settings.scrollbackLines)
        if GetFocus() != controls[.scrollback] { setTextIfChanged(.scrollback, String(settings.scrollbackLines)) }
        fillCombo(.bell, TerminalBell.allCases.map(\.title), selected: TerminalBell.allCases.firstIndex(of: settings.bell))
        fillCombo(.newTabs, Self.newTabPlaces, selected: profile.newTabsInSameFolder ? 0 : 1)
        let choices = ShellChoice.available
        let shell = ShellChoice.current
        let shellTitle = choices.first { $0.commandLine == shell }?.title ?? shell
        fillCombo(.shell, choices.map(\.title), selected: choices.firstIndex { $0.title == shellTitle }, text: shellTitle)
        setCheck(.restoreSession, profile.restoreSession)
        setCheck(.askBeforeClosing, profile.askBeforeClosing)

        setCheck(.sizeBadge, profile.showSizeWhileResizing)
        setSpin(.columnsSpin, profile.windowColumns)
        setSpin(.rowsSpin, profile.windowRows)
        if GetFocus() != controls[.columns] { setTextIfChanged(.columns, String(profile.windowColumns)) }
        if GetFocus() != controls[.rows] { setTextIfChanged(.rows, String(profile.windowRows)) }

        let appearance: [Control] = [.appearanceSystem, .appearanceLight, .appearanceDark]
        for (index, name) in Self.appearances.enumerated() { setCheck(appearance[index], name == profile.appearance) }
        themeNames = [""] + ThemeLibrary.shared.allNames
        fillList(.themeList, themeNames.map { $0.isEmpty ? Self.basicTheme : $0 }, selected: themeNames.firstIndex(of: settings.theme))
        EnableWindow(controls[.removeTheme], ThemeLibrary.shared.isImported(settings.theme))
    }

    private func fillCombo(_ id: Control, _ items: [String], selected: Int?, text: String? = nil) {
        guard let combo = controls[id] else { return }
        SendMessageW(combo, UINT(CB_RESETCONTENT), 0, 0)
        for item in items { withWide(item) { _ = SendMessageW(combo, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) } }
        if let selected { SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(selected), 0) } else if let text { setText(combo, text) }
    }

    private func fillList(_ id: Control, _ items: [String], selected: Int?) {
        guard let list = controls[id] else { return }
        let top = SendMessageW(list, UINT(LB_GETTOPINDEX), 0, 0)
        SendMessageW(list, UINT(WM_SETREDRAW), 0, 0)
        SendMessageW(list, UINT(LB_RESETCONTENT), 0, 0)
        for item in items { withWide(item) { _ = SendMessageW(list, UINT(LB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) } }
        SendMessageW(list, UINT(LB_SETCURSEL), WPARAM(bitPattern: selected ?? -1), 0)
        SendMessageW(list, UINT(LB_SETTOPINDEX), WPARAM(top), 0)
        SendMessageW(list, UINT(WM_SETREDRAW), 1, 0)
        InvalidateRect(list, nil, true)
    }

    private func text(_ id: Control) -> String { text(of: controls[id]).trimmingCharacters(in: .whitespaces) }

    private func text(of control: HWND?) -> String {
        guard let control else { return "" }
        let length = GetWindowTextLengthW(control)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(control, &buffer, length + 1)
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private func selection(_ id: Control) -> Int { Int(SendMessageW(controls[id], UINT(CB_GETCURSEL), 0, 0)) }
    private func listSelection(_ id: Control) -> Int { Int(SendMessageW(controls[id], UINT(LB_GETCURSEL), 0, 0)) }

    private func setText(_ control: HWND?, _ value: String) {
        guard let control, text(of: control) != value else { return }
        withWide(value) { _ = SetWindowTextW(control, $0) }
    }

    private func setTextIfChanged(_ id: Control, _ value: String) { setText(controls[id], value) }

    private func setSpin(_ id: Control, _ value: Int) { SendMessageW(controls[id], UINT(UDM_SETPOS32), 0, LPARAM(value)) }

    private func setCheck(_ id: Control, _ on: Bool) {
        SendMessageW(controls[id], UINT(BM_SETCHECK), WPARAM(on ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    private func isChecked(_ id: Control) -> Bool { SendMessageW(controls[id], UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }

    // MARK: Changes

    private func commit(_ id: Control, finished: Bool = false) {
        guard !loading else { return }
        let profile = TerminalProfile.shared
        switch id {
        case .profileList:
            let index = listSelection(.profileList)
            if profile.profiles.indices.contains(index) { profile.editingID = profile.profiles[index].id }
        case .newProfile:
            profile.editingID = profile.addProfile(named: "New Profile")
        case .duplicateProfile:
            profile.editingID = profile.addProfile(named: profile.name(of: editing) + " copy", copying: editing)
        case .deleteProfile:
            if profile.profiles.count > 1 { profile.removeProfile(editing) }
        case .name:
            let name = text(.name)
            if !name.isEmpty, name != profile.name(of: editing) { profile.rename(editing, to: name) }
        case .startupCommand:
            let value = text(.startupCommand)
            profile.update(editing) { $0.startupCommand = value }
        case .startDirectory:
            let value = text(.startDirectory)
            profile.update(editing) { $0.startDirectory = value }
        case .defaultProfile:
            profile.defaultProfileID = editing
        case .font:
            let index = selection(.font)
            profile.update(editing) { $0.fontFamily = index <= 0 ? "" : self.families[index - 1] }
        case .size:
            if let size = Double(text(.size).replacingOccurrences(of: ",", with: ".")), ProfileSettings.sizeRange.contains(size) {
                profile.update(editing) { $0.fontSize = size }
            } else if finished {
                load()
            }
        case .zoomReset:
            profile.update(editing) { $0.zoom = 0 }
        case .cursorBlock, .cursorUnderline, .cursorBar:
            let shape = CursorShape.allCases[Int(id.rawValue - Control.cursorBlock.rawValue)]
            profile.update(editing) { $0.cursor = shape }
        case .blink:
            let on = isChecked(.blink)
            profile.update(editing) { $0.cursorBlinks = on }
        case .restoreText:
            profile.resetText()
        case .scrollback:
            if let lines = Int(text(.scrollback)), (100...1_000_000).contains(lines) {
                profile.update(editing) { $0.scrollbackLines = lines }
            } else if finished {
                load()
            }
        case .bell:
            let index = selection(.bell)
            if TerminalBell.allCases.indices.contains(index) { profile.update(editing) { $0.bell = TerminalBell.allCases[index] } }
        case .newTabs:
            profile.newTabsInSameFolder = selection(.newTabs) == 0
        case .shell:
            let index = selection(.shell), choices = ShellChoice.available
            let value = choices.indices.contains(index) && !finished ? choices[index].title : text(.shell)
            ShellChoice.current = choices.first { $0.title == value }?.commandLine ?? value
        case .restoreSession:
            profile.restoreSession = isChecked(.restoreSession)
            // Off forgets the saved session at once.
            if !profile.restoreSession { SavedSession.clear() }
        case .askBeforeClosing:
            profile.askBeforeClosing = isChecked(.askBeforeClosing)
        case .sizeBadge:
            profile.showSizeWhileResizing = isChecked(.sizeBadge)
        case .columns, .rows:
            let range = id == .columns ? TerminalProfile.gridRange.columns : TerminalProfile.gridRange.rows
            if let value = Int(text(id)), range.contains(value) {
                if id == .columns { profile.windowColumns = value } else { profile.windowRows = value }
            } else if finished {
                load()
            }
        case .apply:
            App.allWorkspaces.forEach { $0.resize(columns: profile.windowColumns, rows: profile.windowRows) }
        case .useFront:
            guard let terminal = frontWorkspace()?.focusedPane?.terminal, terminal.cols > 0, terminal.rows > 0 else { return }
            profile.windowColumns = terminal.cols
            profile.windowRows = terminal.rows
        case .resetSize:
            profile.windowColumns = TerminalProfile.defaultGrid.columns
            profile.windowRows = TerminalProfile.defaultGrid.rows
        case .appearanceSystem, .appearanceLight, .appearanceDark:
            profile.appearance = Self.appearances[Int(id.rawValue - Control.appearanceSystem.rawValue)]
            if let hwnd { DialogTheme.apply(to: hwnd) }
        case .themeList:
            let index = listSelection(.themeList)
            if themeNames.indices.contains(index) { let name = themeNames[index]; profile.update(editing) { $0.theme = name } }
        case .importTheme:
            importTheme()
        case .removeTheme:
            let name = profile.settings(for: editing).theme
            guard ThemeLibrary.shared.isImported(name) else { return }
            ThemeLibrary.shared.removeImported(name)
            profile.update(editing) { $0.theme = "" }
        case .sizeSpin, .zoom, .preview, .scrollbackSpin, .columnsSpin, .rowsSpin:
            break
        }
    }

    /// The terminal window used most recently: the first one in the windows' front-to-back order.
    private func frontWorkspace() -> Workspace? {
        var window = GetTopWindow(nil)
        while let current = window {
            if let workspace = App.allWorkspaces.first(where: { $0.hwnd == current }) { return workspace }
            window = GetWindow(current, UINT(GW_HWNDNEXT))
        }
        return App.allWorkspaces.last
    }

    private func importTheme() {
        guard let path = openFile(owner: hwnd, title: "Import a Color Preset",
                                  filter: [("iTerm2 color presets (*.itermcolors)", "*.itermcolors")]) else { return }
        do {
            let name = try ThemeLibrary.shared.importFile(URL(fileURLWithPath: path))
            TerminalProfile.shared.update(editing) { $0.theme = name }
        } catch {
            FormDialog.tell(owner: hwnd, title: "Couldn't import that preset", message: error.localizedDescription)
        }
    }

    /// Right-click on an imported color preset: Remove Imported Preset.
    private func themeMenu(at screen: POINT) {
        guard let list = controls[.themeList] else { return }
        var point = screen
        ScreenToClient(list, &point)
        let hit = SendMessageW(list, UINT(LB_ITEMFROMPOINT), 0, LPARAM((Int(point.y) << 16) | (Int(point.x) & 0xFFFF)))
        let index = Int(hit & 0xFFFF)
        guard hiWord(LPARAM(hit)) == 0, themeNames.indices.contains(index), ThemeLibrary.shared.isImported(themeNames[index]) else { return }
        let name = themeNames[index]
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        AppendMenuW(menu, UINT(MF_STRING), 1, "Remove Imported Preset".wide)
        guard let hwnd, MainMenu.trackPopup(menu, at: screen, owner: hwnd) == 1 else { return }
        ThemeLibrary.shared.removeImported(name)
        if TerminalProfile.shared.settings(for: editing).theme == name { TerminalProfile.shared.update(editing) { $0.theme = "" } }
    }

    // MARK: Drawing

    private func gdi(_ color: RGB) -> COLORREF { gdiColor(color) }

    private func draw(_ item: DRAWITEMSTRUCT) {
        guard let dc = item.hDC else { return }
        var rect = item.rcItem
        let selected = item.itemState & UINT(ODS_SELECTED) != 0
        let disabled = item.itemState & UINT(ODS_DISABLED) != 0
        let dark = DialogTheme.dark
        func fill(_ color: COLORREF, _ area: inout RECT) {
            let brush = CreateSolidBrush(color)
            FillRect(dc, &area, brush)
            DeleteObject(brush)
        }
        func text(_ string: String, _ area: inout RECT, _ color: COLORREF, _ format: UINT, font: HFONT? = nil) {
            let old = SelectObject(dc, font ?? fonts.text)
            SetTextColor(dc, color)
            SetBkMode(dc, TRANSPARENT)
            DrawTextW(dc, string.wide, -1, &area, format)
            SelectObject(dc, old)
        }
        let highlight = dark ? colorRef(0, 95, 184) : GetSysColor(COLOR_HIGHLIGHT)
        let highlightText = dark ? colorRef(255, 255, 255) : GetSysColor(COLOR_HIGHLIGHTTEXT)
        switch Int32(item.CtlID) {
        case 900..<905:
            // A page button: its glyph above its title; the shown page is filled in.
            let page = Page(rawValue: Int(item.CtlID) - 900) ?? .profiles
            fill(DialogTheme.background, &rect)
            if page == self.page || selected {
                var tile = rect
                InflateRect(&tile, -s(2), -s(2))
                let brush = CreateSolidBrush(dark ? colorRef(61, 61, 61) : colorRef(229, 229, 229))
                let pen = CreatePen(PS_NULL, 0, 0)
                let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
                RoundRect(dc, tile.left, tile.top, tile.right, tile.bottom, s(8), s(8))
                SelectObject(dc, oldBrush); SelectObject(dc, oldPen)
                DeleteObject(brush); DeleteObject(pen)
            }
            var glyph = RECT(left: rect.left, top: rect.top + s(6), right: rect.right, bottom: rect.top + s(32))
            text(page.glyph, &glyph, DialogTheme.text, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE), font: fonts.pageGlyph)
            var title = RECT(left: rect.left, top: rect.top + s(32), right: rect.right, bottom: rect.bottom - s(4))
            text(page.title, &title, DialogTheme.text, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
            if item.itemState & UINT(ODS_FOCUS) != 0 { DrawFocusRect(dc, &rect) }
        case Control.newProfile.rawValue, Control.duplicateProfile.rawValue, Control.deleteProfile.rawValue:
            fill(selected ? (dark ? colorRef(61, 61, 61) : colorRef(204, 204, 204)) : DialogTheme.background, &rect)
            let glyph = [Control.newProfile.rawValue: "\u{E710}", Control.duplicateProfile.rawValue: "\u{E8C8}"][Int32(item.CtlID)] ?? "\u{E738}"
            text(glyph, &rect, disabled ? DialogTheme.secondaryText : DialogTheme.text, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE), font: fonts.glyph)
            if item.itemState & UINT(ODS_FOCUS) != 0 { DrawFocusRect(dc, &rect) }
        case Control.profileList.rawValue:
            let profiles = TerminalProfile.shared.profiles
            guard profiles.indices.contains(Int(item.itemID)) else { fill(DialogTheme.field, &rect); return }
            let profile = profiles[Int(item.itemID)]
            fill(selected ? highlight : DialogTheme.field, &rect)
            var name = RECT(left: rect.left + s(10), top: rect.top, right: rect.right - s(70), bottom: rect.bottom)
            text(profile.name, &name, selected ? highlightText : DialogTheme.text, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
            if profile.id == TerminalProfile.shared.defaultProfileID {
                var caption = RECT(left: rect.right - s(70), top: rect.top, right: rect.right - s(8), bottom: rect.bottom)
                text("Default", &caption, selected ? highlightText : DialogTheme.secondaryText, UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE))
            }
        case Control.themeList.rawValue:
            guard themeNames.indices.contains(Int(item.itemID)) else { fill(DialogTheme.field, &rect); return }
            let name = themeNames[Int(item.itemID)]
            let theme = ThemeLibrary.shared.theme(named: name)
            let colors = theme?.colors ?? TerminalTheme.basic(dark: true)
            fill(selected ? highlight : DialogTheme.field, &rect)
            var swatch = RECT(left: rect.left + s(8), top: rect.top + s(4), right: rect.left + s(42), bottom: rect.bottom - s(4))
            fill(gdi(colors["Background Color"] ?? RGB(hex: 0)), &swatch)
            text("Aa", &swatch, gdi(colors["Foreground Color"] ?? RGB(hex: 0xFFFFFF)), UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
            let palette = theme?.palette ?? TerminalTheme.basicPalette
            for (index, color) in palette.prefix(8).enumerated() {
                let left = rect.left + s(50) + Int32(index) * s(11), middle = (rect.top + rect.bottom) / 2
                let brush = CreateSolidBrush(gdi(color)), pen = CreatePen(PS_NULL, 0, 0)
                let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
                Ellipse(dc, left, middle - s(4), left + s(9), middle + s(5))
                SelectObject(dc, oldBrush); SelectObject(dc, oldPen)
                DeleteObject(brush); DeleteObject(pen)
            }
            var title = RECT(left: rect.left + s(146), top: rect.top, right: rect.right - s(80), bottom: rect.bottom)
            text(name.isEmpty ? Self.basicTheme : name, &title, selected ? highlightText : DialogTheme.text, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
            if theme != nil, !ThemeLibrary.shared.isImported(name) {
                var caption = RECT(left: rect.right - s(80), top: rect.top, right: rect.right - s(8), bottom: rect.bottom)
                text("Built-in", &caption, selected ? highlightText : DialogTheme.secondaryText, UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE))
            }
        case Control.preview.rawValue:
            // The terminal's text in this profile's font, size and colors.
            let settings = TerminalProfile.shared.settings(for: editing)
            let colors = ThemeLibrary.shared.theme(named: settings.theme)?.colors ?? TerminalTheme.basic(dark: appIsDark)
            fill(DialogTheme.background, &rect)
            let brush = CreateSolidBrush(gdi(colors["Background Color"] ?? RGB(hex: 0))), pen = CreatePen(PS_NULL, 0, 0)
            let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
            RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, s(10), s(10))
            SelectObject(dc, oldBrush); SelectObject(dc, oldPen)
            DeleteObject(brush); DeleteObject(pen)
            let family = settings.fontFamily.isEmpty ? FontSet.stockFamily : settings.fontFamily
            let font = withWide(family) {
                CreateFontW(-Int32((settings.fontSize * Double(dpi) / 96).rounded()), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0,
                            DWORD(CLEARTYPE_QUALITY), DWORD(FIXED_PITCH), $0)
            }
            var area = rect
            InflateRect(&area, -s(10), -s(8))
            text("user@host ~ % ls -la\nThe quick brown fox — 0O 1lI {}[]", &area, gdi(colors["Foreground Color"] ?? RGB(hex: 0xFFFFFF)),
                 UINT(DT_LEFT | DT_TOP | DT_NOPREFIX), font: font)
            DeleteObject(font)
        default:
            break
        }
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_CTLCOLORSTATIC:
            let result = DialogTheme.colors(message, wParam)
            if let control = HWND(bitPattern: Int(lParam)), captions.contains(control) {
                SetTextColor(HDC(bitPattern: UInt(wParam)), DialogTheme.secondaryText)
            }
            return result
        case WM_DRAWITEM:
            guard let pointer = UnsafePointer<DRAWITEMSTRUCT>(bitPattern: Int(lParam)) else { return 0 }
            draw(pointer.pointee)
            return 1
        case WM_CONTEXTMENU:
            if HWND(bitPattern: UInt(wParam)) == controls[.themeList] {
                themeMenu(at: POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(hiWord(lParam))))
                return 0
            }
            return nil
        case WM_COMMAND:
            let code = Int32(hiWord(wParam)), rawID = Int32(wParam & 0xFFFF)
            if rawID == IDCANCEL || rawID == IDOK { DestroyWindow(hwnd); return 0 }
            if (900..<905).contains(rawID), code == BN_CLICKED, let page = Page(rawValue: Int(rawID - 900)) {
                select(page)
                return 0
            }
            guard let id = Control(rawValue: rawID) else { return nil }
            switch code {
            case CBN_SELCHANGE: commit(id)  // also LBN_SELCHANGE (both 1)
            case CBN_KILLFOCUS where id == .shell: commit(id, finished: true)
            case BN_CLICKED: commit(id)
            case EN_CHANGE where [.name, .startupCommand, .startDirectory, .size, .scrollback, .columns, .rows].contains(id): commit(id)
            case EN_KILLFOCUS: commit(id, finished: true)
            default: break
            }
            return 0
        case WM_CLOSE:
            DestroyWindow(hwnd)
            return 0
        case WM_DESTROY:
            for font in [fonts.text, fonts.glyph, fonts.pageGlyph] { if let font { DeleteObject(font) } }
            tokens = []
            self.hwnd = nil
            Self.current = nil
            return 0
        default:
            return DialogTheme.handle(hwnd, message, wParam)
        }
    }
}

/// A profile color as a GDI color.
private func gdiColor(_ color: RGB) -> COLORREF {
    func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
    return colorRef(byte(color.red), byte(color.green), byte(color.blue))
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

/// Light or dark, from Settings ▸ Colors ▸ Appearance (System follows Windows).
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
    // The feature tests' bridge stands in for the dialog (both run on the main thread).
    if let chosen = MainActor.assumeIsolated({ TestBridge.takeChosenFile() }) { return chosen }
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
