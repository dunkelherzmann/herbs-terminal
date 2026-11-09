import Foundation
import Testing
@testable import HerbsTerminal

final class MockRemoteFileService: RemoteFileService, @unchecked Sendable {
    var filesByPath: [String: [RemoteEntry]] = [:]
    var createdDirectories: [String] = []
    var removedPaths: [(path: String, directory: Bool)] = []
    var renames: [(old: String, new: String)] = []

    func list(_ path: String) throws -> [RemoteEntry] {
        return filesByPath[path] ?? []
    }

    func mkdir(_ path: String) throws {
        createdDirectories.append(path)
    }

    func remove(_ path: String, directory: Bool) throws {
        removedPaths.append((path: path, directory: directory))
    }

    func rename(_ old: String, _ new: String, replace: Bool) throws {
        renames.append((old: old, new: new))
    }

    func stat(_ path: String, follow: Bool) throws -> RemoteAttributes {
        return RemoteAttributes(size: 1024, mode: 0o100644, modified: 0)
    }
}

@Suite("Remote Explorer Tests")
@MainActor
struct RemoteExplorerTests {

    @Test
    func listingFiltersHiddenFilesAndSortsFoldersFirst() async throws {
        let mock = MockRemoteFileService()
        let dirAttr = RemoteAttributes(size: nil, mode: 0o040755, modified: 100)
        let fileAttr = RemoteAttributes(size: 500, mode: 0o100644, modified: 100)

        mock.filesByPath["/home/user"] = [
            RemoteEntry(name: "zebra.txt", attributes: fileAttr),
            RemoteEntry(name: ".hidden_file", attributes: fileAttr),
            RemoteEntry(name: ".hidden_dir", attributes: dirAttr),
            RemoteEntry(name: "alpha_folder", attributes: dirAttr),
            RemoteEntry(name: "beta_folder", attributes: dirAttr),
            RemoteEntry(name: "apple.txt", attributes: fileAttr)
        ]

        let endpoint = RemoteEndpoint(host: "remote.host", port: 22, username: "user")
        let vm = RemoteExplorerViewModel(endpoint: endpoint, service: mock)

        // When showHidden is false
        vm.showHidden = false
        await vm.load(path: "/home/user")

        #expect(vm.entries.count == 4)
        // Folders first, sorted alphabetically
        #expect(vm.entries[0].name == "alpha_folder")
        #expect(vm.entries[0].attributes.directory)
        #expect(vm.entries[1].name == "beta_folder")
        #expect(vm.entries[1].attributes.directory)
        // Then files, sorted alphabetically
        #expect(vm.entries[2].name == "apple.txt")
        #expect(!vm.entries[2].attributes.directory)
        #expect(vm.entries[3].name == "zebra.txt")

        // When showHidden is true
        vm.showHidden = true
        await vm.load(path: "/home/user")
        #expect(vm.entries.count == 6)
        #expect(vm.entries.contains { $0.name == ".hidden_file" })
        #expect(vm.entries.contains { $0.name == ".hidden_dir" })
    }

    @Test
    func folderCreationAndDeletion() async throws {
        let mock = MockRemoteFileService()
        let endpoint = RemoteEndpoint(host: "remote.host", port: 22, username: "user")
        let vm = RemoteExplorerViewModel(endpoint: endpoint, service: mock)

        try vm.createFolder(name: "new_folder", in: "/var/www")
        #expect(mock.createdDirectories.contains("/var/www/new_folder"))

        let dirAttr = RemoteAttributes(size: nil, mode: 0o040755, modified: 0)
        let entry = RemoteEntry(name: "old_folder", attributes: dirAttr)
        try vm.delete(entry: entry, in: "/var/www")
        #expect(mock.removedPaths.contains { $0.path == "/var/www/old_folder" && $0.directory == true })
    }

    @Test
    func invalidFileNameRejected() throws {
        let mock = MockRemoteFileService()
        let endpoint = RemoteEndpoint(host: "remote.host", port: 22, username: "user")
        let vm = RemoteExplorerViewModel(endpoint: endpoint, service: mock)

        #expect(throws: (any Error).self) {
            try vm.createFolder(name: "bad/name", in: "/home/user")
        }
        #expect(throws: (any Error).self) {
            try vm.createFolder(name: "..", in: "/home/user")
        }
    }
}
