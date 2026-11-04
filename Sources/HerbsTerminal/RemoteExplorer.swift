import SwiftUI

@MainActor
final class RemoteExplorerViewModel: ObservableObject {
    @Published var entries: [RemoteEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var showHidden = false
    @Published var currentPath: String = "/"

    let endpoint: RemoteEndpoint
    private let service: any RemoteFileService

    init(endpoint: RemoteEndpoint, service: (any RemoteFileService)? = nil) {
        self.endpoint = endpoint
        self.service = service ?? (try? SFTPClient(endpoint: endpoint)) ?? FallbackRemoteService()
    }

    func load(path: String) async {
        currentPath = path
        isLoading = true
        errorMessage = nil

        let svc = self.service
        let hidden = self.showHidden

        do {
            let items = try await Task.detached {
                let listed = try svc.list(path)
                return listed.filter { item in
                    hidden || !item.name.hasPrefix(".")
                }.sorted {
                    if $0.attributes.directory != $1.attributes.directory {
                        return $0.attributes.directory
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }.value

            if !Task.isCancelled {
                self.entries = items
                self.isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func createFolder(name: String, in path: String) throws {
        try validateFileName(name)
        try service.mkdir(remoteJoin(path, name))
    }

    func delete(entry: RemoteEntry, in path: String) throws {
        try service.remove(remoteJoin(path, entry.name), directory: entry.attributes.directory)
    }

    func rename(entry: RemoteEntry, newName: String, in path: String) throws {
        try validateFileName(newName)
        try service.rename(remoteJoin(path, entry.name), remoteJoin(path, newName), replace: false)
    }
}

private final class FallbackRemoteService: RemoteFileService, @unchecked Sendable {
    func list(_ path: String) throws -> [RemoteEntry] { throw FileIssue("Remote session is disconnected.") }
    func mkdir(_ path: String) throws { throw FileIssue("Remote session is disconnected.") }
    func remove(_ path: String, directory: Bool) throws { throw FileIssue("Remote session is disconnected.") }
    func rename(_ old: String, _ new: String, replace: Bool) throws { throw FileIssue("Remote session is disconnected.") }
    func stat(_ path: String, follow: Bool) throws -> RemoteAttributes { throw FileIssue("Remote session is disconnected.") }
}

struct RemoteExplorer: View {
    @Binding var currentPath: String
    @ObservedObject var viewModel: RemoteExplorerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    let parent = (currentPath as NSString).deletingLastPathComponent
                    currentPath = parent.isEmpty ? "/" : parent
                } label: {
                    Label("Parent folder", systemImage: "arrow.up")
                }
                .disabled(currentPath == "/")

                Text("\(viewModel.endpoint.label): \(currentPath)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)

                Spacer()

                Button {
                    viewModel.showHidden.toggle()
                    Task { await viewModel.load(path: currentPath) }
                } label: {
                    Label(viewModel.showHidden ? "Hide dotfiles" : "Show dotfiles",
                          systemImage: viewModel.showHidden ? "eye.slash" : "eye")
                }

                Button {
                    Task { await viewModel.load(path: currentPath) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .labelStyle(.iconOnly)
            .padding(8)

            Divider()

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 8) {
                    Text(error).foregroundColor(.red).padding()
                    Button("Retry") {
                        Task { await viewModel.load(path: currentPath) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.entries) { entry in
                    HStack {
                        Button {
                            if entry.attributes.directory {
                                currentPath = remoteJoin(currentPath, entry.name)
                            }
                        } label: {
                            Label(entry.name, systemImage: entry.attributes.directory ? "folder" : "doc")
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if !entry.attributes.directory, let size = entry.attributes.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            do {
                                try viewModel.delete(entry: entry, in: currentPath)
                                Task { await viewModel.load(path: currentPath) }
                            } catch {
                                viewModel.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .task(id: currentPath) {
            await viewModel.load(path: currentPath)
        }
    }
}
