import SwiftUI
import HerbsTerminalUI

private struct Entry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var size: Int64?
    var id: URL { url }
}

@MainActor
private final class DirectoryListing: ObservableObject {
    @Published var revision = 0
    /// Copy, move or trash work running in the background.
    @Published var working: String?
    @Published var entries: [Entry] = []
    @Published var error: String?
    @Published var devices = LocalPlaces.devices()

    func load(_ directory: URL, showHidden: Bool) async {
        entries = []
        error = nil
        do {
            let items = try await Task.detached {
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey],
                                                            options: showHidden ? [] : [.skipsHiddenFiles]).map { url in
                    Entry(url: url, isDirectory: opensAsFolder(url),
                          size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
                }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            }.value
            if !Task.isCancelled { entries = items }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// Folders and symlinks to folders open in the explorer; packages such as apps open with their Mac app.
func opensAsFolder(_ url: URL) -> Bool {
    let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    return values?.isDirectory == true && values?.isPackage != true
}

struct Place: Identifiable, Equatable {
    let name: String
    let symbol: String
    let path: String
    var id: String { path }
}

enum LocalPlaces {
    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Place] {
        let folders = [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc.text"), ("Downloads", "arrow.down.circle"),
                       ("Movies", "film"), ("Music", "music.note"), ("Pictures", "photo")]
        return [Place(name: "Home", symbol: "house", path: home.path)]
            + folders.map { Place(name: $0.0, symbol: $0.1, path: home.appendingPathComponent($0.0).path) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            + [Place(name: "Computer", symbol: "desktopcomputer", path: "/"),
               Place(name: "Trash", symbol: "trash", path: home.appendingPathComponent(".Trash").path)]
    }

    static func devices() -> [Place] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                                          options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path != "/" }.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
            return Place(name: name, symbol: "externaldrive", path: url.path)
        }
    }
}

