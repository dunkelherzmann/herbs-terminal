import Foundation

/// Thunar-style back/forward history for one explorer pane, keyed by POSIX path.
struct NavigationHistory: Equatable {
    static let limit = 100
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    private(set) var current: String

    init(_ start: String) { current = start }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Records a new location. Revisiting the current one is ignored; anything else clears forward history.
    mutating func visit(_ path: String) {
        guard path != current else { return }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
        current = path
    }

    mutating func goBack() -> String? {
        guard let previous = back.popLast() else { return nil }
        forward.append(current)
        current = previous
        return previous
    }

    mutating func goForward() -> String? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        current = next
        return next
    }
}

struct PathSegment: Equatable {
    let name: String
    let path: String
}

/// The clickable path buttons for a location, root first.
func pathSegments(_ path: String) -> [PathSegment] {
    var segments = [PathSegment(name: "/", path: "/")]
    var built = ""
    for part in normalizePath(path).split(separator: "/") {
        built += "/" + part
        segments.append(PathSegment(name: String(part), path: built))
    }
    return segments
}

/// Collapses `.`, `..`, repeated and trailing slashes without touching the filesystem.
func normalizePath(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
        if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
}

func parentPath(_ path: String) -> String { normalizePath(path + "/..") }

/// Resolves location-field input: absolute, `~`-relative, or relative to the current folder.
func resolveLocation(_ input: String, from current: String, home: String?) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text == "~" || text.hasPrefix("~/") {
        guard let home else { return nil }
        return normalizePath(home + text.dropFirst())
    }
    return normalizePath(text.hasPrefix("/") ? text : remoteJoin(current, text))
}

/// Bookmarks kept as newline-separated paths in one string, optionally scoped to a remote host.
struct BookmarkList {
    var raw: String
    let scope: String

    var paths: [String] {
        raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if scope.isEmpty { return parts.count == 1 ? parts[0] : nil }
            return parts.count == 2 && parts[0] == scope ? parts[1] : nil
        }
    }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    mutating func toggle(_ path: String) {
        let line = scope.isEmpty ? path : scope + "\t" + path
        var lines = raw.split(separator: "\n").map(String.init)
        if let index = lines.firstIndex(of: line) { lines.remove(at: index) } else { lines.append(line) }
        raw = lines.joined(separator: "\n")
    }
}

struct Place: Equatable {
    let name: String
    let icon: String
    let path: String
}

struct PlacesSection {
    let title: String
    let places: [Place]
    var removable = false
}

/// The local side pane: the XDG user folders that exist, the whole computer, the Trash, and mounted devices.
enum LocalPlaces {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func standard() -> [Place] {
        let folders: [(String, String, String)] = [
            ("DESKTOP", "Desktop", "user-desktop-symbolic"), ("DOCUMENTS", "Documents", "folder-documents-symbolic"),
            ("DOWNLOAD", "Downloads", "folder-download-symbolic"), ("MUSIC", "Music", "folder-music-symbolic"),
            ("PICTURES", "Pictures", "folder-pictures-symbolic"), ("VIDEOS", "Videos", "folder-videos-symbolic"),
        ]
        let dirs = userDirs()
        let places = folders.compactMap { key, fallback, icon -> Place? in
            let path = dirs[key] ?? home + "/" + fallback
            guard path != home, FileManager.default.fileExists(atPath: path) else { return nil }
            return Place(name: (path as NSString).lastPathComponent, icon: icon, path: path)
        }
        return [Place(name: "Home", icon: "user-home-symbolic", path: home)] + places
            + [Place(name: "Computer", icon: "computer-symbolic", path: "/"),
               Place(name: "Trash", icon: "user-trash-symbolic", path: Trash.homeFiles)]
    }

    /// ~/.config/user-dirs.dirs, which names the user's Desktop, Documents and the like (possibly translated).
    static func userDirs() -> [String: String] {
        // The host's own file: inside the Flatpak, XDG_CONFIG_HOME points at the app's private folder.
        let file = home + "/.config/user-dirs.dirs"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("XDG_") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasSuffix("_DIR") else { continue }
            let key = String(parts[0].dropFirst(4).dropLast(4))
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: "$HOME", with: home)
            result[key] = value
        }
        return result
    }

    /// Removable drives and other mounts, as file managers list them under /run/media, /media and /mnt.
    static func devices() -> [Place] {
        let user = NSUserName()
        var places: [Place] = []
        for base in ["/run/media/\(user)", "/media/\(user)", "/media", "/mnt"] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") && name != user {
                let path = base + "/" + name
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue,
                      !places.contains(where: { $0.path == path }) else { continue }
                places.append(Place(name: name, icon: "drive-harddisk-symbolic", path: path))
            }
        }
        return places
    }
}

/// "Permission denied" from this computer or an SFTP server: the case Administrator mode solves.
func isPermissionError(_ message: String) -> Bool {
    let text = message.lowercased()
    return text.contains("permission") || text.contains("not permitted") || text.contains("sftp 3:")
}

func formatBytes(_ count: Int64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    if count < 1000 { return count == 1 ? "1 byte" : "\(count) bytes" }
    var value = Double(count), unit = 0
    while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
    return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
}
