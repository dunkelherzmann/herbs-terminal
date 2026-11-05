import SwiftUI
import HerbsTerminalUI

/// Connect via SSH ▸ Manage Logins…: a window listing the saved logins, with New, Edit, Import, Export and
/// the Administrator Password along the top. Opening it asks for the Administrator Password when one is set;
/// skipping that still shows the logins stored as plain text.
@MainActor
enum ManageLoginsWindow {
    private static var window: NSWindow?

    static func show(_ store: CredentialStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if store.protection == .unset { LoginVaultPrompts.explainSetup(store) }
        if store.isLocked {
            LoginVaultPrompts.unlock(store, cancelTitle: "Skip",
                                     detail: "Enter the Administrator Password to see your encrypted logins. Skip to see only logins stored as plain text.")
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ManageLoginsView(store: store)))
        window.title = "Manage Logins"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 420))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { Self.window = nil }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// The window's own state; `@State` isn't available in this package's build, so it lives here.
@MainActor
final class ManageLoginsState: ObservableObject {
    @Published var selection: SSHLogin.ID?
    @Published var editing: LoginDraft?
    @Published var notice: String?
    /// Logins ticked for Export.
    @Published var checked: Set<SSHLogin.ID> = []
}

struct ManageLoginsView: View {
    @ObservedObject var store: CredentialStore
    @StateObject private var state = ManageLoginsState()
    private var selection: SSHLogin.ID? { state.selection }
    private var notice: String? { state.notice }

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            Divider()
            if let reason = CredentialStore.unavailableReason {
                banner("exclamationmark.triangle.fill", "Saved logins are unavailable: \(reason)")
            }
            if store.isLocked {
                banner("lock.fill", "\(store.lockedCount) encrypted login\(store.lockedCount == 1 ? " is" : "s are") hidden until you enter the Administrator Password.") {
                    Button("Unlock…") { LoginVaultPrompts.unlock(store) }
                        .hint("Unlock\nEnter the Administrator Password to see and use your encrypted logins.")
                }
            } else if store.protection == .plainText {
                banner("lock.open.fill", "Logins are stored as plain text. Create an Administrator Password to encrypt them.")
            }
            table
            if let notice {
                Divider()
                HStack {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("OK") { state.notice = nil }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 640, minHeight: 300)
        .sheet(item: $state.editing) { (draft: LoginDraft) in
            LoginEditor(draft: draft, store: store) { saved in
                state.editing = nil
                if let saved { state.selection = saved.id }
            }
        }
    }

    private var menuBar: some View {
        HStack(spacing: 2) {
            barButton("New", "plus", help: "New Login\nSave a host, port, username and password.") { edit(nil) }
            barButton("Edit", "pencil", help: "Edit Login\nChange the selected login.") { edit(selectedLogin) }
                .disabled(selectedLogin == nil)
            Divider().frame(height: 16).padding(.horizontal, 4)
            barButton("Import", "square.and.arrow.down", help: "Import Login Data\nAdd logins from a CSV file (host,port,username,password).") {
                state.notice = LoginVaultPrompts.importData(store) ?? state.notice
            }
            barButton(exportTitle, "square.and.arrow.up", help: "Export Login Data\nSave the ticked logins, passwords included, to a CSV file. Tick them in the first column, or all at once in its heading.") {
                state.notice = LoginVaultPrompts.exportData(store, only: checkedIDs) ?? state.notice
            }
            .disabled(checkedIDs.isEmpty)
            Divider().frame(height: 16).padding(.horizontal, 4)
            barButton(store.protection == .adminPassword ? "Modify Administrator Password" : "Create Administrator Password", "key",
                      help: store.protection == .adminPassword ? "Modify Administrator Password\nChange the password that encrypts saved logins."
                                                               : "Create Administrator Password\nEncrypt saved logins with a password only you know.") {
                if LoginVaultPrompts.createOrModify(store) {
                    state.notice = store.protection == .adminPassword ? "Saved logins are encrypted with your Administrator Password." : state.notice
                }
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.bar)
    }

    private func barButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
            .hint(help)
    }

    /// Ticked logins that are still listed.
    private var checkedIDs: Set<SSHLogin.ID> { state.checked.intersection(store.logins.map(\.id)) }
    private var exportTitle: String { checkedIDs.isEmpty ? "Export" : "Export (\(checkedIDs.count))" }
    private var allChecked: Bool { !store.logins.isEmpty && checkedIDs.count == store.logins.count }

    private enum Width {
        static let check: CGFloat = 22, port: CGFloat = 52, username: CGFloat = 120, password: CGFloat = 90, stored: CGFloat = 100
    }

