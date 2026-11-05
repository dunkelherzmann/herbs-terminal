import AppKit
import SwiftUI
import HerbsTerminalUI

/// A machine reached over Tailcat. Its address is a bearer secret, so it is protected like saved logins
/// (encrypted with the Administrator Password when one is set) and only handed to tailcat on connect.
struct TailcatPeer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var username: String
    var port = 22
    /// One-time peers come from an ephemeral `tailcat serve` and stop working when it exits.
    var persistent: Bool
    var secret: Data
}

enum TailcatRoute: Equatable {
    case unknown, checking, direct(String), relayed(String), unreachable(String)
}

enum Tailcat {
    /// The copy bundled in Herb's Terminal.app/Contents/Helpers. Copies on PATH or from Homebrew are never used,
    /// so behaviour doesn't change with whatever else is installed. Unbundled development builds and tests
    /// use the same pinned binary from the repository's Vendor folder.
    static let executable: String? = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tailcat").path
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Vendor/tailcat/tailcat").standardizedFileURL.path
        return [bundled, vendored].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Reads a ping report such as "pong in 42.1ms via DERP(sfo)" or "pong in 1.2ms via 203.0.113.7:41641".
    static func route(fromPing output: String) -> TailcatRoute {
        let pongs = output.split(separator: "\n").filter { $0.hasPrefix("pong") }
        guard let last = pongs.last.map(String.init) else {
            let reason = output.split(separator: "\n").last.map(String.init) ?? "No reply."
            return .unreachable(reason.isEmpty ? "No reply." : reason)
        }
        let latency = last.range(of: #"in [0-9.]+ ?[mµ]?s"#, options: .regularExpression).map { String(last[$0].dropFirst(3)) } ?? ""
        if pongs.contains(where: { !$0.contains("DERP") }) {
            let path = pongs.last { !$0.contains("DERP") }.flatMap { $0.components(separatedBy: "via ").last } ?? ""
            return .direct("\(latency) via \(path)")
        }
        let relay = last.components(separatedBy: "via ").last ?? "DERP"
        return .relayed("\(latency) via \(relay)")
    }
}

@MainActor
final class TailcatPeerStore: ObservableObject {
    static let shared = TailcatPeerStore()

    @Published private(set) var peers: [TailcatPeer] = []
    @Published var routes: [UUID: TailcatRoute] = [:]
    @Published var error: String?
    private let file: URL
    private let secrets: CredentialStore?

    init(file: URL? = nil, secrets: CredentialStore? = CredentialStore.shared) {
        self.secrets = secrets
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerbsTerminal/tailcat-peers.json")
        if let data = try? Data(contentsOf: self.file) {
            if let decoded = try? JSONDecoder().decode([TailcatPeer].self, from: data) {
                peers = decoded
            } else {
                // The next save would replace it; set the unreadable file aside instead.
                let aside = self.file.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: self.file, to: aside)
                NSLog("Herb's Terminal: saved Tailcat peers couldn't be read; kept at \(aside.lastPathComponent).")
            }
        }
    }

    /// Saved addresses follow a change of login protection: they are read with the old key, `change` runs,
    /// and they are written again with the new one (or as plain text).
    func reprotect(_ change: () throws -> Void) throws {
        guard let secrets, !peers.isEmpty else { try change(); return }
        let addresses = try peers.map { try secrets.reveal($0.secret) }
        try change()
        for index in peers.indices { peers[index].secret = try secrets.protect(addresses[index]) }
        try save()
    }

    func add(name: String, username: String, address: String, persistent: Bool) throws {
        let name = name.trimmingCharacters(in: .whitespaces), address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !username.isEmpty, !address.isEmpty else { throw FileIssue("Enter a name, a username and the peer's tailcat address.") }
        guard !address.contains(where: \.isWhitespace) else { throw FileIssue("A tailcat address has no spaces.") }
        guard let secrets else { throw FileIssue("Herb's Terminal's login store is unavailable.") }
        peers.append(TailcatPeer(name: name, username: username, persistent: persistent, secret: try secrets.protect(address)))
        try save()
    }

    /// Forgets the peer and its address here. A persistent peer's own server keeps accepting the address
    /// until it is stopped or its key is rotated there.
    func remove(_ peer: TailcatPeer) throws {
        peers.removeAll { $0.id == peer.id }
        routes[peer.id] = nil
        try save()
    }

    func address(of peer: TailcatPeer) throws -> String {
        guard let secrets else { throw FileIssue("Herb's Terminal's login store is unavailable.") }
        return try secrets.reveal(peer.secret)
    }

