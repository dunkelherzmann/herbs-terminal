import Foundation
import Glibc

/// What Get Info shows for one file or folder.
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

/// Get Info on this computer.
enum LocalFileInfo {
    static func load(_ url: URL) throws -> FileInfo {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else { throw FileIssue("“\(url.lastPathComponent)”: \(String(cString: strerror(errno)))") }
        let kind = info.st_mode & S_IFMT
        var target = stat()
        let followed = kind == S_IFLNK && stat(path, &target) == 0
        let shown = followed ? target : info
        return FileInfo(name: url.lastPathComponent, location: url.deletingLastPathComponent().path,
                        isFolder: (shown.st_mode & S_IFMT) == S_IFDIR, isLink: kind == S_IFLNK,
                        size: UInt64(shown.st_size),
                        modified: Date(timeIntervalSince1970: TimeInterval(shown.st_mtim.tv_sec)),
                        mode: UInt32(shown.st_mode) & 0o7777,
                        owner: getpwuid(shown.st_uid).map { String(cString: $0.pointee.pw_name) } ?? String(shown.st_uid),
                        group: getgrgid(shown.st_gid).map { String(cString: $0.pointee.gr_name) } ?? String(shown.st_gid))
    }

    static func apply(_ change: FileInfoChange, to urls: [URL]) throws {
        for url in urls { try apply(change, to: url, top: true) }
    }

    private static func apply(_ change: FileInfoChange, to url: URL, top: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw FileIssue("“\(url.lastPathComponent)”: \(String(cString: strerror(errno)))") }
        // Inside a folder, links are skipped: changing one would change whatever it points at.
        if !top, (info.st_mode & S_IFMT) == S_IFLNK { return }
        var target = info
        if (info.st_mode & S_IFMT) == S_IFLNK { _ = stat(url.path, &target) }
        let isFolder = (target.st_mode & S_IFMT) == S_IFDIR
        if let mode = change.mode {
            guard chmod(url.path, mode_t((isFolder && !top) ? folderMode(mode) : mode)) == 0 else { throw explain(url, ownership: false) }
        }
        if change.owner != nil || change.group != nil {
            let uid = try change.owner.map(Accounts.localUser) ?? UInt32(target.st_uid)
            let gid = try change.group.map(Accounts.localGroup) ?? UInt32(target.st_gid)
            guard chown(url.path, uid, gid) == 0 else { throw explain(url, ownership: change.owner != nil) }
        }
        if change.recursive, isFolder, (info.st_mode & S_IFMT) != S_IFLNK {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try apply(change, to: child, top: false)
            }
        }
    }

    private static func explain(_ url: URL, ownership: Bool) -> Error {
        let code = errno
        guard code == EPERM || code == EACCES else { return FileIssue("“\(url.lastPathComponent)”: \(String(cString: strerror(code)))") }
        return FileIssue(ownership
            ? "Only an administrator can give “\(url.lastPathComponent)” to another owner. Turn on Administrator mode (the lock) and try again."
            : "You don't have permission to change “\(url.lastPathComponent)”. Turn on Administrator mode (the lock) and try again.")
    }
}

