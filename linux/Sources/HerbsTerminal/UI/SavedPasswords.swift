import CGtk
import CHerb
import Foundation

/// The toolbar's Saved Passwords button: a menu of saved passwords by name, each with its description as a hover
/// hint. Choosing one types its password into the focused terminal as the keyboard does (so MultiExec forwards
/// it), without pressing Return.
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

    static func show(_ workspace: Workspace, under anchor: Widget) {
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        let popover = gtk_popover_new()!
        let items = box(.vertical)
        for entry in entries(store) {
            if entry.action == "manage" { append(items, separator()) }
            let item = button(entry.title, classes: ["flat"]) {
                gtk_popover_popdown(c(popover))
                run(entry.action, in: workspace, anchor: anchor)
            }
            gtk_widget_set_halign(gtk_button_get_child(c(item)), GTK_ALIGN_START)
            if entry.action.isEmpty { enable(item, false) }
            if !entry.help.isEmpty { hint(item, entry.help) }
            append(items, item)
        }
        gtk_popover_set_child(c(popover), items)
        gtk_widget_set_parent(popover, anchor)
        gtk_popover_set_has_arrow(c(popover), 0)
        on(popover, "closed") { _ in idle { gtk_widget_unparent(popover) } }
        gtk_popover_popup(c(popover))
    }

    /// Runs one of the menu's entries.
    static func run(_ action: String, in workspace: Workspace, anchor: Widget?) {
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        switch action {
        case "unlock":
            Task {
                if await LoginVaultPrompts.unlock(store, parent: workspace.window), let anchor { show(workspace, under: anchor) }
            }
        case "manage": ManagePasswordsWindow.show(store, parent: workspace.window)
        default:
            guard let saved = store.passwords.first(where: { $0.id == action }) else { return }
            let pane = workspace.selected.focused
            pane.focus()
            pane.typeAsKeyboard(saved.password)
        }
    }
}

/// Saved Passwords ▸ Manage Passwords…: the saved passwords with New, Edit and Delete.
@MainActor
final class ManagePasswordsWindow {
    private static var open: ManagePasswordsWindow?
    /// The window while it's open, for the feature tests' bridge.
    static var current: ManagePasswordsWindow? { open }

    private let store: CredentialStore
    private let window: ToolWindow
    private let banners = box(.vertical)
    private let list: Widget
    private let empty: Widget
    private let editButton: Widget
    private let deleteButton: Widget
    private var shown: [SavedPassword] = []
    private var token: ObservationToken?

    static func show(_ store: CredentialStore, parent: Widget?) {
        if let open { open.window.present(); return }
        Task {
            if store.isLocked {
                await LoginVaultPrompts.unlock(store, parent: parent, cancelTitle: "Skip",
                                               detail: "Enter the Administrator Password to see your snippets.")
            }
            let window = ManagePasswordsWindow(store: store, parent: parent)
            window.window.owner = window
            open = window
            window.window.present()
        }
    }

    private init(store: CredentialStore, parent: Widget?) {
        self.store = store
        window = ToolWindow(title: "Manage Snippets", width: 620, height: 360, resizable: true, parent: parent)
        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(c(list), GTK_SELECTION_SINGLE)
        gtk_list_box_set_activate_on_single_click(c(list), 0)
        empty = label("", classes: ["dim-label"], xalign: 0.5)
        editButton = gtk_button_new()!
        deleteButton = gtk_button_new()!
        build()
        token = store.objectWillChange.observe { [weak self] in self?.refresh() }
        window.onClose = { Self.open = nil }
        refresh()
    }

    private func barButton(_ widget: Widget, _ title: String, _ icon: String, _ help: String, _ action: @escaping @MainActor () -> Void) -> Widget {
        gtk_button_set_child(c(widget), box(.horizontal, spacing: 6, [image(icon), label(title)]))
        gtk_widget_add_css_class(widget, "flat")
        hint(widget, help)
        on(widget, "clicked") { _ in action() }
        return widget
    }

    private func column(_ title: String, width: Int32 = -1, expand: Bool = false) -> Widget {
        let widget = label(title)
        if expand { gtk_widget_set_hexpand(widget, 1) } else { gtk_widget_set_size_request(widget, width, -1) }
        return widget
    }

