import SwiftUI
import HerbsTerminalUI

/// The toolbar's Saved Passwords button: a menu of saved passwords by name. Choosing one types its password into
/// the focused terminal through the keyboard's path (so MultiExec forwards it), without pressing Return.
@MainActor
enum SavedPasswordsMenu {
    private final class Target: NSObject {
        let run: (Int) -> Void
        init(_ run: @escaping (Int) -> Void) { self.run = run }
        @objc func choose(_ item: NSMenuItem) { run(item.tag) }
    }
    private static var target: Target?

    /// What the menu offers now: "unlock", "manage", or a saved password's name (for the feature tests too).
    static func entries(_ store: CredentialStore) -> [(title: String, help: String, action: String)] {
        var entries: [(String, String, String)] = []
        if store.isLocked {
            entries.append(("Unlock…", "Unlock\nEnter the Administrator Password to use your saved passwords.", "unlock"))
        } else if store.passwords.isEmpty {
            entries.append(("No Saved Passwords", "", ""))
        } else {
            for saved in store.passwords {
                entries.append((saved.name, saved.description.isEmpty ? "Type this password into the terminal." : saved.description, saved.id))
            }
        }
        entries.append(("Manage Passwords…", "Manage Passwords\nAdd, change or remove saved passwords.", "manage"))
        return entries
    }

    static func show(for workspace: Workspace) {
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        let entries = entries(store)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = Target { index in run(entries[index].action, in: workspace) }
        self.target = target
        for (index, entry) in entries.enumerated() {
            if entry.action == "manage" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            item.isEnabled = !entry.action.isEmpty
            item.toolTip = entry.help.isEmpty ? nil : entry.help
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Runs one of the menu's entries.
    static func run(_ action: String, in workspace: Workspace) {
        let store = CredentialStore.shared ?? CredentialStore.unavailable()
        switch action {
        case "unlock":
            if LoginVaultPrompts.unlock(store) { show(for: workspace) }
        case "manage": ManagePasswordsWindow.show(store)
        default:
            guard let saved = store.passwords.first(where: { $0.id == action }) else { return }
            type(saved.password, in: workspace)
        }
    }

    static func type(_ password: String, in workspace: Workspace) {
        let shell = workspace.selected.focusedShell
        shell.view.window?.makeFirstResponder(shell.view)
        shell.view.send(txt: password)
    }
}

/// Saved Passwords ▸ Manage Passwords…: the saved passwords with New, Edit and Delete.
@MainActor
enum ManagePasswordsWindow {
    private static var window: NSWindow?

    static func show(_ store: CredentialStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if store.isLocked {
            LoginVaultPrompts.unlock(store, cancelTitle: "Skip", detail: "Enter the Administrator Password to see your saved passwords.")
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ManagePasswordsView(store: store)))
        window.title = "Manage Passwords"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 360))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { Self.window = nil }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ManagePasswordsState: ObservableObject {
    @Published var selection: SavedPassword.ID?
    @Published var editing: PasswordDraft?
}

struct PasswordDraft: Identifiable {
    let id = UUID()
    let original: SavedPassword?
}

struct ManagePasswordsView: View {
    @ObservedObject var store: CredentialStore
    @StateObject private var state = ManagePasswordsState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                barButton("New", "plus", help: "New Password\nSave a name, a password and a description.") { edit(nil) }
                barButton("Edit", "pencil", help: "Edit Password\nChange the selected password.") { edit(selected) }
                    .disabled(selected == nil)
                barButton("Delete", "trash", help: "Delete Password\nRemove the selected password, after asking.") { if let selected { delete(selected) } }
                    .disabled(selected == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            if store.isLocked {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("\(store.lockedPasswordCount) saved password\(store.lockedPasswordCount == 1 ? " is" : "s are") hidden until you enter the Administrator Password.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Unlock…") { LoginVaultPrompts.unlock(store) }
                        .hint("Unlock\nEnter the Administrator Password to see and use your saved passwords.")
                }
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(.yellow.opacity(0.12))
            }
            header
            Divider()
            List(store.passwords, selection: $state.selection) { saved in row(saved).tag(saved.id) }
                .contextMenu(forSelectionType: SavedPassword.ID.self) { ids in
                    if let id = ids.first, let saved = store.passwords.first(where: { $0.id == id }) {
                        Button("Edit…") { edit(saved) }
                        Button("Delete…", role: .destructive) { delete(saved) }
                    } else {
                        Button("New Password…") { edit(nil) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(store.passwords.first { $0.id == id }) }
                }
                .onDeleteCommand { if let selected { delete(selected) } }
                .overlay {
                    if store.passwords.isEmpty {
                        Text(store.isLocked ? "Unlock to see your saved passwords." : "No saved passwords. Click New to add one.")
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 260)
        .onAppear { ManagePasswordsBridge.window = bridgeHooks }
        .onDisappear { ManagePasswordsBridge.window = nil }
        .sheet(item: $state.editing) { draft in
            PasswordEditor(draft: draft, store: store) { saved in
                state.editing = nil
                if let saved { state.selection = saved.id }
            }
        }
    }

    private var selected: SavedPassword? { state.selection.flatMap { id in store.passwords.first { $0.id == id } } }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Name").frame(width: 150, alignment: .leading)
            Text("Description").frame(maxWidth: .infinity, alignment: .leading)
            Text("Password").frame(width: 90, alignment: .leading)
            Text("Stored").frame(width: 100, alignment: .leading)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    private func row(_ saved: SavedPassword) -> some View {
        HStack(spacing: 8) {
            Text(saved.name).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(saved.description).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text("••••••••").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Group {
                if store.plainTextPasswordIDs.contains(saved.id) {
                    Label("Plain text", systemImage: "lock.open").foregroundStyle(.orange)
                } else {
                    Label("Encrypted", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, alignment: .leading)
        }
    }

    private func barButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }.hint(help)
    }

    private func edit(_ saved: SavedPassword?) {
        // Saving needs a protection choice, and an unlocked store when passwords are encrypted.
        if store.protection == .unset, !LoginVaultPrompts.explainSetup(store) { return }
        if store.isLocked, !LoginVaultPrompts.unlock(store) { return }
        state.editing = PasswordDraft(original: saved)
    }

    private func delete(_ saved: SavedPassword) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the saved password “\(saved.name)”?"
        alert.informativeText = "It's removed from Herb's Terminal. This can't be undone."
        // Cancel is the default, so Return or a stray click never deletes.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store.deletePassword(id: saved.id)
            state.selection = nil
        } catch { LoginVaultPrompts.show(error) }
    }

