import SwiftUI
import HerbsTerminalUI
import UniformTypeIdentifiers

@MainActor
final class SSHConnectViewModel: ObservableObject {
    @Published var host: String = ""
    @Published var port: Int = 22
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var saveToLogins: Bool = false
    @Published var selectedSavedLoginID: SSHLogin.ID? = nil
    @Published var errorMessage: String? = nil
    @Published var showingExportConfirm: Bool = false
    @Published var noticeMessage: String? = nil

    let store: CredentialStore
    /// Set when the login database couldn't be opened; saving is then disabled, never redirected.
    let lockedReason: String? = CredentialStore.unavailableReason

    init(store: CredentialStore = .shared ?? .unavailable()) {
        self.store = store
    }

    func select(login: SSHLogin?) {
        if let login {
            selectedSavedLoginID = login.id
            host = login.host
            port = login.port
            username = login.username
            password = login.password
            saveToLogins = false
        } else {
            selectedSavedLoginID = nil
        }
    }

    func handleConnect() throws -> SSHLogin {
        let login = SSHLogin(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                             port: port,
                             username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                             password: password)
        try login.validate()

        if saveToLogins, lockedReason == nil, store.protection != .unset {
            try store.save(login)
        }

        return login
    }

    func importCSV(from url: URL, policy: ConflictPolicy = .overwrite) throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        return try store.importCSV(data, policy: policy)
    }

    func exportCSV(to url: URL) throws {
        let data = try store.exportCSV()
        // The export holds passwords: readable by this account only, from the moment it exists.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw FileIssue("Couldn't write \(url.lastPathComponent).")
        }
    }
}