struct LocalExplorer: View {
    @Binding var directory: URL
    @Binding var history: NavigationHistory
    @ObservedObject var log: FileOperationLog
    var findRequest = 0
    /// The Places side pane's width; 0 hides it when the pane is too narrow, so nothing is clipped.
    var sidebarWidth: CGFloat = 170
    /// Turns Administrator mode on or off; nil hides the lock button.
    var administratorToggle: (() -> Void)?
    var isAdministrator = false
    /// The tab whose feature-test bridge this explorer answers.
    var bridgeHost: WindowState?
    @StateObject private var listing = DirectoryListing()
    @StateObject private var filter = ExplorerFilter()
    @StateObject private var selection = ListSelection<URL>()
    @AppStorage("explorerShowHidden") private var showHidden = false
    @AppStorage("explorerBookmarks") private var bookmarkList = ""

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var path: String { directory.standardizedFileURL.path }
    private var bookmarks: [String] { bookmarkList.split(separator: "\n").map(String.init) }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarWidth > 0 {
            PlacesSidebar(sections: [
                PlacesSection(title: "Places", places: LocalPlaces.standard()),
                PlacesSection(title: "Devices", places: listing.devices),
                PlacesSection(title: "Bookmarks", places: bookmarks.map {
                    Place(name: URL(fileURLWithPath: $0).lastPathComponent, symbol: "folder", path: $0)
                }, removable: true),
            ], current: path, open: navigate, remove: toggleBookmark, width: sidebarWidth)
            Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                LocationBar(path: path, history: $history, home: home, showHidden: $showHidden,
                            go: { directory = URL(fileURLWithPath: $0, isDirectory: true) },
                            reload: { listing.devices = LocalPlaces.devices(); listing.revision += 1 }) {
                    Button { toggleBookmark(history.current) } label: {
                        Label("Bookmark", systemImage: bookmarks.contains(path) ? "bookmark.fill" : "bookmark")
                    }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                .accessibilityValue(bookmarks.contains(path) ? "On" : "Off")
                    .hint(bookmarks.contains(path) ? "Remove Bookmark (⌥⌘D)\nTake this folder out of the side pane's Bookmarks."
                                                   : "Bookmark This Folder (⌥⌘D)\nAdd it to the side pane's Bookmarks.")
                    if let administratorToggle {
                        Button(action: administratorToggle) {
                            Label("Administrator mode", systemImage: isAdministrator ? "lock.open.fill" : "lock")
                                .foregroundStyle(isAdministrator ? Color.red : Color.primary)
                        }
                        .accessibilityValue(isAdministrator ? "On" : "Off")
                        .hint(isAdministrator ? "Leave Administrator Mode\nGo back to working with your own account's access."
                                              : "Administrator Mode\nWork as root with sudo: open and change any file. Asks for the sudo password.")
                    }
                    FileActionsMenu(actions: actions)
                    .hint("File Actions\nUpload, download, undo, cut, copy, paste, delete, select all and find.")
                }
                Divider()
                if filter.active { FilterBar(filter: filter); Divider() }
                if let working = listing.working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(working).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    Divider()
                }
                if let error = listing.error {
                    Text(error).padding()
                    if let administratorToggle, isPermissionError(error) {
                        Button("Open with Administrator Mode…", action: administratorToggle)
                            .padding(.horizontal)
                            .hint("Administrator Mode\nOpen this folder as root with sudo. Asks for your Mac password.")
                    }
                    Spacer()
                } else {
                    files
                }
            }
        }
        .onChange(of: directory) { history.visit(path); filter.close() }
        .onChange(of: findRequest) { filter.active = true }
        .onAppear { bridgeHost?.explorerBridge = makeBridge() }
        .onDisappear { if bridgeHost?.explorerBridge?.owner == "local" { bridgeHost?.explorerBridge = nil } }
        .task(id: ListingRequest(directory: directory, revision: listing.revision, showHidden: showHidden)) {
            selection.ids = []
            await listing.load(directory, showHidden: showHidden)
        }
    }

    private var files: some View {
        List(visibleEntries, selection: $selection.ids) { entry in
            FileRow(name: entry.url.lastPathComponent, isFolder: entry.isDirectory, size: entry.size)
                .tag(entry.url)
                .hint(entry.isDirectory ? "Folder\nDouble-click or press Return to open it."
                      : "File\nDouble-click or press Return to open it: text files in the text editor, others in their Mac app.")
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.isEmpty {
                Button("New Folder…") { create(folder: true) }
                Button("New File…") { create(folder: false) }
                Button("Paste") { paste() }.disabled(!FileClipboard.shared.hasContent)
            }
            if let url = urls.first {
                Button("Open") { open(url) }
                if !opensAsFolder(url) {
                    Button("Open in Text Editor") { urls.filter { !opensAsFolder($0) }.forEach { Workspace.openEditor(.local($0)) } }
                    Button("Open with Default App") { urls.forEach { NSWorkspace.shared.open($0) } }
                }
                if urls.count == 1 { Button("Rename…") { rename(url) } }
                if opensAsFolder(url) {
                    // In the same form as the location's path (/tmp, not /private/tmp), so the star matches.
                    let folder = url.standardizedFileURL.path
                    Button(bookmarks.contains(folder) ? "Remove Bookmark" : "Add Bookmark") { toggleBookmark(folder) }
                }
                Button("Get Info…") { FileInfoWindow.show(.local(Array(urls))) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                Divider()
                Button("Cut") { cut(urls) }
                Button("Copy") { copy(urls) }
                Button("Paste") { paste() }.disabled(!FileClipboard.shared.hasContent)
                Button("Move to Trash") { trash(urls) }
            }
        } primaryAction: { urls in
            urls.first.map(open)
        }
        .fileCommands(actions) {
            if let previous = history.goBack() { directory = URL(fileURLWithPath: previous, isDirectory: true) }
        }
    }

    private var visibleEntries: [Entry] { listing.entries.filter { filter.matches($0.url.lastPathComponent) } }
    private var selectedURLs: [URL] { visibleEntries.map(\.url).filter(selection.ids.contains) }

    private var actions: FileActions {
        let hasSelection = !selection.ids.isEmpty
        return FileActions(
            transferHelp: "Connect this tab via SSH first. The explorer then shows the remote host, where you can upload and download.",
            undoTitle: log.undoTitle, redoTitle: log.redoTitle,
            undo: log.canUndo ? { perform { try log.undo() } } : nil,
            redo: log.canRedo ? { perform { try log.redo() } } : nil,
            cut: hasSelection ? { cut(selectedURLs) } : nil,
            copy: hasSelection ? { copy(selectedURLs) } : nil,
            paste: { paste() },
            delete: hasSelection ? { trash(selectedURLs) } : nil,
            selectAll: { selection.ids = Set(visibleEntries.map(\.url)) },
            find: { filter.active = true })
    }

    private func create(folder: Bool) {
        guard let name = askForName(title: folder ? "New Folder" : "New File",
                                    message: "Name for the new \(folder ? "folder" : "file") in \(directory.lastPathComponent):",
                                    initial: folder ? "untitled folder" : "untitled") else { return }
        perform {
            let change = try LocalFiles.create(folder: folder, named: name, in: directory)
            log.record(change, as: folder ? "New Folder" : "New File")
            if case .created(let urls) = change {
                selection.ids = Set(urls)
                // A new file opens straight away in the text editor.
                if !folder, let url = urls.first { Workspace.openEditor(.local(url)) }
            }
        }
    }

    private func rename(_ url: URL) {
        guard let name = askForName(title: "Rename", message: "New name for “\(url.lastPathComponent)”:",
                                    initial: url.lastPathComponent), name != url.lastPathComponent else { return }
        perform {
            let change = try LocalFiles.rename(url, to: name)
            log.record(change, as: "Rename")
            if case .moved(let moves) = change { selection.ids = Set(moves.map(\.to)) }
        }
    }

    private func cut(_ urls: Set<URL>) { cut(Array(urls)) }
    private func copy(_ urls: Set<URL>) { copy(Array(urls)) }
    private func trash(_ urls: Set<URL>) { trash(Array(urls)) }
    private func cut(_ urls: [URL]) { FileClipboard.shared.writeLocal(urls, cut: true) }
    private func copy(_ urls: [URL]) { FileClipboard.shared.writeLocal(urls, cut: false) }
    private func trash(_ urls: [URL]) {
        inBackground("Moving to Trash…", { try LocalFiles.trash(urls) }) { log.record($0) }
    }

    private func paste() {
        let (urls, cut) = FileClipboard.shared.readLocal()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = directory
        inBackground(cut ? "Moving…" : "Copying…", {
            cut ? try LocalFiles.move(urls, into: folder) : try LocalFiles.copy(urls, into: folder)
        }) { change in
            log.record(change)
            if cut { FileClipboard.shared.finishCut() }
            if case .created(let created) = change { selection.ids = Set(created) }
        }
    }

    /// Copy, move and trash can take a long time (big folders, other volumes), so they run off the main
    /// thread: the window and every terminal keep working, and the folder reloads when they finish.
    private func inBackground(_ title: String, _ work: @escaping @Sendable () throws -> FileChange,
                              then record: @escaping (FileChange) -> Void) {
        listing.working = title
        Task {
            do { record(try await Task.detached(operation: work).value) } catch { NSAlert(error: error).runModal() }
            listing.working = nil
            listing.revision += 1
        }
    }

    /// Runs a file change, reloads the folder and reports any failure in an alert.
    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { NSAlert(error: error).runModal() }
        listing.revision += 1
    }

    private func navigate(to target: String) {
        // In the form the location shows (/tmp, not /private/tmp): the visit when `directory` changes then
        // matches this one instead of adding the same folder twice, which made Back need two presses.
        let target = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL.path
        history.visit(target)
        directory = URL(fileURLWithPath: target, isDirectory: true)
    }

    private func open(_ url: URL) {
        if opensAsFolder(url) { navigate(to: url.standardizedFileURL.path) }
        else if TextCodec.isLocalText(url) { Workspace.openEditor(.local(url)) }
        else { NSWorkspace.shared.open(url) }
    }

    private func toggleBookmark(_ target: String) {
        var marks = bookmarks
        if let index = marks.firstIndex(of: target) { marks.remove(at: index) } else { marks.append(target) }
        bookmarkList = marks.joined(separator: "\n")
    }
}

