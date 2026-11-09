import Foundation
import WinSDK

/// Get Info for items on a host, as on the Mac and Linux: the item's details, its permissions (chmod) as checkboxes
/// and an octal field kept in step, its owner and group (chown, by name or number), and Apply to enclosed items
/// for folders. Apply changes only what was edited, on every selected item; Revert reloads the current values.
@MainActor
final class GetInfoWindow: WindowObject {
    static let className = "HerbsTerminalGetInfo"

    private let names: [String]
    private let folder: String
    private let session: RemoteSession
    /// Called after changes were applied, so the explorer can list the folder again.
    private let onApplied: () -> Void
    private var hwnd: HWND?
    private var owner: HWND?
    private var done = false
    private var items: [FileInfo] = []
    private var original: FileInfo?
    private var mode: UInt32 = 0
    private var busy = true
    private var updating = false
    private var fonts: [HFONT?] = []
    private var tooltip: HWND?

    private var headerLabels: [HWND?] = []
    private var headerValues: [HWND?] = []
    private var ownerField: HWND?
    private var groupField: HWND?
    private var bitBoxes: [UInt32: HWND?] = [:]
    private var executeHeading: HWND?
    private var octalField: HWND?
    private var symbolic: HWND?
    private var recursiveBox: HWND?
    private var message: HWND?
    private var messageIsError = false
    private var revertButton: HWND?
    private var applyButton: HWND?

