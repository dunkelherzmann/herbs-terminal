import AppKit
import Foundation
import Testing
@testable import HerbsTerminal

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herbsterminal-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
private func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

/// The macOS SFTP server, talking over pipes to the local filesystem: real SFTP without a network.
private func localSFTP() throws -> SFTPClient { try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: []) }

@Test(.timeLimit(.minutes(2)))
func destinationsGetFinderStyleCopyNames() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a", to: root.appendingPathComponent("notes.txt"))
    try write("a", to: root.appendingPathComponent("notes copy.txt"))
    #expect(LocalFiles.destination(for: "notes.txt", in: root).lastPathComponent == "notes copy 2.txt")
    #expect(LocalFiles.destination(for: "fresh", in: root).lastPathComponent == "fresh")
}

@Test(.timeLimit(.minutes(2))) @MainActor
func localCopyMoveAndTrashUndoAndRedo() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let file = a.appendingPathComponent("report.txt")
    try write("hello", to: file)
    let log = FileOperationLog()

    // Copy into the same folder keeps both.
    log.record(try LocalFiles.copy([file], into: a))
    #expect(try read(a.appendingPathComponent("report copy.txt")) == "hello")
    try log.undo()
    #expect(!FileManager.default.fileExists(atPath: a.appendingPathComponent("report copy.txt").path))
    #expect(log.redoTitle == "Redo Copy")
    try log.redo()
    #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("report copy.txt").path))
    #expect(log.undoTitle == "Undo Copy")

    // Move (cut + paste) and undo it.
    log.record(try LocalFiles.move([file], into: b))
    #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("report.txt").path))
    #expect(log.undoTitle == "Undo Move")
    try log.undo()
    #expect(try read(file) == "hello")
    #expect(log.canRedo)

    // Moving a folder into its own subfolder is refused.
    let inner = a.appendingPathComponent("inner")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    #expect(throws: FileIssue.self) { _ = try LocalFiles.move([a], into: inner) }

    // Delete goes to the Trash and Undo restores it, leaving nothing behind in the Trash.
    log.record(try LocalFiles.trash([file]))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(log.undoTitle == "Undo Move to Trash")
    try log.undo()
    #expect(try read(file) == "hello")
    #expect(log.redoTitle == "Redo Move to Trash")
}

