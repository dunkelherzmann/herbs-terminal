import Foundation

/// What Get Info shows for one item on a host.
struct FileInfo: Equatable, Sendable {
    var name: String
    var location: String
    var isFolder: Bool
    var isLink = false
    var size: UInt64?
    var modified: Date?
    /// Permission bits, including setuid, setgid and sticky (07777).
    var mode: UInt32
    var owner: String
    var group: String
}

/// The changes Apply makes; nil leaves that attribute as it is on each item.
struct FileInfoChange: Equatable, Sendable {
    var mode: UInt32?
    var owner: String?
    var group: String?
    /// Also change everything inside folders. Folders inside keep their search (x) bits wherever they are
    /// readable, so they stay openable; links inside are left alone.
    var recursive = false

    var isEmpty: Bool { mode == nil && owner == nil && group == nil }
}

/// rwx text for a mode, as `ls -l` shows it (`rwxr-x---`, with s/S and t/T for the special bits).
func symbolicMode(_ mode: UInt32) -> String {
    let marks: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                        (0o004, "r"), (0o002, "w"), (0o001, "x")]
    var text = marks.map { mode & $0.0 != 0 ? $0.1 : "-" }
    func special(_ bit: UInt32, at index: Int, _ set: Character) {
        guard mode & bit != 0 else { return }
        text[index] = text[index] == "x" ? set : Character(set.uppercased())
    }
    special(0o4000, at: 2, "s")
    special(0o2000, at: 5, "s")
    special(0o1000, at: 8, "t")
    return String(text)
}

/// The mode a folder inside a recursive change gets: `mode`, plus search wherever reading is allowed.
func folderMode(_ mode: UInt32) -> UInt32 {
    var result = mode
    if mode & 0o400 != 0 { result |= 0o100 }
    if mode & 0o040 != 0 { result |= 0o010 }
    if mode & 0o004 != 0 { result |= 0o001 }
    return result
}

/// Get Info on a host, over the explorer's SFTP channel, as on Linux.
enum RemoteInfo {
    /// The items `names` in `folder`. A listing carries owner and group names; stat alone only has the numbers.
    static func load(_ names: [String], in folder: String, session: RemoteSession) throws -> [FileInfo] {
        try session.run { client in
            let listed = Dictionary((try? client.list(folder))?.map { ($0.name, $0.attributes) } ?? [], uniquingKeysWith: { a, _ in a })
            return try names.map { name in
                let path = remoteJoin(folder, name)
                let own = try client.stat(path, follow: false)
                let attributes = own.link ? ((try? client.stat(path, follow: true)) ?? own) : own
                return FileInfo(name: name, location: folder, isFolder: attributes.directory, isLink: own.link,
                                size: attributes.size, modified: attributes.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                mode: (attributes.mode ?? 0) & 0o7777,
                                owner: listed[name]?.owner ?? attributes.uid.map(String.init) ?? "",
                                group: listed[name]?.group ?? attributes.gid.map(String.init) ?? "")
            }
        }
    }

    /// Applies `change` to each item. Owner and group names are looked up on the host itself.
    static func apply(_ change: FileInfoChange, to names: [String], in folder: String, session: RemoteSession) throws {
        let uid = try change.owner.map { try account($0, group: false, session: session) }
        let gid = try change.group.map { try account($0, group: true, session: session) }
        try session.run { client in
            for name in names { try apply(change, uid: uid, gid: gid, to: remoteJoin(folder, name), top: true, client: client) }
        }
    }

    private static func apply(_ change: FileInfoChange, uid: UInt32?, gid: UInt32?, to path: String, top: Bool, client: SFTPClient) throws {
        let own = try client.stat(path, follow: false)
        // Inside a folder, links are skipped: SFTP would change whatever they point at.
        if !top, own.link { return }
        let attributes = own.link ? try client.stat(path, follow: true) : own
        if let mode = change.mode { try client.permissions(path, (attributes.directory && !top) ? folderMode(mode) : mode) }
        if uid != nil || gid != nil {
            guard let newUID = uid ?? attributes.uid, let newGID = gid ?? attributes.gid else {
                throw FileIssue("The server didn't report who owns “\(RemotePath.name(path))”.")
            }
            do { try client.owner(path, uid: newUID, gid: newGID) }
            catch let status as SFTPStatus where status.code == 3 {
                throw FileIssue("Only root can give “\(RemotePath.name(path))” to another owner.")
            }
        }
        if change.recursive, attributes.directory, !own.link {
            for entry in try client.list(path) {
                try apply(change, uid: uid, gid: gid, to: remoteJoin(path, entry.name), top: false, client: client)
            }
        }
    }

    /// The number for a user or group name on the host (a number is taken as it is): getent on Linux, dscl on
    /// a Mac host, id for users anywhere.
    static func account(_ name: String, group: Bool, session: RemoteSession) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw FileIssue("“\(name)” isn't a valid account name.") }
        let quoted = "'" + name + "'"
        let command = group
            ? "getent group \(quoted) 2>/dev/null | cut -d: -f3 || dscl . -read /Groups/\(quoted) PrimaryGroupID 2>/dev/null | awk '{print $2}'"
            : "id -u \(quoted) 2>/dev/null"
        let text = try session.execute(command).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let id = UInt32(text.trimmingCharacters(in: .whitespaces)) else {
            throw FileIssue("There's no \(group ? "group" : "user") named “\(name)” on \(session.endpoint.host).")
        }
        return id
    }
}
