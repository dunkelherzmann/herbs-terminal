import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Typed ssh following")
struct TypedSSHTests {
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/herbs-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Runs a shell with the integration's environment and a throwaway HOME.
    private func run(_ shell: String, arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test
    func socketPathsFitUnixLimits() {
        #expect(SSHControl.longestSocketPath < 104)
        #expect(SSHControl.controlPath.hasSuffix("/cm-%C"))
    }

    @Test
    func privateFolderRejectsASymlinkPlantedInTmp() throws {
        let target = try scratch()
        defer { try? FileManager.default.removeItem(at: target) }
        let base = "/tmp/herbs-trap-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createSymbolicLink(atPath: base, withDestinationPath: target.path)
        defer { try? FileManager.default.removeItem(atPath: base); try? FileManager.default.removeItem(atPath: base + "-1") }
        let chosen = SSHControl.privateDirectory(base: base)
        #expect(chosen.path == base + "-1")
        var info = stat()
        #expect(lstat(chosen.path, &info) == 0 && (info.st_mode & 0o777) == 0o700)
    }

    @Test
    func announcementsAndLabelsNeverShowAPassword() {
        let endpoint = ShellIntegration.endpoint(fromAnnouncement: "admin:asdf\n192.0.2.10\n22\n")
        #expect(endpoint?.host == "192.0.2.10" && endpoint?.port == 22)
        #expect(endpoint?.label == "admin@192.0.2.10")
        #expect(ShellIntegration.endpoint(fromAnnouncement: "\n\n\n") == nil)
        #expect(ShellIntegration.endpoint(fromAnnouncement: "me\nhost\n") == nil)
    }

    @Test
    func zshLoadsYourStartupFilesThenFollowsTypedSSH() throws {
        try ShellIntegration.install()
        let home = try scratch(), announce = try scratch()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: announce) }
        try "export HERBS_TEST_MARKER=from-your-zshrc\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let script = """
        print -r -- "marker=$HERBS_TEST_MARKER"
        print -r -- "zdotdir=$ZDOTDIR"
        whence -w ssh
        ssh -o BatchMode=yes -o ConnectTimeout=2 -p 1 nobody@127.0.0.1 true
        cat "$HERBS_ANNOUNCE_DIR/announce-$$"
        """
        let output = try run("/bin/zsh", arguments: ["-l", "-i", "-c", script], environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb",
            "ZDOTDIR": ShellIntegration.folder.path, "HERBS_USER_ZDOTDIR": home.path,
            "HERBS_ANNOUNCE_DIR": announce.path,
        ])
        #expect(output.contains("marker=from-your-zshrc"))
        #expect(output.contains("zdotdir=\(home.path)"))   // your ZDOTDIR is back after startup
        #expect(output.contains("ssh: function"))
        #expect(output.contains("nobody\n127.0.0.1\n1\n"))
    }

    @Test
    func bashLoadsYourProfileThenFollowsTypedSSH() throws {
        try ShellIntegration.install()
        let home = try scratch(), announce = try scratch()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: announce) }
        try "export HERBS_TEST_MARKER=from-your-profile\n".write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let script = """
        echo "marker=$HERBS_TEST_MARKER"
        type -t ssh
        ssh -o BatchMode=yes -o ConnectTimeout=2 -p 1 nobody@127.0.0.1 true
        cat "$HERBS_ANNOUNCE_DIR/announce-$$"
        """
        let output = try run("/bin/bash", arguments: ["--rcfile", ShellIntegration.folder.appendingPathComponent("bashrc").path, "-i", "-c", script],
                             environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "HERBS_ANNOUNCE_DIR": announce.path])
        #expect(output.contains("marker=from-your-profile"))
        #expect(output.contains("function"))
        #expect(output.contains("nobody\n127.0.0.1\n1\n"))
    }
}
