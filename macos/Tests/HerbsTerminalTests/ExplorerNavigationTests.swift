import Foundation
import Testing
@testable import HerbsTerminal

@Test
func historyGoesBackAndForwardLikeThunar() {
    var history = NavigationHistory("/Users/a")
    history.visit("/Users/a/Documents")
    history.visit("/Users/a/Documents/Work")
    #expect(history.goBack() == "/Users/a/Documents")
    #expect(history.goBack() == "/Users/a")
    #expect(history.goBack() == nil)
    #expect(history.current == "/Users/a")
    #expect(history.goForward() == "/Users/a/Documents")
    // A new visit drops the forward branch.
    history.visit("/tmp")
    #expect(!history.canGoForward)
    #expect(history.goBack() == "/Users/a/Documents")
}

@Test
func historyIgnoresRevisitsAndCapsLength() {
    var history = NavigationHistory("/")
    history.visit("/")
    #expect(!history.canGoBack)
    for index in 0..<(NavigationHistory.limit + 20) { history.visit("/d\(index)") }
    #expect(history.back.count == NavigationHistory.limit)
}

@Test
func pathSegmentsBuildClickablePathBar() {
    #expect(pathSegments("/") == [PathSegment(name: "/", path: "/")])
    #expect(pathSegments("/Users/a b/x/").map(\.path) == ["/", "/Users", "/Users/a b", "/Users/a b/x"])
    #expect(pathSegments("/Users/a b/x").last?.name == "x")
}

@Test
func locationInputResolvesAbsoluteHomeAndRelativePaths() {
    let home = "/Users/a"
    #expect(resolveLocation("/etc/../var//log/", from: "/x", home: home) == "/var/log")
    #expect(resolveLocation("~", from: "/x", home: home) == home)
    #expect(resolveLocation("~/Downloads", from: "/x", home: home) == "/Users/a/Downloads")
    #expect(resolveLocation("../b", from: "/srv/a", home: home) == "/srv/b")
    #expect(resolveLocation("  ", from: "/x", home: home) == nil)
    #expect(resolveLocation("~/x", from: "/x", home: nil) == nil)
    #expect(parentPath("/") == "/")
    #expect(parentPath("/srv/a/") == "/srv")
}

@Test
func symlinkedFoldersOpenInExplorerButPackagesDoNot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    let file = root.appendingPathComponent("file.txt")
    try Data().write(to: file)
    #expect(opensAsFolder(folder))
    #expect(opensAsFolder(link))
    #expect(!opensAsFolder(file))
    #expect(!opensAsFolder(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
}
