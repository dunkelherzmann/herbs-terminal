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
            return Place(name: name ?? url.lastPathComponent, symbol: "externaldrive", path: url.path)
        }
    }
}

struct LocalExplorer: View {
    @Binding var directory: URL
    @Binding var history: NavigationHistory
    @ObservedObject var log: FileOperationLog
    var findRequest = 0
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
            PlacesSidebar(sections: [
                PlacesSection(title: "Places", places: LocalPlaces.standard()),
                PlacesSection(title: "Devices", places: listing.devices),
                PlacesSection(title: "Bookmarks", places: bookmarks.map {
                    Place(name: URL(fileURLWithPath: $0).lastPathComponent, symbol: "folder", path: $0)
                }, removable: true),
            ], current: path, open: navigate, remove: toggleBookmark)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                LocationBar(path: path, history: $history, home: home, showHidden: $showHidden,
                            go: { directory = URL(fileURLWithPath: $0, isDirectory: true) },
                            reload: { listing.devices = LocalPlaces.devices(); listing.revision += 1 }) {
                    Button { toggleBookmark(history.current) } label: {
                        Label("Bookmark", systemImage: bookmarks.contains(path) ? "bookmark.fill" : "bookmark")
                    }
                    .keyboardShortcut("d")
                    .hint(bookmarks.contains(path) ? "Remove Bookmark (⌘D)\nTake this folder out of the side pane's Bookmarks."
                                                   : "Bookmark This Folder (⌘D)\nAdd it to the side pane's Bookmarks.")
                    FileActionsMenu(actions: actions)
                    .hint("File Actions\nUpload, download, undo, cut, copy, paste, delete, select all and find.")
                }
                Divider()
                if filter.active { FilterBar(filter: filter); Divider() }
                if let error = listing.error {
                    Text(error).padding()
                    Spacer()
                } else {
                    files
                }
            }
        }
        .onChange(of: directory) { history.visit(path); filter.close() }
        .onChange(of: findRequest) { filter.active = true }
        .task(id: ListingRequest(directory: directory, revision: listing.revision, showHidden: showHidden)) {
            selection.ids = []
            await listing.load(directory, showHidden: showHidden)
        }
    }

    private var files: some View {
        List(visibleEntries, selection: $selection.ids) { entry in
            FileRow(name: entry.url.lastPathComponent, isFolder: entry.isDirectory, size: entry.size)
                .tag(entry.url)
                .hint(entry.isDirectory ? "Folder\nDouble-click or press Return to open it." : "File\nDouble-click or press Return to open it with its Mac app.")
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                Button("Open") { open(url) }
                if opensAsFolder(url) {
                    Button(bookmarks.contains(url.path) ? "Remove Bookmark" : "Add Bookmark") { toggleBookmark(url.path) }
                }
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

    private func cut(_ urls: Set<URL>) { cut(Array(urls)) }
    private func copy(_ urls: Set<URL>) { copy(Array(urls)) }
    private func trash(_ urls: Set<URL>) { trash(Array(urls)) }
    private func cut(_ urls: [URL]) { FileClipboard.shared.writeLocal(urls, cut: true) }
    private func copy(_ urls: [URL]) { FileClipboard.shared.writeLocal(urls, cut: false) }
    private func trash(_ urls: [URL]) { perform { log.record(try LocalFiles.trash(urls)) } }

    private func paste() {
        let (urls, cut) = FileClipboard.shared.readLocal()
        guard !urls.isEmpty else { NSSound.beep(); return }
        perform {
            let change = cut ? try LocalFiles.move(urls, into: directory) : try LocalFiles.copy(urls, into: directory)
            log.record(change)
            if cut { FileClipboard.shared.finishCut() }
            if case .created(let created) = change { selection.ids = Set(created) }
        }
    }

    /// Runs a file change, reloads the folder and reports any failure in an alert.
    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { NSAlert(error: error).runModal() }
        listing.revision += 1
    }

    private func navigate(to target: String) {
        history.visit(target)
        directory = URL(fileURLWithPath: target, isDirectory: true)
    }

    private func open(_ url: URL) {
        if opensAsFolder(url) { navigate(to: url.standardizedFileURL.path) }
        else { NSWorkspace.shared.open(url) }
    }

    private func toggleBookmark(_ target: String) {
        var marks = bookmarks
        if let index = marks.firstIndex(of: target) { marks.remove(at: index) } else { marks.append(target) }
        bookmarkList = marks.joined(separator: "\n")
    }
}

private struct ListingRequest: Equatable {
    let directory: URL
    let revision: Int
    let showHidden: Bool
}
