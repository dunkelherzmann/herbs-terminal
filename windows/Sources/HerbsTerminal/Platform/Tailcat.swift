import Foundation
import WinSDK

/// Tailcat peers on Windows, as on the Mac and Linux (section 8): the app's bundled `tailcat.exe` (Tailscale's own
/// Windows release) reaches machines that can't see each other by IP. A peer's secret address is protected like a
/// saved login and reaches tailcat only through a one-time token and the loopback socket.
enum Tailcat {
    /// The copy beside the app's executable. Copies on PATH are never used.
    static let executable: String? = {
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tailcat.exe").path
        return FileManager.default.fileExists(atPath: beside) ? beside : nil
    }()

    static let missing = "This Herb's Terminal build is missing its bundled tailcat helper."

    /// A job object whose processes end when this process does, however it ends: tailcat servers and proxies
    /// never outlive the app (or the proxy helper) that started them.
    nonisolated(unsafe) private static var job: HANDLE? = {
        let job = CreateJobObjectW(nil, nil)
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        return job
    }()

    /// Ties a started tailcat to this process's life.
    static func bind(_ process: Process) {
        guard let job, let handle = OpenProcess(DWORD(PROCESS_SET_QUOTA | PROCESS_TERMINATE), false, DWORD(process.processIdentifier)) else { return }
        AssignProcessToJobObject(job, handle)
        CloseHandle(handle)
    }

    /// A peer's endpoint carries this instead of a ProxyCommand: Windows' ssh can't share a connection, so the
    /// shell, the explorer and Run Command on Hosts each sign in separately, and each gets its own one-time token
    /// when it starts (see `sshOptions`).
    static let marker = "herbs-tailcat:"

    /// The secret address of the Tailcat peer an endpoint reaches; nil for an ordinary host.
    @MainActor
    static func address(for endpoint: RemoteEndpoint) throws -> String? {
        guard let proxy = endpoint.proxyCommand, proxy.hasPrefix(marker) else { return nil }
        guard let id = Foundation.UUID(uuidString: String(proxy.dropFirst(marker.count))),
              let peer = TailcatPeerStore.shared.peers.first(where: { $0.id == id }) else {
            throw FileIssue("That Tailcat peer was removed.")
        }
        return try TailcatPeerStore.shared.address(of: peer)
    }

    /// ssh options for an endpoint: a ProxyCommand with a fresh token for a Tailcat peer, nothing otherwise.
    @MainActor
    static func sshOptions(_ endpoint: RemoteEndpoint) throws -> [String] {
        guard let address = try address(for: endpoint) else { return [] }
        return try proxyOptions(address: address)
    }

    // MARK: Connections without a terminal

    /// Windows' ssh stalls running a ProxyCommand when it has no terminal (the explorer's channel, Run Command on
    /// Hosts), so those connections go to a loopback port instead: the app forwards it through one shared local
    /// `tailcat socks` proxy, started from the window thread and ended with the app.
    nonisolated(unsafe) private static var socksPort: UInt16?

    @MainActor
    static func startSocks() {
        guard socksPort == nil, let tailcat = executable, TailcatProxy.startup(), let port = TailcatProxy.freeLoopbackPort() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailcat)
        process.arguments = ["socks", "--listen=127.0.0.1:\(port)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        bind(process)
        socksPort = port
    }

    /// Opens a loopback port that carries one connection to the peer at `address`; returns the port.
    static func forward(address: String, port: UInt16) throws -> UInt16 {
        guard let socksPort else { throw FileIssue("tailcat's local proxy isn't running.") }
        return try TailcatProxy.forward(through: socksPort, to: address, port: port)
    }

    /// ssh options and destination for a connection without a terminal to a Tailcat peer: a loopback port, and the
    /// peer's name for its host key (the one the terminal accepted).
    static func directOptions(address: String, endpoint: RemoteEndpoint) throws -> (options: [String], destination: String) {
        let local = try forward(address: address, port: UInt16(endpoint.port))
        return (["-o", "HostKeyAlias=\(endpoint.host)", "-o", "CheckHostIP=no", "-p", String(local)], "\(endpoint.username)@127.0.0.1")
    }

    /// The ProxyCommand that reaches `address` once: the token in it is good for one connection.
    static func proxyOptions(address: String) throws -> [String] {
        guard Tailcat.executable != nil else { throw FileIssue(missing) }
        guard let broker = AskpassBroker.shared else { throw FileIssue("The Herb's Terminal secret helper is unavailable.") }
        // ssh replaces %p with the port; the token is one-time, so seeing it in ssh's arguments gives nothing away.
        let command = [AskpassBroker.executablePath, TailcatProxy.flag, broker.pipeName, broker.issue(address)].map(quoteArgument)
            .joined(separator: " ") + " %p"
        return ["-o", "ProxyCommand=" + command]
    }
}

