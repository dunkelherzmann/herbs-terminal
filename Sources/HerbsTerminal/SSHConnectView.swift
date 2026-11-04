import SwiftUI
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

    init(store: CredentialStore = .shared ?? (try! CredentialStore(databaseURL: URL(fileURLWithPath: "/tmp/fallback.db"), vault: CryptoVault(keyProvider: StaticKeyProvider(key: .init(size: .bits256)))))) {
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

        if saveToLogins {
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
        try data.write(to: url, options: .atomic)
    }
}

struct SSHConnectView: View {
    @ObservedObject var viewModel: SSHConnectViewModel
    let onConnect: (SSHLogin) -> Void
    let onDismiss: () -> Void

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
            }

            Form {
                TextField("Host or IP Address:", text: $viewModel.host)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Port:", value: $viewModel.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                }

                TextField("Username:", text: $viewModel.username)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password:", text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)

                Toggle("Save credentials to encrypted store", isOn: $viewModel.saveToLogins)
                    .padding(.top, 4)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Menu("CSV Logins") {
                    Button("Import CSV…") { importCSV() }
                    Button("Export CSV…") { viewModel.showingExportConfirm = true }
                }

                Spacer()

                Button("Cancel", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Connect") {
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
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .confirmationDialog("Export Plaintext Passwords?", isPresented: $viewModel.showingExportConfirm) {
            Button("Export CSV", role: .destructive) { exportCSV() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Exporting credentials will save all usernames and passwords as unencrypted plaintext in the CSV file.")
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

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.title = "Import SSH Logins CSV"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let summary = try viewModel.importCSV(from: url, policy: .overwrite)
            viewModel.noticeMessage = "Import completed: \(summary.added) added, \(summary.updated) updated, \(summary.skipped) skipped."
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export SSH Logins CSV"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "herbsterminal_logins.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try viewModel.exportCSV(to: url)
            viewModel.noticeMessage = "Credentials exported successfully."
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
