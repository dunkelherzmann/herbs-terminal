import Foundation
import Testing
@testable import HerbsTerminal

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herbs-editor-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

private func localSFTP() throws -> SFTPClient { try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: []) }

@Test(.timeLimit(.minutes(2)))
func textFilesAreRecognisedByTypeOrContent() {
    for name in ["notes.txt", "README.md", "main.swift", "config.json", "site.yaml", "run.sh", "data.csv", "Info.plist"] {
        #expect(TextCodec.isText(name: name) { nil }, "\(name)")
    }
    for name in ["photo.png", "paper.pdf", "archive.zip"] {
        #expect(!TextCodec.isText(name: name) { Data("looks like text".utf8) }, "\(name)")
    }
    // No extension, or one macOS doesn't know: the first bytes decide.
    #expect(TextCodec.isText(name: "Makefile") { Data("all:\n\tswift build\n".utf8) })
    #expect(TextCodec.isText(name: ".bashrc") { Data("export A=1\n".utf8) })
    #expect(!TextCodec.isText(name: "blob") { Data([0x7F, 0x45, 0x4C, 0x46, 0, 0, 1]) })
}

@Test(.timeLimit(.minutes(2)))
func encodingsRoundTripByteForByte() throws {
    let samples: [Data] = [
        Data("plain ascii\r\nwith CRLF\n".utf8),
        Data("UTF-8 ✓ café\n".utf8),
        Data([0xFF, 0xFE]) + "UTF-16 text".data(using: .utf16LittleEndian)!,
        Data([0x63, 0x61, 0x66, 0xE9, 0x0A]),   // "café" in Latin-1
    ]
    for data in samples {
        let decoded = try #require(TextCodec.decode(data))
        #expect(decoded.text.data(using: decoded.encoding) == data || decoded.encoding == .utf16)
    }
    #expect(TextCodec.decode(Data([0x00, 0x01, 0x02])) == nil)
}

@Test(.timeLimit(.minutes(2)))
func localSavesKeepPermissionsAndEditThroughLinks() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("script.sh")
    try Data("echo hi\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: file.path)
    let link = root.appendingPathComponent("link.sh")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    let source = TextFileSource.local(link)
    #expect(String(decoding: try await source.read(), as: UTF8.self) == "echo hi\n")
    let before = try await source.version()
    try await source.write(Data("echo bye, with more text\n".utf8))
    #expect(try String(contentsOf: file, encoding: .utf8) == "echo bye, with more text\n")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o750)
    #expect(try await source.version() != before)
}

@Test(.timeLimit(.minutes(2)))
func remoteFilesAreReadAndReplacedWhole() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("remote.conf")
    let big = String(repeating: "line of config text\n", count: 5000)   // several SFTP chunks
    try Data(big.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

    let transfer = SFTPTransfer(client: try localSFTP())
    #expect(try transfer.readAll(file.path, limit: TextCodec.sizeLimit) == Data(big.utf8))
    #expect(throws: (any Error).self) { try transfer.readAll(file.path, limit: 10) }

    try transfer.replace(file.path, with: Data("edited\n".utf8))
    #expect(try String(contentsOf: file, encoding: .utf8) == "edited\n")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o640)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["remote.conf"])
}

@Test(.timeLimit(.minutes(2))) @MainActor
func remoteNewFileOpensThroughTheExplorersConnection() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = RemoteExplorerViewModel(endpoint: RemoteEndpoint(host: "localhost", username: "me"),
                                        service: try localSFTP(), makeClient: { try localSFTP() }, queue: TransferQueue())
    let path = try #require(await model.newFile(named: "todo.md", in: root.path))
    #expect(path == root.appendingPathComponent("todo.md").path)
    let source = model.textSource(for: path)
    #expect(try await source.read().isEmpty)
    try await source.write(Data("# Todo\n".utf8))
    #expect(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) == "# Todo\n")
    #expect(source.location.hasSuffix(":" + path))
    // A second New File with the same name gets a free one instead of overwriting.
    #expect(await model.newFile(named: "todo.md", in: root.path) != path)
}

@Test(.timeLimit(.minutes(2))) @MainActor
func filesOpenAsTabsInTheTerminalWindow() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.md")
    try Data("# Notes\n".utf8).write(to: file)
    let workspace = Workspace(restoring: nil)
    defer { workspace.tabs.forEach { $0.shells.forEach { $0.close() } } }

    workspace.openEditor(.local(file))
    #expect(workspace.tabs.count == 2)
    let tab = try #require(workspace.selected.editor.map { _ in workspace.selected })
    #expect(tab.title == "notes.md" && tab.shells.isEmpty)
    // Opening it again selects the same tab.
    workspace.select(workspace.tabs[0])
    workspace.openEditor(.local(file))
    #expect(workspace.tabs.count == 2 && workspace.selected === tab)
    // Editor tabs don't use up terminal numbers and aren't saved with the session.
    workspace.add()
    #expect(workspace.tabs.last?.number == 2)
    let defaults = try #require(UserDefaults(suiteName: "editor-\(UUID())"))
    SessionRestore.save([workspace], defaults: defaults)
    SessionRestore.reset()
    #expect(SessionRestore.takeNext(defaults: defaults)?.tabs.count == 2)
    SessionRestore.reset()
    // An unchanged file closes without asking.
    workspace.close(tab)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!workspace.tabs.contains { $0 === tab })
}
