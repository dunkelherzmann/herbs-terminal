import Foundation

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