/// The dialogs around the Administrator Password. They are AppKit alerts so they can stack over the sheet.
@MainActor
enum LoginVaultPrompts {
    /// The first-use explanation. Returns true once a protection has been chosen.
    @discardableResult
    static func explainSetup(_ store: CredentialStore) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Create an Administrator Password"
        alert.informativeText = """
        Herb's Terminal keeps saved logins inside the app. To encrypt them, create an Administrator Password; you'll \
        enter it once each time you open Herb's Terminal to unlock your saved logins.

        Without one, saved logins (including their passwords) are stored as plain text inside Herb's Terminal, which \
        is a security risk: anyone or anything that can read your files could read them.
        """
        alert.addButton(withTitle: "Create Administrator Password…")
        alert.addButton(withTitle: "Store as Plain Text")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1B}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return createOrModify(store)
        case .alertSecondButtonReturn:
            // The risky choice is never one click away.
            let confirm = NSAlert()
            confirm.alertStyle = .critical
            confirm.messageText = "Store saved logins as plain text?"
            confirm.informativeText = "Passwords you save will be readable by anyone or anything that can read your files. You can create an Administrator Password later in Manage Logins."
            confirm.addButton(withTitle: "Cancel")
            confirm.addButton(withTitle: "Store as Plain Text")
            guard confirm.runModal() == .alertSecondButtonReturn else { return false }
            do { try store.choosePlainText(); return true } catch { show(error); return false }
        default:
            return false
        }
    }

    /// Creates the Administrator Password, or changes it after checking the current one.
    @discardableResult
    static func createOrModify(_ store: CredentialStore) -> Bool {
        let modifying = store.protection == .adminPassword
        var message: String?
        while true {
            let alert = NSAlert()
            alert.messageText = modifying ? "Modify Administrator Password" : "Create Administrator Password"
            alert.informativeText = (message.map { $0 + "\n\n" } ?? "")
                + (modifying ? "Saved logins are re-encrypted with the new password.\n\nLeave both new password fields blank to remove the Administrator Password: saved logins are then stored as plain text, unprotected."
                             : "Saved logins will be encrypted with this password. Herb's Terminal can't recover it if you forget it; you would have to delete and re-enter your logins.")
            let current = secureField("Current password")
            let new = secureField(modifying ? "New password (blank to remove)" : "New password (at least 8 characters)")
            let confirm = secureField("Confirm new password")
            alert.accessoryView = stack(modifying ? [current, new, confirm] : [new, confirm])
            alert.window.initialFirstResponder = modifying ? current : new
            alert.addButton(withTitle: modifying ? "Change Password" : "Create Password")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            guard new.stringValue == confirm.stringValue else { message = "The new passwords don't match."; continue }
            do {
                // Saved addresses are re-encoded with whatever protection follows, so they stay readable.
                if modifying { try store.unlock(current.stringValue) }
                if modifying, new.stringValue.isEmpty {
                    guard confirmRemoval() else { continue }
                    try TailcatPeerStore.shared.reprotect { try store.removeAdminPassword(current: current.stringValue) }
                } else {
                    try TailcatPeerStore.shared.reprotect { try store.setAdminPassword(new.stringValue, current: modifying ? current.stringValue : nil) }
                }
                return true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private static func confirmRemoval() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove the Administrator Password?"
        alert.informativeText = "Saved logins, passwords included, will be stored as plain text: anyone or anything that can read your files could read them."
        // Cancel is the default, so Return never removes the protection by accident.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Password").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Asks for the Administrator Password to unlock saved logins for this session.
    @discardableResult
    static func unlock(_ store: CredentialStore, cancelTitle: String = "Cancel", detail: String? = nil) -> Bool {
        var message: String?
        while store.isLocked {
            let alert = NSAlert()
            alert.messageText = "Unlock Saved Logins"
            alert.informativeText = message ?? detail ?? "Enter the Administrator Password to use your saved logins."
            let field = secureField("Administrator Password")
            alert.accessoryView = stack([field])
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Unlock")
            alert.addButton(withTitle: cancelTitle)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            do { try store.unlock(field.stringValue) } catch { message = error.localizedDescription }
        }
        return true
    }

    /// Export writes readable passwords, so it needs the Administrator Password, or a confirmation without one.
    static func confirmExport(_ store: CredentialStore) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export Login Data?"
        alert.informativeText = "The exported file contains every saved username and password as readable plain text. Keep it somewhere safe and delete it when you're done."
        let field = secureField("Administrator Password")
        if store.protection == .adminPassword {
            alert.accessoryView = stack([field])
            alert.window.initialFirstResponder = field
        }
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard store.protection != .adminPassword || store.verify(field.stringValue) else {
            show(StoreError("That Administrator Password is not correct."))
            return false
        }
        return true
    }

    /// Import Login Data: a CSV of host,port,username,password. Returns a summary to show, or nil if cancelled.
    static func importData(_ store: CredentialStore) -> String? {
        if store.protection == .unset, !explainSetup(store) { return nil }
        if store.isLocked, !unlock(store) { return nil }
        let panel = NSOpenPanel()
        panel.title = "Import Login Data"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let summary = try store.importCSV(try Data(contentsOf: url), policy: .overwrite)
            return "Import completed: \(summary.added) added, \(summary.updated) updated, \(summary.skipped) skipped."
        } catch {
            show(error)
            return nil
        }
    }

    /// Export Login Data, after the Administrator Password (or a plain-text confirmation): the logins in `ids`.
    static func exportData(_ store: CredentialStore, only ids: Set<SSHLogin.ID>) -> String? {
        guard !ids.isEmpty else { return nil }
        guard confirmExport(store) else { return nil }
        let panel = NSSavePanel()
        panel.title = "Export Login Data"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "logins_export.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try store.exportCSV(only: ids)
            // The export holds passwords: readable by this account only, from the moment it exists.
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw FileIssue("Couldn't write \(url.lastPathComponent).")
            }
            return "\(ids.count) login\(ids.count == 1 ? "" : "s") exported. The file contains readable passwords; delete it when you're done."
        } catch {
            show(error)
            return nil
        }
    }

    static func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private static func secureField(_ label: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: 24))
        field.placeholderString = label
        field.setAccessibilityLabel(label)
        return field
    }

    private static let fieldWidth: CGFloat = 260

    /// Each field under its own label, laid out by frame: an alert's accessory view gets no Auto Layout
    /// sizing, so a stack view there squeezed the fields down to slivers.
    private static func stack(_ fields: [NSSecureTextField]) -> NSView {
        let row: CGFloat = 46
        let view = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: CGFloat(fields.count) * row - 6))
        for (index, field) in fields.enumerated() {
            let top = view.frame.height - CGFloat(index) * row
            let label = NSTextField(labelWithString: field.placeholderString ?? "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: top - 16, width: fieldWidth, height: 16)
            field.frame = NSRect(x: 0, y: top - 40, width: fieldWidth, height: 24)
            view.addSubview(label)
            view.addSubview(field)
        }
        // Tab moves down the fields in order.
        for (field, next) in zip(fields, fields.dropFirst()) { field.nextKeyView = next }
        return view
    }
}

struct SSHConnectView: View {
    @ObservedObject var viewModel: SSHConnectViewModel
    @ObservedObject private var observedStore: CredentialStore
    let onConnect: (SSHLogin) -> Void
    let onDismiss: () -> Void

