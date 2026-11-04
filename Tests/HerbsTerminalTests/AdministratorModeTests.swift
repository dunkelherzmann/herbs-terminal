import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Administrator mode")
struct AdministratorModeTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test
    func sudoCommandsNeverCarryThePassword() {
        let (local, localArgs) = PrivilegedAccess.invocation(.local, sudo: ["-S", "-k", "-p", ""], command: ["/usr/libexec/sftp-server"])
        #expect(local == "/usr/bin/sudo" && localArgs == ["-S", "-k", "-p", "", "/usr/libexec/sftp-server"])
        let host = RemoteEndpoint(host: "nas", port: 2222, username: "admin")
        let (remote, remoteArgs) = PrivilegedAccess.invocation(.remote(host), sudo: ["-S", "-k", "-p", ""], command: ["sh", "-c", PrivilegedAccess.remoteServer])
        #expect(remote == "/usr/bin/ssh")
        #expect(remoteArgs.contains("ControlPath=\(SSHControl.controlPath)") && remoteArgs.contains("BatchMode=yes"))
        let command = remoteArgs.last!
        #expect(command.hasPrefix("sudo -S -k -p '' sh -c "))
        #expect(command.contains("/usr/lib/openssh/sftp-server"))
        #expect(PrivilegedAccess.Target.remote(host).label == "nas" && PrivilegedAccess.Target.local.label == "this Mac")
    }

    /// A stand-in for `sudo -S`: reads the password line, then becomes the SFTP server.
    private func fakeSudo(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("fake-sudo")
        try "#!/bin/sh\nIFS= read -r pw\n[ \"$pw\" = \"s3cret\" ] || exit 1\nexec /usr/libexec/sftp-server\n"
            .write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o700)
        return url
    }

    @Test
    func thePasswordGoesInOnStandardInputBeforeTheSession() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sudo = try fakeSudo(in: folder)
        let client = try SFTPClient(executable: sudo.path, arguments: [], preamble: Data("s3cret\n".utf8))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("etc"), withIntermediateDirectories: true)
        #expect(try client.list(folder.path).contains { $0.name == "etc" })
        #expect(throws: (any Error).self) { _ = try SFTPClient(executable: sudo.path, arguments: [], preamble: Data("wrong\n".utf8)) }
    }

    @Test @MainActor
    func oneSharedRootSessionHandlesActionsOneAtATime() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: [])
        let vm = RemoteExplorerViewModel(administrator: client, endpoint: RemoteEndpoint(host: "this Mac", username: "root"))
        #expect(vm.isAdministrator)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { await vm.newFolder(named: "dir\(index)", in: folder.path) }
            }
            group.addTask { await vm.load(path: folder.path) }
        }
        await vm.load(path: folder.path)
        #expect(vm.alert == nil)
        #expect(vm.entries.map(\.name).sorted() == (0..<8).map { "dir\($0)" })
        await vm.rename("dir0", to: "renamed", in: folder.path)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("renamed").path))
    }
}
