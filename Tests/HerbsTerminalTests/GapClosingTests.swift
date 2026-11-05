import AppKit
import Foundation
import Testing
@testable import HerbsTerminal

@MainActor
@Suite("Parity gap tests")
struct GapClosingTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gaps-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test
    func renameMigrationCarriesSettingsAndDataOnce() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support"), caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("HerbsTerminal"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: support.appendingPathComponent("HerbsTerminal/logins.sqlite3"))
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("HerbsTerminal/ssh"), withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "gaps-\(UUID().uuidString)"))
        defaults.set("Nord", forKey: "terminalTheme")

        RenameMigration.run(defaults: defaults, oldSettings: ["terminalTheme": "Solarized Dark", "appearance": "Dark"],
                            support: support, caches: caches)
        #expect(defaults.string(forKey: "terminalTheme") == "Nord")   // a newer value wins
        #expect(defaults.string(forKey: "appearance") == "Dark")
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("HerbsTerminal/logins.sqlite3").path))
        #expect(!FileManager.default.fileExists(atPath: caches.appendingPathComponent("HerbsTerminal").path))
        // Runs once.
        defaults.removeObject(forKey: "appearance")
        RenameMigration.run(defaults: defaults, oldSettings: ["appearance": "Light"], support: support, caches: caches)
        #expect(defaults.string(forKey: "appearance") == nil)
    }

    @Test
    func sessionsSaveAndReopenTabsFoldersLayoutsAndNames() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "gaps-\(UUID().uuidString)"))
        SessionRestore.reset()
        let workspace = Workspace(restoring: nil)
        defer { workspace.tabs.forEach { $0.shell.close() } }
        workspace.selected.state.layout = .explorer
        workspace.selected.state.directory = root
        workspace.selected.customTitle = "Builds"
        workspace.selected.shell.startDirectory = root.path
        SessionRestore.save([workspace], defaults: defaults)

        SessionRestore.reset()
        let saved = try #require(SessionRestore.takeNext(defaults: defaults))
        #expect(saved.tabs.count == 1 && saved.tabs[0].title == "Builds" && saved.tabs[0].layout == "explorer")
        #expect(SessionRestore.takeNext(defaults: defaults) == nil)
        let reopened = Workspace(restoring: saved)
        defer { reopened.tabs.forEach { $0.shell.close() } }
        #expect(reopened.selected.title == "Builds")
        #expect(reopened.selected.state.layout == .explorer)
        #expect(reopened.selected.state.directory.path == root.path)
        #expect(reopened.selected.shell.startDirectory == root.path)
        SessionRestore.reset()
    }

    @Test
    func tabsReorderAndSelectByNumber() {
        let workspace = Workspace(restoring: nil)
        defer { workspace.tabs.forEach { $0.shell.close() } }
        workspace.add(); workspace.add()
        let (one, two, three) = (workspace.tabs[0], workspace.tabs[1], workspace.tabs[2])
        workspace.move(three, to: 0)
        #expect(workspace.tabs.map(\.number) == [3, 1, 2])
        workspace.selectTab(number: 1)
        #expect(workspace.selected === one)
        workspace.moveSelected(by: 5)
        #expect(workspace.tabs.last === one)
        workspace.selectTab(number: 9)
        #expect(workspace.selected === one)
        two.customTitle = "logs"
        #expect(two.title == "logs" && three.title == "Terminal 3")
        // A closed tab's number is used again by the next new tab.
        workspace.close(two)
        workspace.add()
        #expect(workspace.tabs.last?.number == 2)
        // ⌘9 is the last tab.
        workspace.selectTab(number: 8)
        #expect(workspace.selected === workspace.tabs.last)
    }

    @Test
    func newFolderNewFileAndRenameAreUndoable() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = FileOperationLog()
        log.record(try LocalFiles.create(folder: true, named: "reports", in: root), as: "New Folder")
        log.record(try LocalFiles.create(folder: false, in: root), as: "New File")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("reports").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("untitled").path))
        #expect(log.undoTitle == "Undo New File")

        log.record(try LocalFiles.rename(root.appendingPathComponent("reports"), to: "2026"), as: "Rename")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026").path))
        #expect(throws: FileIssue.self) { _ = try LocalFiles.rename(root.appendingPathComponent("2026"), to: "untitled") }
        #expect(throws: FileIssue.self) { _ = try LocalFiles.rename(root.appendingPathComponent("2026"), to: "a/b") }
        try log.undo()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("reports").path))
        #expect(log.redoTitle == "Redo Rename")
        // Undoing the new file moves it to the Trash; redo brings it back so nothing is left there.
        try log.undo()
        try log.redo()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("untitled").path))
    }

    @Test
    func remoteNewFolderRenameUndoAndRetry() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sftp: @Sendable () throws -> SFTPClient = { try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: []) }
        let queue = TransferQueue()
        let vm = RemoteExplorerViewModel(endpoint: RemoteEndpoint(host: "local", username: "me"),
                                         service: try sftp(), makeClient: sftp, queue: queue)
        await vm.newFolder(named: "inbox", in: root.path)
        await vm.newFolder(named: "inbox", in: root.path)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox copy").path))
        await vm.rename("inbox", to: "archive", in: root.path)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive").path))
        await vm.undo()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox").path))

        // A failed upload can be retried once its cause is fixed.
        let missing = root.appendingPathComponent("later.txt")
        await vm.upload([missing], into: root.appendingPathComponent("inbox").path)
        let failed = try #require(queue.items.last)
        if case .failed = failed.state {} else { Issue.record("expected the first upload to fail") }
        #expect(vm.canRetry(failed.id))
        try Data("now".utf8).write(to: missing)
        await vm.retryTransfer(failed.id)
        #expect(queue.items.last?.state == .completed)
        #expect(!queue.items.contains { $0.id == failed.id })
        #expect(try String(contentsOf: root.appendingPathComponent("inbox/later.txt"), encoding: .utf8) == "now")
    }

    @Test
    func backgroundOpacityIsClampedAndMakesWindowsTranslucent() throws {
        let defaults = try #require(UserDefaults(suiteName: "gaps-\(UUID().uuidString)"))
        let profile = TerminalProfile(defaults: defaults)
        #expect(profile.backgroundOpacity == 1 && !profile.isTranslucent && profile.restoreSession)
        profile.backgroundOpacity = 0.05
        #expect(profile.backgroundOpacity == 0.2 && profile.isTranslucent)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        profile.editing.applyTransparency(to: window)
        #expect(!window.isOpaque)
        profile.backgroundOpacity = 1
        profile.editing.applyTransparency(to: window)
        #expect(window.isOpaque)
    }

    @Test
    func profilesAreNamedSavedAndUsedPerTab() throws {
        let defaults = try #require(UserDefaults(suiteName: "gaps-\(UUID().uuidString)"))
        // Settings from before profiles become the first profile, theme included.
        defaults.set("Menlo", forKey: "terminalFontFamily")
        defaults.set(14.0, forKey: "terminalFontSize")
        defaults.set("Nord", forKey: "terminalTheme")
        let library = TerminalProfile(defaults: defaults)
        #expect(library.profiles.map(\.name) == ["Basic"])
        #expect(library.defaultProfile.settings.fontFamily == "Menlo" && library.defaultProfile.settings.theme == "Nord")

        let work = library.addProfile(named: "Work", copying: library.defaultProfileID)
        let dupe = library.addProfile(named: "Work")
        #expect(library.name(of: dupe) == "Work 2")
        library.update(work) { $0.startupCommand = "cd /tmp"; $0.fontSize = 18 }
        library.rename(work, to: "Builds")
        library.defaultProfileID = work

        let reopened = TerminalProfile(defaults: defaults)
        #expect(reopened.profiles.map(\.name) == ["Basic", "Builds", "Work 2"])
        #expect(reopened.defaultProfile.name == "Builds")
        #expect(reopened.settings(for: work).fontSize == 18 && reopened.settings(for: work).fontFamily == "Menlo")
        #expect(reopened.settings(for: UUID()).startupCommand == "cd /tmp")   // unknown id → default
        reopened.removeProfile(work)
        #expect(reopened.defaultProfile.name == "Basic")
        reopened.removeProfile(reopened.profiles[0].id)
        reopened.removeProfile(reopened.profiles[0].id)
        #expect(reopened.profiles.count == 1)   // the last profile stays
    }

    @Test
    func zoomPersistsInTheProfileAndRestoreDefaultsClearsIt() throws {
        let defaults = try #require(UserDefaults(suiteName: "gaps-\(UUID().uuidString)"))
        let library = TerminalProfile(defaults: defaults)
        let id = library.defaultProfileID
        library.update(id) { $0.zoom += 3; $0.theme = "Nord"; $0.backgroundOpacity = 0.5; $0.fontFamily = "Menlo"; $0.optionAsMeta = true }
        let reopened = TerminalProfile(defaults: defaults)
        #expect(reopened.settings(for: id).zoom == 3)
        #expect(reopened.settings(for: id).effectiveSize == 14)
        #expect(reopened.settings(for: id).font.pointSize == 14)
        reopened.update(id) { $0.zoom += 100 }
        #expect(reopened.settings(for: id).effectiveSize == 72)
        reopened.update(id) { $0.restoreTheming() }
        let restored = reopened.settings(for: id)
        #expect(restored.zoom == 0 && restored.theme == "" && restored.backgroundOpacity == 1 && restored.fontFamily == "")
        #expect(restored.optionAsMeta)   // behavior settings aren't theming
    }

    @Test
    func tabsStartWithTheirProfileFolderAndCommand() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TerminalProfile.shared
        let id = library.addProfile(named: "Scratch-\(UUID().uuidString.prefix(4))")
        defer { library.removeProfile(id) }
        library.update(id) { $0.startDirectory = root.path }
        let workspace = Workspace(restoring: nil)
        defer { workspace.tabs.forEach { $0.shell.close() } }
        workspace.add(profile: id)
        #expect(workspace.selected.shell.profileID == id)
        #expect(workspace.selected.shell.startDirectory == root.path)
        workspace.add()
        #expect(workspace.selected.shell.profileID == id)   // new tabs keep the current tab's profile
        workspace.useProfile(library.defaultProfileID)
        #expect(workspace.selected.shell.profileID == library.defaultProfileID)
    }
}