    init(viewModel: SSHConnectViewModel, onConnect: @escaping (SSHLogin) -> Void, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.observedStore = viewModel.store
        self.onConnect = onConnect
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect via SSH")
                .font(.headline)

            if !viewModel.store.logins.isEmpty {
                Picker("Saved Logins", selection: Binding(
                    get: { viewModel.selectedSavedLoginID },
                    set: { id in
                        if let id, let found = viewModel.store.get(id: id) {
                            viewModel.select(login: found)
                        } else {
                            viewModel.select(login: nil)
                        }
                    }
                )) {
                    Text("Manual Entry").tag(nil as SSHLogin.ID?)
                    ForEach(viewModel.store.logins) { item in
                        Text(item.label).tag(item.id as SSHLogin.ID?)
                    }
                }
                .hint("Saved Logins\nFill in host, port, username and password from a login saved in Herb's Terminal.")
            }

            if let reason = viewModel.lockedReason {
                notice("exclamationmark.triangle.fill", "Saved logins are unavailable: \(reason)")
            }
            if store.isLocked {
                HStack {
                    notice("lock.fill", "Saved logins are locked with your Administrator Password.")
                    Button("Unlock…") { LoginVaultPrompts.unlock(store) }
                        .hint("Unlock\nEnter the Administrator Password to use saved logins this session.")
                }
            } else if store.protection == .plainText {
                notice("lock.open.fill", "Saved logins are stored as plain text. Create an Administrator Password in Manage Logins to encrypt them.")
            }
            if store.legacyCount > 0 {
                HStack {
                    notice("key.fill", "\(store.legacyCount) login\(store.legacyCount == 1 ? "" : "s") saved by an earlier version can't be read anymore. Re-enter them, then discard the old copies.")
                    Button("Discard…") { discardLegacy() }
                        .hint("Discard\nPermanently delete the unreadable old logins.")
                }
            }

            Form {
                TextField("Host or IP Address:", text: $viewModel.host)
                    .textFieldStyle(.roundedBorder)
                    .hint("Host\nThe server's name, IP address or ~/.ssh/config alias.")

                HStack {
                    TextField("Port:", value: $viewModel.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .hint("Port\nThe server's SSH port; usually 22.")
                    Spacer()
                }

                TextField("Username:", text: $viewModel.username)
                    .textFieldStyle(.roundedBorder)
                    .hint("Username\nThe account to sign in as on the server.")

                SecureField("Password:", text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
                    .hint("Password\nLeave empty to use your SSH keys or agent.")

                Toggle(store.protection == .plainText ? "Save credentials (plain text, not encrypted)"
                       : store.protection == .adminPassword ? "Save credentials (encrypted with Administrator Password)"
                       : "Save credentials in Herb's Terminal",
                       isOn: $viewModel.saveToLogins)
                    .disabled(viewModel.lockedReason != nil || store.isLocked)
                    .padding(.top, 4)
                    .hint(store.protection == .plainText ? "Save credentials\nKeep this login inside Herb's Terminal as plain text."
                                                         : "Save credentials\nKeep this login inside Herb's Terminal, encrypted with your Administrator Password.")
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Manage Logins…") { ManageLoginsWindow.show(store) }
                .disabled(viewModel.lockedReason != nil)
                .hint("Manage Logins\nSee, add and edit saved logins, import or export them, and set the Administrator Password.")

                Spacer()

                Button("Cancel", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hint("Cancel (Esc)\nClose without connecting.")

                Button("Connect") {
                    // First SSH use with saving on: explain protection before anything is written.
                    if viewModel.saveToLogins, store.protection == .unset, !LoginVaultPrompts.explainSetup(store) {
                        viewModel.saveToLogins = false
                    }
                    do {
                        let login = try viewModel.handleConnect()
                        viewModel.errorMessage = nil
                        onConnect(login)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .hint("Connect (Return)\nOpen the remote shell in this tab; the explorer follows the host.")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            // The first time SSH is used, explain the Administrator Password; later, offer to unlock.
            DispatchQueue.main.async {
                if store.protection == .unset { LoginVaultPrompts.explainSetup(store) }
                else if store.isLocked { LoginVaultPrompts.unlock(store) }
            }
        }
        .alert("Notice", isPresented: Binding(
            get: { viewModel.noticeMessage != nil },
            set: { if !$0 { viewModel.noticeMessage = nil } }
        )) {
            Button("OK") { viewModel.noticeMessage = nil }
        } message: {
            Text(viewModel.noticeMessage ?? "")
        }
    }

    private var store: CredentialStore { viewModel.store }

    private func notice(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func discardLegacy() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(store.legacyCount) old saved login\(store.legacyCount == 1 ? "" : "s")?"
        alert.informativeText = "They were encrypted with a key this version no longer has, so they can't be read. This can't be undone."
        // Cancel is the default, so Return or a stray click never deletes.
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.discardLegacy() } catch { viewModel.errorMessage = error.localizedDescription }
    }

}
