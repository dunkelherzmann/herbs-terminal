import Foundation
import WinSDK

/// The explorer's own SFTP channel to an SSH tab's host. On the Mac and Linux the explorer rides the tab's shared
/// connection; Windows' OpenSSH has no `ControlMaster`, so this signs in separately (through `SFTPRelay`), with the
/// tab's saved password through the password helper (section 4) or with keys and `ssh-agent`. It only accepts host keys that are
/// already known: the terminal tab asks about a new one first. Requests run one at a time.
final class RemoteSession: @unchecked Sendable {
    let endpoint: RemoteEndpoint
    private let password: String?
    /// Administrator mode: the host's own SFTP server runs under sudo, so every request runs as root.
    let asRoot: Bool
    /// The sudo password, sent once on sudo's standard input (`sudo -S`); nil for password-free sudo.
    private let sudoPassword: String?
    private let lock = NSLock()
    private var client: SFTPClient?

    /// A Tailcat peer's secret address: each connection gets its own one-time ProxyCommand from it.
    private let tailcatAddress: String?

    init(endpoint: RemoteEndpoint, password: String?, asRoot: Bool = false, sudoPassword: String? = nil, tailcatAddress: String? = nil) {
        self.endpoint = endpoint
        self.password = password
        self.tailcatAddress = tailcatAddress
        self.asRoot = asRoot
        self.sudoPassword = sudoPassword
    }

    /// Whether this login has a password to sign in with (otherwise only keys and ssh-agent).
    var hasPassword: Bool { password?.isEmpty == false }

    /// The same login with `password` (asked for by the explorer when keys don't sign in).
    func with(password: String) -> RemoteSession {
        RemoteSession(endpoint: endpoint, password: password, asRoot: asRoot, sudoPassword: sudoPassword, tailcatAddress: tailcatAddress)
    }

    /// The same login as root (Administrator mode).
    func administrator(sudoPassword: String?) -> RemoteSession {
        RemoteSession(endpoint: endpoint, password: password, asRoot: true, sudoPassword: sudoPassword, tailcatAddress: tailcatAddress)
    }

    /// Finds the SFTP server, wherever its OpenSSH package put it (as on the Mac and Linux).
    static let serverSearch = "for p in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server "
        + "/usr/libexec/sftp-server /usr/lib/sftp-server /usr/sbin/sftp-server; do "
        + "if [ -x \"$p\" ]; then exec \"$p\"; fi; done; echo \"no sftp-server found\" >&2; exit 127"

    /// True unless sudo works without a password for this account on the host.
    func sudoNeedsPassword() throws -> Bool {
        !(try execute("sudo -n -v 2>/dev/null && echo herbs-sudo-ok")).contains("herbs-sudo-ok")
    }

    /// Checks the sudo password on its own first: a wrong one must never reach the SFTP session, where sudo would
    /// wait for another attempt.
    func checkSudo(_ password: String) throws -> Bool {
        (try execute("sudo -S -k -v -p '' 2>/dev/null && echo herbs-sudo-ok", input: password + "\n")).contains("herbs-sudo-ok")
    }

    /// Runs `body` with the channel, connecting first if needed. A channel that has died is replaced once.
    func run<T>(_ body: (SFTPClient) throws -> T) throws -> T {
        try lock.withLock {
            if let client {
                do { return try body(client) } catch let error as FileIssue where Self.isChannelError(error) {
                    self.client = nil // The connection dropped; sign in again below.
                }
            }
            let fresh = try connect()
            client = fresh
            return try body(fresh)
        }
    }

    func disconnect() {
        lock.withLock { client = nil }
    }

    private static func isChannelError(_ error: FileIssue) -> Bool {
        error.message.hasPrefix("SFTP channel closed") || error.message.hasPrefix("The server stopped responding")
    }

    /// ssh's options for this host, and the relay's first input line: the password helper's pipe and a one-time
    /// token, or "-" for keys only.
    func relaySetup() throws -> (arguments: [String], preamble: String, destination: String) {
        guard SSH.executable != nil else {
            throw FileIssue("Windows' OpenSSH client isn't installed. Add it in Settings ▸ System ▸ Optional features ▸ OpenSSH Client.")
        }
        var arguments = SSH.keepAliveOptions + ["-o", "ControlPath=none", "-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1"]
        var destination = "\(endpoint.username)@\(endpoint.host)"
        var logins = endpoint.passwordLogins
        if let tailcatAddress {
            // Through a loopback port the app forwards to the peer (Windows' ssh stalls on a ProxyCommand here).
            let direct = try Tailcat.directOptions(address: tailcatAddress, endpoint: endpoint)
            arguments += direct.options
            destination = direct.destination
            logins.append(direct.destination) // ssh's password prompt names the loopback address.
        } else {
            arguments += ["-p", String(endpoint.port)]
        }
        var preamble = "-\n"
        if let password, !password.isEmpty, let broker = AskpassBroker.shared {
            preamble = "\(broker.pipeName) \(broker.issue(password, for: logins))\n"
        } else {
            arguments += ["-o", "BatchMode=yes"] // Keys and ssh-agent only; nothing could answer a prompt.
        }
        return (arguments, preamble, destination)
    }