extension LocalExplorer {
    /// What the feature tests' bridge reads and runs, through the same code the menus and buttons use.
    fileprivate func makeBridge() -> ExplorerBridge {
        let bridge = ExplorerBridge(owner: "local")
        // With symlinks resolved, as the tests write it (/private/var rather than /var).
        bridge.path = {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        bridge.items = { visibleEntries.map { $0.isDirectory ? $0.url.lastPathComponent + "/" : $0.url.lastPathComponent } }
        bridge.selected = { selectedURLs.map(\.lastPathComponent) }
        bridge.select = { names in selection.ids = Set(visibleEntries.map(\.url).filter { names.contains($0.lastPathComponent) }) }
        bridge.go = { navigate(to: $0) }
        bridge.setFilter = { filter.active = true; filter.text = $0 }
        bridge.extra = {
            ["hidden": showHidden, "bookmarked": bookmarks.contains(path), "status": listing.error ?? listing.working ?? "",
             "finding": filter.active, "filter": filter.text, "canUndo": log.canUndo, "canRedo": log.canRedo,
             "undoTitle": log.undoTitle, "redoTitle": log.redoTitle, "administrator": isAdministrator, "remote": false]
        }
        bridge.command = { name, run in
            let actions = self.actions
            let urls = selectedURLs
            let selected = !urls.isEmpty
            let one: URL? = urls.count == 1 ? urls[0] : nil
            let commands: [String: (() -> Void)?] = [
                "cut": actions.cut, "copy": actions.copy, "paste": actions.paste, "delete": actions.delete,
                "select-all": actions.selectAll, "undo": actions.undo, "redo": actions.redo, "find": actions.find,
                "upload": nil, "download": nil,
                "new-folder": { create(folder: true) }, "new-file": { create(folder: false) },
                "open": selected ? { urls.first.map(open) } : nil,
                "edit": urls.contains { !opensAsFolder($0) } ? { urls.filter { !opensAsFolder($0) }.forEach { Workspace.openEditor(.local($0)) } } : nil,
                "open-default": urls.contains { !opensAsFolder($0) } ? { urls.forEach { NSWorkspace.shared.open($0) } } : nil,
                "rename": one.map { url in { rename(url) } },
                "info": selected ? { FileInfoWindow.show(.local(urls)) } : nil,
                "reveal": selected ? { NSWorkspace.shared.activateFileViewerSelecting(urls) } : nil,
                "bookmark-selected": one.flatMap { url in opensAsFolder(url) ? { toggleBookmark(url.standardizedFileURL.path) } : nil },
                "hidden": { showHidden.toggle() },
                "reload": { listing.revision += 1 },
                // The location bar's buttons run these same lines.
                "back": history.canGoBack ? { if let p = history.goBack() { directory = URL(fileURLWithPath: p, isDirectory: true) } } : nil,
                "forward": history.canGoForward ? { if let p = history.goForward() { directory = URL(fileURLWithPath: p, isDirectory: true) } } : nil,
                "up": path == "/" ? nil : { navigate(to: parentPath(history.current)) },
                "home": { navigate(to: home) },
            ]
            guard let entry = commands[name] else { return "missing" }
            guard let action = entry else { return "disabled" }
            // After the bridge's answer: a dialog's modal loop would hold it back.
            if run { DispatchQueue.main.async { action() } }
            return run ? "ran" : "enabled"
        }
        return bridge
    }
}

private struct ListingRequest: Equatable {
    let directory: URL
    let revision: Int
    let showHidden: Bool
}