/// The saved peers: names, accounts and protected addresses, in the same file format as the Mac and Linux.
@MainActor
final class TailcatPeerStore: ObservableObject {
    static let shared = TailcatPeerStore()

    @Published private(set) var peers: [TailcatPeer] = []
    @Published var routes: [Foundation.UUID: TailcatRoute] = [:]
    private let file = AppFolders.support().appendingPathComponent("tailcat-peers.json")
    private var secrets: CredentialStore? { CredentialStore.shared }

    init() {
        guard let data = try? Data(contentsOf: file) else { return }
        if let decoded = try? JSONDecoder().decode([TailcatPeer].self, from: data) {
            peers = decoded
        } else {
            // Set aside, never overwritten.
            try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        }
    }

    func add(name: String, username: String, address: String, persistent: Bool) throws {
        let name = name.trimmingCharacters(in: .whitespaces), username = username.trimmingCharacters(in: .whitespaces)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// The endpoint ssh connects to: the peer's name as the host (for its host key) and the Tailcat marker.
    func endpoint(for peer: TailcatPeer) -> RemoteEndpoint {
        RemoteEndpoint(host: "tailcat-" + peer.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }, port: peer.port,
                       username: peer.username, proxyCommand: Tailcat.marker + peer.id.uuidString)
    }

    /// Ping: Direct or Relayed with the latency, as `tailcat ping` reports it.
    func ping(_ peer: TailcatPeer) {
        guard let tailcat = Tailcat.executable else { routes[peer.id] = .unreachable("Bundled tailcat helper missing."); return }
        let address: String
        do { address = try self.address(of: peer) } catch { routes[peer.id] = .unreachable(error.localizedDescription); return }
        routes[peer.id] = .checking
        // Started here, on the main thread (see RunOnHosts): only the waiting happens in the background.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailcat)
        process.arguments = ["ping", "--until-direct", "--timeout=8s", address]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { routes[peer.id] = .unreachable("Could not run tailcat."); return }
        let box = TailcatProcessBox(process)
        MainThread.background({ () -> String in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            box.process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        }) { [weak self] result in
            guard let self, self.peers.contains(where: { $0.id == peer.id }) else { return }
            self.routes[peer.id] = (try? result.get()).map(TailcatRoute.init(ping:)) ?? .unreachable("Could not run tailcat.")
        }
    }

    /// After a change of login protection (an Administrator Password set, changed or removed): addresses are read
    /// with the old key, `change` runs, and they're written again with the new one.
    func reprotect(_ change: () throws -> Void) throws {
        guard let secrets, !peers.isEmpty else { try change(); return }
        let addresses = try peers.map { try secrets.reveal($0.secret) }
        try change()
        for index in peers.indices { peers[index].secret = try secrets.protect(addresses[index]) }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(peers).write(to: file, options: .atomic)
    }
}

final class TailcatProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Shares this PC's SSH server over Tailcat, for a peer to add as its own Tailcat peer. It needs Windows' OpenSSH
/// Server running; sharing stops when the app quits.
@MainActor
final class TailcatShare: ObservableObject {
    static let shared = TailcatShare()
    @Published private(set) var address: String?
    @Published private(set) var persistent = false
    @Published private(set) var starting = false
    @Published var error: String?
    private var process: Process?

    var isSharing: Bool { process?.isRunning == true }

    func start(persistent: Bool) {
        guard let tailcat = Tailcat.executable else { error = Tailcat.missing; return }
        stop()
        error = nil
        // tailcat hands each peer to this PC's port 22; without an SSH server there, the peer's ssh is cut off.
        guard TailcatProxy.acceptsLocalConnections(on: 22) else {
            error = "Turn on this PC's SSH server first: nothing here answers SSH, so a peer couldn't log in. In Windows Settings › System › Optional features, add OpenSSH Server, then start the OpenSSH SSH Server service."
            objectWillChange.send()
            return
        }
        starting = true
        self.persistent = persistent
        let addressFile = AppFolders.support().appendingPathComponent("share-\(randomHex(8)).addr")
        if persistent { Self.ensureDefaultKey(tailcat) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tailcat)
        // One-time pairing uses a fresh key that dies with this server; persistent uses the saved "default" key.
        process.arguments = (persistent ? ["serve"] : ["serve", "--key=new"]) + ["22"]
        var environment = ProcessInfo.processInfo.environment
        environment["TAILCAT_ADDR_FILE"] = addressFile.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { self.error = error.localizedDescription; starting = false; return }
        Tailcat.bind(process)
        self.process = process
        waitForAddress(addressFile, attempt: 0)
    }