    /// Runs one shell command on the host and returns what it printed. Windows' ssh can't reuse the tab's
    /// connection, so this signs in once more, the same way as the SFTP channel. It ends after 20 seconds.
    func execute(_ command: String, input: String? = nil) throws -> String {
        let setup = try relaySetup()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AskpassBroker.executablePath)
        process.arguments = [SFTPRelay.flag] + setup.arguments + ["-T", setup.destination, command]
        let pipe = Pipe(), output = Pipe()
        process.standardInput = pipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.write(contentsOf: Data((setup.preamble + (input ?? "")).utf8))
        try? pipe.fileHandleForWriting.close()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    private func connect() throws -> SFTPClient {
        let setup = try relaySetup()
        var arguments = setup.arguments
        var preamble = setup.preamble
        if asRoot {
            // sudo reads its password line first; everything after it is the SFTP conversation.
            let sudo = sudoPassword == nil ? "sudo -n" : "sudo -S -k -p ''"
            arguments += ["-T", setup.destination, "\(sudo) /bin/sh -c '\(Self.serverSearch)'"]
            if let sudoPassword { preamble += sudoPassword + "\n" }
        } else {
            arguments += ["-T", "-s", setup.destination, "sftp"]
        }
        do {
            return try SFTPClient(executable: AskpassBroker.executablePath, arguments: [SFTPRelay.flag] + arguments,
                                  preamble: Data(preamble.utf8))
        } catch {
            if asRoot {
                throw FileIssue("The root SFTP server didn't start on \(endpoint.host) (\(error.localizedDescription)). "
                    + "The host needs OpenSSH's sftp-server, and sudo must accept the password.")
            }
            throw FileIssue("Couldn't open the files of \(endpoint.label): \(error.localizedDescription) "
                + "The explorer signs in with the tab's saved password, or with SSH keys.")
        }
    }
}

/// File operations on a host, as on Linux: free " copy" names, deleting whole folders, copying on the host.
enum RemoteFiles {
    static let read: UInt32 = 0x01, write: UInt32 = 0x02, create: UInt32 = 0x08, exclusive: UInt32 = 0x20

