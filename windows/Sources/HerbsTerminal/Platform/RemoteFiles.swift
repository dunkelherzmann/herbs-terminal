import Foundation
import WinSDK

/// The explorer's own SFTP channel to an SSH tab's host. On the Mac and Linux the explorer rides the tab's shared
/// connection; Windows' OpenSSH has no `ControlMaster`, so this signs in separately (through `SFTPRelay`), with the
/// tab's saved password through the password helper (section 4) or with keys and `ssh-agent`. It only accepts host keys that are
/// already known: the terminal tab asks about a new one first. Requests run one at a time.
final class RemoteSession: @unchecked Sendable {
    let endpoint: RemoteEndpoint
    private let password: String?
    private let lock = NSLock()
    private var client: SFTPClient?

    init(endpoint: RemoteEndpoint, password: String?) {
        self.endpoint = endpoint
        self.password = password
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

    private func connect() throws -> SFTPClient {
        guard SSH.executable != nil else {
            throw FileIssue("Windows' OpenSSH client isn't installed. Add it in Settings ▸ System ▸ Optional features ▸ OpenSSH Client.")
        }
        var arguments = ["-p", String(endpoint.port)] + SSH.keepAliveOptions
        arguments += ["-o", "ControlPath=none", "-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1"]
        // The relay's first input line: the password helper's pipe and a one-time token, or "-" for keys only.
        var preamble = "-\n"
        if let password, !password.isEmpty, let broker = AskpassBroker.shared {
            preamble = "\(broker.pipeName) \(broker.issue(password, for: endpoint.passwordLogins))\n"
        } else {
            arguments += ["-o", "BatchMode=yes"] // Keys and ssh-agent only; nothing could answer a prompt.
        }
        arguments += ["-T", "-s", "\(endpoint.username)@\(endpoint.host)", "sftp"]
        do {
            return try SFTPClient(executable: AskpassBroker.executablePath, arguments: [SFTPRelay.flag] + arguments,
                                  preamble: Data(preamble.utf8))
        } catch {
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
    static func remove(_ path: String, client: SFTPClient) throws {
        let attributes = try client.stat(path)
        if attributes.directory {
            for entry in try client.list(path) { try remove(remoteJoin(path, entry.name), client: client) }
            try client.remove(path, directory: true)
        } else {
            try client.remove(path)
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
}

extension RemoteEndpoint {
    /// The names ssh's password prompt uses for this login ("user@host's password:").
    var passwordLogins: [String] { ["\(username)@\(host)"] }
}
