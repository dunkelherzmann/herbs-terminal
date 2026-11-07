import CGtk
import CHerb
import Foundation

/// The dialogs around the Administrator Password.
@MainActor
enum LoginVaultPrompts {
    /// The first-use explanation. Returns true once a protection has been chosen.
    @discardableResult
    static func explainSetup(_ store: CredentialStore, parent: Widget?) async -> Bool {
        let answer = await Dialogs.ask(parent, "Create an Administrator Password", """
        Herb's Terminal keeps saved logins inside the app. To encrypt them, create an Administrator Password; you'll \
        enter it once each time you open Herb's Terminal to unlock your saved logins.

        Without one, saved logins (including their passwords) are stored as plain text inside Herb's Terminal, which \
        is a security risk: anyone or anything that can read your files could read them.
        """, choices: [.init("later", "Not Now"), .init("plain", "Store as Plain Text"), .init("create", "Create Administrator Password…", .suggested)],
        defaultID: "create", cancel: "later")
        switch answer {
        case "create":
            return await createOrModify(store, parent: parent)
        case "plain":
            // The risky choice is never one click away.
            let confirm = await Dialogs.ask(parent, "Store saved logins as plain text?",
                                            "Passwords you save will be readable by anyone or anything that can read your files. You can create an Administrator Password later in Manage Logins.",
                                            choices: [.init("cancel", "Cancel"), .init("plain", "Store as Plain Text", .destructive)], cancel: "cancel")
            guard confirm == "plain" else { return false }
            do { try store.choosePlainText(); return true } catch { await Dialogs.show(parent, error); return false }
        default:
            return false
        }
    }