    /// A name in `folder` nothing has yet: `name`, then "name copy", "name copy 2"… (extension kept).
    static func destination(for name: String, in folder: String, client: SFTPClient) throws -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = remoteJoin(folder, name)
        var index = 1
        while try client.existing(candidate) != nil {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            candidate = remoteJoin(folder, base + suffix + (ext.isEmpty ? "" : "." + ext))
            index += 1
        }
        return candidate
    }

    /// New Folder / New File names: "untitled folder", then "untitled folder 2", 3… as on this PC.
    static func freeName(_ base: String, in folder: String, client: SFTPClient) throws -> String {
        if try client.existing(remoteJoin(folder, base)) == nil { return base }
        var number = 2
        while try client.existing(remoteJoin(folder, "\(base) \(number)")) != nil { number += 1 }
        return "\(base) \(number)"
    }

    static func newFile(_ path: String, client: SFTPClient) throws {
        try client.close(try client.open(path, flags: write | create | exclusive, mode: 0o644))
    }

    /// Deletes `path`, emptying folders first. Links are removed, never followed.
    ///
    /// `asRoot` (Administrator mode): SFTP removes by path, so another account that could change a folder in the
    /// tree could swap it for a link mid-delete and point root's deletes elsewhere. As root, a folder is only
    /// emptied when root owns it and the folder holding it and no other account can write to them; otherwise
    /// nothing more is deleted and the error says why.
    static func remove(_ path: String, client: SFTPClient, asRoot: Bool = false, top: Bool = true) throws {
        let attributes = try client.stat(path)
        if attributes.directory {
            if asRoot {
                if top { try requireRootOnly(RemotePath.parent(path), try client.stat(RemotePath.parent(path)), deleting: path) }
                try requireRootOnly(path, attributes, deleting: path)
            }
            for entry in try client.list(path) { try remove(remoteJoin(path, entry.name), client: client, asRoot: asRoot, top: false) }
            try client.remove(path, directory: true)
        } else {
            try client.remove(path)
        }
    }

    private static func requireRootOnly(_ folder: String, _ attributes: RemoteAttributes, deleting path: String) throws {
        let mode = attributes.mode ?? 0o7777
        // Group write is fine for root's and the administrators' groups, whose members can use sudo anyway.
        let trustedGroup = attributes.gid == 0 || attributes.gid == 80
        guard attributes.uid == 0, mode & 0o002 == 0, mode & 0o020 == 0 || trustedGroup else {
            throw FileIssue("“\(RemotePath.name(path))” wasn't deleted as root: \(folder) can be changed by another account, "
                + "which could redirect the deletion. Turn off Administrator mode to delete it with your own account's access.")
        }
    }

    /// Copies a file or folder tree to `target` (a new name) on the same host. One channel can't read and write in
    /// the same pipeline, so each file passes through a private temporary file on this PC. Links inside are skipped.
    static func copy(_ source: String, to target: String, client: SFTPClient, top: Bool = true) throws {
        let attributes = try client.stat(source, follow: top)
        if attributes.link { return }
        if attributes.directory {
            let children = try client.list(source)
            try client.mkdir(target)
            for entry in children { try copy(remoteJoin(source, entry.name), to: remoteJoin(target, entry.name), client: client, top: false) }
            return
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("herbsterminal-copy-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw FileIssue("Couldn't stage the copy on this PC.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let writer = try FileHandle(forWritingTo: staging)
        let input = try client.open(source, flags: read)
        do {
            try client.readAll(input) { try writer.write(contentsOf: $0) }
            try client.close(input)
            try writer.close()
        } catch {
            try? client.close(input)
            try? writer.close()
            throw error
        }
        let reader = try FileHandle(forReadingFrom: staging)
        defer { try? reader.close() }
        // The target is a new name; opening it exclusively never writes through something already there.
        let output = try client.open(target, flags: write | create | exclusive, mode: (attributes.mode ?? 0o644) & 0o777)
        do {
            try client.writeAll(output) { try reader.read(upToCount: 32768) }
            try client.close(output)
        } catch {
            try? client.close(output)
            throw error
        }
    }
}

/// POSIX path helpers for host paths.
enum RemotePath {
    /// Collapses `.`, `..`, repeated and trailing slashes.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func parent(_ path: String) -> String { normalize(path + "/..") }

    /// The last part of a path ("/" for the root).
    static func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "/" }

    /// Location-field input: absolute, `~`-relative, or relative to the current folder.
    static func resolve(_ input: String, from current: String, home: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "~" || text.hasPrefix("~/") { return normalize(home + text.dropFirst()) }
        return normalize(text.hasPrefix("/") ? text : remoteJoin(current, text))
    }
}

/// Items cut or copied in a host's explorer, which paste into an explorer of the same host. Copying them to this PC
/// comes with transfers.
@MainActor
enum RemoteClipboard {
    static var host: String?
    static var paths: [String] = []
    static var move = false
    static var session: RemoteSession?
    /// The Windows clipboard's sequence number right after the host items were copied.
    private static var sequence: DWORD = 0

    /// Host items were copied and nothing newer is on the Windows clipboard.
    static var isCurrent: Bool { !paths.isEmpty && sequence == GetClipboardSequenceNumber() }

    /// Copy or Cut in a host's explorer. The Windows clipboard gets the paths as text (so a later copy elsewhere
    /// clearly replaces them), and pasting into this PC's explorer downloads the items.
    static func put(_ paths: [String], move: Bool, from session: RemoteSession, owner: HWND?) {
        host = session.endpoint.label
        self.paths = paths
        self.move = move
        self.session = session
        setClipboardText(paths.joined(separator: "\r\n"), owner: owner)
        sequence = GetClipboardSequenceNumber()
    }

    static func clear() { paths = [] }
}

extension RemoteEndpoint {
    /// The names ssh's password prompt uses for this login ("user@host's password:").
    var passwordLogins: [String] { ["\(username)@\(host)"] }
}

extension RemoteSession {
    /// Another channel to the same host with the same login, so transfers don't hold up browsing.
    func twin() -> RemoteSession { RemoteSession(endpoint: endpoint, password: password, asRoot: asRoot, sudoPassword: sudoPassword, tailcatAddress: tailcatAddress) }
}

