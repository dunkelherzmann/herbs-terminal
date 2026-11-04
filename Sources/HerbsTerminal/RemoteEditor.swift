import AppKit
import Foundation

@MainActor
final class RemoteEditor: ObservableObject {
    static let shared = RemoteEditor()

    let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("HerbsTerminal/remote_drafts", isDirectory: true)
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            self.cacheDirectory = caches
        }
    }

    func stageWorkingCopy(endpoint: RemoteEndpoint, remotePath: String, content: Data) throws -> URL {
        let hostFolder = cacheDirectory.appendingPathComponent(endpoint.host, isDirectory: true)
        let normalizedPath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let localFileURL = hostFolder.appendingPathComponent(normalizedPath)

        let parentDir = localFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        try content.write(to: localFileURL, options: .atomic)
        return localFileURL
    }

    func hasConflict(initial: RemoteAttributes, current: RemoteAttributes) -> Bool {
        return initial.size != current.size || initial.modified != current.modified
    }

    func openInDefaultApp(localURL: URL) {
        NSWorkspace.shared.open(localURL)
    }
}
