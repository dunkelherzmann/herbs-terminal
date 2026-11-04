import Foundation

struct FileIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SFTPStatus: LocalizedError {
    let code: UInt32
    let message: String
    var errorDescription: String? { "SFTP \(code): \(message)" }
}

struct RemoteAttributes: Equatable, Sendable {
    let size: UInt64?
    let mode: UInt32?
    let modified: UInt32?
    var kind: UInt32 { (mode ?? 0) & 0o170000 }
    var directory: Bool { kind == 0o040000 }
    var link: Bool { kind == 0o120000 }
}

struct RemoteEntry: Identifiable, Sendable {
    let name: String
    let attributes: RemoteAttributes
    var id: String { name }
}

private struct Packet {
    var data = Data()
    var position = 0
    mutating func number<T: FixedWidthInteger>(_ n: T) {
        withUnsafeBytes(of: n.bigEndian) { data.append(contentsOf: $0) }
    }
    mutating func blob(_ bytes: Data) { number(UInt32(bytes.count)); data.append(bytes) }
    mutating func string(_ s: String) { blob(Data(s.utf8)) }
    mutating func take<T: FixedWidthInteger>(_ t: T.Type) throws -> T {
        guard position + MemoryLayout<T>.size <= data.count else { throw FileIssue("Incomplete SFTP packet.") }
        defer { position += MemoryLayout<T>.size }
        return data.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: position, as: T.self)) }
    }
    mutating func bytes() throws -> Data {
        let n = Int(try take(UInt32.self))
        guard n <= data.count - position else { throw FileIssue("Incomplete SFTP string.") }
        defer { position += n }
        return data.subdata(in: position..<(position+n))
    }
    mutating func text() throws -> String {
        guard let s = String(data: try bytes(), encoding: .utf8) else { throw FileIssue("Non-UTF-8 server filename.") }
        return s
    }
    mutating func attributes() throws -> RemoteAttributes {
        let flags = try take(UInt32.self)
        let size = flags & 1 != 0 ? try take(UInt64.self) : nil
        if flags & 2 != 0 { _ = try take(UInt64.self) }
        let mode = flags & 4 != 0 ? try take(UInt32.self) : nil
        var modified: UInt32?
        if flags & 8 != 0 { _ = try take(UInt32.self); modified = try take(UInt32.self) }
        if flags & 0x80000000 != 0 {
            for _ in 0..<(try take(UInt32.self)) { _ = try bytes(); _ = try bytes() }
        }
        return RemoteAttributes(size: size, mode: mode, modified: modified)
    }
}

func remoteJoin(_ parent: String, _ name: String) -> String {
    parent.hasSuffix("/") ? parent + name : parent + "/" + name
}

func validateFileName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
        throw FileIssue("Enter a single file or folder name.")
    }
}

struct RemoteEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    /// Set for peers reached over Tailcat instead of a direct address.
    var proxyCommand: String?

    /// For display. A password typed into the user name (`user:pass@host`) is never shown.
    var label: String { "\(username.split(separator: ":", maxSplits: 1).first.map(String.init) ?? username)@\(host)" }

    init(host: String, port: Int = 22, username: String, proxyCommand: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.proxyCommand = proxyCommand
    }

    /// ssh arguments that reach this endpoint through the tab's shared connection. `extra` comes first
    /// because ssh keeps the first value it sees for an option.
    func sshArguments(_ extra: [String] = []) -> [String] {
        var args = ["-p", String(port)]
        args.append(contentsOf: extra)
        args += ["-o", "ControlPath=\(SSHControl.controlPath)"]
        if let proxyCommand { args += ["-o", "ProxyCommand=\(proxyCommand)"] }
        args.append("\(username)@\(host)")
        return args
    }
}

protocol RemoteFileService: Sendable {
    func list(_ path: String) throws -> [RemoteEntry]
    func mkdir(_ path: String) throws
    func remove(_ path: String, directory: Bool) throws
    func rename(_ old: String, _ new: String, replace: Bool) throws
    func stat(_ path: String, follow: Bool) throws -> RemoteAttributes
}

extension SFTPClient: RemoteFileService, @unchecked Sendable {}