    /// An endpoint whose ProxyCommand is Herb's Terminal's helper, which redeems a one-time token for the address
    /// and becomes the bundled tailcat. The address never appears in ssh's arguments or the shell history.
    func endpoint(for peer: TailcatPeer) throws -> RemoteEndpoint {
        guard Tailcat.executable != nil else { throw FileIssue("This Herb's Terminal build is missing its bundled tailcat helper.") }
        guard let broker = AskpassBroker.shared else { throw FileIssue("The Herb's Terminal secret helper is unavailable.") }
        let token = broker.issue(try address(of: peer))
        let proxy = "HERBSTERMINAL_HELPER=tailcat-proxy HERBSTERMINAL_SECRET_TOKEN=\(token) HERBSTERMINAL_SECRET_SOCKET=\(shellQuote(broker.socketPath)) "
            + "\(shellQuote(broker.helperPath)) %p"
        return RemoteEndpoint(host: "tailcat-" + peer.name.filter { $0.isLetter || $0.isNumber || $0 == "-" },
                              port: peer.port, username: peer.username, proxyCommand: proxy)
    }

    func ping(_ peer: TailcatPeer) async {
        guard let tailcat = Tailcat.executable else { routes[peer.id] = .unreachable("Bundled tailcat helper missing."); return }
        routes[peer.id] = .checking
        do {
            let address = try address(of: peer)
            let output = await Task.detached { () -> String in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tailcat)
                process.arguments = ["ping", "--until-direct", "--timeout=8s", address]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                guard (try? process.run()) != nil else { return "Could not start tailcat." }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }.value
            routes[peer.id] = Tailcat.route(fromPing: output)
        } catch {
            routes[peer.id] = .unreachable(error.localizedDescription)
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(peers).write(to: file, options: [.atomic, .completeFileProtection])
        chmod(file.path, 0o600)
    }
}

/// Shares this Mac's SSH service (Remote Login) over Tailcat, for a peer to add as its own Tailcat peer.
@MainActor
final class TailcatShare: ObservableObject {
    static let shared = TailcatShare()
    @Published private(set) var address: String?
    @Published private(set) var persistent = false
    @Published private(set) var starting = false
    @Published var error: String?
    private var process: Process?

    var isSharing: Bool { process?.isRunning == true }

    func start(persistent: Bool) async {
        guard let tailcat = Tailcat.executable else { error = "This Herb's Terminal build is missing its bundled tailcat helper."; return }
        stop()
        starting = true
        defer { starting = false }
        self.persistent = persistent
        let addressFile = SSHControl.directory.appendingPathComponent("share-\(UUID().uuidString).addr")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailcat)
        // One-time pairing uses a fresh key that dies with this server; persistent uses the saved
        // "default" server key, created on first use, so the address survives restarts.
        if persistent { await Self.ensureDefaultKey(tailcat) }
        process.arguments = (persistent ? ["serve"] : ["serve", "--key=new"]) + ["22"]
        var environment = ProcessInfo.processInfo.environment
        environment["TAILCAT_ADDR_FILE"] = addressFile.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { self.error = error.localizedDescription; return }
        self.process = process
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if let text = try? String(contentsOf: addressFile, encoding: .utf8), !text.isEmpty {
                address = text.trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: addressFile)
                return
            }
            if !process.isRunning { break }
        }
        try? FileManager.default.removeItem(at: addressFile)
        stop()
        error = "tailcat didn't report an address. Check that it can reach the internet."
    }

    func stop() {
        process?.terminate()
        process = nil
        address = nil
    }

    private nonisolated static func ensureDefaultKey(_ tailcat: String) async {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: tailcat)
        list.arguments = ["genkey", "--list"]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return }
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        guard !names.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("default") }) else { return }
        let create = Process()
        create.executableURL = URL(fileURLWithPath: tailcat)
        create.arguments = ["genkey", "--key=default"]
        create.standardOutput = FileHandle.nullDevice
        create.standardError = FileHandle.nullDevice
        try? create.run()
        create.waitUntilExit()
    }
}

/// What's typed in Tailcat Peers. Nothing here is kept: the panel starts empty each time it opens.
@MainActor
final class TailcatForm: ObservableObject {
    @Published var name = ""
    @Published var username = ""
    @Published var address = ""
    @Published var persistent = false
    @Published var sharePersistent = false

    func clear() {
        name = ""
        username = ""
        address = ""
        persistent = false
        sharePersistent = false
    }
}

