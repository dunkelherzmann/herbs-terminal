import AppKit
import CryptoKit
import Foundation
import Testing
@testable import HerbsTerminal

@Test(.timeLimit(.minutes(2)))
func askpassHandsOverThePasswordOnceAndNeverForOtherPrompts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let broker = try AskpassBroker(directory: directory, helperPath: "/Applications/Herb's Terminal.app/Contents/MacOS/HerbsTerminal")
    let secret = "p@ss, \"word\" 'x'"
    let environment = broker.environment(token: broker.issue(secret))
    #expect(environment["SSH_ASKPASS"] == "/Applications/Herb's Terminal.app/Contents/MacOS/HerbsTerminal")
    #expect(environment["HERBSTERMINAL_HELPER"] == "askpass")
    #expect(!environment.values.contains(secret))

    var asked: [String] = []
    let terminal: (String, Bool) -> String? = { prompt, _ in asked.append(prompt); return nil }
    let token = environment["HERBSTERMINAL_SECRET_TOKEN"]!, socket = environment["HERBSTERMINAL_SECRET_SOCKET"]!
    #expect(HelperMode.askpass(prompt: "me@host's password: ", token: token, socket: socket, terminal: terminal) == secret)
    // Single use: a retry after a wrong password is asked on the terminal instead.
    #expect(HelperMode.askpass(prompt: "me@host's password: ", token: token, socket: socket, terminal: terminal) == nil)
    // A host-key question never receives the saved password.
    let fresh = broker.issue("secret")
    #expect(HelperMode.askpass(prompt: "Are you sure you want to continue connecting (yes/no)? ", token: fresh,
                                   socket: socket, terminal: terminal) == nil)
    #expect(asked.count == 2)
    #expect(AskpassBroker.redeem(token: fresh, socket: socket) == "secret")
    #expect(HelperMode.isSecretPrompt("Verification code: ") && !HelperMode.isSecretPrompt("(yes/no)? "))
    #expect(HelperMode.run(environment: [:], arguments: ["Herb's Terminal"]) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor
func sshLauncherKeepsTokensOffScreenAndDeletesItself() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try LocalShell.writeLauncher(label: "me@host", environment: ["HERBSTERMINAL_SECRET_TOKEN": "abc123"],
                                           arguments: ["-p", "22", "me@host"], in: directory)
    let script = try String(contentsOf: url, encoding: .utf8)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o700)
    #expect(script.contains("export HERBSTERMINAL_SECRET_TOKEN=abc123"))
    #expect(script.contains("exec /usr/bin/ssh -p 22 me@host"))
    #expect(script.contains("rm -f -- \"$0\""))
    // Run it with a stand-in for ssh's exec: the launcher erases the typed line, deletes itself and announces.
    let probe = script.replacingOccurrences(of: "exec /usr/bin/ssh", with: "echo ran")
    try probe.write(to: url, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(output.hasPrefix("\u{1B}[1A\r\u{1B}[2K"))
    #expect(output.contains("Connecting to me@host…\nran -p 22 me@host"))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test(.timeLimit(.minutes(2)))
func bundledTailcatIsTheOnlyOneUsed() throws {
    let path = try #require(Tailcat.executable)
    #expect(path.hasSuffix("Contents/Helpers/tailcat") || path.hasSuffix("Vendor/tailcat/tailcat"))
    #expect(!path.hasPrefix("/opt/homebrew") && !path.hasPrefix("/usr/local"))
}

@Test(.timeLimit(.minutes(2)))
func bookmarksAreScopedPerHost() {
    var list = BookmarkList(raw: "", scope: "me@a:22")
    list.toggle("/srv")
    list.toggle("/var/log")
    var other = BookmarkList(raw: list.raw, scope: "me@b:22")
    #expect(other.paths.isEmpty)
    other.toggle("/srv")
    #expect(BookmarkList(raw: other.raw, scope: "me@a:22").paths == ["/srv", "/var/log"])
    #expect(BookmarkList(raw: other.raw, scope: "me@b:22").paths == ["/srv"])
    list = BookmarkList(raw: other.raw, scope: "me@a:22")
    list.toggle("/srv")
    #expect(list.paths == ["/var/log"])
}

@Test(.timeLimit(.minutes(2))) @MainActor
func newTabsCanStartInTheShellsRealFolder() async throws {
    let shell = LocalShell()
    shell.startDirectory = "/tmp"
    shell.start()
    defer { shell.close() }
    try await Task.sleep(for: .milliseconds(400))
    #expect(shell.currentDirectory == "/private/tmp")
    #expect(shell.foregroundProgram == nil)
}

@Test(.timeLimit(.minutes(2)))
func titlesHideCredentialsInCommandLines() {
    #expect(redactCredentials("ssh admin:s3cret@192.0.2.10") == "ssh admin:•••@192.0.2.10")
    #expect(redactCredentials("curl https://bob:hunter2@example.com/x") == "curl https://bob:•••@example.com/x")
    #expect(redactCredentials("mysql --password=hunter2 db") == "mysql --password=••• db")
    #expect(redactCredentials("API_TOKEN=abc123 make deploy") == "API_TOKEN=••• make deploy")
    #expect(redactCredentials("ssh -p 2222 admin@host") == "ssh -p 2222 admin@host")
}

@Test(.timeLimit(.minutes(2)))
func sshArgumentsShareTheTabConnectionAndLetCallersOverride() {
    let direct = RemoteEndpoint(host: "h", port: 2222, username: "u")
    let args = direct.sshArguments(["-o", "ProxyCommand=/usr/bin/false"])
    #expect(args.first == "-p" && args[1] == "2222" && args.last == "u@h")
    #expect(args.contains("ControlPath=\(SSHControl.controlPath)"))
    // ssh keeps the first value of an option, so the caller's ProxyCommand must come before the endpoint's.
    let peer = RemoteEndpoint(host: "tailcat-box", username: "u", proxyCommand: "tailcat X %p")
    let peerArgs = peer.sshArguments(["-o", "ProxyCommand=/usr/bin/false"])
    #expect(peerArgs.firstIndex(of: "ProxyCommand=/usr/bin/false")! < peerArgs.firstIndex(of: "ProxyCommand=tailcat X %p")!)
    #expect(shellQuote("plain-word") == "plain-word")
    #expect(shellQuote("it's here") == "'it'\\''s here'")
}

@Test(.timeLimit(.minutes(2)))
func tailcatPingReportsDirectOrRelayedRoutes() {
    #expect(Tailcat.route(fromPing: "pong in 42.1ms via DERP(sfo)\npong in 1.2ms via 203.0.113.7:41641\n")
            == .direct("1.2ms via 203.0.113.7:41641"))
    #expect(Tailcat.route(fromPing: "pong in 40ms via DERP(fra)\npong in 39ms via DERP(fra)\n") == .relayed("39ms via DERP(fra)"))
    if case .unreachable = Tailcat.route(fromPing: "timeout waiting for pong\n") {} else { Issue.record("expected unreachable") }
}

