import Foundation
import Glibc

// MARK: Run Command on Hosts

/// One destination for a multi-host command: a saved login, or the tab's live connection.
struct HostTarget: Hashable {
    let endpoint: RemoteEndpoint
    let password: String?
    let source: String
    var id: String { "\(endpoint.username)@\(endpoint.host):\(endpoint.port)" }

    static func == (a: HostTarget, b: HostTarget) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HostResult {
    enum Outcome: Equatable { case running, succeeded, failed(Int32), notReached(String), cancelled }
    let target: HostTarget
    var outcome: Outcome = .running
    var output = ""
    var seconds: Double = 0
    var id: String { target.id }
}

/// Runs the same command on several hosts at once, each over its own non-interactive ssh channel. It never types
/// into interactive sessions, never retries, and reports every host on its own.
@MainActor
final class MultiHostModel: ObservableObject {
    @Published var command = ""
    @Published var selected = Set<String>()
    @Published private(set) var results: [HostResult] = []
    @Published private(set) var running = false
    private var processes: [String: Process] = [:]

    nonisolated static let outputLimit = 64 * 1024

    func run(_ targets: [HostTarget]) async {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !targets.isEmpty else { return }
        running = true
        results = targets.map { HostResult(target: $0) }
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                let process = Self.makeProcess(target, command: command)
                processes[target.id] = process
                group.addTask { [weak self] in
                    let result = await Self.execute(process, target: target)
                    await self?.finish(result)
                }
            }
        }
        processes = [:]
        running = false
    }

    func cancel() {
        for (id, process) in processes where process.isRunning {
            process.terminate()
            if let index = results.firstIndex(where: { $0.id == id }) { results[index].outcome = .cancelled }
        }
    }

    private func finish(_ result: HostResult) {
        guard let index = results.firstIndex(where: { $0.id == result.id }) else { return }
        if results[index].outcome == .cancelled { results[index].output = result.output; return }
        results[index] = result
    }

    nonisolated static func makeProcess(_ target: HostTarget, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -T: no terminal, so nothing waits at a prompt. Unknown host keys are refused, not accepted.
        process.arguments = target.endpoint.sshArguments([
            "-T", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1",
        ]) + [command]
        var environment = ProcessInfo.processInfo.environment
        if let password = target.password, !password.isEmpty, let broker = AskpassBroker.shared {
            environment.merge(broker.environment(token: broker.issue(password, for: SSHControl.passwordLogins(target.endpoint)))) { $1 }
        } else {
            environment["SSH_ASKPASS_REQUIRE"] = "never"
            environment["SSH_ASKPASS"] = nil
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    nonisolated static func execute(_ process: Process, target: HostTarget) async -> HostResult {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started = Date()
        var result = HostResult(target: target)
        do { try process.run() } catch {
            result.outcome = .notReached(error.localizedDescription)
            return result
        }
        // Only the first `outputLimit` bytes are kept; the rest is read and dropped.
        let (data, truncated) = await Task.detached { () -> (Data, Bool) in
            var kept = Data(), dropped = false
            let handle = pipe.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                let room = outputLimit - kept.count
                if room > 0 { kept.append(chunk.prefix(room)) }
                if chunk.count > room { dropped = true }
            }
            return (kept, dropped)
        }.value
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); done.resume() }
        }
        result.seconds = Date().timeIntervalSince(started)
        result.output = String(decoding: data, as: UTF8.self)
        if truncated { result.output += "\n… output truncated" }
        let status = process.terminationStatus
        if process.terminationReason == .uncaughtSignal {
            result.outcome = .cancelled
        } else if status == 0 {
            result.outcome = .succeeded
        } else if status == 255 {
            let reason = result.output.split(separator: "\n").last.map(String.init) ?? "ssh could not connect."
            result.outcome = .notReached(reason)
        } else {
            result.outcome = .failed(status)
        }
        return result
    }
}

// MARK: Tailcat

