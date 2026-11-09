import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import HerbsTerminal

@MainActor
@Suite("MultiExec")
struct MultiExecTests {
    @Test
    func onlyWhatTheUserTypesIsBroadcast() {
        let view = LocalShell().view
        var sent: [String] = []
        view.broadcast = { sent.append(String(decoding: Array($0), as: UTF8.self)) }
        view.send(source: view, data: Array("ls\r".utf8)[...])          // keys and paste
        view.send(source: view.getTerminal(), data: Array("\u{1B}[1;1R".utf8)[...])   // emulator reply
        view.sendQuietly("launcher\n")                                   // typed by the app itself
        #expect(sent == ["ls\r"])
    }

    @Test
    func commandNumbersPickGridTerminalsAndCloseOnlyTheActiveOne() {
        let workspace = Workspace(restoring: nil)
        defer { workspace.tabs.forEach { $0.shells.forEach { $0.close() } } }
        workspace.add()
        let (first, second) = (workspace.tabs[0], workspace.tabs[1])
        workspace.split(.horizontal, in: first)
        let pane = first.shells[1]
        workspace.multiExec = true
        // Grid order: Terminal 1, its second pane, Terminal 2.
        workspace.selectTab(number: 1)
        #expect(workspace.selected === first && first.focusedShell === pane)
        workspace.selectTab(number: 8)
        #expect(workspace.selected === second)
        // ⌘W's action in the grid closes the active terminal only.
        workspace.selectTab(number: 1)
        workspace.closePane(confirm: false)
        #expect(workspace.allShells.count == 2 && !first.shells.contains { $0 === pane })
        #expect(workspace.multiExec)
    }

    @Test
    func typingReachesIncludedTabsOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("multiexec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = Workspace(restoring: nil)
        workspace.add(); workspace.add()
        defer { workspace.tabs.forEach { $0.shell.close() } }
        workspace.tabs.forEach { $0.shell.start() }
        try await Task.sleep(for: .milliseconds(1500))   // let each shell finish its startup files

        workspace.multiExec = true
        workspace.setIncluded(workspace.tabs[2], false)
        #expect(workspace.multiExecTargets.count == 2)
        let typed = Array(" echo $$ >> '\(folder.path)/hits'\r".utf8)
        let first = workspace.tabs[0].shell.view
        first.send(source: first, data: typed[...])
        try await Task.sleep(for: .milliseconds(1200))
        let lines = try String(contentsOf: folder.appendingPathComponent("hits"), encoding: .utf8).split(separator: "\n")
        let pids = Set(workspace.tabs.map { String($0.shell.view.process.shellPid) })
        #expect(lines.count == 2 && Set(lines.map(String.init)).isSubset(of: pids))
        #expect(!lines.contains(Substring(String(workspace.tabs[2].shell.view.process.shellPid))))

        // Leaving MultiExec stops the broadcast.
        workspace.multiExec = false
        first.send(source: first, data: typed[...])
        try await Task.sleep(for: .milliseconds(800))
        #expect(try String(contentsOf: folder.appendingPathComponent("hits"), encoding: .utf8).split(separator: "\n").count == 3)
    }
}