    private enum ID {
        static let owner: Int32 = 10, group: Int32 = 11, octal: Int32 = 12, recursive: Int32 = 13
        static let revert: Int32 = 20, close: Int32 = 21, apply: Int32 = 22
        static let firstBit: Int32 = 100
    }
    /// The permission bits in checkbox order: owner, group and others' read, write, execute; then the specials.
    private static let bitOrder: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001, 0o4000, 0o2000, 0o1000]

    /// The window on top, for scripted runs.
    private(set) static var current: GetInfoWindow?

    /// Shows Get Info for `names` in `folder` and waits until it's closed.
    static func show(owner: HWND?, names: [String], in folder: String, session: RemoteSession, onApplied: @escaping () -> Void) {
        let window = GetInfoWindow(names: names, folder: folder, session: session, onApplied: onApplied)
        window.owner = owner
        current = window
        window.run()
        current = nil
    }

    private init(names: [String], folder: String, session: RemoteSession, onApplied: @escaping () -> Void) {
        self.names = names
        self.folder = folder
        self.session = session
        self.onApplied = onApplied
    }

    // MARK: Building

    private func run() {
        let dpi = owner.map { GetDpiForWindow($0) } ?? GetDpiForSystem()
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        let width = s(470), margin = s(18), inner = width - 2 * margin
        let font = makeFont(dpi: dpi, weight: FW_NORMAL)
        let mono = withWide("Cascadia Mono") {
            CreateFontW(-s(12), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), DWORD(FIXED_PITCH | FF_MODERN), $0)
        }
        fonts = [font, mono]
        let height = s(640)
        var frame = RECT(left: 0, top: 0, right: width, bottom: height)
        let style = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
        AdjustWindowRectExForDpi(&frame, style, false, DWORD(WS_EX_DLGMODALFRAME), dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (frame.right - frame.left)) / 2
            y = ownerRect.top + max(s(30), ((ownerRect.bottom - ownerRect.top) - (frame.bottom - frame.top)) / 4)
        }
        let title = (names.count == 1 ? names[0] : "\(names.count) items") + " Info"
        hwnd = createWindow(self, className: Self.className, title: title, style: style,
                            exStyle: DWORD(WS_EX_DLGMODALFRAME) | DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: frame.right - frame.left, height: frame.bottom - frame.top, parent: owner)
        guard let hwnd else { return }
        tooltip = withWide("tooltips_class32") {
            CreateWindowExW(DWORD(WS_EX_TOPMOST), $0, nil, DWORD(WS_POPUP) | DWORD(TTS_ALWAYSTIP) | DWORD(TTS_NOPREFIX),
                            CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, hwnd, nil, GetModuleHandleW(nil), nil)
        }
        SendMessageW(tooltip, UINT(TTM_SETMAXTIPWIDTH), 0, LPARAM(s(340)))

        func add(_ cls: String, _ text: String, _ style: DWORD, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                 id: Int32 = 0, font f: HFONT? = nil, hint: String? = nil) -> HWND? {
            let control = withWide(cls) { c in
                withWide(text) { t in
                    CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style, x, y, w, h, hwnd,
                                    HMENU(bitPattern: Int(id)), GetModuleHandleW(nil), nil)
                }
            }
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(f ?? font)))), 1)
            if let hint, let control { addHint(control, hint) }
            return control
        }
        let labelStyle = DWORD(SS_LEFT) | DWORD(SS_NOPREFIX)
        var top = margin

        // The item's details: label and value rows (one line for several items).
        for _ in 0..<6 {
            headerLabels.append(add("STATIC", "", labelStyle, margin, top, s(96), s(20)))
            headerValues.append(add("STATIC", "", labelStyle | DWORD(SS_PATHELLIPSIS), margin + s(104), top, inner - s(104), s(20)))
            top += s(22)
        }
        withWide("Loading…") { _ = SetWindowTextW(headerLabels[0], $0) }
        top += s(10)
        _ = add("STATIC", "", DWORD(SS_ETCHEDHORZ), margin, top, inner, 1)
        top += s(14)

        // Owner and group.
        let fieldStyle = DWORD(WS_TABSTOP) | DWORD(WS_BORDER) | DWORD(ES_AUTOHSCROLL)
        _ = add("STATIC", "Owner", labelStyle, margin, top + s(3), s(96), s(20))
        ownerField = add("EDIT", "", fieldStyle, margin + s(104), top, inner - s(104), s(25), id: ID.owner,
                         hint: "Owner\nThe account that owns it (chown), by name or number. Giving it to someone else needs root.")
        top += s(34)
        _ = add("STATIC", "Group", labelStyle, margin, top + s(3), s(96), s(20))
        groupField = add("EDIT", "", fieldStyle, margin + s(104), top, inner - s(104), s(25), id: ID.group,
                         hint: "Group\nThe group whose members get the Group permissions (chgrp), by name or number.")
        for field in [ownerField, groupField] { withWide("user name or number") { _ = SendMessageW(field, UINT(EM_SETCUEBANNER), 1, LPARAM(Int(bitPattern: $0))) } }
        top += s(40)

        // Read, write and execute for owner, group and others.
        let column = s(80), firstColumn = margin + s(104)
        for (index, heading) in ["Read", "Write", "Execute"].enumerated() {
            let control = add("STATIC", heading, DWORD(SS_CENTER) | DWORD(SS_NOPREFIX), firstColumn + Int32(index) * column - s(20), top, s(60), s(20))
            if index == 2 { executeHeading = control }
        }
        top += s(24)
        for (row, who) in ["Owner", "Group", "Others"].enumerated() {
            _ = add("STATIC", who, labelStyle, margin, top + s(2), s(96), s(20))
            for kind in 0..<3 {
                let index = row * 3 + kind
                let bit = Self.bitOrder[index]
                let what = ["read", "write", "execute"][kind]
                bitBoxes[bit] = add("BUTTON", "", DWORD(BS_AUTOCHECKBOX) | DWORD(WS_TABSTOP), firstColumn + Int32(kind) * column, top, s(20), s(22),
                                    id: ID.firstBit + Int32(index), hint: "\(who) \(what)")
            }
            top += s(28)
        }
        top += s(6)
        let specials: [(String, String)] = [
            ("Set user ID", "Set user ID (setuid)\nA program runs with its owner's rights."),
            ("Set group ID", "Set group ID (setgid)\nA program runs with its group's rights; in a folder, new items get its group."),
            ("Sticky", "Sticky\nIn a folder, only an item's owner can rename or delete it, as in /tmp."),
        ]
        var sx = margin
        for (offset, special) in specials.enumerated() {
            let index = 9 + offset
            bitBoxes[Self.bitOrder[index]] = add("BUTTON", special.0, DWORD(BS_AUTOCHECKBOX) | DWORD(WS_TABSTOP), sx, top, s(130), s(22),
                                                 id: ID.firstBit + Int32(index), hint: special.1)
            sx += s(140)
        }
        top += s(36)
        _ = add("STATIC", "Octal", labelStyle, margin, top + s(3), s(96), s(20))
        octalField = add("EDIT", "", fieldStyle | DWORD(ES_NUMBER), margin + s(104), top, s(70), s(25), id: ID.octal, font: mono,
                         hint: "Octal\nThe same permissions as chmod takes them, e.g. 644 or 755.")
        SendMessageW(octalField, UINT(EM_SETLIMITTEXT), 4, 0)
        symbolic = add("STATIC", "", labelStyle, margin + s(186), top + s(4), s(160), s(20), font: mono)
        top += s(38)
        recursiveBox = add("BUTTON", "Apply to enclosed items", DWORD(BS_AUTOCHECKBOX) | DWORD(WS_TABSTOP), margin, top, inner, s(22), id: ID.recursive,
                           hint: "Apply to enclosed items\nAlso change everything inside the folder. Folders inside stay openable; links are left alone.")
        ShowWindow(recursiveBox, SW_HIDE)
        top += s(30)
        message = add("STATIC", "", labelStyle, margin, top, inner, s(40))
        top += s(48)

        // Buttons: Revert on the left; Close and Apply on the right.
        revertButton = add("BUTTON", "Revert", DWORD(WS_TABSTOP) | DWORD(BS_PUSHBUTTON), margin, top, s(90), s(30), id: ID.revert,
                           hint: "Revert\nGo back to the values on the host.")
        _ = add("BUTTON", "Close", DWORD(WS_TABSTOP) | DWORD(BS_PUSHBUTTON), width - margin - s(188), top, s(90), s(30), id: ID.close,
                hint: "Close (Esc)\nClose without applying anything more.")
        applyButton = add("BUTTON", "Apply", DWORD(WS_TABSTOP) | DWORD(BS_DEFPUSHBUTTON), width - margin - s(90), top, s(90), s(30), id: ID.apply,
                          hint: "Apply (Enter)\nMake these changes.")
        top += s(30) + margin
        // Fit the window to what was laid out.
        var used = RECT(left: 0, top: 0, right: width, bottom: top)
        AdjustWindowRectExForDpi(&used, style, false, DWORD(WS_EX_DLGMODALFRAME), dpi)
        SetWindowPos(hwnd, nil, 0, 0, used.right - used.left, used.bottom - used.top, UINT(SWP_NOMOVE | SWP_NOZORDER))

        refreshButtons()
        if let owner { EnableWindow(owner, false) }
        DialogTheme.apply(to: hwnd)
        ShowWindow(hwnd, TestScript.active ? SW_SHOWNOACTIVATE : SW_SHOW)
        SetFocus(ownerField)
        load()

        var msg = MSG()
        while !done {
            guard GetMessageW(&msg, nil, 0, 0) else {
                PostQuitMessage(Int32(msg.wParam))
                break
            }
            if IsDialogMessageW(hwnd, &msg) { continue }
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }
        if let owner {
            EnableWindow(owner, true)
            SetActiveWindow(owner)
        }
        if let tooltip { DestroyWindow(tooltip) }
        DestroyWindow(hwnd)
        self.hwnd = nil
        for font in fonts where font != nil { DeleteObject(font) }
    }

    private func makeFont(dpi: UINT, weight: Int32) -> HFONT? {
        withWide("Segoe UI") { CreateFontW(-scaled(12, dpi: dpi), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0) }
    }

    private func addHint(_ control: HWND, _ text: String) {
        var units = text.wide
        units.withUnsafeMutableBufferPointer { pointer in
            var info = TTTOOLINFOW()
            info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
            info.uFlags = UINT(TTF_IDISHWND | TTF_SUBCLASS)
            info.hwnd = hwnd
            info.uId = UINT_PTR(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(control))))
            info.lpszText = pointer.baseAddress
            _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_ADDTOOLW), 0, LPARAM(Int(bitPattern: $0))) }
        }
    }

    // MARK: State

    private func text(_ control: HWND?) -> String { control.map { String(windowText: $0) } ?? "" }
    private func setText(_ control: HWND?, _ value: String) { withWide(value) { _ = SetWindowTextW(control, $0) } }
    private func isChecked(_ control: HWND?) -> Bool { SendMessageW(control, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }
    private var hasFolders: Bool { items.contains { $0.isFolder } }

    private var change: FileInfoChange {
        guard let original else { return FileInfoChange() }
        var change = FileInfoChange(recursive: hasFolders && isChecked(recursiveBox))
        if mode != original.mode { change.mode = mode }
        let ownerText = text(ownerField).trimmingCharacters(in: .whitespaces), groupText = text(groupField).trimmingCharacters(in: .whitespaces)
        if !ownerText.isEmpty, ownerText != original.owner { change.owner = ownerText }
        if !groupText.isEmpty, groupText != original.group { change.group = groupText }
        // A recursive change applies the current values all the way down even where the first item matches.
        if change.recursive, change.isEmpty { change.mode = mode }
        return change
    }

    private func refresh(octalToo: Bool) {
        updating = true
        for (bit, box) in bitBoxes { SendMessageW(box, UINT(BM_SETCHECK), WPARAM(mode & bit != 0 ? BST_CHECKED : BST_UNCHECKED), 0) }
        if octalToo {
            let digits = String(mode, radix: 8)
            setText(octalField, digits.count >= 3 ? digits : String(repeating: "0", count: 3 - digits.count) + digits)
        }
        setText(symbolic, symbolicMode(mode))
        updating = false
        refreshButtons()
    }

    private func refreshButtons() {
        let empty = change.isEmpty
        EnableWindow(revertButton, !empty && !busy)
        EnableWindow(applyButton, !empty && !busy)
    }

    private func show(_ text: String, error: Bool) {
        messageIsError = error
        setText(message, text)
    }

    private func load() {
        busy = true
        refreshButtons()
        let names = self.names, folder = self.folder, session = self.session
        MainThread.background({ try RemoteInfo.load(names, in: folder, session: session) }) { [weak self] result in
            guard let self, self.hwnd != nil else { return }
            self.busy = false
            switch result {
            case .success(let items):
                self.items = items
                guard let first = items.first else { return }
                self.original = first
                self.mode = first.mode
                self.updating = true
                self.setText(self.ownerField, first.owner)
                self.setText(self.groupField, first.group)
                self.updating = false
                self.renderHeader()
                ShowWindow(self.recursiveBox, self.hasFolders ? SW_SHOW : SW_HIDE)
                self.setText(self.executeHeading, self.hasFolders && items.count == 1 ? "Open" : "Execute")
                self.refresh(octalToo: true)
            case .failure(let error):
                self.setText(self.headerLabels[0], "")
                self.show(error.localizedDescription, error: true)
                self.refreshButtons()
            }
        }
    }

    private func renderHeader() {
        var rows: [(String, String)] = []
        if items.count == 1, let item = items.first {
            rows = [("Name", item.name), ("Where", item.location), ("Kind", item.isLink ? "Link" : item.isFolder ? "Folder" : "File")]
            if !item.isFolder, let size = item.size {
                rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " (\(size) bytes)"))
            }
            if let modified = item.modified {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                rows.append(("Modified", formatter.string(from: modified)))
            }
            rows.append(("Permissions", symbolicMode(item.mode) + "  (" + String(item.mode, radix: 8) + ")"))
        } else {
            rows = [("\(items.count) items", "Changes apply to each of them.")]
        }
        for index in headerLabels.indices {
            let row = rows.indices.contains(index) ? rows[index] : ("", "")
            setText(headerLabels[index], row.0)
            setText(headerValues[index], row.1)
        }
    }

    private func apply() {
        let change = change
        guard !change.isEmpty, !busy else { return }
        busy = true
        refreshButtons()
        show("Applying…", error: false)
        let names = self.names, folder = self.folder, session = self.session
        MainThread.background({ try RemoteInfo.apply(change, to: names, in: folder, session: session) }) { [weak self] result in
            guard let self, self.hwnd != nil else { return }
            switch result {
            case .success:
                self.show("Changes applied.", error: false)
                self.onApplied()
            case .failure(let error):
                self.show(error.localizedDescription, error: true)
            }
            self.load()
        }
    }

    /// For scripted runs: owner=NAME, group=NAME, octal=DIGITS, recursive, apply, revert, close.
    func perform(named name: String) {
        if name.hasPrefix("owner=") { setText(ownerField, String(name.dropFirst(6))) }
        else if name.hasPrefix("group=") { setText(groupField, String(name.dropFirst(6))) }
        else if name.hasPrefix("octal=") { setText(octalField, String(name.dropFirst(6))) }
        else if name == "recursive" { SendMessageW(recursiveBox, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0); refreshButtons() }
        else if name == "apply" { apply() }
        else if name == "revert" { load() }
        else if name == "close" { done = true }
    }

    var window: HWND? { hwnd }

    /// Feature tests: what the window shows.
    var bridgeState: [String: Any] {
        ["open": !done, "title": (names.count == 1 ? names[0] : "\(names.count) items") + " Info", "names": items.map(\.name),
         "folders": items.filter(\.isFolder).map(\.name), "location": items.first?.location ?? "",
         "size": items.first?.size.map { Int($0) as Any } ?? NSNull(), "modified": items.first?.modified != nil,
         "octal": text(octalField), "symbolic": text(symbolic), "owner": text(ownerField), "group": text(groupField),
         "recursive": isChecked(recursiveBox), "hasFolders": hasFolders, "macFlags": false, "busy": busy,
         "message": text(message), "changed": !change.isEmpty]
    }

    /// Feature tests: edits the fields as a person would (each change goes through the control's own message),
    /// then Apply, Revert, Close or neither.
    func bridge(_ request: [String: Any]) {
        if let value = request["octal"] as? String { setText(octalField, value) }
        for bit in request["toggle"] as? [Int] ?? [] {
            guard let index = Self.bitOrder.firstIndex(of: UInt32(bit)), let box = bitBoxes[UInt32(bit)] ?? nil else { continue }
            SendMessageW(box, UINT(BM_SETCHECK), WPARAM(isChecked(box) ? BST_UNCHECKED : BST_CHECKED), 0)
            SendMessageW(hwnd, UINT(WM_COMMAND), WPARAM(ID.firstBit + Int32(index)), LPARAM(Int(bitPattern: UnsafeRawPointer(box))))
        }
        if let value = request["owner"] as? String { setText(ownerField, value) }
        if let value = request["group"] as? String { setText(groupField, value) }
        if let value = request["recursive"] as? Bool {
            SendMessageW(recursiveBox, UINT(BM_SETCHECK), WPARAM(value ? BST_CHECKED : BST_UNCHECKED), 0)
            refreshButtons()
        }
        switch request["action"] as? String {
        case "apply": apply()
        case "revert": show("", error: false); load()
        case "close": done = true
        default: break
        }
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if Int32(message) != WM_CTLCOLORSTATIC, let themed = DialogTheme.handle(hwnd, message, wParam) { return themed }
        switch Int32(message) {
        case WM_COMMAND:
            let id = Int32(wParam & 0xFFFF), code = Int32(hiWord(LPARAM(Int(bitPattern: UInt(wParam)))))
            switch id {
            case ID.firstBit..<(ID.firstBit + 12):
                guard !updating else { return 0 }
                let bit = Self.bitOrder[Int(id - ID.firstBit)]
                if isChecked(bitBoxes[bit] ?? nil) { mode |= bit } else { mode &= ~bit }
                refresh(octalToo: true)
            case ID.octal where code == EN_CHANGE:
                guard !updating else { return 0 }
                if let value = UInt32(text(octalField), radix: 8), value <= 0o7777 {
                    mode = value
                    refresh(octalToo: false)
                }
            case ID.owner, ID.group:
                if code == EN_CHANGE, !updating { refreshButtons() }
            case ID.recursive: refreshButtons()
            case ID.revert: show("", error: false); load()
            case ID.apply, IDOK: apply()
            case ID.close, IDCANCEL: done = true
            default: break
            }
            return 0
        case WM_CLOSE:
            done = true
            return 0
        case WM_CTLCOLORSTATIC:
            let brush = DialogTheme.colors(message, wParam)
            let dc = HDC(bitPattern: UInt(wParam))
            let control = HWND(bitPattern: UInt(lParam))
            if control == self.message, messageIsError { SetTextColor(dc, DialogTheme.errorText) }
            else if headerLabels.contains(where: { $0 == control }) { SetTextColor(dc, DialogTheme.secondaryText) }
            return brush
        default:
            return nil
        }
    }
}