/// A machine reached over Tailcat. Its address is a bearer secret, so it is protected like saved logins and only
/// handed to tailcat on connect.
struct TailcatPeer: Codable, Equatable {
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
    /// The copy bundled with the app (/app/bin in the Flatpak, next to the executable in a development build).
    /// Copies on PATH are never used, so behaviour doesn't change with whatever else is installed.
    static let executable: String? = {
        let beside = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("tailcat").path
        return ["/app/bin/tailcat", beside].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Reads a ping report such as "pong in 42.1ms via DERP(sfo)" or "pong in 1.2ms via 203.0.113.7:41641".
    static func route(fromPing output: String) -> TailcatRoute {
        let pongs = output.split(separator: "\n").filter { $0.hasPrefix("pong") }
        guard let last = pongs.last.map(String.init) else {
            let reason = output.split(separator: "\n").last.map(String.init) ?? "No reply."
            return .unreachable(reason.isEmpty ? "No reply." : reason)
        }
        let latency = last.components(separatedBy: " ").dropFirst(2).first ?? ""
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

    init(file: URL? = nil, secrets: CredentialStore? = nil) {
        self.secrets = secrets ?? CredentialStore.shared
        self.file = file ?? AppFolders.support().appendingPathComponent("tailcat-peers.json")
        if let data = try? Data(contentsOf: self.file) {
            if let decoded = try? JSONDecoder().decode([TailcatPeer].self, from: data) {
                peers = decoded
            } else {
                let aside = self.file.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: self.file, to: aside)
            }
        }
    }

    /// Saved addresses follow a change of login protection: read with the old key, `change` runs, and they are
    /// written again with the new one (or as plain text).
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

    func remove(_ peer: TailcatPeer) throws {
        peers.removeAll { $0.id == peer.id }
        routes[peer.id] = nil
        try save()
    }

    func address(of peer: TailcatPeer) throws -> String {
        guard let secrets else { throw FileIssue("Herb's Terminal's login store is unavailable.") }
        return try secrets.reveal(peer.secret)
    }

    /// An endpoint whose ProxyCommand is this app's helper, which redeems a one-time token for the address and
    /// becomes the bundled tailcat. The address never appears in ssh's arguments or the shell history.
    func endpoint(for peer: TailcatPeer) throws -> RemoteEndpoint {
        guard Tailcat.executable != nil else { throw FileIssue("This Herb's Terminal build is missing its bundled tailcat helper.") }
        guard let broker = AskpassBroker.shared else { throw FileIssue("The Herb's Terminal secret helper is unavailable.") }
        let token = broker.issue(try address(of: peer))
        // ssh runs a ProxyCommand as `exec <command>`, and `exec VAR=value program` looks for a program named
        // "VAR=value"; env sets the variables instead.
        let proxy = "/usr/bin/env HERBSTERMINAL_HELPER=tailcat-proxy HERBSTERMINAL_SECRET_TOKEN=\(token) HERBSTERMINAL_SECRET_SOCKET=\(shellQuote(broker.socketPath)) "
            + Host.helperCommand.map(shellQuote).joined(separator: " ") + " %p"
        return RemoteEndpoint(host: "tailcat-" + peer.name.filter { $0.isLetter || $0.isNumber || $0 == "-" },
                              port: peer.port, username: peer.username, proxyCommand: proxy)
    }

    func ping(_ peer: TailcatPeer) async {
        guard let tailcat = Tailcat.executable else { routes[peer.id] = .unreachable("Bundled tailcat helper missing."); return }
        routes[peer.id] = .checking
        do {
            let address = try address(of: peer)
            let output = await Task.detached { () -> String in
                let result = ChildProcess.run([tailcat, "ping", "--until-direct", "--timeout=8s", address], errors: true, timeout: 30)
                if result.status == nil && result.output.isEmpty { return "Could not run tailcat." }
                return String(decoding: result.output, as: UTF8.self)
            }.value
            routes[peer.id] = Tailcat.route(fromPing: output)
        } catch {
            routes[peer.id] = .unreachable(error.localizedDescription)
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(peers).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}

/// Shares this computer's SSH service over Tailcat, for a peer to add as its own Tailcat peer.
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
        error = nil
        starting = true
        defer { starting = false }
        // tailcat hands each peer to this computer's port 22; without an SSH server there, the peer's ssh is cut off.
        guard await Task.detached(operation: { TailcatProxy.acceptsLocalConnections(on: 22) }).value else {
            error = "Turn on this computer's SSH service first: nothing here answers SSH, so a peer couldn't log in. On most systems: sudo systemctl enable --now sshd"
            return
        }
        self.persistent = persistent
        let addressFile = SSHControl.directory.appendingPathComponent("share-\(UUID().uuidString).addr")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailcat)
        // One-time pairing uses a fresh key that dies with this server; persistent uses the saved "default" server
        // key, created on first use, so the address survives restarts.
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
            try? await Task.sleep(nanoseconds: 250_000_000)
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
        let list = ChildProcess.run([tailcat, "genkey", "--list"])
        guard list.status != nil else { return }
        let names = String(decoding: list.output, as: UTF8.self)
        guard !names.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("default") }) else { return }
        _ = ChildProcess.run([tailcat, "genkey", "--key=default"])
    }
}

// MARK: Session restore

/// The saved shape of a tab's panes, for session restore.
struct SavedPane: Codable, Equatable {
    var directory: String?
    var axis: String?
    var children: [SavedPane]?
}

/// What reopens at launch: each window's tabs with their folder, layout, name and explorer folder. Remote sessions
/// reopen as local shells in the folder their shell was in; logins are never replayed.
struct SavedTab: Codable, Equatable {
    var directory: String
    var layout: String
    var title: String?
    var explorerPath: String
    var profile: String?
    var panes: SavedPane?
}

struct SavedWindow: Codable, Equatable {
    var tabs: [SavedTab]
    var selected: Int
}

enum SavedSession {
    static let key = "savedSession"

    static func write(_ windows: [SavedWindow]) {
        if let data = try? JSONEncoder().encode(windows) { Preferences.shared.set(data, key) }
    }

    static func read() -> [SavedWindow] {
        Preferences.shared.data(key).flatMap { try? JSONDecoder().decode([SavedWindow].self, from: $0) } ?? []
    }

    static func clear() { Preferences.shared.set(nil, key) }
}

/// "<tab name> <yyyy-MM-dd HH-mm>.txt", with characters that can't be in a file name replaced.
func sessionFileName(title: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH-mm"
    let name = title.map { "/:\\".contains($0) ? "-" : $0 }
    return String(name).trimmingCharacters(in: .whitespaces) + " " + formatter.string(from: date) + ".txt"
}
