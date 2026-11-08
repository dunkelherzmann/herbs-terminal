import Foundation
import WinSDK

/// Where an edited file lives: this PC, or a host the explorer reaches over SFTP. `version` is checked before
/// each save so changes made elsewhere aren't overwritten silently. The closures block, so the editor calls them
/// off the window thread.
struct TextFileSource: Sendable {
    struct Version: Equatable, Sendable {
        let size: UInt64?
        let modified: Double?
    }

    let name: String
    /// Shown as the toolbar's subtitle and used to find an already open tab: a path, or user@host:path.
    let location: String
    let read: @Sendable () throws -> Data
    let version: @Sendable () throws -> Version?
    let write: @Sendable (Data) throws -> Void

    static func local(_ path: String) -> TextFileSource {
        // Edit the file a link points at; replacing the link would otherwise turn it into a copy.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let path = url.path.windowsPath
        return TextFileSource(
            name: url.lastPathComponent, location: path,
            read: {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                if let size = (attributes[.size] as? NSNumber)?.intValue, size > TextCodec.sizeLimit { throw TextCodec.tooLarge(url.lastPathComponent) }
                return try Data(contentsOf: url)
            },
            version: {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
                return Version(size: (attributes[.size] as? NSNumber)?.uint64Value,
                               modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
            },
            write: { data in try LocalReplace.write(data, to: path) })
    }

    /// A host's file, through the explorer's SFTP channel.
    static func remote(_ path: String, session: RemoteSession) -> TextFileSource {
        TextFileSource(
            name: RemotePath.name(path), location: "\(session.endpoint.label):\(path)",
            read: { try session.run { try RemoteTransfer(client: $0).readAll(path, limit: TextCodec.sizeLimit) } },
            version: {
                let attributes = try session.run { try $0.stat(path, follow: true) }
                return Version(size: attributes.size, modified: attributes.modified.map(Double.init))
            },
            write: { data in try session.run { try RemoteTransfer(client: $0).replace(path, with: data) } })
    }
}

/// Saving on this PC: the text goes to a new file beside the original, which then takes the original's place with
/// ReplaceFileW. The file keeps its attributes, permissions (ACL) and creation date, and a failure part-way leaves
/// the original as it was.
enum LocalReplace {
    static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            try data.write(to: url) // Deleted meanwhile: saving puts it back.
            return
        }
        let folder = url.deletingLastPathComponent().path.windowsPath
        let staging = (folder.hasSuffix("\\") ? folder : folder + "\\") + ".\(url.lastPathComponent).\(Foundation.UUID().uuidString.prefix(8)).herbsterminal-part"
        let handle = withWide(staging) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_HIDDEN), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw issue(GetLastError(), url.lastPathComponent) }
        var ok = true
        data.withUnsafeBytes { bytes in
            var offset = 0
            while ok, offset < bytes.count {
                var written: DWORD = 0
                let chunk = DWORD(min(bytes.count - offset, 1 << 20))
                ok = WriteFile(handle, bytes.baseAddress! + offset, chunk, &written, nil) && written > 0
                offset += Int(written)
            }
        }
        if ok { ok = FlushFileBuffers(handle) }
        let error = ok ? 0 : GetLastError()
        CloseHandle(handle)
        guard ok else {
            _ = withWide(staging) { DeleteFileW($0) }
            throw issue(error, url.lastPathComponent)
        }
        let replaced = withWide(path) { target in withWide(staging) { ReplaceFileW(target, $0, nil, DWORD(REPLACEFILE_IGNORE_MERGE_ERRORS), nil, nil) } }
        if !replaced {
            let error = GetLastError()
            _ = withWide(staging) { DeleteFileW($0) }
            throw issue(error, url.lastPathComponent)
        }
    }

    private static func issue(_ code: DWORD, _ name: String) -> FileIssue {
        switch Int32(code) {
        case ERROR_ACCESS_DENIED: FileIssue("You don't have permission to change “\(name)” or its folder.")
        case ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION, ERROR_UNABLE_TO_REMOVE_REPLACED, ERROR_UNABLE_TO_MOVE_REPLACEMENT:
            FileIssue("“\(name)” is open in another program that won't let it be replaced. Close it there and save again.")
        case ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL: FileIssue("There isn't enough space to save “\(name)”.")
        default: FileIssue("“\(name)” couldn't be saved (Windows error \(code)).")
        }
    }
}

extension RemoteTransfer {
    /// The whole file, refused when it's larger than `limit`.
    func readAll(_ path: String, limit: Int) throws -> Data {
        let attributes = try client.stat(path, follow: true)
        guard !attributes.directory else { throw FileIssue("“\(RemotePath.name(path))” is a folder.") }
        if let size = attributes.size, size > UInt64(limit) { throw TextCodec.tooLarge(RemotePath.name(path)) }
        let handle = try client.open(path, flags: RemoteFiles.read)
        defer { try? client.close(handle) }
        var data = Data()
        try client.readAll(handle) { chunk in
            data.append(chunk)
            guard data.count <= limit else { throw TextCodec.tooLarge(RemotePath.name(path)) }
        }
        return data
    }