/// Streams files and folders between this PC and a host over one SFTP channel, as Linux's `SFTPTransfer` does.
/// Uploads land under an unguessable temporary name opened exclusively and are renamed into place, so an
/// interrupted upload never leaves a half-written file under the real name, and nothing already there is written
/// through. Downloads are staged the same way on this PC.
struct RemoteTransfer {
    let client: SFTPClient
    var progress: (Int64) -> Void = { _ in }
    var isCancelled: () -> Bool = { false }

    func upload(_ local: URL, to remote: String) throws {
        try checkCancelled()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isFolder) else {
            throw FileIssue("“\(local.lastPathComponent)” no longer exists on this PC.")
        }
        if isFolder.boolValue {
            try client.mkdir(remote)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, to: remoteJoin(remote, child.lastPathComponent))
            }
            return
        }
        // Windows has no POSIX permissions to carry over; files arrive as rw-r--r--.
        let tag = UUID().uuidString.prefix(8).lowercased()
        let part = remoteJoin(RemotePath.parent(remote), ".\(RemotePath.name(remote)).\(tag).herbsterminal-part")
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        let handle = try client.open(part, flags: RemoteFiles.write | RemoteFiles.create | RemoteFiles.exclusive, mode: 0o644)
        do {
            try client.writeAll(handle) {
                try checkCancelled()
                guard let chunk = try source.read(upToCount: 32768), !chunk.isEmpty else { return nil }
                progress(Int64(chunk.count))
                return chunk
            }
            try client.close(handle)
            try client.rename(part, remote)
        } catch {
            try? client.close(handle)
            try? client.remove(part)
            throw error
        }
    }

    /// `top` is the item that was picked, followed if it's a link. Inside a folder, links are skipped, so a link
    /// such as `loop -> ..` can't recurse forever.
    func download(_ remote: String, to local: URL, top: Bool = true) throws {
        try checkCancelled()
        let attributes = try client.stat(remote, follow: top)
        if attributes.link { return }
        if attributes.directory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            for entry in try client.list(remote) {
                try download(remoteJoin(remote, entry.name), to: local.appendingPathComponent(entry.name), top: false)
            }
            return
        }
        let part = local.deletingLastPathComponent().appendingPathComponent(".\(local.lastPathComponent).herbsterminal-part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw FileIssue("Couldn't write in “\(local.deletingLastPathComponent().path)”.")
        }
        do {
            let target = try FileHandle(forWritingTo: part)
            defer { try? target.close() }
            let handle = try client.open(remote, flags: RemoteFiles.read)
            defer { try? client.close(handle) }
            try client.readAll(handle) { chunk in
                try checkCancelled()
                try target.write(contentsOf: chunk)
                progress(Int64(chunk.count))
            }
            try target.close()
            try FileManager.default.moveItem(at: part, to: local)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    func size(of remote: String, top: Bool = true) throws -> Int64 {
        let attributes = try client.stat(remote, follow: top)
        if attributes.link { return 0 }
        guard attributes.directory else { return Int64(attributes.size ?? 0) }
        return try client.list(remote).reduce(0) { $0 + (try size(of: remoteJoin(remote, $1.name), top: false)) }
    }

    static func size(of local: URL) -> Int64 {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isFolder), isFolder.boolValue else {
            return ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        let walker = FileManager.default.enumerator(atPath: local.path)
        var total: Int64 = 0
        while walker?.nextObject() != nil {
            total += ((walker?.fileAttributes?[.size]) as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    /// A name on this PC that nothing has yet: `name`, then "name copy", "name copy 2"… as on the Mac and Linux.
    static func localDestination(for name: String, in folder: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(base + (index == 1 ? " copy" : " copy \(index)") + (ext.isEmpty ? "" : "." + ext))
            index += 1
        }
        return candidate
    }

    private func checkCancelled() throws {
        if isCancelled() { throw FileIssue("Transfer cancelled.") }
    }
}

/// Shared between a background transfer and the Cancel button that stops it.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func cancel() { lock.withLock { set = true } }
}

/// Collects byte counts from a background transfer and reports them about ten times a second.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var reported = Date.distantPast
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func add(_ bytes: Int64) {
        let snapshot: Int64? = lock.withLock {
            done += bytes
            guard Date().timeIntervalSince(reported) > 0.1 else { return nil }
            reported = Date()
            return done
        }
        if let snapshot { report(snapshot) }
    }
}