    private func build() {
        let bar = box(.horizontal, spacing: 2, classes: ["toolbar-strip"])
        append(bar,
               barButton(gtk_button_new()!, "New", "list-add-symbolic", "New Snippet\nSave a name, a snippet and a description.") { [weak self] in self?.edit(nil) },
               barButton(editButton, "Edit", "document-edit-symbolic", "Edit Snippet\nChange the selected snippet.") { [weak self] in self?.edit(self?.selected) },
               barButton(deleteButton, "Delete", "user-trash-symbolic", "Delete Snippet\nRemove the selected snippet, after asking.") { [weak self] in
                   if let selected = self?.selected { self?.delete(selected) }
               })
        let header = box(.horizontal, spacing: 8, classes: ["login-header"])
        append(header, column("Name", width: 150), column("Description", expand: true), column("Snippets", width: 90), column("Stored", width: 100))
        let stack = gtk_overlay_new()!
        gtk_overlay_set_child(c(stack), scrolled(list))
        gtk_widget_set_halign(empty, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(empty, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(empty, 0)
        gtk_overlay_add_overlay(c(stack), empty)
        gtk_widget_set_vexpand(stack, 1)
        append(window.content, bar, separator(), banners, header, separator(), stack)

        on(list, "row-activated") { [weak self] args in
            guard let self, let row = args.pointer(1) else { return }
            let index = Int(gtk_list_box_row_get_index(c(row)))
            if self.shown.indices.contains(index) { self.edit(self.shown[index]) }
        }
        on(list, "selected-rows-changed") { [weak self] _ in self?.updateButtons() }
        onClick(list, button: 3) { [weak self] _, x, y in
            guard let self else { return }
            let row = gtk_list_box_get_row_at_y(c(self.list), Int32(y))
            if let row { gtk_list_box_select_row(c(self.list), row) }
            let menu = gtk_popover_new()!
            let items = box(.vertical)
            if let saved = self.selected, row != nil {
                append(items, button("Edit…", classes: ["flat"]) { [weak self] in gtk_popover_popdown(c(menu)); self?.edit(saved) },
                       button("Delete…", classes: ["flat"]) { [weak self] in gtk_popover_popdown(c(menu)); self?.delete(saved) })
            } else {
                append(items, button("New Snippet…", classes: ["flat"]) { [weak self] in gtk_popover_popdown(c(menu)); self?.edit(nil) })
            }
            gtk_popover_set_child(c(menu), items)
            gtk_widget_set_parent(menu, self.list)
            var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
            gtk_popover_set_pointing_to(c(menu), &rect)
            on(menu, "closed") { _ in idle { gtk_widget_unparent(menu) } }
            gtk_popover_popup(c(menu))
        }
        let keys = LocalShortcuts(list)
        keys.add("Delete|KP_Delete") { [weak self] in if let saved = self?.selected { self?.delete(saved) } }
    }

    private var selected: SavedPassword? {
        guard let row = gtk_list_box_get_selected_row(c(list)) else { return nil }
        let index = Int(gtk_list_box_row_get_index(row))
        return shown.indices.contains(index) ? shown[index] : nil
    }

    private func updateButtons() {
        enable(editButton, selected != nil)
        enable(deleteButton, selected != nil)
    }

    private func refresh() {
        removeChildren(banners)
        if store.isLocked {
            let count = store.lockedPasswordCount
            let unlock = button("Unlock…", classes: ["flat"], hint: "Unlock\nEnter the Administrator Password to see and use your snippets.") { [weak self] in
                guard let self else { return }
                Task { await LoginVaultPrompts.unlock(self.store, parent: self.window.window) }
            }
            let message = label("\(count) snippet\(count == 1 ? " is" : "s are") hidden until you enter the Administrator Password.", wrap: true)
            gtk_widget_set_hexpand(message, 1)
            append(banners, box(.horizontal, spacing: 8, [image("changes-prevent-symbolic", classes: ["warning"]), message, unlock], classes: ["banner-warn"]))
        }
        gtk_list_box_remove_all(c(list))
        shown = store.passwords
        for saved in shown {
            let plain = store.plainTextPasswordIDs.contains(saved.id)
            let stored = box(.horizontal, spacing: 4, [image(plain ? "changes-allow-symbolic" : "changes-prevent-symbolic", classes: plain ? ["warning"] : ["dim-label"]),
                                                       label(plain ? "Plain text" : "Encrypted", classes: plain ? ["warning"] : ["dim-label"])])
            gtk_widget_set_size_request(stored, 100, -1)
            let row = box(.horizontal, spacing: 8, [cell(saved.name, width: 150), cell(saved.description, expand: true, dim: true),
                                                    cell("••••••••", width: 90, dim: true), stored])
            margins(row, top: 4, bottom: 4, start: 10, end: 10)
            gtk_list_box_append(c(list), row)
        }
        setLabel(empty, shown.isEmpty ? (store.isLocked ? "Unlock to see your snippets." : "No snippets. Click New to add one.") : "")
        updateButtons()
    }

    private func cell(_ text: String, width: Int32 = -1, expand: Bool = false, dim: Bool = false) -> Widget {
        let widget = label(text, classes: dim ? ["dim-label"] : [], ellipsize: PANGO_ELLIPSIZE_END)
        if expand { gtk_widget_set_hexpand(widget, 1) } else { gtk_widget_set_size_request(widget, width, -1) }
        return widget
    }

    private func edit(_ saved: SavedPassword?) {
        Task {
            // Saving needs a protection choice, and an unlocked store when passwords are encrypted.
            if store.protection == .unset, !(await LoginVaultPrompts.explainSetup(store, parent: window.window)) { return }
            if store.isLocked, !(await LoginVaultPrompts.unlock(store, parent: window.window)) { return }
            await PasswordEditor.run(saved, store: store, parent: window.window)
        }
    }

    private func delete(_ saved: SavedPassword) {
        Task {
            // Cancel is the default, so Return or a stray click never deletes.
            let answer = await Dialogs.ask(window.window, "Delete the snippet “\(saved.name)”?", "It's removed from Herb's Terminal. This can't be undone.",
                                           choices: [.init("cancel", "Cancel"), .init("delete", "Delete", .destructive)], cancel: "cancel")
            guard answer == "delete" else { return }
            do { try store.deletePassword(id: saved.id) } catch { await Dialogs.show(window.window, error) }
        }
    }

    /// Feature tests: what the window shows.
    var bridgeState: [String: Any] {
        let selectedID = selected?.id
        return ["open": true, "rows": shown.map { saved in
                    ["name": saved.name, "description": saved.description, "password": "••••••••",
                     "stored": store.plainTextPasswordIDs.contains(saved.id) ? "Plain text" : "Encrypted",
                     "selected": saved.id == selectedID] as [String: Any]
                },
                "locked": store.isLocked, "lockedCount": store.lockedPasswordCount]
    }

    /// Feature tests: presses the window's controls, through the same code they run.
    func bridge(_ action: String, _ value: Any?) {
        func saved(_ index: Int?) -> SavedPassword? { index.flatMap { shown.indices.contains($0) ? shown[$0] : nil } }
        if let index = value as? Int, let row = gtk_list_box_get_row_at_index(c(list), Int32(index)) { gtk_list_box_select_row(c(list), row) }
        switch action {
        case "new": edit(nil)
        case "edit", "open": if let target = saved(value as? Int) ?? selected { edit(target) }
        case "delete": if let target = saved(value as? Int) ?? selected { delete(target) }
        default: break
        }
    }
}

/// New Password and Edit Password: name, password and description.
@MainActor
enum PasswordEditor {
    static func run(_ original: SavedPassword?, store: CredentialStore, parent: Widget?) async {
        var message: String?
        var values = [original?.name ?? "", original?.password ?? "", original?.description ?? ""]
        while true {
            let content = box(.vertical, spacing: 10)
            var fields: [Widget] = []
            for (index, title) in ["Name", "Snippets", "Description"].enumerated() {
                let field = entry(placeholder: index == 2 ? "Optional" : "", text: values[index], password: index == 1)
                accessibleLabel(field, title)
                herb_set_bool(raw(field), "activates-default", 1)
                if index == 1 { herb_set_bool(raw(field), "show-peek-icon", 1) }
                append(content, box(.vertical, spacing: 4, [label(title, classes: ["caption", "dim-label"]), field]))
                fields.append(field)
            }
            append(content, label(store.protection == .adminPassword ? "Saved encrypted with your Administrator Password." : "Saved as plain text.",
                                  classes: ["caption", "dim-label"]))
            if let message { append(content, label(message, classes: ["caption", "error-text"], wrap: true)) }
            after(milliseconds: 80) { gtk_widget_grab_focus(fields[0]) }
            Dialogs.fieldsForNextAsk(fields)
            let answer = await Dialogs.ask(parent, original == nil ? "New Snippet" : "Edit Snippet",
                                           choices: [.init("cancel", "Cancel"), .init("save", "Save", .suggested)], defaultID: "save", cancel: "cancel",
                                           extra: content, collect: { values = fields.map { text(of: $0) } })
            guard answer == "save" else { return }
            do {
                try store.savePassword(SavedPassword(name: values[0], password: values[1],
                                                     description: values[2].trimmingCharacters(in: .whitespacesAndNewlines)),
                                       replacing: original?.id)
                return
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