    /// Creates the Administrator Password, or changes it after checking the current one.
    @discardableResult
    static func createOrModify(_ store: CredentialStore, parent: Widget?) async -> Bool {
        let modifying = store.protection == .adminPassword
        var message: String?
        while true {
            let body = (message.map { $0 + "\n\n" } ?? "")
                + (modifying ? "Saved logins are re-encrypted with the new password.\n\nLeave both new password fields blank to remove the Administrator Password: saved logins are then stored as plain text, unprotected."
                             : "Saved logins will be encrypted with this password. Herb's Terminal can't recover it if you forget it; you would have to delete and re-enter your logins.")
            var fields = [Dialogs.Field(label: modifying ? "New password (blank to remove)" : "New password (at least 8 characters)", secure: true),
                          Dialogs.Field(label: "Confirm new password", secure: true)]
            if modifying { fields.insert(Dialogs.Field(label: "Current password", secure: true), at: 0) }
            guard let values = await Dialogs.prompt(parent, modifying ? "Modify Administrator Password" : "Create Administrator Password", body,
                                                    fields: fields, ok: modifying ? "Change Password" : "Create Password") else { return false }
            let current = modifying ? values[0] : ""
            let new = values[modifying ? 1 : 0], confirm = values[modifying ? 2 : 1]
            guard new == confirm else { message = "The new passwords don't match."; continue }
            do {
                // Saved addresses are re-encoded with whatever protection follows, so they stay readable.
                if modifying { try store.unlock(current) }
                if modifying, new.isEmpty {
                    guard await confirmRemoval(parent) else { continue }
                    try TailcatPeerStore.shared.reprotect { try store.removeAdminPassword(current: current) }
                } else {
                    try TailcatPeerStore.shared.reprotect { try store.setAdminPassword(new, current: modifying ? current : nil) }
                }
                return true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private static func confirmRemoval(_ parent: Widget?) async -> Bool {
        // Cancel is the default, so Return never removes the protection by accident.
        await Dialogs.ask(parent, "Remove the Administrator Password?",
                          "Saved logins, passwords included, will be stored as plain text: anyone or anything that can read your files could read them.",
                          choices: [.init("cancel", "Cancel"), .init("remove", "Remove Password", .destructive)], cancel: "cancel") == "remove"
    }

    /// Asks for the Administrator Password to unlock saved logins for this session.
    @discardableResult
    static func unlock(_ store: CredentialStore, parent: Widget?, cancelTitle: String = "Cancel", detail: String? = nil) async -> Bool {
        var message: String?
        while store.isLocked {
            let field = Dialogs.Field(label: "Administrator Password", secure: true)
            let list = box(.vertical, spacing: 4)
            let input = entry(password: true)
            accessibleLabel(input, field.label)
            herb_set_bool(raw(input), "activates-default", 1)
            append(list, label(field.label, classes: ["caption", "dim-label"]), input)
            after(milliseconds: 80) { gtk_widget_grab_focus(input) }
            let answer = await Dialogs.ask(parent, "Unlock Saved Logins", message ?? detail ?? "Enter the Administrator Password to use your saved logins.",
                                           choices: [.init("cancel", cancelTitle), .init("unlock", "Unlock", .suggested)],
                                           defaultID: "unlock", cancel: "cancel", extra: list)
            guard answer == "unlock" else { return false }
            do { try store.unlock(text(of: input)) } catch { message = error.localizedDescription }
        }
        return true
    }

    /// Export writes readable passwords, so it needs the Administrator Password, or a confirmation without one.
    static func confirmExport(_ store: CredentialStore, parent: Widget?) async -> Bool {
        let body = "The exported file contains every saved username and password as readable plain text. Keep it somewhere safe and delete it when you're done."
        if store.protection == .adminPassword {
            guard let values = await Dialogs.prompt(parent, "Export Login Data?", body, fields: [Dialogs.Field(label: "Administrator Password", secure: true)],
                                                    ok: "Export", okStyle: .destructive) else { return false }
            guard store.verify(values[0]) else {
                await Dialogs.tell(parent, "That Administrator Password is not correct.")
                return false
            }
            return true
        }
        return await Dialogs.ask(parent, "Export Login Data?", body,
                                 choices: [.init("cancel", "Cancel"), .init("export", "Export", .destructive)], cancel: "cancel") == "export"
    }

    /// Import Login Data: a CSV of host,port,username,password. Returns a summary to show, or nil if cancelled.
    static func importData(_ store: CredentialStore, parent: Widget?) async -> String? {
        if store.protection == .unset, !(await explainSetup(store, parent: parent)) { return nil }
        if store.isLocked, !(await unlock(store, parent: parent)) { return nil }
        guard let path = await Dialogs.openFiles(parent, title: "Import Login Data", accept: "Import", pattern: "*.csv").first else { return nil }
        do {
            let summary = try store.importCSV(try Data(contentsOf: URL(fileURLWithPath: path)), policy: .overwrite)
            return "Import completed: \(summary.added) added, \(summary.updated) updated, \(summary.skipped) skipped."
        } catch {
            await Dialogs.show(parent, error, heading: "The logins couldn't be imported")
            return nil
        }
    }

    /// Export Login Data, after the Administrator Password (or a plain-text confirmation): the logins in `ids`.
    static func exportData(_ store: CredentialStore, only ids: Set<SSHLogin.ID>, parent: Widget?) async -> String? {
        guard !ids.isEmpty, await confirmExport(store, parent: parent) else { return nil }
        guard let path = await Dialogs.save(parent, title: "Export Login Data", name: "logins_export.csv") else { return nil }
        do {
            let data = try store.exportCSV(only: ids)
            // The export holds passwords: readable by this account only, from the moment it exists.
            try? FileManager.default.removeItem(atPath: path)
            guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw FileIssue("Couldn't write \((path as NSString).lastPathComponent).")
            }
            return "\(ids.count) login\(ids.count == 1 ? "" : "s") exported. The file contains readable passwords; delete it when you're done."
        } catch {
            await Dialogs.show(parent, error, heading: "The logins couldn't be exported")
            return nil
        }
    }
}

/// Connect via SSH: a host, port, username and password, or a saved login.
@MainActor
final class SSHConnectDialog {
    private let window: ToolWindow
    private let store: CredentialStore
    private let lockedReason = CredentialStore.unavailableReason
    private let connect: (SSHLogin) -> Void
    private let notices: Widget
    private let savedRow: Widget
    private var saved: Widget?
    private let host = entry(placeholder: "Host, IP address or SSH alias")
    private let port = entry(text: "22")
    private let username = entry(placeholder: "Username")
    private let password = entry(placeholder: "Leave empty to use SSH keys", password: true)
    private let save: Widget
    private let error: Widget
    private var token: ObservationToken?
    private var logins: [SSHLogin] = []

    static func show(parent: Widget?, connect: @escaping (SSHLogin) -> Void) {
        let dialog = SSHConnectDialog(parent: parent, connect: connect)
        dialog.window.owner = dialog
        dialog.window.present()
        Task { await dialog.firstUse() }
    }

    private init(parent: Widget?, connect: @escaping (SSHLogin) -> Void) {
        store = CredentialStore.shared ?? CredentialStore.unavailable()
        self.connect = connect
        window = ToolWindow(title: "Connect via SSH", width: 460, parent: parent)
        gtk_window_set_modal(c(window.window), 1)
        notices = box(.vertical, spacing: 6)
        savedRow = box(.vertical)
        save = check("Save credentials in Herb's Terminal")
        error = label("", classes: ["error-text", "caption"], wrap: true)
        build()
        token = store.objectWillChange.observe { [weak self] in self?.refresh() }
        refresh()
    }

    private func build() {
        let content = box(.vertical, spacing: 14)
        margins(content, 20)
        let heading = label("Connect via SSH", classes: ["heading-text"], xalign: 0.5)
        append(content, heading, savedRow, notices)

        let form = grid(rowSpacing: 8, columnSpacing: 12)
        for (index, (title, field, help)) in [("Host or IP Address:", host, "Host\nThe server's name, IP address or ~/.ssh/config alias."),
                                              ("Port:", port, "Port\nThe server's SSH port; usually 22."),
                                              ("Username:", username, "Username\nThe account to sign in as on the server."),
                                              ("Password:", password, "Password\nLeave empty to use your SSH keys or agent.")].enumerated() {
            attach(form, label(title, xalign: 1), column: 0, row: Int32(index))
            attach(form, field, column: 1, row: Int32(index))
            accessibleLabel(field, String(title.dropLast()))
            hint(field, help)
            herb_set_bool(raw(field), "activates-default", 1)
        }
        gtk_widget_set_hexpand(host, 1)
        gtk_editable_set_width_chars(c(port), 6)
        gtk_widget_set_halign(port, GTK_ALIGN_START)
        herb_set_bool(raw(password), "show-peek-icon", 1)
        attach(form, save, column: 1, row: 4)
        append(content, form, error)

        let manage = button("Manage Logins…", hint: "Manage Logins\nSee, add and edit saved logins, import or export them, and set the Administrator Password.") { [weak self] in
            guard let self else { return }
            ManageLoginsWindow.show(self.store, parent: self.window.window)
        }
        enable(manage, lockedReason == nil)
        let cancel = button("Cancel", hint: "Cancel (Esc)\nClose without connecting.") { [weak self] in self?.window.close() }
        let go = button("Connect", classes: ["suggested-action"], hint: "Connect (Return)\nOpen the remote shell in this tab; the explorer follows the host.") { [weak self] in
            Task { await self?.submit() }
        }
        append(content, box(.horizontal, spacing: 8, [manage, spacer(), cancel, go]))
        gtk_window_set_default_widget(c(window.window), go)
        append(window.content, content)
        after(milliseconds: 50) { [weak self] in self.map { gtk_widget_grab_focus($0.host) } }
    }

    /// The first time SSH is used, explain the Administrator Password; later, offer to unlock.
    private func firstUse() async {
        if store.protection == .unset { await LoginVaultPrompts.explainSetup(store, parent: window.window) }
        else if store.isLocked { await LoginVaultPrompts.unlock(store, parent: window.window) }
    }

    private func refresh() {
        removeChildren(savedRow)
        logins = store.logins
        if !logins.isEmpty {
            let picker = dropDown(["Manual Entry"] + logins.map(\.label), selected: 0) { [weak self] index in self?.pick(index) }
            hint(picker, "Saved Logins\nFill in host, port, username and password from a login saved in Herb's Terminal.")
            accessibleLabel(picker, "Saved Logins")
            append(savedRow, picker)
            saved = picker
        }
        removeChildren(notices)
        if let reason = lockedReason { append(notices, notice("dialog-warning-symbolic", "Saved logins are unavailable: \(reason)")) }
        if store.isLocked {
            let unlock = button("Unlock…", hint: "Unlock\nEnter the Administrator Password to use saved logins this session.") { [weak self] in
                guard let self else { return }
                Task { await LoginVaultPrompts.unlock(self.store, parent: self.window.window) }
            }
            append(notices, box(.horizontal, spacing: 8, [notice("changes-prevent-symbolic", "Saved logins are locked with your Administrator Password."), unlock]))
        } else if store.protection == .plainText {
            append(notices, notice("changes-allow-symbolic", "Saved logins are stored as plain text. Create an Administrator Password in Manage Logins to encrypt them."))
        }
        if store.legacyCount > 0 {
            let discard = button("Discard…", hint: "Discard\nPermanently delete the unreadable old logins.") { [weak self] in Task { await self?.discardLegacy() } }
            let count = store.legacyCount
            append(notices, box(.horizontal, spacing: 8, [notice("dialog-password-symbolic",
                                                                 "\(count) login\(count == 1 ? "" : "s") saved by an earlier version can't be read anymore. Re-enter them, then discard the old copies."), discard]))
        }
        let title = store.protection == .plainText ? "Save credentials (plain text, not encrypted)"
            : store.protection == .adminPassword ? "Save credentials (encrypted with Administrator Password)" : "Save credentials in Herb's Terminal"
        gtk_check_button_set_label(c(save), title)
        hint(save, store.protection == .plainText ? "Save credentials\nKeep this login inside Herb's Terminal as plain text."
                                                  : "Save credentials\nKeep this login inside Herb's Terminal, encrypted with your Administrator Password.")
        enable(save, lockedReason == nil && !store.isLocked)
    }

    private func notice(_ icon: String, _ text: String) -> Widget {
        let message = label(text, classes: ["caption"], wrap: true)
        gtk_widget_set_hexpand(message, 1)
        return box(.horizontal, spacing: 8, [image(icon, classes: ["warning"]), message])
    }

    private func pick(_ index: Int) {
        guard index > 0, logins.indices.contains(index - 1) else { return }
        let login = logins[index - 1]
        setText(host, login.host)
        setText(port, String(login.port))
        setText(username, login.username)
        setText(password, login.password)
        setActive(save, false)
    }

    private func submit() async {
        // First SSH use with saving on: explain protection before anything is written.
        if isActive(save), store.protection == .unset, !(await LoginVaultPrompts.explainSetup(store, parent: window.window)) { setActive(save, false) }
        let login = SSHLogin(host: text(of: host).trimmingCharacters(in: .whitespacesAndNewlines), port: Int(text(of: port).trimmingCharacters(in: .whitespaces)) ?? 0,
                             username: text(of: username).trimmingCharacters(in: .whitespacesAndNewlines), password: text(of: password))
        do {
            try login.validate()
            if isActive(save), lockedReason == nil, store.protection != .unset { try store.save(login) }
            window.close()
            connect(login)
        } catch {
            setLabel(self.error, error.localizedDescription)
        }
    }

    private func discardLegacy() async {
        let count = store.legacyCount
        // Cancel is the default, so Return or a stray click never deletes.
        let answer = await Dialogs.ask(window.window, "Delete \(count) old saved login\(count == 1 ? "" : "s")?",
                                       "They were encrypted with a key this version no longer has, so they can't be read. This can't be undone.",
                                       choices: [.init("cancel", "Cancel"), .init("delete", "Delete", .destructive)], cancel: "cancel")
        guard answer == "delete" else { return }
        do { try store.discardLegacy() } catch { setLabel(self.error, error.localizedDescription) }
    }
}

/// Connect via SSH ▸ Manage Logins…: a window listing the saved logins, with New, Edit, Import, Export and the
/// Administrator Password along the top.
@MainActor
final class ManageLoginsWindow {
    private static var open: ManageLoginsWindow?
    private let store: CredentialStore
    private let window: ToolWindow
    private let banners = box(.vertical)
    private let list: Widget
    private let empty: Widget
    private let checkAll: Widget
    private let exportButton: Widget
    private let editButton: Widget
    private let passwordButton: Widget
    private let noticeBar: Widget
    private let noticeLabel: Widget
    private var checked: Set<SSHLogin.ID> = []
    private var shown: [SSHLogin] = []
    private var token: ObservationToken?
    private var updating = false

    static func show(_ store: CredentialStore, parent: Widget?) {
        if let open { open.window.present(); return }
        Task {
            if store.protection == .unset { await LoginVaultPrompts.explainSetup(store, parent: parent) }
            if store.isLocked {
                await LoginVaultPrompts.unlock(store, parent: parent, cancelTitle: "Skip",
                                               detail: "Enter the Administrator Password to see your encrypted logins. Skip to see only logins stored as plain text.")
            }
            let window = ManageLoginsWindow(store: store, parent: parent)
            window.window.owner = window
            open = window
            window.window.present()
        }
    }

    private init(store: CredentialStore, parent: Widget?) {
        self.store = store
        window = ToolWindow(title: "Manage Logins", width: 720, height: 420, resizable: true, parent: parent)
        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(c(list), GTK_SELECTION_SINGLE)
        gtk_list_box_set_activate_on_single_click(c(list), 0)
        empty = label("", classes: ["dim-label"], xalign: 0.5)
        checkAll = check("")
        exportButton = gtk_button_new()!
        editButton = gtk_button_new()!
        passwordButton = gtk_button_new()!
        noticeLabel = label("", classes: ["caption", "dim-label"], wrap: true)
        noticeBar = box(.horizontal, spacing: 8)
        build()
        token = store.objectWillChange.observe { [weak self] in self?.refresh() }
        window.onClose = { Self.open = nil }
        refresh()
    }

    private func barButton(_ widget: Widget, _ title: String, _ icon: String, _ help: String, _ action: @escaping @MainActor () -> Void) -> Widget {
        let content = box(.horizontal, spacing: 6, [image(icon), label(title)])
        gtk_button_set_child(c(widget), content)
        gtk_widget_add_css_class(widget, "flat")
        hint(widget, help)
        on(widget, "clicked") { _ in action() }
        return widget
    }

    private func build() {
        let bar = box(.horizontal, spacing: 2, classes: ["toolbar-strip"])
        append(bar,
               barButton(gtk_button_new()!, "New", "list-add-symbolic", "New Login\nSave a host, port, username and password.") { [weak self] in self?.edit(nil) },
               barButton(editButton, "Edit", "document-edit-symbolic", "Edit Login\nChange the selected login.") { [weak self] in self?.edit(self?.selectedLogin) },
               separator(.vertical),
               barButton(gtk_button_new()!, "Import", "document-open-symbolic", "Import Login Data\nAdd logins from a CSV file (host,port,username,password).") { [weak self] in
                   guard let self else { return }
                   Task { if let notice = await LoginVaultPrompts.importData(self.store, parent: self.window.window) { self.setNotice(notice) } }
               },
               barButton(exportButton, "Export", "document-save-symbolic",
                         "Export Login Data\nSave the ticked logins, passwords included, to a CSV file. Tick them in the first column, or all at once in its heading.") { [weak self] in
                   guard let self else { return }
                   Task { if let notice = await LoginVaultPrompts.exportData(self.store, only: self.checkedIDs, parent: self.window.window) { self.setNotice(notice) } }
               },
               separator(.vertical),
               barButton(passwordButton, "Create Administrator Password", "dialog-password-symbolic", "") { [weak self] in
                   guard let self else { return }
                   Task {
                       if await LoginVaultPrompts.createOrModify(self.store, parent: self.window.window), self.store.protection == .adminPassword {
                           self.setNotice("Saved logins are encrypted with your Administrator Password.")
                       }
                   }
               })
        let header = box(.horizontal, spacing: 8, classes: ["login-header"])
        on(checkAll, "toggled") { [weak self] _ in
            guard let self, !self.updating else { return }
            self.checked = isActive(self.checkAll) ? Set(self.store.logins.map(\.id)) : []
            self.refresh()
        }
        accessibleLabel(checkAll, "Tick all logins for export")
        hint(checkAll, "All logins\nTick or untick every login for Export.")
        append(header, checkAll, column("Host", expand: true), column("Port", width: 52), column("Username", width: 120),
               column("Password", width: 90), column("Stored", width: 100))
        let scroll = scrolled(list)
        let stack = gtk_overlay_new()!
        gtk_overlay_set_child(c(stack), scroll)
        gtk_widget_set_halign(empty, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(empty, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(empty, 0)
        gtk_overlay_add_overlay(c(stack), empty)
        gtk_widget_set_vexpand(stack, 1)
        gtk_widget_set_hexpand(noticeLabel, 1)
        append(noticeBar, noticeLabel, button("OK", classes: ["flat"]) { [weak self] in self.map { setVisible($0.noticeBar, false) } })
        margins(noticeBar, top: 6, bottom: 6, start: 12, end: 12)
        setVisible(noticeBar, false)
        append(window.content, bar, separator(), banners, header, separator(), stack, noticeBar)

        on(list, "row-activated") { [weak self] args in
            guard let self, let row = args.pointer(1) else { return }
            let index = Int(gtk_list_box_row_get_index(c(row)))
            if self.shown.indices.contains(index) { self.edit(self.shown[index]) }
        }
        on(list, "selected-rows-changed") { [weak self] _ in self.map { enable($0.editButton, $0.selectedLogin != nil) } }
        onClick(list, button: 3) { [weak self] _, x, y in
            guard let self else { return }
            let row = gtk_list_box_get_row_at_y(c(self.list), Int32(y))
            if let row { gtk_list_box_select_row(c(self.list), row) }
            let menu = gtk_popover_new()!
            let items = box(.vertical)
            if let login = self.selectedLogin, row != nil {
                append(items, button("Edit…", classes: ["flat"]) { [weak self] in gtk_popover_popdown(c(menu)); self?.edit(login) },
                       button("Delete…", classes: ["flat"]) { [weak self] in gtk_popover_popdown(c(menu)); self?.delete(login) })
            } else {
                append(items, button("New Login…", classes: ["flat"]) { [weak self] in gtk_popover_popdown(c(menu)); self?.edit(nil) })
            }
            gtk_popover_set_child(c(menu), items)
            gtk_widget_set_parent(menu, self.list)
            var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
            gtk_popover_set_pointing_to(c(menu), &rect)
            on(menu, "closed") { _ in idle { gtk_widget_unparent(menu) } }
            gtk_popover_popup(c(menu))
        }
        let keys = LocalShortcuts(list)
        keys.add("Delete|KP_Delete") { [weak self] in if let login = self?.selectedLogin { self?.delete(login) } }
    }

    private func column(_ title: String, width: Int32 = -1, expand: Bool = false) -> Widget {
        let widget = label(title)
        if expand { gtk_widget_set_hexpand(widget, 1) } else { gtk_widget_set_size_request(widget, width, -1) }
        return widget
    }

    private var checkedIDs: Set<SSHLogin.ID> { checked.intersection(store.logins.map(\.id)) }

    private var selectedLogin: SSHLogin? {
        guard let row = gtk_list_box_get_selected_row(c(list)) else { return nil }
        let index = Int(gtk_list_box_row_get_index(row))
        return shown.indices.contains(index) ? shown[index] : nil
    }

    private func setNotice(_ text: String) {
        setLabel(noticeLabel, text)
        setVisible(noticeBar, true)
    }

    private func refresh() {
        updating = true
        defer { updating = false }
        removeChildren(banners)
        if let reason = CredentialStore.unavailableReason { append(banners, banner("dialog-warning-symbolic", "Saved logins are unavailable: \(reason)")) }
        if store.isLocked {
            let count = store.lockedCount
            let unlock = button("Unlock…", classes: ["flat"], hint: "Unlock\nEnter the Administrator Password to see and use your encrypted logins.") { [weak self] in
                guard let self else { return }
                Task { await LoginVaultPrompts.unlock(self.store, parent: self.window.window) }
            }
            append(banners, banner("changes-prevent-symbolic", "\(count) encrypted login\(count == 1 ? " is" : "s are") hidden until you enter the Administrator Password.", unlock))
        } else if store.protection == .plainText {
            append(banners, banner("changes-allow-symbolic", "Logins are stored as plain text. Create an Administrator Password to encrypt them."))
        }
        let admin = store.protection == .adminPassword
        let title = admin ? "Modify Administrator Password" : "Create Administrator Password"
        gtk_button_set_child(c(passwordButton), box(.horizontal, spacing: 6, [image("dialog-password-symbolic"), label(title)]))
        hint(passwordButton, admin ? "Modify Administrator Password\nChange the password that encrypts saved logins."
                                   : "Create Administrator Password\nEncrypt saved logins with a password only you know.")
        let ids = checkedIDs
        gtk_button_set_child(c(exportButton), box(.horizontal, spacing: 6, [image("document-save-symbolic"), label(ids.isEmpty ? "Export" : "Export (\(ids.count))")]))
        enable(exportButton, !ids.isEmpty)
        setActive(checkAll, !store.logins.isEmpty && ids.count == store.logins.count)
        enable(checkAll, !store.logins.isEmpty)

        gtk_list_box_remove_all(c(list))
        shown = store.logins
        for login in shown {
            let tick = check("", active: checked.contains(login.id)) { [weak self] on in
                guard let self, !self.updating else { return }
                if on { self.checked.insert(login.id) } else { self.checked.remove(login.id) }
                self.refresh()
            }
            accessibleLabel(tick, "Export \(login.label)")
            let plain = store.plainTextIDs.contains(login.id)
            let stored = box(.horizontal, spacing: 4, [image(plain ? "changes-allow-symbolic" : "changes-prevent-symbolic", classes: plain ? ["warning"] : ["dim-label"]),
                                                       label(plain ? "Plain text" : "Encrypted", classes: plain ? ["warning"] : ["dim-label"])])
            gtk_widget_set_size_request(stored, 100, -1)
            let row = box(.horizontal, spacing: 8, [tick, cell(login.host, expand: true), cell(String(login.port), width: 52),
                                                    cell(login.username, width: 120),
                                                    cell(login.password.isEmpty ? "None (keys)" : "••••••••", width: 90, dim: true), stored])
            margins(row, top: 4, bottom: 4, start: 10, end: 10)
            gtk_list_box_append(c(list), row)
        }
        setLabel(empty, shown.isEmpty ? (store.isLocked ? "No plain-text logins. Unlock to see encrypted ones." : "No saved logins. Click New or Import to add some.") : "")
        enable(editButton, selectedLogin != nil)
    }

    private func cell(_ text: String, width: Int32 = -1, expand: Bool = false, dim: Bool = false) -> Widget {
        let widget = label(text, classes: dim ? ["dim-label"] : [], ellipsize: PANGO_ELLIPSIZE_MIDDLE)
        if expand { gtk_widget_set_hexpand(widget, 1) } else { gtk_widget_set_size_request(widget, width, -1) }
        return widget
    }

    private func banner(_ icon: String, _ text: String, _ accessory: Widget? = nil) -> Widget {
        let message = label(text, wrap: true)
        gtk_widget_set_hexpand(message, 1)
        return box(.horizontal, spacing: 8, [image(icon, classes: ["warning"]), message, accessory], classes: ["banner-warn"])
    }

    private func edit(_ login: SSHLogin?) {
        Task {
            // Saving needs a protection choice, and an unlocked store when logins are encrypted.
            if store.protection == .unset, !(await LoginVaultPrompts.explainSetup(store, parent: window.window)) { return }
            if store.isLocked, !(await LoginVaultPrompts.unlock(store, parent: window.window)) { return }
            await LoginEditor.run(login, store: store, parent: window.window)
        }
    }

    private func delete(_ login: SSHLogin) {
        Task {
            // Cancel is the default, so Return or a stray click never deletes.
            let answer = await Dialogs.ask(window.window, "Delete the login for \(login.label)?", "Its saved password is removed from Herb's Terminal. This can't be undone.",
                                           choices: [.init("cancel", "Cancel"), .init("delete", "Delete", .destructive)], cancel: "cancel")
            guard answer == "delete" else { return }
            do { try store.delete(id: login.id) } catch { await Dialogs.show(window.window, error) }
        }
    }
}

/// New Login and Edit Login: host, port, username and password.
@MainActor
enum LoginEditor {
    static func run(_ original: SSHLogin?, store: CredentialStore, parent: Widget?) async {
        var message: String?
        var values = [original?.host ?? "", String(original?.port ?? 22), original?.username ?? "", original?.password ?? ""]
        while true {
            let content = box(.vertical, spacing: 10)
            var fields: [Widget] = []
            for (index, title) in ["Host or IP Address", "Port", "Username", "Password"].enumerated() {
                let field = entry(placeholder: index == 3 ? "Empty to use SSH keys" : "", text: values[index], password: index == 3)
                accessibleLabel(field, title)
                herb_set_bool(raw(field), "activates-default", 1)
                // Readable only when nothing is hidden: plain-text logins, or once the Administrator Password was given.
                if index == 3, store.protection != .adminPassword || !store.isLocked { herb_set_bool(raw(field), "show-peek-icon", 1) }
                append(content, box(.vertical, spacing: 4, [label(title, classes: ["caption", "dim-label"]), field]))
                fields.append(field)
            }
            append(content, label(store.protection == .adminPassword ? "Saved encrypted with your Administrator Password." : "Saved as plain text.",
                                  classes: ["caption", "dim-label"]))
            if let message { append(content, label(message, classes: ["caption", "error-text"], wrap: true)) }
            after(milliseconds: 80) { gtk_widget_grab_focus(fields[0]) }
            let answer = await Dialogs.ask(parent, original == nil ? "New Login" : "Edit Login",
                                           choices: [.init("cancel", "Cancel"), .init("save", "Save", .suggested)], defaultID: "save", cancel: "cancel", extra: content)
            guard answer == "save" else { return }
            values = fields.map { text(of: $0) }
            let login = SSHLogin(host: values[0].trimmingCharacters(in: .whitespacesAndNewlines), port: Int(values[1].trimmingCharacters(in: .whitespaces)) ?? 0,
                                 username: values[2].trimmingCharacters(in: .whitespacesAndNewlines), password: values[3])
            do {
                try store.save(login)
                // A changed host, port or username is a different login: the old entry goes.
                if let original, original.id != login.id { try store.delete(id: original.id) }
                return
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