struct TailcatPeersView: View {
    @ObservedObject var store: TailcatPeerStore
    @ObservedObject var share: TailcatShare
    @StateObject private var form = TailcatForm()
    let connect: (TailcatPeer) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tailcat Peers").font(.headline)
            if Tailcat.executable == nil {
                Text("This build is missing its bundled tailcat helper; rebuild Herb's Terminal with script/build_and_run.sh.")
                    .foregroundStyle(.red)
            }
            Text("Reach machines that can't see each other by IP. Each peer runs `tailcat serve 22`; paste the address it prints. Addresses are secrets; they are encrypted with your Administrator Password when one is set.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if store.peers.isEmpty {
                Text("No peers yet.").foregroundStyle(.secondary)
            } else {
                ForEach(store.peers) { peer in peerRow(peer) }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }

            GroupBox("Accept a pairing") {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Name", text: $form.name).frame(width: 130)
                            .hint("Name\nHow this peer appears in Herb's Terminal.")
                        TextField("Username", text: $form.username).frame(width: 120)
                            .hint("Username\nThe SSH account to sign in as on the peer.")
                        SecureField("Tailcat address", text: $form.address)
                            .hint("Tailcat address\nThe secret address the peer's `tailcat serve` printed.")
                    }
                    HStack {
                        Picker("", selection: $form.persistent) {
                            Text("One-time").tag(false)
                            Text("Persistent").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                        .hint("Pairing type\nOne-time: the address dies when its server stops. Persistent: the peer keeps a saved server key.")
                        Spacer()
                        Button("Add Peer") {
                            do {
                                try store.add(name: form.name, username: form.username, address: form.address, persistent: form.persistent)
                                form.clear(); store.error = nil
                            } catch { store.error = error.localizedDescription }
                        }
                        .hint("Add Peer\nSave this peer so you can ping and connect to it.")
                    }
                }
                .padding(4)
            }

            GroupBox("Share this Mac") {
                VStack(alignment: .leading, spacing: 6) {
                    if let address = share.address {
                        Text("Sharing SSH (Remote Login) \(share.persistent ? "persistently" : "one-time"). Give this secret address only to the peer:")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(address).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                            }
                            .hint("Copy\nCopy the address to send to your peer over a private channel.")
                            Button("Stop Sharing") { share.stop() }
                                .hint("Stop Sharing\nShut down this Mac's tailcat server; peers can no longer connect.")
                        }
                    } else {
                        HStack {
                            Picker("", selection: $form.sharePersistent) {
                                Text("One-time").tag(false)
                                Text("Persistent").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                            .hint("Sharing type\nOne-time uses a fresh key; persistent keeps the same address across restarts.")
                            Spacer()
                            if share.starting { ProgressView().controlSize(.small) }
                            Button("Start Sharing") { Task { await share.start(persistent: form.sharePersistent) } }
                                .disabled(Tailcat.executable == nil || share.starting)
                                .hint("Start Sharing\nRun a tailcat server for this Mac's port 22. Requires Remote Login in System Settings ▸ General ▸ Sharing.")
                        }
                    }
                    if let error = share.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
                    .hint("Done (Esc)\nClose this panel. Sharing keeps running until you stop it or quit Herb's Terminal.")
            }
        }
        .padding(20)
        .frame(width: 600)
        // Typed but unsaved values never come back the next time the panel opens.
        .onAppear { form.clear() }
        .onDisappear { form.clear() }
    }

    private func peerRow(_ peer: TailcatPeer) -> some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            VStack(alignment: .leading) {
                Text("\(peer.username)@\(peer.name)").font(.callout.weight(.semibold))
                Text((peer.persistent ? "Persistent" : "One-time") + " · " + routeText(store.routes[peer.id] ?? .unknown))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ping") { Task { await store.ping(peer) } }
                .hint("Ping\nCheck the peer is reachable and whether the route is Direct or Relayed.")
            Button("Connect") { connect(peer) }
                .hint("Connect\nOpen an SSH shell to this peer in the current tab; the explorer follows it.")
            Button("Remove", role: .destructive) {
                do { try store.remove(peer) } catch { store.error = error.localizedDescription }
            }
            .hint("Remove\nForget this peer and its address here. Stop or re-key the peer's server to revoke it there too.")
        }
    }

    private func routeText(_ route: TailcatRoute) -> String {
        switch route {
        case .unknown: "Route not checked"
        case .checking: "Checking route…"
        case .direct(let detail): "Direct · \(detail)"
        case .relayed(let detail): "Relayed · \(detail)"
        case .unreachable(let reason): "Unreachable · \(reason)"
        }
    }
}
