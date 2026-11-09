import Foundation
import WinSDK

/// The toolbar's Saved Passwords button: a menu of saved passwords by name, with each description beside it (Win32
/// menus have no hover hints). Choosing one types its password into the focused terminal as the keyboard does (so
/// MultiExec forwards it), without pressing Return.
@MainActor
enum SavedPasswordsMenu {
    /// What the menu offers now: "unlock", "manage", or a saved password's id (for the feature tests too).
    static func entries(_ store: CredentialStore) -> [(title: String, help: String, action: String)] {
        var entries: [(String, String, String)] = []
        if store.isLocked {
            entries.append(("Unlock…", "Unlock\nEnter the Administrator Password to use your snippets.", "unlock"))
        } else if store.passwords.isEmpty {
            entries.append(("No Snippets", "", ""))
        } else {
            for saved in store.passwords {
                entries.append((saved.name, saved.description.isEmpty ? "Type this snippet into the terminal." : saved.description, saved.id))
            }
        }
        entries.append(("Manage Snippets…", "Manage Snippets\nAdd, change or remove snippets.", "manage"))
        return entries
    }

    /// Shows the menu under the button at `point` (screen coordinates).
    static func show(for workspace: Workspace, at point: POINT) {
        guard let owner = workspace.hwnd else { return }
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        let entries = entries(store)
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        for (index, entry) in entries.enumerated() {
            if entry.action == "manage" { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }
            let described = store.passwords.first { $0.id == entry.action }?.description ?? ""
            let title = entry.title.replacingOccurrences(of: "&", with: "&&") + (described.isEmpty ? "" : "\t" + described)
            withWide(title) { _ = AppendMenuW(menu, UINT(MF_STRING) | (entry.action.isEmpty ? UINT(MF_GRAYED) : 0), UINT_PTR(index + 1), $0) }
        }
        let chosen = Int(MainMenu.trackPopup(menu, at: point, owner: owner))
        guard chosen > 0, chosen <= entries.count else { return }
        run(entries[chosen - 1].action, in: workspace, at: point)
    }

    /// Runs one of the menu's entries.
    static func run(_ action: String, in workspace: Workspace, at point: POINT? = nil) {
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        switch action {
        case "unlock":
            if LoginVaultPrompts.unlock(store, owner: workspace.hwnd), let point { show(for: workspace, at: point) }
        case "manage": ManagePasswordsWindow.show(owner: workspace.hwnd)
        default:
            guard let saved = store.passwords.first(where: { $0.id == action }), let pane = workspace.focusedPane else { return }
            if let terminal = pane.hwnd { SetFocus(terminal) }
            pane.type(saved.password)
        }
    }
}

/// Saved Passwords ▸ Manage Passwords…: the saved passwords with New, Edit and Delete.
@MainActor
final class ManagePasswordsWindow: WindowObject {
    static let className = "HerbsTerminalPasswords"
    private static var current: ManagePasswordsWindow?
    /// The window while it's open, for the feature tests' bridge.
    static var bridgeWindow: ManagePasswordsWindow? { current }

    private var hwnd: HWND?
    private var list: HWND?
    private var banner: HWND?
    private var buttons: [Action: HWND] = [:]
    private var font: HFONT?
    private var shown: [SavedPassword] = []
    private var observer: ObservationToken?
    private var store: CredentialStore { CredentialStore.shared ?? CredentialStore.unavailable() }

    private enum Action: Int32, CaseIterable {
        case new = 3100, edit, delete, unlock, close
        var title: String {
            switch self {
            case .new: "New…"
            case .edit: "Edit…"
            case .delete: "Delete…"
            case .unlock: "Unlock…"
            case .close: "Close"
            }
        }
    }

    static func show(owner: HWND?) {
        if let window = current?.hwnd {
            ShowWindow(window, SW_RESTORE)
            SetForegroundWindow(window)
            return
        }
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        if store.isLocked {
            LoginVaultPrompts.unlock(store, owner: owner, cancelTitle: "Skip", detail: "Enter the Administrator Password to see your snippets.")
        }
        current = ManagePasswordsWindow(owner: owner)
    }