    /// What the feature tests' bridge reads and presses, through the same code as the window's controls.
    private var bridgeHooks: ManagePasswordsBridge.Window {
        let store = store, state = state
        return ManagePasswordsBridge.Window(
            state: {
                ["rows": store.passwords.map { saved in
                    ["name": saved.name, "description": saved.description, "password": "••••••••",
                     "stored": store.plainTextPasswordIDs.contains(saved.id) ? "Plain text" : "Encrypted",
                     "selected": state.selection == saved.id] as [String: Any]
                },
                 "locked": store.isLocked, "lockedCount": store.lockedPasswordCount, "editing": state.editing != nil]
            },
            run: { action, value in
                let all = store.passwords
                func saved(_ index: Int?) -> SavedPassword? { index.flatMap { all.indices.contains($0) ? all[$0] : nil } }
                switch action {
                case "select": state.selection = saved(value as? Int)?.id
                case "new": edit(nil)
                case "edit", "open": edit(saved(value as? Int) ?? selected)
                case "delete": if let target = saved(value as? Int) ?? selected { delete(target) }
                default: break
                }
            })
    }
}

@MainActor
private final class PasswordFields: ObservableObject {
    @Published var name = ""
    @Published var password = ""
    @Published var description = ""
    @Published var showPassword = false
    @Published var error: String?
}

private struct PasswordEditor: View {
    let draft: PasswordDraft
    let store: CredentialStore
    let done: (SavedPassword?) -> Void
    @StateObject private var fields = PasswordFields()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "New Password" : "Edit Password").font(.headline)
            Form {
                TextField("Name:", text: $fields.name)
                if fields.showPassword {
                    TextField("Password:", text: $fields.password)
                } else {
                    SecureField("Password:", text: $fields.password)
                }
                TextField("Description:", text: $fields.description, prompt: Text("Optional"))
                Toggle("Show password", isOn: $fields.showPassword)
                    .hint("Show password\nShow the password as text while you edit it.")
            }
            if let error = fields.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(store.protection == .adminPassword ? "Saved encrypted with your Administrator Password." : "Saved as plain text.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear { ManagePasswordsBridge.form = nil }
        .onAppear {
            if let original = draft.original {
                fields.name = original.name
                fields.password = original.password
                fields.description = original.description
            }
            let fields = fields
            ManagePasswordsBridge.form = ManagePasswordsBridge.Form(
                state: {
                    ["title": draft.original == nil ? "New Password" : "Edit Password", "name": fields.name, "password": fields.password,
                     "description": fields.description, "showPassword": fields.showPassword, "error": fields.error ?? ""]
                },
                run: { action, request in
                    if let value = request["name"] as? String { fields.name = value }
                    if let value = request["password"] as? String { fields.password = value }
                    if let value = request["description"] as? String { fields.description = value }
                    if let value = request["showPassword"] as? Bool { fields.showPassword = value }
                    if action == "save" { save() }
                    if action == "cancel" { done(nil) }
                })
        }
    }

    private func save() {
        let saved = SavedPassword(name: fields.name, password: fields.password,
                                  description: fields.description.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try store.savePassword(saved, replacing: draft.original?.id)
            done(saved)
        } catch {
            fields.error = error.localizedDescription
        }
    }
}

/// The Manage Passwords window and its form as the feature tests' bridge sees them.
@MainActor
enum ManagePasswordsBridge {
    struct Window {
        let state: () -> [String: Any]
        let run: (String, Any?) -> Void
    }
    struct Form {
        let state: () -> [String: Any]
        let run: (String, [String: Any]) -> Void
    }
    static var window: Window?
    static var form: Form?
}
