import SwiftUI
import HerbsTerminalUI
import Testing
@testable import HerbsTerminal

@Test @MainActor
func switchingLayoutsKeepsShell() async throws {
    _ = NSApplication.shared
    let state = WindowState()
    let shell = LocalShell()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 580),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: SessionView(state: state, shell: shell))
    window.orderBack(nil)
    defer { window.orderOut(nil); shell.close() }
    try await Task.sleep(for: .milliseconds(250))
    let pid = shell.view.process.shellPid
    try #require(pid > 0)
    for layout in [SessionLayout.split, .explorer, .terminal] {
        state.layout = layout
        try await Task.sleep(for: .milliseconds(200))
        #expect(shell.view.process.shellPid == pid)
        #expect(kill(pid, 0) == 0)
        #expect((shell.view.window != nil) == (layout != .explorer))
    }
}

@Test @MainActor
func terminalUsesFactoryBasicProfile() throws {
    let path = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/Basic.terminal"
    let profile = try #require(NSDictionary(contentsOfFile: path))
    let shell = LocalShell()
    let data = try #require(profile["Font"] as? Data)
    let stock = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data))
    #expect(shell.view.font.fontName == stock.fontName)
    #expect(shell.view.font.pointSize == stock.pointSize)
    for dark in [false, true] {
        shell.applyColors(dark: dark)
        #expect(shell.view.nativeForegroundColor == (dark ? NSColor.white : NSColor.black))
        #expect(shell.view.nativeBackgroundColor == (dark ? NSColor.black : NSColor.white))
    }
}

@Test @MainActor
func tabsKeepIndependentShellsAndSearchReopensTerminal() async throws {
    _ = NSApplication.shared
    let workspace = Workspace()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace))
    window.orderBack(nil)
    defer { window.orderOut(nil); workspace.tabs.forEach { $0.shell.close() } }
    try await Task.sleep(for: .milliseconds(250))
    let first = workspace.selected
    let pid = first.shell.view.process.shellPid
    try #require(pid > 0)
    workspace.add()
    try await Task.sleep(for: .milliseconds(250))
    let second = workspace.selected
    #expect(second.shell.view.process.shellPid > 0)
    #expect(second.shell.view.process.shellPid != pid)
    workspace.close(second)
    try await Task.sleep(for: .milliseconds(250))
    #expect(workspace.selected === first)
    #expect(first.shell.view.process.shellPid == pid)
    #expect(kill(pid, 0) == 0)
    first.state.layout = .explorer
    try await Task.sleep(for: .milliseconds(150))
    first.state.find()
    try await Task.sleep(for: .milliseconds(250))
    #expect(first.state.layout == .terminal)
    #expect(first.shell.view.subviews.contains { String(describing: type(of: $0)).contains("FindBar") && !$0.isHidden })
}

@Test @MainActor
func headerCentersOnWindowControls() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    let content = NSHostingView(rootView: WorkspaceView())
    window.contentView = content
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func header(in view: NSView) -> NSView? {
        if String(reflecting: type(of: view)).contains("HeaderMeasurement.Probe") { return view }
        return view.subviews.lazy.compactMap { header(in: $0) }.first
    }
    for width in [960, 720] {
        window.setContentSize(NSSize(width: width, height: 540))
        try await Task.sleep(for: .milliseconds(300))
        let bar = try #require(header(in: content))
        for control in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(control))
            let difference = bar.convert(bar.bounds, to: nil).midY - button.convert(button.bounds, to: nil).midY
            #expect(abs(difference) <= 0.5)
        }
    }
}

@Test @MainActor
func activeTabLegendTracksTerminalMetadata() {
    let workspace = Workspace()
    let first = workspace.selected
    let view = first.shell.view
    view.feed(text: "\u{1B}]2;Build host\u{7}")
    let home = FileManager.default.homeDirectoryForCurrentUser
    let directory = home.appendingPathComponent("Project Files").absoluteString
    view.feed(text: "\u{1B}]7;" + directory + "\u{7}")
    #expect(first.shell.legend.title == "Build host")
    #expect(first.shell.legend.subtitle == "~/Project Files")
    view.feed(text: "\u{1B}]6;" + directory + "/notes.txt\u{7}")
    first.shell.legend.refresh(view)
    #expect(first.shell.legend.subtitle == "~/Project Files/notes.txt")
    workspace.add()
    #expect(workspace.selected.shell.legend.subtitle == "~")
    workspace.close(workspace.selected)
    #expect(workspace.selected.shell.legend.title == "Build host")
}
