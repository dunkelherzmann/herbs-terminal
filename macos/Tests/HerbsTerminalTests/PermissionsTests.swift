import Foundation
import Testing
@testable import HerbsTerminal

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herbs-perm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

private func localSFTP() throws -> SFTPClient { try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: []) }
private func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }

@Test(.timeLimit(.minutes(2)))
func modesReadLikeLsDashL() {
    #expect(symbolicMode(0o755) == "rwxr-xr-x")
    #expect(symbolicMode(0o640) == "rw-r-----")
    #expect(symbolicMode(0o4755) == "rwsr-xr-x")
    #expect(symbolicMode(0o2644) == "rw-r-Sr--")
    #expect(symbolicMode(0o1777) == "rwxrwxrwt")
    #expect(folderMode(0o644) == 0o755 && folderMode(0o600) == 0o700)
}

@Test(.timeLimit(.minutes(2)))
func localPermissionsChangeRecursivelyAndSkipLinks() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("project"), inner = folder.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let file = inner.appendingPathComponent("main.c"), outside = root.appendingPathComponent("outside.txt")
    try Data("x".utf8).write(to: file)
    try Data("y".utf8).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)

    let info = try LocalFileInfo.load(folder)
    #expect(info.isFolder && info.owner == NSUserName())
    try LocalFileInfo.apply(FileInfoChange(mode: 0o750, recursive: true), to: [folder])
    #expect(try mode(folder) == 0o750)
    #expect(try mode(inner) == 0o750)     // folders inside stay openable
    #expect(try mode(file) == 0o750)
    #expect(try mode(outside) == 0o600)   // the link's target is untouched

    try LocalFileInfo.apply(FileInfoChange(hidden: true, locked: true), to: [file])
    let flagged = try LocalFileInfo.load(file)
    #expect(flagged.hidden == true && flagged.locked == true)
    try LocalFileInfo.apply(FileInfoChange(hidden: false, locked: false), to: [file])
    #expect(try LocalFileInfo.load(file).locked == false)
    // Giving a file away needs root.
    #expect(throws: (any Error).self) { try LocalFileInfo.apply(FileInfoChange(owner: "root"), to: [file]) }
}

@Test(.timeLimit(.minutes(2))) @MainActor
func remotePermissionsAndOwnersGoOverSFTP() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("site")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let page = folder.appendingPathComponent("index.html")
    try Data("<p>".utf8).write(to: page)
    let model = RemoteExplorerViewModel(endpoint: RemoteEndpoint(host: "localhost", username: "me"),
                                        service: try localSFTP(), makeClient: { try localSFTP() }, queue: TransferQueue())

    let source = model.infoSource(for: ["site"], in: root.path)
    let info = try #require(try await source.load().first)
    #expect(info.isFolder && info.owner == NSUserName())
    try await source.apply(FileInfoChange(mode: 0o700, recursive: true))
    #expect(try mode(folder) == 0o700)
    #expect(try mode(page) == 0o700)
    // Its own uid is allowed; root's isn't, and the message says how to get there.
    try await source.apply(FileInfoChange(owner: String(getuid())))
    await #expect(throws: (any Error).self) { try await source.apply(FileInfoChange(owner: "0")) }
}