    /// Saves the text editor's file: written in full under an unguessable name next to it, then renamed over it,
    /// so a dropped connection never leaves it half written. Its permissions are kept.
    func replace(_ path: String, with data: Data) throws {
        let mode = ((try? client.stat(path, follow: true))?.mode ?? 0o644) & 0o777
        let tag = Foundation.UUID().uuidString.prefix(8).lowercased()
        let part = remoteJoin(RemotePath.parent(path), ".\(RemotePath.name(path)).\(tag).herbsterminal-part")
        let handle = try client.open(part, flags: RemoteFiles.write | RemoteFiles.create | RemoteFiles.exclusive, mode: mode)
        do {
            var offset = 0
            try client.writeAll(handle) {
                guard offset < data.count else { return nil }
                let chunk = data.subdata(in: offset..<min(data.count, offset + 32768))
                offset += chunk.count
                return chunk
            }
            try client.close(handle)
            try client.rename(part, path, replace: true)
        } catch {
            try? client.close(handle)
            try? client.remove(part)
            throw error
        }
    }
}

/// Text encodings the editor reads and writes back unchanged, and which files count as text.
enum TextCodec {
    static let sizeLimit = 20 * 1024 * 1024

    static func tooLarge(_ name: String) -> FileIssue {
        FileIssue("“\(name)” is larger than \(sizeLimit / 1_048_576) MB, too big to edit here.")
    }

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

    /// The line ending a text uses most: CRLF, LF or CR (LF for a text without any).
    static func lineEnding(of text: String) -> String {
        var crlf = 0, lf = 0, cr = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 10 { if previous == 13 { crlf += 1; cr -= 1 } else { lf += 1 } }
            if byte == 13 { cr += 1 }
            previous = byte
        }
        if crlf >= lf && crlf >= cr && crlf > 0 { return "\r\n" }
        return cr > lf ? "\r" : "\n"
    }

    static func name(ofEnding ending: String) -> String {
        switch ending {
        case "\r\n": "CRLF"
        case "\r": "CR"
        default: "LF"
        }
    }

    /// Plain text, Markdown, source code, scripts, configuration, JSON, YAML, XML, CSV and logs.
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst", "adoc", "org", "log", "csv", "tsv", "json", "jsonc", "json5", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "config", "properties", "env", "xml", "plist", "html", "htm", "xhtml", "css", "scss",
        "sass", "less", "svg", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "swift", "go", "rs", "py", "pyw", "rb", "pl", "pm", "php", "java", "kt", "kts", "scala", "cs", "fs", "lua", "r",
        "sql", "sh", "bash", "zsh", "fish", "ksh", "csh", "ps1", "psm1", "psd1", "bat", "cmd", "vbs", "reg", "inf",
        "mk", "make", "cmake", "gradle", "dockerfile", "sln", "csproj", "vcxproj", "props", "targets", "manifest", "xaml",
        "service", "socket", "timer", "mount", "desktop", "rules", "repo", "list", "diff", "patch", "tex", "bib", "vim",
        "el", "lisp", "clj", "hs", "ml", "ex", "exs", "erl", "dart", "vue", "svelte", "graphql", "proto", "tf", "hcl",
        "nix", "spec", "pem", "crt", "pub", "key", "csr", "gitignore", "gitattributes", "editorconfig", "npmrc", "lock",
    ]

    /// Formats that aren't text, so their files open in another app without being sniffed.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "ico", "icns", "pdf", "zip", "gz", "tgz", "bz2",
        "xz", "zst", "7z", "rar", "tar", "iso", "dmg", "img", "deb", "rpm", "apk", "msi", "msix", "appx", "cab", "exe", "dll",
        "sys", "lnk", "url", "so", "a", "o", "obj", "lib", "pdb", "dylib", "class", "jar", "war", "mp3", "m4a", "aac", "flac",
        "ogg", "opus", "wav", "wma", "mp4", "m4v", "mov", "mkv", "avi", "wmv", "webm", "doc", "docx", "xls", "xlsx", "ppt",
        "pptx", "odt", "ods", "odp", "ttf", "otf", "woff", "woff2", "sqlite", "sqlite3", "db", "bin", "dat", "pyc",
    ]

    /// Whether a file opens in the editor rather than its own app: text types by extension, and files without a
    /// known type whose first bytes look like text. `sniff` returns nil when the content can't be read cheaply.
    static func isText(name: String, sniff: () -> Data?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let bare = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if textExtensions.contains(ext) || textExtensions.contains(bare) { return true }
        if binaryExtensions.contains(ext) { return false }
        guard let head = sniff() else { return false }
        return decode(head) != nil
    }

    static func isLocalText(_ path: String) -> Bool {
        isText(name: (path as NSString).lastPathComponent) {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8192)
        }
    }
}