    /// The column headings. The first column holds the Export checkboxes: the box in the heading ticks them all.
    private var header: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { allChecked },
                                     set: { state.checked = $0 ? Set(store.logins.map(\.id)) : [] }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(store.logins.isEmpty)
                .frame(width: Width.check)
                .accessibilityLabel("Tick all logins for export")
                .hint("All logins\nTick or untick every login for Export.")
            Text("Host").frame(maxWidth: .infinity, alignment: .leading)
            Text("Port").frame(width: Width.port, alignment: .leading)
            Text("Username").frame(width: Width.username, alignment: .leading)
            Text("Password").frame(width: Width.password, alignment: .leading)
            Text("Stored").frame(width: Width.stored, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    private func row(_ login: SSHLogin) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { state.checked.contains(login.id) },
                                     set: { if $0 { state.checked.insert(login.id) } else { state.checked.remove(login.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: Width.check)
                .accessibilityLabel("Export \(login.label)")
            Text(login.host).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(login.port)).monospacedDigit().frame(width: Width.port, alignment: .leading)
            Text(login.username).lineLimit(1).frame(width: Width.username, alignment: .leading)
            Text(login.password.isEmpty ? "None (keys)" : "••••••••").foregroundStyle(.secondary).frame(width: Width.password, alignment: .leading)
            Group {
                if store.plainTextIDs.contains(login.id) {
                    Label("Plain text", systemImage: "lock.open").foregroundStyle(.orange)
                } else {
                    Label("Encrypted", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: Width.stored, alignment: .leading)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(store.logins, selection: $state.selection) { login in
                row(login).tag(login.id)
            }
            .contextMenu(forSelectionType: SSHLogin.ID.self) { ids in
                if let id = ids.first, let login = store.get(id: id) {
                    Button("Edit…") { edit(login) }
                    Button("Delete…", role: .destructive) { delete(login) }
                } else {
                    Button("New Login…") { edit(nil) }
                }
            } primaryAction: { ids in
                if let id = ids.first { edit(store.get(id: id)) }
            }
            .onDeleteCommand { if let selectedLogin { delete(selectedLogin) } }
            .overlay {
                if store.logins.isEmpty {
                    Text(store.isLocked ? "No plain-text logins. Unlock to see encrypted ones." : "No saved logins. Click New or Import to add some.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectedLogin: SSHLogin? { selection.flatMap(store.get(id:)) }

    private func edit(_ login: SSHLogin?) {
        // Saving needs a protection choice, and an unlocked store when logins are encrypted.
        if store.protection == .unset, !LoginVaultPrompts.explainSetup(store) { return }
        if store.isLocked, !LoginVaultPrompts.unlock(store) { return }
        state.editing = LoginDraft(original: login)
    }

    private func delete(_ login: SSHLogin) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the login for \(login.label)?"
        alert.informativeText = "Its saved password is removed from Herb's Terminal. This can't be undone."
        // Cancel is the default, so Return or a stray click never deletes.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store.delete(id: login.id)
            state.selection = nil
        } catch { LoginVaultPrompts.show(error) }
    }

    private func banner<Accessory: View>(_ symbol: String, _ text: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            accessory()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.yellow.opacity(0.12))
    }
}

/// What New and Edit change; `original` is the login being edited, nil for a new one.
struct LoginDraft: Identifiable {
    let id = UUID()
    let original: SSHLogin?
}

@MainActor
private final class LoginFields: ObservableObject {
    @Published var host = ""
    @Published var port = 22
    @Published var username = ""
    @Published var password = ""
    @Published var error: String?
    @Published var showPassword = false
}

private struct LoginEditor: View {
    let draft: LoginDraft
    let store: CredentialStore
    let done: (SSHLogin?) -> Void
    @StateObject private var fields = LoginFields()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "New Login" : "Edit Login").font(.headline)
            Form {
                TextField("Host or IP Address:", text: $fields.host)
                TextField("Port:", value: $fields.port, format: .number.grouping(.never)).frame(width: 160)
                TextField("Username:", text: $fields.username)
                if fields.showPassword {
                    TextField("Password:", text: $fields.password, prompt: Text("Empty to use SSH keys"))
                } else {
                    SecureField("Password:", text: $fields.password, prompt: Text("Empty to use SSH keys"))
                }
                // Readable only when nothing is hidden: plain-text logins, or once the Administrator Password was given.
                if store.protection != .adminPassword || !store.isLocked {
                    Toggle("Show password", isOn: $fields.showPassword)
                        .hint("Show password\nShow the stored password as text while you edit it.")
                }
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
        .onAppear {
            guard let original = draft.original else { return }
            fields.host = original.host
            fields.port = original.port
            fields.username = original.username
            fields.password = original.password
        }
    }

    private func save() {
        let login = SSHLogin(host: fields.host.trimmingCharacters(in: .whitespacesAndNewlines), port: fields.port,
                             username: fields.username.trimmingCharacters(in: .whitespacesAndNewlines), password: fields.password)
        do {
            try store.save(login)
            // A changed host, port or username is a different login: the old entry goes.
            if let original = draft.original, original.id != login.id { try store.delete(id: original.id) }
            done(login)
        } catch {
            fields.error = error.localizedDescription
        }
    }
}