/// Account names ↔ numbers. A number is always accepted as it is.
enum Accounts {
    static func localUser(_ name: String) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        if let entry = getpwnam(name) { return entry.pointee.pw_uid }
        if let id = hostLookup(["/usr/bin/id", "-u", name]) { return id }
        throw FileIssue("There's no user named “\(name)” on this computer.")
    }

    static func localGroup(_ name: String) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        if let entry = getgrnam(name) { return entry.pointee.gr_gid }
        if let line = Host.run(["/usr/bin/getent", "group", name], timeout: 5).output.split(separator: "\n").first,
           let id = line.split(separator: ":", omittingEmptySubsequences: false).dropFirst(2).first.flatMap({ UInt32($0) }) {
            return id
        }
        throw FileIssue("There's no group named “\(name)” on this computer.")
    }

    /// The Flatpak's own account list only knows this user; the host knows them all.
    private static func hostLookup(_ command: [String]) -> UInt32? {
        let result = Host.run(command, timeout: 5)
        guard result.status == 0 else { return nil }
        return UInt32(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The number for a user or group name on `endpoint`, asked over the tab's shared SSH connection.
    static func remote(_ name: String, group: Bool, on endpoint: RemoteEndpoint) throws -> UInt32 {
        if let id = UInt32(name) { return id }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw FileIssue("“\(name)” isn't a valid account name.") }
        let quoted = shellQuote(name)
        // getent on Linux, dscl on a Mac host; id covers users anywhere.
        let command = group
            ? "getent group \(quoted) 2>/dev/null | cut -d: -f3 || dscl . -read /Groups/\(quoted) PrimaryGroupID 2>/dev/null | awk '{print $2}'"
            : "id -u \(quoted) 2>/dev/null"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = endpoint.sshArguments(["-o", "BatchMode=yes", "-T"]) + [command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let id = UInt32(text.trimmingCharacters(in: .whitespaces)) else {
            throw FileIssue("There's no \(group ? "group" : "user") named “\(name)” on \(endpoint.host).")
        }
        return id
    }
}

/// Where Get Info reads and writes: this computer's files, or a host's over SFTP.
struct FileInfoSource {
    let title: String
    let load: () async throws -> [FileInfo]
    let apply: (FileInfoChange) async throws -> Void

    static func local(_ urls: [URL]) -> FileInfoSource {
        FileInfoSource(title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
                       load: { try await Task.detached { try urls.map(LocalFileInfo.load) }.value },
                       apply: { change in try await Task.detached { try LocalFileInfo.apply(change, to: urls) }.value })
    }
}

/// Where an edited file lives: this computer, or a host the explorer reaches over SFTP (as root in Administrator
/// mode). `version` is checked before each save so changes made elsewhere aren't overwritten silently.
struct TextFileSource {
    struct Version: Equatable, Sendable {
        let size: UInt64?
        let modified: Double?
    }

    let name: String
    /// Shown as the tab's subtitle and used to find an already open tab: a path, or user@host:path.
    let location: String
    let read: () async throws -> Data
    let version: () async throws -> Version?
    let write: (Data) async throws -> Void

    static func local(_ url: URL) -> TextFileSource {
        // Edit the file a link points at; an atomic save would otherwise replace the link with a copy.
        let url = url.resolvingSymlinksInPath()
        return TextFileSource(
            name: url.lastPathComponent, location: url.path,
            read: { try await Task.detached { try Data(contentsOf: url) }.value },
            version: {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
                return Version(size: (attributes[.size] as? NSNumber)?.uint64Value,
                               modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
            },
            write: { data in
                try await Task.detached {
                    let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    try data.write(to: url, options: .atomic)
                    if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                }.value
            })
    }
}

/// Text encodings the editor reads and writes back unchanged.
enum TextCodec {
    static let sizeLimit = 20 * 1024 * 1024

    /// The text and its encoding, or nil for a file that looks binary (NUL bytes without a UTF-16 mark).
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return (text, .utf16) }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        // Every byte sequence is valid Latin-1, so older 8-bit files still open and save byte for byte.
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1) }
    }

    static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .isoLatin1: "Latin-1"
        default: "\(encoding)"
        }
    }

    /// Plain text, Markdown, source code, scripts, configuration, JSON, YAML, XML, CSV and logs.
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst", "adoc", "org", "log", "csv", "tsv", "json", "jsonc", "json5", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "config", "properties", "env", "xml", "plist", "html", "htm", "xhtml", "css", "scss",
        "sass", "less", "svg", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "swift", "go", "rs", "py", "pyw", "rb", "pl", "pm", "php", "java", "kt", "kts", "scala", "cs", "fs", "lua", "r",
        "sql", "sh", "bash", "zsh", "fish", "ksh", "csh", "ps1", "bat", "cmd", "mk", "make", "cmake", "gradle", "dockerfile",
        "service", "socket", "timer", "mount", "desktop", "rules", "repo", "list", "diff", "patch", "tex", "bib", "vim",
        "el", "lisp", "clj", "hs", "ml", "ex", "exs", "erl", "dart", "vue", "svelte", "graphql", "proto", "tf", "hcl",
        "nix", "spec", "pem", "crt", "pub", "key", "csr", "gitignore", "gitattributes", "editorconfig", "npmrc", "lock",
    ]

    /// Formats that aren't text, so their files open in another app without being sniffed.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "ico", "icns", "pdf", "zip", "gz", "tgz", "bz2",
        "xz", "zst", "7z", "rar", "tar", "iso", "dmg", "img", "deb", "rpm", "apk", "flatpak", "appimage", "exe", "dll",
        "so", "a", "o", "dylib", "class", "jar", "war", "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "mp4", "m4v",
        "mov", "mkv", "avi", "webm", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "ttf", "otf",
        "woff", "woff2", "sqlite", "sqlite3", "db", "bin", "dat", "pyc",
    ]

    /// Whether a file opens in the editor rather than its own app: text types by extension, and files without a
    /// known type whose first bytes look like text.
    static func isText(name: String, sniff: () -> Data?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) || textExtensions.contains(name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            return true
        }
        if binaryExtensions.contains(ext) { return false }
        guard let head = sniff() else { return false }
        return decode(head) != nil
    }

    static func isLocalText(_ url: URL) -> Bool {
        isText(name: url.lastPathComponent) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8192)
        }
    }
}