    private init(owner: HWND?) {
        var controls = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_LISTVIEW_CLASSES))
        InitCommonControlsEx(&controls)
        let dpi = owner.map { GetDpiForWindow($0) } ?? 96
        var rect = RECT(left: 0, top: 0, right: scaled(640, dpi: dpi), bottom: scaled(400, dpi: dpi))
        let style = DWORD(WS_OVERLAPPEDWINDOW)
        AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (rect.right - rect.left)) / 2
            y = ownerRect.top + scaled(50, dpi: dpi)
        }
        hwnd = createWindow(self, className: Self.className, title: "Manage Snippets", style: style, exStyle: DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: owner)
        guard let hwnd else { return }
        font = withWide("Segoe UI") {
            CreateFontW(-scaled(12, dpi: dpi), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0)
        }
        banner = control("STATIC", "", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX))
        list = control(WC_LISTVIEWW_NAME, "", DWORD(LVS_REPORT) | DWORD(LVS_SHOWSELALWAYS) | DWORD(LVS_SINGLESEL) | DWORD(WS_BORDER) | DWORD(WS_TABSTOP))
        SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE), 0, LPARAM(LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER))
        for (index, column) in [("Name", 170.0), ("Description", 240.0), ("Snippets", 90.0), ("Stored", 100.0)].enumerated() {
            var item = LVCOLUMNW()
            item.mask = UINT(LVCF_TEXT | LVCF_WIDTH)
            item.cx = scaled(column.1, dpi: dpi)
            var title = column.0.wide
            title.withUnsafeMutableBufferPointer { pointer in
                item.pszText = pointer.baseAddress
                _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: $0))) }
            }
        }
        // Delete removes the selected password, as on the Mac and Linux.
        if let list {
            SetWindowSubclass(list, { window, message, wParam, lParam, _, _ in
                if message == UINT(WM_KEYDOWN), wParam == WPARAM(VK_DELETE) {
                    PostMessageW(GetParent(window), UINT(WM_COMMAND), WPARAM(3102 /* Action.delete */), 0)
                    return 0
                }
                return DefSubclassProc(window, message, wParam, lParam)
            }, 0x5057, 0)
        }
        for action in Action.allCases {
            buttons[action] = control("BUTTON", action.title, DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), id: action.rawValue)
        }
        observer = store.objectWillChange.observe { [weak self] in self?.refresh() }
        refresh()
        layout()
        DialogTheme.apply(to: hwnd)
        ShowWindow(hwnd, TestScript.active ? SW_SHOWNOACTIVATE : SW_SHOW)
    }

    private func control(_ cls: String, _ text: String, _ style: DWORD, id: Int32 = 0) -> HWND? {
        let control = withWide(cls) { c in
            withWide(text) { t in
                CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style, 0, 0, 10, 10, hwnd,
                                HMENU(bitPattern: Int(id)), GetModuleHandleW(nil), nil)
            }
        }
        SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(font)))), 1)
        return control
    }

    private func layout() {
        guard let hwnd else { return }
        let dpi = GetDpiForWindow(hwnd)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let margin = s(12)
        MoveWindow(banner, margin, margin, rect.right - 2 * margin, s(36), true)
        let buttonTop = rect.bottom - margin - s(30)
        MoveWindow(list, margin, margin + s(42), rect.right - 2 * margin, buttonTop - s(10) - (margin + s(42)), true)
        var x = margin
        for action in Action.allCases where action != .close {
            guard let button = buttons[action], IsWindowVisible(button) else { continue }
            MoveWindow(button, x, buttonTop, s(84), s(30), true)
            x += s(90)
        }
        MoveWindow(buttons[.close], rect.right - margin - s(84), buttonTop, s(84), s(30), true)
    }

    private func refresh() {
        guard hwnd != nil else { return }
        let store = self.store
        shown = store.passwords
        SendMessageW(list, UINT(LVM_DELETEALLITEMS), 0, 0)
        for (row, saved) in shown.enumerated() {
            let cells = [saved.name, saved.description, "••••••••", store.plainTextPasswordIDs.contains(saved.id) ? "Plain text" : "Encrypted"]
            for (column, text) in cells.enumerated() {
                var item = LVITEMW()
                item.mask = UINT(LVIF_TEXT)
                item.iItem = Int32(row)
                item.iSubItem = Int32(column)
                var units = text.wide
                units.withUnsafeMutableBufferPointer { pointer in
                    item.pszText = pointer.baseAddress
                    _ = withUnsafeMutablePointer(to: &item) {
                        SendMessageW(list, UINT(column == 0 ? LVM_INSERTITEMW : LVM_SETITEMW), 0, LPARAM(Int(bitPattern: $0)))
                    }
                }
            }
        }
        var notice: String
        if store.isLocked {
            let count = store.lockedPasswordCount
            notice = "\(count) snippet\(count == 1 ? " is" : "s are") hidden until you enter the Administrator Password."
        } else if shown.isEmpty {
            notice = "No snippets: click New to add one."
        } else {
            notice = store.protection == .adminPassword ? "Snippets are encrypted with your Administrator Password."
                                                        : "Snippets are stored as plain text. Create an Administrator Password in Manage Logins to encrypt them."
        }
        withWide(notice) { _ = SetWindowTextW(banner, $0) }
        ShowWindow(buttons[.unlock], store.isLocked ? SW_SHOW : SW_HIDE)
        layout()
    }

    private var selectedRow: Int? {
        let index = SendMessageW(list, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED))
        return index >= 0 && Int(index) < shown.count ? Int(index) : nil
    }

    private func select(_ row: Int) {
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        item.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_SETITEMSTATE), WPARAM(row), LPARAM(Int(bitPattern: $0))) }
    }

    private func perform(_ action: Action) {
        let store = self.store
        switch action {
        case .new: edit(nil)
        case .edit: if let row = selectedRow { edit(shown[row]) }
        case .delete:
            guard let row = selectedRow else { return }
            let saved = shown[row]
            if FormDialog.ask(owner: hwnd, title: "Delete the snippet “\(saved.name)”?",
                              message: "It's removed from Herb's Terminal. This can't be undone.",
                              buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Delete")]) == 1 {
                do { try store.deletePassword(id: saved.id) } catch { LoginVaultPrompts.show(error, owner: hwnd) }
            }
        case .unlock: LoginVaultPrompts.unlock(store, owner: hwnd)
        case .close: if let hwnd { DestroyWindow(hwnd) }
        }
        refresh()
    }

    /// New or Edit Password.
    private func edit(_ original: SavedPassword?) {
        let store = self.store
        if store.protection == .unset, !LoginVaultPrompts.explainSetup(store, owner: hwnd) { return }
        guard LoginVaultPrompts.unlock(store, owner: hwnd) else { return }
        var problem: String?
        var values = [original?.name ?? "", original?.password ?? "", original?.description ?? ""]
        while true {
            guard let result = FormDialog.run(
                owner: hwnd, title: original == nil ? "New Snippet" : "Edit Snippet",
                message: store.protection == .adminPassword ? "Saved encrypted with your Administrator Password." : "Saved as plain text.",
                fields: [.init(label: "Name", text: values[0]), .init(label: "Snippets", text: values[1], secure: true),
                         .init(label: "Description (optional)", text: values[2])],
                buttons: [.init(title: "Cancel"), .init(title: "Save", isDefault: true)], error: problem),
                result.button == 1 else { return }
            values = result.values
            do {
                try store.savePassword(SavedPassword(name: values[0], password: values[1],
                                                     description: values[2].trimmingCharacters(in: .whitespacesAndNewlines)),
                                       replacing: original?.id)
                return
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Feature tests: what the window shows.
    var bridgeState: [String: Any] {
        let selected = selectedRow
        return ["open": true, "rows": shown.enumerated().map { row, saved in
                    ["name": saved.name, "description": saved.description, "password": "••••••••",
                     "stored": store.plainTextPasswordIDs.contains(saved.id) ? "Plain text" : "Encrypted",
                     "selected": row == selected] as [String: Any]
                },
                "locked": store.isLocked, "lockedCount": store.lockedPasswordCount]
    }

    /// Feature tests: presses the window's controls. Actions that open a dialog run after the bridge has answered.
    func bridge(_ action: String, _ value: Any?) {
        if let index = value as? Int, shown.indices.contains(index) { select(index) }
        switch action {
        case "new": MainThread.async { self.perform(.new) }
        case "edit", "open": MainThread.async { self.perform(.edit) }
        case "delete": MainThread.async { self.perform(.delete) }
        default: break
        }
    }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if let themed = DialogTheme.handle(hwnd, message, wParam) { return themed }
        switch Int32(message) {
        case WM_SIZE:
            layout()
            return 0
        case WM_COMMAND:
            let id = Int32(wParam & 0xFFFF)
            if id == IDCANCEL { DestroyWindow(hwnd); return 0 }
            if let action = Action(rawValue: id) { perform(action) }
            return 0
        case WM_NOTIFY:
            if let header = UnsafePointer<NMHDR>(bitPattern: UInt(lParam)), header.pointee.hwndFrom == list,
               Int32(bitPattern: header.pointee.code) == -3 /* NM_DBLCLK */, let row = selectedRow {
                edit(shown[row])
                refresh()
            }
            if let header = UnsafePointer<NMHDR>(bitPattern: UInt(lParam)), header.pointee.hwndFrom == list,
               Int32(bitPattern: header.pointee.code) == -5 /* NM_RCLICK */ {
                contextMenu()
            }
            return nil
        case WM_DESTROY:
            if let font { DeleteObject(font) }
            observer = nil
            self.hwnd = nil
            Self.current = nil
            return 0
        default:
            return nil
        }
    }

    /// Right-click: Edit and Delete for the password under the pointer, New elsewhere.
    private func contextMenu() {
        guard let hwnd else { return }
        var point = POINT()
        GetCursorPos(&point)
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        if selectedRow != nil {
            withWide("Edit…") { _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(Action.edit.rawValue), $0) }
            withWide("Delete…\tDelete") { _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(Action.delete.rawValue), $0) }
        } else {
            withWide("New Snippet…") { _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(Action.new.rawValue), $0) }
        }
        let chosen = MainMenu.trackPopup(menu, at: point, owner: hwnd)
        if let action = Action(rawValue: Int32(chosen)) { perform(action) }
    }
}