    private func waitForAddress(_ file: URL, attempt: Int) {
        if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
            address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: file)
            starting = false
            return
        }
        guard attempt < 40, process?.isRunning == true else {
            try? FileManager.default.removeItem(at: file)
            stop()
            starting = false
            error = "tailcat didn't report an address. Check that it can reach the internet."
            return
        }
        MainThread.after(0.25) { [weak self] in self?.waitForAddress(file, attempt: attempt + 1) }
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        address = nil
        objectWillChange.send()
    }

    private static func ensureDefaultKey(_ tailcat: String) {
        func run(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tailcat)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let names = run(["genkey", "--list"])
        guard !names.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("default") }) else { return }
        _ = run(["genkey", "--key=default"])
    }
}

/// ssh's ProxyCommand for a Tailcat peer (`HerbsTerminal.exe --tailcat-proxy <pipe> <token> <port>`): trades the
/// token for the peer's address, runs the bundled tailcat as a local SOCKS5 proxy (which needs no address on its
/// command line), sends the address to it over the loopback socket, then relays ssh's bytes both ways.
enum TailcatProxy {
    static let flag = "--tailcat-proxy"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 3 else { return 2 }
        guard let address = AskpassBroker.redeem(token: arguments[1], pipe: arguments[0]) else {
            report("The Tailcat address couldn't be read (the one-time token was used or expired). Connect again.")
            return 1
        }
        guard let tailcat = Tailcat.executable else { report(Tailcat.missing); return 1 }
        let port = UInt16(arguments[2]) ?? 22
        let name = Array(address.utf8)
        guard name.count <= 255, startup(), let proxyPort = freeLoopbackPort() else { report("tailcat's local proxy couldn't start."); return 1 }
        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: tailcat)
        proxy.arguments = ["socks", "--listen=127.0.0.1:\(proxyPort)"]
        proxy.standardInput = FileHandle.nullDevice
        proxy.standardOutput = FileHandle.nullDevice
        proxy.standardError = FileHandle.nullDevice
        guard (try? proxy.run()) != nil else { report("tailcat couldn't be started."); return 1 }
        Tailcat.bind(proxy)
        defer { if proxy.isRunning { proxy.terminate() } }
        // tailcat needs a moment to start listening.
        var socket: SOCKET = INVALID_SOCKET
        for _ in 0..<100 {
            socket = connectLoopback(proxyPort)
            if socket != INVALID_SOCKET { break }
            Sleep(100)
        }
        guard socket != INVALID_SOCKET else { report("tailcat didn't start its local proxy."); return 1 }
        defer { closesocket(socket) }
        guard handshake(socket, name: name, port: port) else { return 1 }
        guard relay(socket) else {
            // tailcat reached the peer, but nothing listened on the port there and it hung up.
            report("The Tailcat peer was reached, but nothing answered SSH on port \(port) there. On that computer, turn on SSH: "
                   + "on a Mac, Remote Login in System Settings › General › Sharing; on Linux, the SSH service (sshd); "
                   + "on Windows, the OpenSSH SSH Server service.")
            return 1
        }
        return 0
    }

    /// A one-shot loopback listener: the first connection to it is carried through the SOCKS proxy on `socksPort`
    /// to `address`:`port`, both ways, on its own threads. Returns the listening port.
    static func forward(through socksPort: UInt16, to address: String, port: UInt16) throws -> UInt16 {
        guard startup() else { throw FileIssue("Windows sockets aren't available.") }
        let listener = WinSDK.socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard listener != INVALID_SOCKET else { throw FileIssue("Couldn't open a local port for the Tailcat peer.") }
        var bound = loopback(0)
        let ok = withUnsafePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, Int32(MemoryLayout<sockaddr_in>.size)) } } == 0
            && listen(listener, 1) == 0
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        guard ok else { closesocket(listener); throw FileIssue("Couldn't open a local port for the Tailcat peer.") }
        let name = Array(address.utf8), raw = UInt(listener)
        Thread.detachNewThread {
            defer { closesocket(SOCKET(raw)) }
            let client = accept(SOCKET(raw), nil, nil)
            guard client != INVALID_SOCKET else { return }
            let peer = connectLoopback(socksPort)
            guard peer != INVALID_SOCKET, name.count <= 255, handshake(peer, name: name, port: port) else {
                closesocket(client)
                if peer != INVALID_SOCKET { closesocket(peer) }
                return
            }
            let a = UInt(client), b = UInt(peer)
            let done = DispatchSemaphore(value: 0)
            for (from, to) in [(a, b), (b, a)] {
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let count = buffer.withUnsafeMutableBufferPointer {
                            recv(SOCKET(from), UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
                        }
                        guard count > 0, send(SOCKET(to), Array(buffer[0..<Int(count)])) else { break }
                    }
                    shutdown(SOCKET(to), Int32(SD_SEND))
                    done.signal()
                }
            }
            done.wait()
            done.wait()
            closesocket(SOCKET(a))
            closesocket(SOCKET(b))
        }
        return UInt16(bigEndian: bound.sin_port)
    }

    /// Whether something on this PC accepts connections on `port`; a Tailcat share passes peers to it.
    static func acceptsLocalConnections(on port: UInt16) -> Bool {
        guard startup() else { return false }
        let socket = connectLoopback(port)
        guard socket != INVALID_SOCKET else { return false }
        closesocket(socket)
        return true
    }

    static func startup() -> Bool {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }

    private static func handshake(_ socket: SOCKET, name: [UInt8], port: UInt16) -> Bool {
        guard send(socket, [5, 1, 0]), let greeting = receive(socket, 2), greeting == [5, 0] else {
            report("tailcat's local proxy refused the connection."); return false
        }
        guard send(socket, [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)]),
              let reply = receive(socket, 4) else {
            report("tailcat's local proxy stopped answering."); return false
        }
        guard reply[1] == 0 else {
            report("Couldn't reach the Tailcat peer (SOCKS error \(reply[1])). Check that it's still serving and the address is right.")
            return false
        }
        let rest: Int
        switch reply[3] {
        case 1: rest = 4 + 2
        case 4: rest = 16 + 2
        case 3: rest = Int(receive(socket, 1)?.first ?? 0) + 2
        default: return false
        }
        return receive(socket, rest) != nil
    }

    /// Copies ssh's standard input to the peer and the peer's replies to standard output until either side closes.
    /// False when the peer hung up without sending a byte: nothing answered on its end.
    private static func relay(_ socket: SOCKET) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let silent = Flag()
        let input = UInt(bitPattern: GetStdHandle(STD_INPUT_HANDLE)), output = UInt(bitPattern: GetStdHandle(STD_OUTPUT_HANDLE))
        let raw = UInt(socket)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var read: DWORD = 0
                guard ReadFile(HANDLE(bitPattern: input), &buffer, DWORD(buffer.count), &read, nil), read > 0 else { break }
                guard send(SOCKET(raw), Array(buffer[0..<Int(read)])) else { break }
            }
            shutdown(SOCKET(raw), Int32(SD_SEND))
            // Not a signal for `done`: ssh's banner, sent at once, could end the wait before the peer's silence was seen.
        }
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var total = 0
            while true {
                let count = buffer.withUnsafeMutableBufferPointer { recv(SOCKET(raw), UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
                guard count > 0 else { break }
                var offset = 0
                while offset < Int(count) {
                    var written: DWORD = 0
                    let ok = buffer[offset..<Int(count)].withUnsafeBufferPointer {
                        WriteFile(HANDLE(bitPattern: output), $0.baseAddress, DWORD($0.count), &written, nil)
                    }
                    guard ok, written > 0 else { break }
                    offset += Int(written)
                }
                total += Int(count)
            }
            if total == 0 { silent.set() }
            done.signal()
        }
        done.wait()
        return !silent.isSet
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private static func send(_ socket: SOCKET, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBufferPointer {
                WinSDK.send(socket, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
            }
            guard sent > 0 else { return false }
            offset += Int(sent)
        }
        return true
    }

    private static func receive(_ socket: SOCKET, _ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes[offset...].withUnsafeMutableBufferPointer {
                recv(socket, UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
            }
            guard got > 0 else { return nil }
            offset += Int(got)
        }
        return bytes
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }

    static func freeLoopbackPort() -> UInt16? {
        let socket = WinSDK.socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard socket != INVALID_SOCKET else { return nil }
        defer { closesocket(socket) }
        var address = loopback(0)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, Int32(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func connectLoopback(_ port: UInt16) -> SOCKET {
        let socket = WinSDK.socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard socket != INVALID_SOCKET else { return INVALID_SOCKET }
        var address = loopback(port)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, Int32(MemoryLayout<sockaddr_in>.size)) } }
        if connected == 0 { return socket }
        closesocket(socket)
        return INVALID_SOCKET
    }

    private static func report(_ message: String) {
        var bytes = Array(("Herb's Terminal: " + message + "\r\n").utf8)
        var written: DWORD = 0
        let error = GetStdHandle(STD_ERROR_HANDLE)
        if error != nil, error != INVALID_HANDLE_VALUE, WriteFile(error, &bytes, DWORD(bytes.count), &written, nil), written > 0 { return }
        // No usable error output (this helper is a GUI program): write to the terminal's console instead, so the
        // person sees why instead of only "Connection closed by UNKNOWN port 65535".
        _ = AttachConsole(DWORD(bitPattern: -1)) // ATTACH_PARENT_PROCESS
        let console = withWide("CONOUT$") {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        guard let console, console != INVALID_HANDLE_VALUE else { return }
        WriteFile(console, &bytes, DWORD(bytes.count), &written, nil)
        CloseHandle(console)
    }
}
