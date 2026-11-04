import SwiftUI

private struct Entry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
}

@MainActor
private final class DirectoryListing: ObservableObject {
    @Published var revision = 0
    @Published var entries: [Entry] = []
    @Published var error: String?

    func load(_ directory: URL) async {
        entries = []
        error = nil
        do {
            let items = try await Task.detached {
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]).map { url in
                    Entry(url: url, isDirectory: try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
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

struct LocalExplorer: View {
    @Binding var directory: URL
    @StateObject private var listing = DirectoryListing()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { directory = directory.deletingLastPathComponent().standardizedFileURL } label: {
                    Label("Parent folder", systemImage: "arrow.up")
                }
                .disabled(directory.path == "/")
                Text(directory.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { createFile() } label: {
                    Label("New file", systemImage: "doc.badge.plus")
                }
                Button { listing.revision += 1 } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button { directory = FileManager.default.homeDirectoryForCurrentUser } label: {
                    Label("Home folder", systemImage: "house")
                }
            }
            .labelStyle(.iconOnly).padding(8)
            Divider()
            if let error = listing.error {
                Text(error).padding()
            } else {
                List(listing.entries) { entry in
                    Button {
                        if entry.isDirectory { directory = entry.url }
                        else { NSWorkspace.shared.open(entry.url) }
                    } label: {
                        Label(entry.url.lastPathComponent, systemImage: entry.isDirectory ? "folder" : "doc")
                    }.buttonStyle(.plain)
                }
            }
        }
        .task(id: ListingRequest(directory: directory, revision: listing.revision)) { await listing.load(directory) }
    }

    private func createFile() {
        let panel = NSSavePanel()
        panel.title = "Create Local File"
        panel.prompt = "Create"
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            directory = url.deletingLastPathComponent()
            listing.revision += 1
        } catch {
            listing.error = error.localizedDescription
        }
    }
}

private struct ListingRequest: Equatable {
    let directory: URL
    let revision: Int
}
