import AppKit
import SwiftUI
import Testing
@testable import HerbsTerminal

@MainActor
@Suite("Window size")
struct WindowSizeTests {
    @Test
    func sizeBadgeShowsAfterAResizeNotWhenTheTabOpens() async throws {
        let legend = SessionLegend()
        let view = LocalShell().view
        legend.sizeChanged(source: view, newCols: 80, newRows: 24)
        #expect(!legend.showingSize && legend.columns == 80 && legend.rows == 24)
        legend.sizeChanged(source: view, newCols: 100, newRows: 30)
        #expect(legend.showingSize && legend.columns == 100 && legend.rows == 30)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(!legend.showingSize)
        #expect(TerminalProfile(defaults: try #require(UserDefaults(suiteName: "size-\(UUID())"))).showSizeWhileResizing)
    }

    @Test
    func windowSizeIsKeptInColumnsAndRowsAndMigratedFromPoints() throws {
        let suite = "size-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = TerminalProfile(defaults: defaults)
        #expect(fresh.windowColumns == TerminalProfile.defaultGrid.columns && fresh.windowRows == TerminalProfile.defaultGrid.rows)

        // Points from earlier builds become the columns × rows that fit in them.
        let cell = ProfileSettings.cellSize(of: fresh.defaultProfile.settings.font)
        let chrome = TerminalProfile.estimatedChrome
        let legacySuite = "size-\(UUID())"
        let legacy = try #require(UserDefaults(suiteName: legacySuite))
        defer { legacy.removePersistentDomain(forName: legacySuite) }
        legacy.set(Double(chrome.width + cell.width * 100 + 2), forKey: "windowWidth")
        legacy.set(Double(chrome.height + cell.height * 30 + 2), forKey: "windowHeight")
        let migrated = TerminalProfile(defaults: legacy)
        #expect(migrated.windowColumns == 100 && migrated.windowRows == 30)

        // And the window opens big enough for exactly that grid.
        let size = migrated.windowContentSize
        #expect(Int((size.width - chrome.width) / cell.width) == 100)
        #expect(Int((size.height - chrome.height) / cell.height) == 30)
    }

    @Test
    func titleDoubleClickRestoresTheDefaultGridAndRightClickSavesIt() async throws {
        let profile = TerminalProfile.shared
        let saved = (profile.windowColumns, profile.windowRows, profile.windowChrome, profile.defaultProfile.settings)
        defer {
            profile.windowColumns = saved.0
            profile.windowRows = saved.1
            profile.windowChrome = saved.2
            profile.update(profile.defaultProfileID) { $0 = saved.3 }
        }
        let workspace = Workspace(restoring: nil)
        defer { workspace.tabs.forEach { $0.shell.close() } }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SessionView(state: workspace.selected.state, shell: workspace.selected.shell))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        workspace.window = window
        try await Task.sleep(for: .milliseconds(300))

        profile.windowColumns = 110
        profile.windowRows = 28
        profile.update(workspace.selected.shell.profileID) { $0.fontSize = 12; $0.zoom = 4 }
        try await Task.sleep(for: .milliseconds(150))
        workspace.restoreDefaultSize()
        try await Task.sleep(for: .milliseconds(400))
        let terminal = workspace.selected.shell.view.getTerminal()
        #expect(terminal.cols == 110 && terminal.rows == 28, "got \(terminal.cols) × \(terminal.rows), content \(window.contentLayoutRect.size), view \(workspace.selected.shell.view.frame.size)")
        #expect(workspace.selected.shell.settings.zoom == 0)

        // Making the current size the default keeps the zoomed text size and the grid the badge shows.
        window.setContentSize(NSSize(width: 820, height: 480))
        try await Task.sleep(for: .milliseconds(300))
        profile.update(workspace.selected.shell.profileID) { $0.zoom = 3 }
        try await Task.sleep(for: .milliseconds(300))
        let shown = workspace.selected.shell.view.getTerminal()
        workspace.makeCurrentSizeDefault()
        #expect(profile.windowColumns == shown.cols && profile.windowRows == shown.rows)
        #expect(workspace.selected.shell.settings.fontSize == 15 && workspace.selected.shell.settings.zoom == 0)
    }
}