@Test(.timeLimit(.minutes(2))) @MainActor
func tailcatPeersStoreAddressesEncryptedAndKeepThemOutOfSSHArguments() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("peers-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let database = file.deletingPathExtension().appendingPathExtension("sqlite3")
    defer { try? FileManager.default.removeItem(at: database) }
    let secrets = try CredentialStore(databaseURL: database, vault: CryptoVault(keyProvider: StaticKeyProvider(key: SymmetricKey(size: .bits256))))
    let store = TailcatPeerStore(file: file, secrets: secrets)
    let address = "tc1-secret-bearer-address"
    try store.add(name: "nas", username: "admin", address: address, persistent: true)
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(address))
    let reloaded = TailcatPeerStore(file: file, secrets: secrets)
    let peer = try #require(reloaded.peers.first)
    #expect(try reloaded.address(of: peer) == address)
    if Tailcat.executable != nil {
        let endpoint = try reloaded.endpoint(for: peer)
        #expect(endpoint.host == "tailcat-nas")
        #expect(!endpoint.sshArguments().joined(separator: " ").contains(address))
        // ssh runs a ProxyCommand as `exec <command>`: run it that way, with the helper swapped for printenv.
        let helper = try #require(AskpassBroker.shared).helperPath
        let command = try #require(endpoint.proxyCommand)
            .replacingOccurrences(of: shellQuote(helper), with: "/usr/bin/printenv")
            .replacingOccurrences(of: " %p", with: " HERBSTERMINAL_HELPER")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "exec " + command]
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardError = FileHandle.nullDevice
        try sh.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        sh.waitUntilExit()
        #expect(printed.trimmingCharacters(in: .whitespacesAndNewlines) == "tailcat-proxy")
    }
    #expect(throws: FileIssue.self) { try store.add(name: "x", username: "u", address: "has space", persistent: false) }
    try reloaded.remove(peer)
    #expect(TailcatPeerStore(file: file, secrets: secrets).peers.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func multiHostClassifiesEachHostOnItsOwn() async throws {
    func outcome(_ script: String) async -> HostResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let target = HostTarget(endpoint: RemoteEndpoint(host: "h", username: "u"), password: nil, source: "test")
        return await MultiHostModel.execute(process, target: target)
    }
    let ok = await outcome("echo up")
    #expect(ok.outcome == .succeeded && ok.output == "up\n")
    #expect(await outcome("echo nope >&2; exit 3").outcome == .failed(3))
    let unreached = await outcome("echo 'ssh: connect to host h port 22: Connection refused' >&2; exit 255")
    #expect(unreached.outcome == .notReached("ssh: connect to host h port 22: Connection refused"))
    // The ssh invocation never allocates a terminal and refuses unknown host keys.
    let process = MultiHostModel.makeProcess(HostTarget(endpoint: RemoteEndpoint(host: "h", username: "u"), password: nil, source: ""),
                                             command: "uptime")
    #expect(process.arguments?.contains("-T") == true)
    #expect(process.arguments?.contains("StrictHostKeyChecking=yes") == true)
    #expect(process.arguments?.last == "uptime")
}

