import Foundation
import Testing
@testable import HerbsTerminal

@MainActor
@Suite("Split panes")
struct SplitPaneTests {
    @Test
    func splittingBuildsAndCollapsesTheTree() {
        let a = LocalShell(), b = LocalShell(), c = LocalShell(), d = LocalShell()
        let root = PaneNode(shell: a)
        root.leaf(for: a)!.split(.horizontal, adding: PaneNode(shell: b))
        root.leaf(for: b)!.split(.horizontal, adding: PaneNode(shell: c))   // same direction: a sibling
        #expect(root.axis == .horizontal && root.children.count == 3)
        root.leaf(for: c)!.split(.vertical, adding: PaneNode(shell: d))     // other direction: nested
        #expect(root.children.count == 3 && root.children[2].axis == .vertical)
        #expect(root.leaves.map(\.id) == [a, b, c, d].map(\.id))
        root.leaf(for: d)!.removeFromParent()
        #expect(root.children[2].shell === c)                              // a one-child split collapses
        root.leaf(for: b)!.removeFromParent()
        root.leaf(for: c)!.removeFromParent()
        #expect(root.shell === a && root.children.isEmpty)
    }

    @Test
    func workspaceSplitsClosesAndPromotesTheFirstPane() async throws {
        let workspace = Workspace(restoring: nil)
        let tab = workspace.selected
        defer { tab.shells.forEach { $0.close() } }
        let first = tab.shell
        workspace.split(.horizontal)
        workspace.split(.vertical)
        #expect(tab.shells.count == 3 && tab.focusedShell === tab.shells[2])
        workspace.focusPane(offset: 1)
        #expect(tab.focusedShell === first)
        // Closing the first pane hands the tab's connection and explorer to the next pane.
        workspace.closePane(first, in: tab, confirm: false)
        #expect(tab.shells.count == 2 && tab.shell !== first && tab.shell === tab.shells[0])
        // MultiExec reaches every pane.
        workspace.multiExec = true
        #expect(workspace.multiExecTargets.count == 2)
        workspace.setIncluded(tab.shells[1], false)
        #expect(workspace.multiExecTargets.map(\.id) == [tab.shells[0].id])
        workspace.multiExec = false
    }

    @Test
    func typingExitClosesThePane() async throws {
        let workspace = Workspace(restoring: nil)
        let tab = workspace.selected
        defer { tab.shells.forEach { $0.close() } }
        workspace.split(.horizontal)
        tab.shells.forEach { $0.start() }
        try await Task.sleep(for: .milliseconds(1500))
        let pane = tab.shells[1]
        pane.view.send(source: pane.view, data: Array(" exit\r".utf8)[...])
        try await Task.sleep(for: .milliseconds(1500))
        #expect(tab.shells.count == 1 && tab.shells[0] === tab.shell)
    }

    @Test
    func paneLayoutsSurviveSaveAndRestore() {
        let workspace = Workspace(restoring: nil)
        let tab = workspace.selected
        defer { tab.shells.forEach { $0.close() } }
        workspace.split(.horizontal)
        workspace.split(.vertical)
        let saved = tab.root.saved
        #expect(saved.axis == .horizontal && saved.children?.count == 2 && saved.children?[1].axis == .vertical)
        let restored = TerminalTab(number: 1, panes: saved)
        defer { restored.shells.forEach { $0.close() } }
        #expect(restored.shells.count == 3 && restored.shells[0] === restored.shell)
        #expect(restored.root.children[1].children.count == 2)
    }
}
