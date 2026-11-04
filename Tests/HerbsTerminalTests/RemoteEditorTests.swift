import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Remote Editor Tests")
@MainActor
struct RemoteEditorTests {

    @Test
    func stageWorkingCopyWritesLocalFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = RemoteEditor(cacheDirectory: tempDir)
        let endpoint = RemoteEndpoint(host: "server.example.com", port: 22, username: "admin")
        let fileData = Data("echo 'Hello World'\n".utf8)

        let workingCopy = try editor.stageWorkingCopy(endpoint: endpoint, remotePath: "/etc/motd", content: fileData)

        #expect(FileManager.default.fileExists(atPath: workingCopy.path))
        let readBack = try Data(contentsOf: workingCopy)
        #expect(readBack == fileData)
    }

    @Test
    func conflictDetectionDetectsRemoteChange() {
        let editor = RemoteEditor()
        let originalAttr = RemoteAttributes(size: 100, mode: 0o100644, modified: 1000)
        let changedAttr = RemoteAttributes(size: 150, mode: 0o100644, modified: 1050)

        #expect(editor.hasConflict(initial: originalAttr, current: changedAttr))
        #expect(!editor.hasConflict(initial: originalAttr, current: originalAttr))
    }
}
