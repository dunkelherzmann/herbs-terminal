import AppKit
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
    func titleDoubleClickRestoresDefaultsAndRightClickSavesThem() throws {
        let profile = TerminalProfile.shared
        let saved = (profile.windowWidth, profile.windowHeight, profile.defaultProfile.settings)
        defer {
            profile.windowWidth = saved.0
            profile.windowHeight = saved.1
            profile.update(profile.defaultProfileID) { $0 = saved.2 }
        }
        let workspace = Workspace(restoring: nil)
        defer { workspace.tabs.forEach { $0.shell.close() } }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        workspace.window = window

        profile.windowWidth = 900
        profile.windowHeight = 500
        profile.update(workspace.selected.shell.profileID) { $0.fontSize = 12; $0.zoom = 4 }
        workspace.restoreDefaultSize()
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 900, height: 500))
        #expect(workspace.selected.shell.settings.zoom == 0)

        // In Split View each pane gets the default width.
        workspace.selected.state.layout = .split
        workspace.restoreDefaultSize()
        let splitWidth = window.contentRect(forFrameRect: window.frame).width
        #expect(splitWidth == min(1800, (window.screen?.visibleFrame.width ?? 1800)))

        // Making the current size the default keeps the zoomed text size and one pane's width.
        workspace.selected.state.layout = .terminal
        window.setContentSize(NSSize(width: 1000, height: 600))
        profile.update(workspace.selected.shell.profileID) { $0.zoom = 3 }
        workspace.makeCurrentSizeDefault()
        #expect(profile.windowWidth == 1000 && profile.windowHeight == 600)
        #expect(workspace.selected.shell.settings.fontSize == 15 && workspace.selected.shell.settings.zoom == 0)
    }
}