/// One synchronous SFTP v3 channel per background operation. The failing proxy
/// prevents OpenSSH from making a new connection if its master has disappeared.
final class SFTPClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var sequence: UInt32 = 0
    private(set) var extensions = Set<String>()

    convenience init(endpoint: RemoteEndpoint) throws {
        try self.init(executable: "/usr/bin/ssh", arguments: endpoint.sshArguments(["-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes", "-T", "-s"]) + ["sftp"])
    }

    init(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            var initPacket = Packet()
            initPacket.number(UInt8(1)); initPacket.number(UInt32(3))
            try send(initPacket)
            var version = try receive()
            guard try version.take(UInt8.self) == 2, try version.take(UInt32.self) == 3 else {
                throw FileIssue("This server does not provide SFTP version 3.")
            }
            while version.position < version.data.count {
                extensions.insert(try version.text()); _ = try version.bytes()
            }
        } catch {
            stop()
            throw error
        }
    }
    deinit { stop() }
    private func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    private func exact(_ n: Int) throws -> Data {
        var data = Data()
        while data.count < n {
            guard let chunk = try output.fileHandleForReading.read(upToCount: n-data.count), !chunk.isEmpty else {
                throw FileIssue("SFTP channel closed. Check the SSH session and whether the server permits SFTP.")
            }
            data.append(chunk)
        }
        return data
    }
    private func receive() throws -> Packet {
        var header = Packet(data: try exact(4))
        let n = Int(try header.take(UInt32.self))
        guard (1...4_194_304).contains(n) else { throw FileIssue("Invalid SFTP packet length.") }
        return Packet(data: try exact(n))
    }
    private func send(_ p: Packet) throws {
        var frame = Packet()
        frame.blob(p.data)
        try input.fileHandleForWriting.write(contentsOf: frame.data)
    }
    private func request(_ type: UInt8, _ expected: UInt8, _ fill: (inout Packet) -> Void) throws -> Packet {
        sequence &+= 1
        var p = Packet()
        p.number(type); p.number(sequence); fill(&p)
        try send(p)
        var response = try receive()
        let kind = try response.take(UInt8.self)
        guard try response.take(UInt32.self) == sequence else { throw FileIssue("Mismatched SFTP reply.") }
        if kind == 101 {
            let code = try response.take(UInt32.self)
            if code != 0 { throw SFTPStatus(code: code, message: try response.text()) }
        }
        guard kind == expected else { throw FileIssue("Unexpected SFTP response.") }
        return response
    }
    func canonical(_ path: String) throws -> String {
        var p = try request(16, 104) { $0.string(path) }
        guard try p.take(UInt32.self) == 1 else { throw FileIssue("Cannot resolve remote path.") }
        return try p.text()
    }
    func stat(_ path: String, follow: Bool = false) throws -> RemoteAttributes {
        var p = try request(follow ? 17 : 7, 105) { $0.string(path) }
        return try p.attributes()
    }
    func existing(_ path: String) throws -> RemoteAttributes? {
        do { return try stat(path) } catch let s as SFTPStatus where s.code == 2 { return nil }
    }
    func list(_ path: String) throws -> [RemoteEntry] {
        var p = try request(11, 102) { $0.string(path) }
        let handle = try p.bytes()
        defer { try? close(handle) }
        var items: [RemoteEntry] = []
        do {
            while true {
                var page = try request(12, 104) { $0.blob(handle) }
                let count = try page.take(UInt32.self)
                guard count > 0 else { throw FileIssue("Empty SFTP directory response.") }
                for _ in 0..<count {
                    let name = try page.text()
                    _ = try page.bytes()
                    let attr = try page.attributes()
                    if name == "." || name == ".." { continue }
                    try validateFileName(name)
                    items.append(RemoteEntry(name: name, attributes: attr))
                }
            }
        } catch let s as SFTPStatus where s.code == 1 { }
        return items
    }
    func mkdir(_ path: String) throws {
        _ = try request(14, 101) { $0.string(path); $0.number(UInt32(0)) }
    }
    func remove(_ path: String, directory: Bool = false) throws {
        _ = try request(directory ? 15 : 13, 101) { $0.string(path) }
    }
    func rename(_ old: String, _ new: String, replace: Bool = false) throws {
        if replace && !extensions.contains("posix-rename@openssh.com") {
            throw FileIssue("This server cannot safely replace an existing file. Choose a new name.")
        }
        _ = try request(replace ? 200 : 18, 101) {
            if replace { $0.string("posix-rename@openssh.com") }
            $0.string(old); $0.string(new)
        }
    }
    func permissions(_ path: String, _ mode: UInt32) throws {
        _ = try request(9, 101) { $0.string(path); $0.number(UInt32(4)); $0.number(mode & 0o7777) }
    }
    func open(_ path: String, flags: UInt32, mode: UInt32 = 0o600) throws -> Data {
        var p = try request(3, 102) {
            $0.string(path); $0.number(flags); $0.number(UInt32(4)); $0.number(mode)
        }
        return try p.bytes()
    }
    func close(_ handle: Data) throws { _ = try request(4, 101) { $0.blob(handle) } }
    func read(_ handle: Data, offset: UInt64) throws -> Data {
        do {
            var p = try request(5, 103) { $0.blob(handle); $0.number(offset); $0.number(UInt32(32768)) }
            let bytes = try p.bytes()
            guard !bytes.isEmpty else { throw FileIssue("Empty SFTP read.") }
            return bytes
        } catch let s as SFTPStatus where s.code == 1 { return Data() }
    }
    func write(_ handle: Data, offset: UInt64, bytes: Data) throws {
        _ = try request(6, 101) { $0.blob(handle); $0.number(offset); $0.blob(bytes) }
    }
}
