import Foundation
import WinSDK

/// How Connect via SSH starts a session, as on the Mac and Linux: the app types only the path of a private launcher
/// into the tab's own shell. The launcher (a small batch file in the app's own folder) clears that line from the
/// screen, gives Windows' ssh the password helper's variables when there's a saved password, runs ssh with the
/// keepalive settings, and deletes itself. No command line, password or token appears on screen or in the shell's
/// history, and when ssh ends the tab is back at its own shell.
enum SSHLauncher {
    /// Writes a launcher for `endpoint` and returns its path.
    static func write(_ endpoint: RemoteEndpoint, password: String?, lines: (String) -> Int, shell: DropQuoting) -> String? {
        guard let ssh = SSH.executable else { return nil }
        let folder = AppFolders.support().appendingPathComponent("launch", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("ssh-\(randomHex(8)).cmd").path
        // Up and clear, once per row the typed line takes: the launcher's own path, which the shell echoed.
        let rows = max(1, lines(typed(path, for: shell)))
        var lines = ["@echo off", "setlocal"]
        lines.append("<nul set /p \"=" + String(repeating: "\u{1b}[1A\u{1b}[2K", count: rows) + "\"")
        if let password, !password.isEmpty, let broker = AskpassBroker.shared {
            for (name, value) in broker.environment(token: broker.issue(password, for: endpoint.passwordLogins)).sorted(by: { $0.key < $1.key }) {
                lines.append("set \"\(name)=\(batchSafe(value))\"")
            }
        }
        let arguments = [ssh] + SSH.keepAliveOptions + ["-p", String(endpoint.port), "\(endpoint.username)@\(endpoint.host)"]
        lines.append(arguments.map { "\"\(batchSafe($0))\"" }.joined(separator: " "))
        // Deletes the launcher as the batch ends (the usual trick, so cmd doesn't look for the next line).
        lines.append("(goto) 2>nul & del \"%~f0\" >nul 2>&1")
        guard FileManager.default.createFile(atPath: path, contents: Data((lines.joined(separator: "\r\n") + "\r\n").utf8)) else { return nil }
        return path
    }

    /// Launchers left by sessions that were cut short (the app quit while ssh ran). Only ones older than a minute, so
    /// another running copy of the app never loses the one it's about to start.
    static func sweep() {
        let folder = AppFolders.support().appendingPathComponent("launch", isDirectory: true)
        let old = Date().addingTimeInterval(-60)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("ssh-") && name.hasSuffix(".cmd") {
            let path = folder.appendingPathComponent(name).path
            if let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, modified < old {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// What to type into the tab's shell to run the launcher.
    static func typed(_ path: String, for shell: DropQuoting) -> String {
        switch shell {
        case .commandPrompt: "\"\(path)\""
        case .powerShell: "& '\(path.replacingOccurrences(of: "'", with: "''"))'"
        case .posix, .wsl: "cmd.exe /c '\(path)'"
        }
    }

    /// `%` starts a variable in a batch file; doubled, it's a percent sign.
    private static func batchSafe(_ value: String) -> String { value.replacingOccurrences(of: "%", with: "%%") }
}

extension ShellLocation {
    /// An ssh.exe running under the shell (directly, or from a launcher or a script), the newest one: its process id
    /// and command line.
    static func sshUnder(_ shell: DWORD) -> (pid: DWORD, commandLine: String)? {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var parents: [DWORD: DWORD] = [:], names: [DWORD: String] = [:]
        guard Process32FirstW(snapshot, &entry) else { return nil }
        repeat {
            parents[entry.th32ProcessID] = entry.th32ParentProcessID
            names[entry.th32ProcessID] = withUnsafeBytes(of: entry.szExeFile) { raw in
                String(decoding: raw.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
            }.lowercased()
        } while Process32NextW(snapshot, &entry)
        func isUnderShell(_ pid: DWORD) -> Bool {
            var current = pid
            for _ in 0..<4 {
                guard let parent = parents[current], parent != current else { return false }
                if parent == shell { return true }
                current = parent
            }
            return false
        }
        let found = names.filter { $0.value == "ssh.exe" && isUnderShell($0.key) }.map(\.key).sorted()
        guard let pid = found.last, let commandLine = commandLine(of: pid) else { return nil }
        return (pid, commandLine)
    }

    /// Where a typed `ssh …` goes: the destination as Windows' ssh resolves it with `ssh -G` (aliases, ports and
    /// users from ~/.ssh/config). Nil for ssh commands that don't open a session (-G, -O, -V, -Q).
    static func resolveSSH(_ commandLine: String) -> RemoteEndpoint? {
        let arguments = Array(arguments(commandLine).dropFirst())
        guard !arguments.isEmpty, !arguments.contains(where: { ["-G", "-O", "-V", "-Q"].contains($0) }), let ssh = SSH.executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = ["-G"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, values[parts[0]] == nil { values[parts[0]] = parts[1] }
        }
        guard let host = values["hostname"], let user = values["user"] else { return nil }
        return RemoteEndpoint(host: host, port: Int(values["port"] ?? "") ?? 22, username: user)
    }
}
