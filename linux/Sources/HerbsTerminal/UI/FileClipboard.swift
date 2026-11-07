import CGtk
import CHerb
import Foundation

/// Cut / Copy / Paste of files. Local items go on the clipboard as files, so file managers can paste them too;
/// remote items are kept here, and file managers get real files, downloaded at the moment they paste.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()

    private var cutPaths: [String]?
    private var remote: (endpoint: RemoteEndpoint, paths: [String], cut: Bool)?
    /// Set while the clipboard holds what this app put there.
    private var owned = false
    private var watching = false

    private var board: OpaquePointer? { clipboard() }

    private func watch() {
        guard !watching, let board else { return }
        watching = true
        on(board, "changed") { [weak self] _ in
            guard let self, let board = self.board else { return }
            if gdk_clipboard_is_local(c(board)) == 0 { self.owned = false; self.remote = nil; self.cutPaths = nil }
        }
    }

    func writeLocal(_ paths: [String], cut: Bool) {
        watch()
        remote = nil
        herb_clipboard_set_files(c(board), paths.joined(separator: "\n"), cut ? 1 : 0)
        owned = true
        cutPaths = cut ? paths : nil
    }

    /// Files on the clipboard, and whether they were cut here (so Paste moves them).
    func readLocal(_ done: @escaping @MainActor ([String], Bool) -> Void) {
        guard herb_clipboard_has_files(c(board)) != 0 else { done([], false); return }
        herb_clipboard_read_files(c(board), receivedTrampoline, stringBox { [weak self] text in
            let paths = text.map { $0.split(separator: "\n").map(String.init) } ?? []
            let cut = self?.owned == true && self?.cutPaths == paths
            done(paths, cut)
        })
    }

    func finishCut() { cutPaths = nil; remote = nil }

    /// Remote items: the app pastes them on the host (or uploads them elsewhere), and file managers get real files.
    /// `fetch` downloads one item to a local path; it runs only when something asks for the files.
    func writeRemote(_ paths: [String], on endpoint: RemoteEndpoint, cut: Bool, fetch: @escaping @Sendable (String, URL) throws -> Void) {
        watch()
        let staging = AppFolders.cache.appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = LazyFiles(paths: paths, folder: folder, fetch: fetch)
        let provider = herb_lazy_files_provider(lazyTrampoline, Unmanaged.passRetained(box).toOpaque(), lazyRelease)
        gdk_clipboard_set_content(c(board), provider)
        g_object_unref(raw(provider))
        owned = true
        cutPaths = nil
        remote = (endpoint, paths, cut)
    }

    func readRemote(for endpoint: RemoteEndpoint) -> (paths: [String], cut: Bool)? {
        guard owned, let remote, remote.endpoint == endpoint else { return nil }
        return (remote.paths, remote.cut)
    }

    var hasContent: Bool { (owned && remote != nil) || herb_clipboard_has_files(c(board)) != 0 }
}

/// Downloads copied remote items when another app pastes them, into a staging folder emptied whenever new remote
/// items are copied.
final class LazyFiles: @unchecked Sendable {
    let paths: [String]
    let folder: URL
    let fetch: @Sendable (String, URL) throws -> Void

    init(paths: [String], folder: URL, fetch: @escaping @Sendable (String, URL) throws -> Void) {
        self.paths = paths
        self.folder = folder
        self.fetch = fetch
    }

    func provide(_ mime: String) -> String? {
        var uris: [String] = []
        for path in paths {
            let target = folder.appendingPathComponent((path as NSString).lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                do { try fetch(path, target) } catch { return nil }
            }
            uris.append(target.absoluteString)
        }
        switch mime {
        case "x-special/gnome-copied-files": return "copy\n" + uris.joined(separator: "\n")
        case "text/uri-list": return uris.map { $0 + "\r\n" }.joined()
        default: return paths.map { folder.appendingPathComponent(($0 as NSString).lastPathComponent).path }.joined(separator: "\n")
        }
    }
}

private let lazyTrampoline: HerbProvide = { data, mime in
    let box = Unmanaged<LazyFiles>.fromOpaque(data!).takeUnretainedValue()
    guard let text = box.provide(mime.map { String(cString: $0) } ?? "") else { return nil }
    return g_strdup(text)
}

private let lazyRelease: HerbRelease = { data in
    Unmanaged<LazyFiles>.fromOpaque(data!).release()
}