@Test(.timeLimit(.minutes(2))) @MainActor
func clipboardTracksCutAndRemoteOwnership() {
    let board = NSPasteboard(name: NSPasteboard.Name("herbsterminal-test-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    let clipboard = FileClipboard(pasteboard: board)
    let url = URL(fileURLWithPath: "/tmp/x.txt")
    clipboard.writeLocal([url], cut: true)
    #expect(clipboard.readLocal().urls == [url])
    #expect(clipboard.readLocal().cut)
    clipboard.finishCut()
    #expect(!clipboard.readLocal().cut)

    let host = RemoteEndpoint(host: "h", port: 22, username: "u")
    clipboard.writeRemote(["/srv/a"], on: host, cut: false)
    #expect(clipboard.readRemote(for: host)?.paths == ["/srv/a"])
    #expect(clipboard.readRemote(for: RemoteEndpoint(host: "other", port: 22, username: "u")) == nil)
    // Copying something else elsewhere invalidates the remote paths.
    board.clearContents()
    board.setString("text", forType: .string)
    #expect(clipboard.readRemote(for: host) == nil)
}

@Test(.timeLimit(.minutes(2)))
func sftpUploadDownloadCopyAndRemoveTrees() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let payload = String(repeating: "herbsterminal ", count: 20_000)  // several 32 KB chunks
    try write(payload, to: source.appendingPathComponent("big.txt"))
    try write("nested", to: source.appendingPathComponent("sub/n.txt"))
    let remote = root.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

    var sent: Int64 = 0
    let transfer = SFTPTransfer(client: try localSFTP(), progress: { sent += $0 })
    let target = try transfer.destination(for: "project", in: remote.path)
    try transfer.upload(source, to: target)
    #expect(try read(remote.appendingPathComponent("project/big.txt")) == payload)
    #expect(try read(remote.appendingPathComponent("project/sub/n.txt")) == "nested")
    #expect(sent == Int64(payload.utf8.count + 6))
    #expect(try transfer.size(of: target) == sent)
    // No temporary upload names are left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("project").path).sorted() == ["big.txt", "sub"])
    #expect(try transfer.destination(for: "project", in: remote.path) == remote.appendingPathComponent("project copy").path)

    try transfer.copy(target, to: remote.appendingPathComponent("dup").path)
    #expect(try read(remote.appendingPathComponent("dup/sub/n.txt")) == "nested")

    let back = root.appendingPathComponent("downloaded")
    try transfer.download(target, to: back)
    #expect(try read(back.appendingPathComponent("big.txt")) == payload)

    try transfer.remove(remote.appendingPathComponent("dup").path)
    #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("dup").path))
}

@Test(.timeLimit(.minutes(2)))
func cancelledUploadLeavesNoPartialFile() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("big.bin")
    try Data(count: 200_000).write(to: file)
    let remote = root.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    var chunks = 0
    let transfer = SFTPTransfer(client: try localSFTP(), progress: { _ in chunks += 1 }, isCancelled: { chunks >= 2 })
    #expect(throws: FileIssue.self) { try transfer.upload(file, to: remote.appendingPathComponent("big.bin").path) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: remote.path).isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor
func remotePasteMovesUndoAndRedo() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    try write("x", to: a.appendingPathComponent("f.txt"))
    let queue = TransferQueue()
    let vm = RemoteExplorerViewModel(endpoint: RemoteEndpoint(host: "local", port: 22, username: "me"),
                                     service: try localSFTP(), makeClient: { try localSFTP() }, queue: queue)

    await vm.paste([a.appendingPathComponent("f.txt").path], cut: true, into: b.path)
    #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("f.txt").path))
    #expect(vm.undoMoves.count == 1)
    await vm.undo()
    #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("f.txt").path))
    #expect(vm.redoMoves.count == 1)
    await vm.redo()
    #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("f.txt").path))

    await vm.paste([b.appendingPathComponent("f.txt").path], cut: false, into: b.path)
    #expect(try read(b.appendingPathComponent("f copy.txt")) == "x")

    let upload = root.appendingPathComponent("up.txt")
    try write("up", to: upload)
    await vm.upload([upload], into: a.path)
    #expect(try read(a.appendingPathComponent("up.txt")) == "up")
    #expect(queue.items.last?.state == .completed)

    await vm.download(["up.txt"], from: a.path, to: b)
    #expect(try read(b.appendingPathComponent("up.txt")) == "up")

    await vm.delete(["f copy.txt"], in: b.path)
    #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("f copy.txt").path))
    #expect(vm.alert == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor
func profileDefaultsToBasicAndClampsSize() throws {
    let defaults = try #require(UserDefaults(suiteName: "herbsterminal-profile-" + UUID().uuidString))
    let profile = TerminalProfile(defaults: defaults)
    #expect(profile.fontFamily.isEmpty)
    #expect(profile.font.fontName == TerminalTypeface.regular.fontName)
    #expect(profile.cursorStyle == .blinkBlock)
    profile.fontSize = 500
    #expect(profile.fontSize == TerminalProfile.sizeRange.upperBound)
    profile.fontFamily = "Menlo"
    profile.fontSize = 14
    profile.cursor = .bar
    profile.cursorBlinks = false
    let reloaded = TerminalProfile(defaults: defaults)
    #expect(reloaded.font.familyName == "Menlo")
    #expect(reloaded.font.pointSize == 14)
    #expect(reloaded.cursorStyle == .steadyBar)
    #expect(TerminalProfile.monospacedFamilies.contains("Menlo"))
    // Terminal's defaults: Option types characters, the bell beeps, and closing asks first.
    #expect(!profile.optionAsMeta && profile.bell == .audible && profile.askBeforeClosing && profile.newTabsInSameFolder)
    profile.scrollbackLines = 5
    #expect(profile.scrollbackLines == 100)
}

@Test(.timeLimit(.minutes(2))) @MainActor
func builtInThemesAreSelectableAndPersist() throws {
    let defaults = try #require(UserDefaults(suiteName: "herbsterminal-themes-" + UUID().uuidString))
    let library = ThemeLibrary(defaults: defaults)
    #expect(library.allNames.contains("Solarized Dark"))
    let profile = TerminalProfile(defaults: defaults)
    profile.theme = "Nord"
    #expect(library.theme(named: profile.theme)?.palette.count == 16)
    #expect(TerminalProfile(defaults: defaults).theme == "Nord")
    #expect(!library.isImported("Nord"))
}

@Test(.timeLimit(.minutes(2))) @MainActor
func remoteSymlinksToFoldersListAsFolders() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents"),
                                               withDestinationURL: root.appendingPathComponent("real"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"),
                                               withDestinationURL: root.appendingPathComponent("missing"))
    let vm = RemoteExplorerViewModel(endpoint: RemoteEndpoint(host: "local", username: "me"),
                                     service: try localSFTP(), makeClient: { try localSFTP() })
    await vm.load(path: root.path)
    #expect(vm.entries.first { $0.name == "Documents" }?.attributes.directory == true)
    #expect(vm.entries.first { $0.name == "dangling" }?.attributes.link == true)
}
