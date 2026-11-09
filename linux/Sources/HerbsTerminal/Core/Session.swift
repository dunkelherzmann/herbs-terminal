import Foundation

// MARK: Session restore

/// The saved shape of a tab's panes, for session restore.
struct SavedPane: Codable, Equatable {
    var directory: String?
    var axis: String?
    var children: [SavedPane]?
}

/// What reopens at launch: each window's tabs with their folder, layout, name and explorer folder. Remote sessions
/// reopen as local shells in the folder their shell was in; logins are never replayed.
struct SavedTab: Codable, Equatable {
    var directory: String
    var layout: String
    var title: String?
    var explorerPath: String
    var profile: String?
    var panes: SavedPane?
}

struct SavedWindow: Codable, Equatable {
    var tabs: [SavedTab]
    var selected: Int
}

enum SavedSession {
    static let key = "savedSession"

    static func write(_ windows: [SavedWindow]) {
        if let data = try? JSONEncoder().encode(windows) { Preferences.shared.set(data, key) }
    }

    static func read() -> [SavedWindow] {
        Preferences.shared.data(key).flatMap { try? JSONDecoder().decode([SavedWindow].self, from: $0) } ?? []
    }

    static func clear() { Preferences.shared.set(nil, key) }
}
