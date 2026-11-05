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
    var uid: UInt32? = nil
    var gid: UInt32? = nil
    /// Account names, when a folder listing gave them (SFTP itself only carries the numbers).
    var owner: String? = nil
    var group: String? = nil
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
        var uid: UInt32?, gid: UInt32?
        if flags & 2 != 0 { uid = try take(UInt32.self); gid = try take(UInt32.self) }
        let mode = flags & 4 != 0 ? try take(UInt32.self) : nil
        var modified: UInt32?
        if flags & 8 != 0 { _ = try take(UInt32.self); modified = try take(UInt32.self) }
        if flags & 0x80000000 != 0 {
            for _ in 0..<(try take(UInt32.self)) { _ = try bytes(); _ = try bytes() }
        }
        return RemoteAttributes(size: size, mode: mode, modified: modified, uid: uid, gid: gid)
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

    /// `preamble` is written before the SFTP handshake, e.g. the password line `sudo -S` reads.
    init(executable: String, arguments: [String], preamble: Data? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            if let preamble { try input.fileHandleForWriting.write(contentsOf: preamble) }
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
    /// How long a reply may take before the server counts as gone. A link that hangs without dropping
    /// would otherwise stall the explorer, and a transfer, for good.
    nonisolated(unsafe) static var replyTimeout: Int32 = 30_000

    private func exact(_ n: Int) throws -> Data {
        var data = Data()
        let fd = output.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: min(max(n, 1), 65536))
        while data.count < n {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waited = poll(&ready, 1, Self.replyTimeout)
            if waited == 0 {
                stop()
                throw FileIssue("The server stopped responding to SFTP for \(Self.replyTimeout / 1000) seconds, so the request was abandoned. Check the network and the SSH session, then try again.")
            }
            if waited < 0, errno == EINTR { continue }
            let count = Darwin.read(fd, &buffer, min(buffer.count, n - data.count))
            guard count > 0 else {
                throw FileIssue("SFTP channel closed. Check the SSH session and whether the server permits SFTP.")
            }
            data.append(contentsOf: buffer[0..<count])
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
                    // The long name reads like `ls -l`: mode, links, owner, group, …
                    let columns = String(decoding: try page.bytes(), as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
                    var attr = try page.attributes()
                    if columns.count > 4 {
                        attr.owner = String(columns[2])
                        attr.group = String(columns[3])
                    }
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
    /// chown by number; SFTP always sets both.
    func owner(_ path: String, uid: UInt32, gid: UInt32) throws {
        _ = try request(9, 101) { $0.string(path); $0.number(UInt32(2)); $0.number(uid); $0.number(gid) }
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
    /// Reads `handle` to its end with up to `depth` requests in flight, as OpenSSH's sftp does, so a slow
    /// link costs one round trip per `depth` chunks instead of per chunk. `sink` gets the bytes in order;
    /// if it throws (a cancel), the replies still on their way are drained so the channel stays usable.
    func readAll(_ handle: Data, depth: Int = 16, chunk: UInt32 = 32768, sink: (Data) throws -> Void) throws {
        var pending: [UInt32: (offset: UInt64, length: UInt32)] = [:]
        var received: [UInt64: Data] = [:]
        var next: UInt64 = 0, delivered: UInt64 = 0
        var reachedEnd = false
        func post(_ offset: UInt64, _ length: UInt32) throws {
            sequence &+= 1
            var p = Packet()
            p.number(UInt8(5)); p.number(sequence); p.blob(handle); p.number(offset); p.number(length)
            try send(p)
            pending[sequence] = (offset, length)
        }
        do {
            while true {
                while !reachedEnd, pending.count < depth {
                    try post(next, chunk)
                    next += UInt64(chunk)
                }
                if pending.isEmpty { break }
                var reply = try receive()
                let kind = try reply.take(UInt8.self)
                guard let request = pending.removeValue(forKey: try reply.take(UInt32.self)) else { throw FileIssue("Mismatched SFTP reply.") }
                if kind == 101 {
                    let code = try reply.take(UInt32.self)
                    guard code == 1 else { throw SFTPStatus(code: code, message: try reply.text()) }
                    reachedEnd = true
                    continue
                }
                guard kind == 103 else { throw FileIssue("Unexpected SFTP response.") }
                let bytes = try reply.bytes()
                if bytes.isEmpty { reachedEnd = true; continue }
                received[request.offset] = bytes
                // A short read: ask again for the rest of that range.
                if bytes.count < Int(request.length) {
                    try post(request.offset + UInt64(bytes.count), request.length - UInt32(bytes.count))
                }
                while let ready = received.removeValue(forKey: delivered) {
                    try sink(ready)
                    delivered += UInt64(ready.count)
                }
            }
        } catch {
            for _ in pending { _ = try? receive() }
            throw error
        }
        guard received.isEmpty else { throw FileIssue("The server skipped part of the file; nothing was saved.") }
    }

    /// Writes what `source` returns (nil or empty at the end) from offset 0, with up to `depth` writes in
    /// flight. On an error the outstanding replies are drained first.
    func writeAll(_ handle: Data, depth: Int = 16, source: () throws -> Data?) throws {
        var pending = Set<UInt32>()
        var offset: UInt64 = 0
        var finished = false
        do {
            while true {
                while !finished, pending.count < depth {
                    guard let bytes = try source(), !bytes.isEmpty else { finished = true; break }
                    sequence &+= 1
                    var p = Packet()
                    p.number(UInt8(6)); p.number(sequence); p.blob(handle); p.number(offset); p.blob(bytes)
                    try send(p)
                    pending.insert(sequence)
                    offset += UInt64(bytes.count)
                }
                if pending.isEmpty { break }
                var reply = try receive()
                let kind = try reply.take(UInt8.self)
                guard pending.remove(try reply.take(UInt32.self)) != nil, kind == 101 else { throw FileIssue("Mismatched SFTP reply.") }
                let code = try reply.take(UInt32.self)
                if code != 0 { throw SFTPStatus(code: code, message: try reply.text()) }
            }
        } catch {
            for _ in pending { _ = try? receive() }
            throw error
        }
    }

    func write(_ handle: Data, offset: UInt64, bytes: Data) throws {
        _ = try request(6, 101) { $0.blob(handle); $0.number(offset); $0.blob(bytes) }
    }
}
