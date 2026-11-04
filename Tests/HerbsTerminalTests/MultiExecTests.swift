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
