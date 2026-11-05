import Foundation
import HerbsTerminalUI

/// What reopens at launch: each window's tabs with their folder, layout, name and explorer folder, like
/// Terminal's window restoration and Ptyxis's saved sessions. Remote sessions reopen as local shells in the
/// folder their shell was in; logins are never replayed.
struct SavedTab: Codable, Equatable {
    var directory: String
    var layout: String
    var title: String?
    var explorerPath: String
    /// The tab's profile; absent in sessions saved before named profiles.
    var profile: String?
    /// The tab's split panes; absent for a single pane.
    var panes: SavedPane?
}

struct SavedWindow: Codable, Equatable {
    var tabs: [SavedTab]
    var selected: Int
}

@MainActor
enum SessionRestore {
    static let key = "savedSession"
    /// Windows from the last session that haven't been reopened yet in this launch.
    private static var pending: [SavedWindow]?

    static func save(_ workspaces: [Workspace], defaults: UserDefaults = .standard) {
        guard TerminalProfile.shared.restoreSession else { defaults.removeObject(forKey: key); return }
        let windows = workspaces.map { workspace in
            // Editor tabs aren't reopened; the files stay where they were saved.
            let terminals = workspace.tabs.filter { $0.editor == nil }
            return SavedWindow(tabs: terminals.map { tab in
                SavedTab(directory: tab.shell.currentDirectory ?? tab.shell.startDirectory,
                         layout: tab.state.layout.savedName, title: tab.customTitle,
                         explorerPath: tab.state.directory.path, profile: tab.shell.profileID?.uuidString,
                         panes: tab.shells.count > 1 ? tab.root.saved : nil)
            }, selected: terminals.firstIndex { $0 === workspace.selected } ?? 0)
        }
        if let data = try? JSONEncoder().encode(windows) { defaults.set(data, forKey: key) }
    }

    /// The next window to reopen, read once per launch.
    static func takeNext(defaults: UserDefaults = .standard) -> SavedWindow? {
        if pending == nil {
            let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedWindow].self, from: $0) } ?? []
            pending = TerminalProfile.shared.restoreSession ? saved.filter { !$0.tabs.isEmpty } : []
        }
        return pending!.isEmpty ? nil : pending!.removeFirst()
    }

    static var hasPending: Bool { !(pending ?? []).isEmpty }

    /// Tests start from a clean slate.
    static func reset() { pending = nil }
}

extension SessionLayout {
    var savedName: String {
        switch self {
        case .terminal: "terminal"
        case .explorer: "explorer"
        }
    }

    init(savedName: String) {
        switch savedName {
        case "explorer": self = .explorer
        default: self = .terminal
        }
    }
}
