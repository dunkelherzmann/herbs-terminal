import Foundation
import WinSDK

/// The dialogs around the Administrator Password, worded as on the Mac and Linux.
@MainActor
enum LoginVaultPrompts {
    /// The first-use explanation. Returns true once a protection has been chosen.
    @discardableResult
    static func explainSetup(_ store: CredentialStore, owner: HWND?) -> Bool {
        let answer = FormDialog.ask(owner: owner, title: "Create an Administrator Password", message: """
        Herb's Terminal keeps saved logins inside the app. To encrypt them, create an Administrator Password; you'll \
        enter it once each time you open Herb's Terminal to unlock your saved logins.

        Without one, saved logins (including their passwords) are stored as plain text inside Herb's Terminal, which \
        is a security risk: anyone or anything that can read your files could read them.
        """, buttons: [.init(title: "Not Now"), .init(title: "Store as Plain Text"), .init(title: "Create Administrator Password…", isDefault: true)])
        switch answer {
        case 2:
            return createOrModify(store, owner: owner)
        case 1:
            // The risky choice is never one click away.
            let confirm = FormDialog.ask(owner: owner, title: "Store saved logins as plain text?",
                                         message: "Passwords you save will be readable by anyone or anything that can read your files. You can create an Administrator Password later in Manage Logins.",
                                         buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Store as Plain Text")])
            guard confirm == 1 else { return false }
            do { try store.choosePlainText(); return true } catch { show(error, owner: owner); return false }
        default:
            return false
        }
    }

    /// Creates the Administrator Password, or changes or removes it after checking the current one.
    @discardableResult
    static func createOrModify(_ store: CredentialStore, owner: HWND?) -> Bool {
        let modifying = store.protection == .adminPassword
        var problem: String?
        while true {
            let body = modifying
                ? "Saved logins are re-encrypted with the new password.\n\nLeave both new password fields blank to remove the Administrator Password: saved logins are then stored as plain text, unprotected."
                : "Saved logins will be encrypted with this password. Herb's Terminal can't recover it if you forget it; you would have to delete and re-enter your logins."
            var fields = [FormDialog.Field(label: modifying ? "New password (blank to remove)" : "New password (at least 8 characters)", secure: true),
                          FormDialog.Field(label: "Confirm new password", secure: true)]
            if modifying { fields.insert(FormDialog.Field(label: "Current password", secure: true), at: 0) }
            guard let result = FormDialog.run(owner: owner, title: modifying ? "Modify Administrator Password" : "Create Administrator Password",
                                              message: body, fields: fields,
                                              buttons: [.init(title: "Cancel"), .init(title: modifying ? "Change Password" : "Create Password", isDefault: true)],
                                              error: problem),
                  result.button == 1 else { return false }
            let values = result.values
            let current = modifying ? values[0] : ""
            let new = values[modifying ? 1 : 0], confirm = values[modifying ? 2 : 1]
            guard new == confirm else { problem = "The new passwords don't match."; continue }
            do {
                if modifying { try store.unlock(current) }
                if modifying, new.isEmpty {
                    guard confirmRemoval(owner) else { continue }
                    try store.removeAdminPassword(current: current)
                } else {
                    try store.setAdminPassword(new, current: modifying ? current : nil)
                }
                return true
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private static func confirmRemoval(_ owner: HWND?) -> Bool {
        // Cancel is the default, so Enter never removes the protection by accident.
        FormDialog.ask(owner: owner, title: "Remove the Administrator Password?",
                       message: "Saved logins, passwords included, will be stored as plain text: anyone or anything that can read your files could read them.",
                       buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Remove Password")]) == 1
    }

    /// Asks for the Administrator Password to unlock saved logins for this session.
    @discardableResult
    static func unlock(_ store: CredentialStore, owner: HWND?, cancelTitle: String = "Cancel", detail: String? = nil) -> Bool {
        guard store.isLocked else { return true }
        let result = FormDialog.run(owner: owner, title: "Unlock Saved Logins",
                                    message: detail ?? "Enter the Administrator Password to use your saved logins.",
                                    fields: [.init(label: "Administrator Password", secure: true)],
                                    buttons: [.init(title: cancelTitle), .init(title: "Unlock", isDefault: true)],
                                    validate: { _, values, _ in
                                        do { try store.unlock(values[0]); return nil } catch { return error.localizedDescription }
                                    })
        return result?.button == 1 && !store.isLocked
    }

    /// Export writes readable passwords, so it needs the Administrator Password, or a confirmation without one.
    static func confirmExport(_ store: CredentialStore, owner: HWND?) -> Bool {
        let body = "The exported file contains every saved username and password as readable plain text. Keep it somewhere safe and delete it when you're done."
        if store.protection == .adminPassword {
            let result = FormDialog.run(owner: owner, title: "Export Login Data?", message: body,
                                        fields: [.init(label: "Administrator Password", secure: true)],
                                        buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Export")],
                                        validate: { _, values, _ in store.verify(values[0]) ? nil : "That Administrator Password is not correct." })
            return result?.button == 1
        }
        return FormDialog.ask(owner: owner, title: "Export Login Data?", message: body,
                              buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Export")]) == 1
    }

    /// Import Login Data: a CSV of host,port,username,password. Returns a summary to show, or nil if cancelled.
    static func importData(_ store: CredentialStore, owner: HWND?) -> String? {
        if store.protection == .unset, !explainSetup(store, owner: owner) { return nil }
        guard unlock(store, owner: owner) else { return nil }
        guard let path = openFile(owner: owner, title: "Import Login Data", filter: [("CSV files (*.csv)", "*.csv")]) else { return nil }
        do {
            let summary = try store.importCSV(Data(contentsOf: URL(fileURLWithPath: path)))
            return "Imported \(summary.added) new and updated \(summary.updated) existing logins."
                + (summary.skipped > 0 ? " Skipped \(summary.skipped)." : "")
        } catch {
            show(error, owner: owner, heading: "The logins couldn't be imported")
            return nil
        }
    }

    /// Export Login Data, for the ticked logins (or all). Returns a summary, or nil if cancelled.
    static func exportData(_ store: CredentialStore, only ids: Set<SSHLogin.ID>?, owner: HWND?) -> String? {
        guard confirmExport(store, owner: owner) else { return nil }
        guard let path = saveFile(owner: owner, title: "Export Login Data", name: "logins_export.csv",
                                  filter: [("CSV files (*.csv)", "*.csv")]) else { return nil }
        do {
            try store.exportCSV(only: ids).write(to: URL(fileURLWithPath: path), options: .atomic)
            return "Exported to \(path)."
        } catch {
            show(error, owner: owner, heading: "The logins couldn't be exported")
            return nil
        }
    }

    static func show(_ error: Error, owner: HWND?, heading: String = "Something went wrong") {
        FormDialog.tell(owner: owner, title: heading, message: error.localizedDescription)
    }
}

/// Connect via SSH: pick a saved login or enter a new one, optionally save it, and open the session in a new tab.
@MainActor
enum ConnectDialog {
    static func run(owner: HWND?, connect: (SSHLogin) -> Void) {
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        var draft = (host: "", port: "22", username: "", password: "", save: false)
        var problem: String?
        while true {
            let logins = store.isLocked ? [] : store.logins
            var notice = ""
            if let reason = CredentialStore.unavailableReason {
                notice = "Saved logins are unavailable: \(reason)"
            } else if store.isLocked {
                notice = "Saved logins are locked with your Administrator Password."
            } else if store.protection == .plainText {
                notice = "Saved logins are stored as plain text. Create an Administrator Password in Manage Logins to encrypt them."
            }
            var fields: [FormDialog.Field] = []
            if !logins.isEmpty { fields.append(.init(label: "Saved logins", text: "0", options: ["Manual Entry"] + logins.map(\.label))) }
            let offset = fields.count
            fields += [.init(label: "Host, IP address or SSH alias", text: draft.host),
                       .init(label: "Port", text: draft.port, number: true),
                       .init(label: "Username", text: draft.username),
                       .init(label: "Password (leave empty to use SSH keys)", text: draft.password, secure: true)]
            let saveLabel = store.protection == .adminPassword ? "Save credentials (encrypted with Administrator Password)" : "Save credentials in Herb's Terminal"
            var buttons: [FormDialog.Button] = [.init(title: "Manage Logins…")]
            if store.isLocked && CredentialStore.unavailableReason == nil { buttons.append(.init(title: "Unlock…")) }
            let cancel = buttons.count
            buttons += [.init(title: "Cancel"), .init(title: "Connect", isDefault: true)]
            let connectIndex = buttons.count - 1

            func login(from values: [String]) -> SSHLogin {
                SSHLogin(host: values[offset].trimmingCharacters(in: .whitespacesAndNewlines),
                         port: Int(values[offset + 1].trimmingCharacters(in: .whitespaces)) ?? 0,
                         username: values[offset + 2].trimmingCharacters(in: .whitespacesAndNewlines), password: values[offset + 3])
            }
            guard let result = FormDialog.run(
                owner: owner, title: "Connect via SSH", message: notice, fields: fields,
                checkbox: CredentialStore.unavailableReason == nil && !store.isLocked ? (saveLabel, draft.save) : nil,
                buttons: buttons, cancelIndex: cancel, error: problem,
                validate: { button, values, _ in
                    guard button == connectIndex else { return nil }
                    do { try login(from: values).validate(); return nil } catch { return error.localizedDescription }
                },
                onChoice: { _, index, form in
                    guard index > 0, logins.indices.contains(index - 1) else { return }
                    let saved = logins[index - 1]
                    form.setText(offset, saved.host)
                    form.setText(offset + 1, String(saved.port))
                    form.setText(offset + 2, saved.username)
                    form.setText(offset + 3, saved.password)
                    form.setChecked(false)
                }) else { return }
            let values = result.values
            draft = (values[offset], values[offset + 1], values[offset + 2], values[offset + 3], result.checked)
            problem = nil
            switch result.button {
            case 0:
                ManageLoginsWindow.show(owner: owner)
                return
            case connectIndex:
                let chosen = login(from: values)
                if result.checked {
                    // First save: explain protection before anything is written.
                    if store.protection == .unset { LoginVaultPrompts.explainSetup(store, owner: owner) }
                    if store.protection != .unset, !store.isLocked {
                        do { try store.save(chosen) } catch { LoginVaultPrompts.show(error, owner: owner, heading: "The login couldn't be saved") }
                    }
                }
                connect(chosen)
                return
            case cancel:
                return
            default:
                LoginVaultPrompts.unlock(store, owner: owner)
            }
        }
    }
}

/// Manage Logins: the saved logins in a list, with New, Edit, Delete, Import and Export, and the Administrator
/// Password.
@MainActor
final class ManageLoginsWindow: WindowObject {
    static let className = "HerbsTerminalLogins"
    private static var current: ManageLoginsWindow?

    private(set) var hwnd: HWND?
    private var list: HWND?
    private var banner: HWND?
    private var buttons: [Action: HWND] = [:]
    private var font: HFONT?
    private var shown: [SSHLogin] = []
    private var observer: ObservationToken?
    private var store: CredentialStore { CredentialStore.shared ?? CredentialStore.unavailable() }

    private enum Action: Int32, CaseIterable {
        case new = 3000, edit, delete, importData, exportData, password, unlock, close
        var title: String {
            switch self {
            case .new: "New…"
            case .edit: "Edit…"
            case .delete: "Delete…"
            case .importData: "Import…"
            case .exportData: "Export…"
            case .password: "Administrator Password…"
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
            LoginVaultPrompts.unlock(store, owner: owner, cancelTitle: "Skip",
                                     detail: "Enter the Administrator Password to see your encrypted logins. Skip to see only logins stored as plain text.")
        }
        current = ManageLoginsWindow(owner: owner)
    }

    static var openWindow: HWND? { current?.hwnd }

    private init(owner: HWND?) {
        var controls = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_LISTVIEW_CLASSES))
        InitCommonControlsEx(&controls)
        let dpi = owner.map { GetDpiForWindow($0) } ?? 96
        var rect = RECT(left: 0, top: 0, right: scaled(760, dpi: dpi), bottom: scaled(440, dpi: dpi))
        let style = DWORD(WS_OVERLAPPEDWINDOW)
        AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (rect.right - rect.left)) / 2
            y = ownerRect.top + scaled(50, dpi: dpi)
        }
        hwnd = createWindow(self, className: Self.className, title: "Manage Logins", style: style, exStyle: DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: owner)
        guard let hwnd else { return }
        font = withWide("Segoe UI") {
            CreateFontW(-scaled(12, dpi: dpi), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0)
        }
        banner = control("STATIC", "", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX))
        list = control(WC_LISTVIEWW_NAME, "", DWORD(LVS_REPORT) | DWORD(LVS_SHOWSELALWAYS) | DWORD(WS_BORDER) | DWORD(WS_TABSTOP))
        SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE), 0,
                     LPARAM(LVS_EX_FULLROWSELECT | LVS_EX_CHECKBOXES | LVS_EX_DOUBLEBUFFER))
        for (index, column) in [("Host", 260.0), ("Port", 60.0), ("Username", 150.0), ("Password", 100.0), ("Stored", 110.0)].enumerated() {
            var item = LVCOLUMNW()
            item.mask = UINT(LVCF_TEXT | LVCF_WIDTH)
            item.cx = scaled(column.1, dpi: dpi)
            var title = column.0.wide
            title.withUnsafeMutableBufferPointer { pointer in
                item.pszText = pointer.baseAddress
                _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: $0))) }
            }
        }
        for action in Action.allCases {
            buttons[action] = control("BUTTON", action.title, DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), id: action.rawValue)
        }
        observer = store.objectWillChange.observe { [weak self] in self?.refresh() }
        refresh()
        layout()
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
            guard let button = buttons[action] else { continue }
            if !IsWindowVisible(button) { continue }
            let width = action == .password ? s(220) : s(84)
            MoveWindow(button, x, buttonTop, width, s(30), true)
            x += width + s(6)
        }
        MoveWindow(buttons[.close], rect.right - margin - s(84), buttonTop, s(84), s(30), true)
    }

    private func refresh() {
        guard hwnd != nil else { return }
        let store = self.store
        shown = store.logins
        SendMessageW(list, UINT(LVM_DELETEALLITEMS), 0, 0)
        for (row, login) in shown.enumerated() {
            let plain = store.plainTextIDs.contains(login.id)
            let cells = [login.host, String(login.port), login.username, login.password.isEmpty ? "SSH keys" : "••••••••",
                         plain ? "Plain text" : "Encrypted"]
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
        if let reason = CredentialStore.unavailableReason {
            notice = "Saved logins are unavailable: \(reason)"
        } else if store.isLocked {
            notice = "Encrypted logins are locked. Unlock to see and use them."
        } else if store.protection == .adminPassword {
            notice = "Saved logins are encrypted with your Administrator Password."
        } else if store.protection == .plainText {
            notice = "Logins are stored as plain text. Create an Administrator Password to encrypt them."
        } else {
            notice = "No protection chosen yet: you'll be asked when you save the first login."
        }
        if shown.isEmpty { notice += store.isLocked ? "" : "  No saved logins: click New or Import to add some." }
        withWide(notice) { _ = SetWindowTextW(banner, $0) }
        let passwordTitle = store.protection == .adminPassword ? "Modify Administrator Password…" : "Create Administrator Password…"
        withWide(passwordTitle) { _ = SetWindowTextW(buttons[.password], $0) }
        ShowWindow(buttons[.unlock], store.isLocked ? SW_SHOW : SW_HIDE)
        layout()
    }

    private var selectedRow: Int? {
        let index = SendMessageW(list, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED))
        return index >= 0 && Int(index) < shown.count ? Int(index) : nil
    }

    private var checkedIDs: Set<SSHLogin.ID> {
        var ids = Set<SSHLogin.ID>()
        for (row, login) in shown.enumerated() {
            let state = SendMessageW(list, UINT(LVM_GETITEMSTATE), WPARAM(row), LPARAM(LVIS_STATEIMAGEMASK))
            if (state >> 12) == 2 { ids.insert(login.id) }
        }
        return ids
    }

    private func perform(_ action: Action) {
        let store = self.store
        switch action {
        case .new: edit(nil)
        case .edit: if let row = selectedRow { edit(shown[row]) }
        case .delete:
            guard let row = selectedRow else { return }
            let login = shown[row]
            if FormDialog.ask(owner: hwnd, title: "Delete the login for \(login.label)?",
                              message: "Its saved password is removed from Herb's Terminal. This can't be undone.",
                              buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Delete")]) == 1 {
                do { try store.delete(id: login.id) } catch { LoginVaultPrompts.show(error, owner: hwnd) }
            }
        case .importData:
            if let summary = LoginVaultPrompts.importData(store, owner: hwnd) { FormDialog.tell(owner: hwnd, title: "Import Login Data", message: summary) }
        case .exportData:
            let ticked = checkedIDs
            if let summary = LoginVaultPrompts.exportData(store, only: ticked.isEmpty ? nil : ticked, owner: hwnd) {
                FormDialog.tell(owner: hwnd, title: "Export Login Data", message: summary)
            }
        case .password: LoginVaultPrompts.createOrModify(store, owner: hwnd)
        case .unlock: LoginVaultPrompts.unlock(store, owner: hwnd)
        case .close: if let hwnd { DestroyWindow(hwnd) }
        }
        refresh()
    }

    /// New or Edit Login.
    private func edit(_ original: SSHLogin?) {
        let store = self.store
        if store.protection == .unset, !LoginVaultPrompts.explainSetup(store, owner: hwnd) { return }
        guard LoginVaultPrompts.unlock(store, owner: hwnd) else { return }
        var problem: String?
        var values = [original?.host ?? "", original.map { String($0.port) } ?? "22", original?.username ?? "", original?.password ?? ""]
        while true {
            guard let result = FormDialog.run(
                owner: hwnd, title: original == nil ? "New Login" : "Edit Login",
                message: store.protection == .adminPassword ? "Saved encrypted with your Administrator Password." : "Saved as plain text.",
                fields: [.init(label: "Host or IP Address", text: values[0]), .init(label: "Port", text: values[1], number: true),
                         .init(label: "Username", text: values[2]), .init(label: "Password (empty to use SSH keys)", text: values[3], secure: true)],
                buttons: [.init(title: "Cancel"), .init(title: "Save", isDefault: true)], error: problem),
                result.button == 1 else { return }
            values = result.values
            let login = SSHLogin(host: values[0].trimmingCharacters(in: .whitespacesAndNewlines), port: Int(values[1]) ?? 0,
                                 username: values[2].trimmingCharacters(in: .whitespacesAndNewlines), password: values[3])
            do {
                try login.validate()
                if let original, original.id != login.id { try store.delete(id: original.id) }
                try store.save(login)
                return
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
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
            return nil
        case WM_CTLCOLORSTATIC:
            SetBkMode(HDC(bitPattern: UInt(wParam)), TRANSPARENT)
            return LRESULT(Int(bitPattern: UnsafeRawPointer(GetSysColorBrush(COLOR_WINDOW))))
        case WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(lParam)) {
                info.pointee.ptMinTrackSize = POINT(x: scaled(700, dpi: GetDpiForWindow(hwnd)), y: scaled(300, dpi: GetDpiForWindow(hwnd)))
            }
            return 0
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
}

/// The Save dialog; returns the chosen path.
func saveFile(owner: HWND?, title: String, name: String, filter: [(String, String)]) -> String? {
    var buffer = [WCHAR](repeating: 0, count: 4096)
    let initial = Array(name.utf16)
    for (index, unit) in initial.enumerated() where index < buffer.count - 1 { buffer[index] = unit }
    var filterUnits: [WCHAR] = []
    for (label, pattern) in filter { filterUnits += Array(label.utf16) + [0] + Array(pattern.utf16) + [0] }
    filterUnits.append(0)
    let extensionUnits = Array("csv".utf16) + [0]
    return filterUnits.withUnsafeBufferPointer { (filterPointer: UnsafeBufferPointer<WCHAR>) -> String? in
        extensionUnits.withUnsafeBufferPointer { (extensionPointer: UnsafeBufferPointer<WCHAR>) -> String? in
            withWide(title) { titlePointer in
                buffer.withUnsafeMutableBufferPointer { file in
                    var dialog = OPENFILENAMEW()
                    dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                    dialog.hwndOwner = owner
                    dialog.lpstrFilter = filterPointer.baseAddress
                    dialog.lpstrFile = file.baseAddress
                    dialog.nMaxFile = DWORD(file.count)
                    dialog.lpstrTitle = titlePointer
                    dialog.lpstrDefExt = extensionPointer.baseAddress
                    dialog.Flags = DWORD(OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_EXPLORER)
                    guard GetSaveFileNameW(&dialog) else { return nil }
                    return String(decoding: file.prefix { $0 != 0 }, as: UTF16.self)
                }
            }
        }
    }
}

/// "SysListView32", which the WC_LISTVIEWW macro names.
let WC_LISTVIEWW_NAME = "SysListView32"
