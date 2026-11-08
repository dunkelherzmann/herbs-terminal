import Foundation
import Glibc

/// The computer outside the Flatpak sandbox. Shells, the interactive ssh, sudo and the system's SFTP server run
/// there, so a tab is a real login on this computer with its own tools, ~/.ssh/config and SSH agent. Outside a
/// Flatpak (a development build) "the host" is simply this process's own system.
enum Host {
    /// HERBS_LOCAL_HOST=1 treats the sandbox as the host, for development builds run inside the Flatpak SDK.
    static let isFlatpak = FileManager.default.fileExists(atPath: "/.flatpak-info") && ProcessInfo.processInfo.environment["HERBS_LOCAL_HOST"] != "1"
    static let appID = ProcessInfo.processInfo.environment["FLATPAK_ID"] ?? "org.herbsterminal.app"

    /// The program and arguments that run `command` on the host. In the Flatpak, `environment` and `directory`
    /// travel with flatpak-spawn; outside, the caller sets them on the process.
    static func argv(_ command: [String], environment: [String: String] = [:], directory: String? = nil) -> [String] {
        guard isFlatpak else { return command }
        var arguments = ["/usr/bin/flatpak-spawn", "--host", "--watch-bus"]
        if let directory { arguments.append("--directory=\(directory)") }
        for key in environment.keys.sorted() { arguments.append("--env=\(key)=\(environment[key]!)") }
        return arguments + command
    }

    /// A process that runs `command` on the host, not yet started.
    static func process(_ command: [String], environment: [String: String] = [:], directory: String? = nil) -> Process {
        let process = Process()
        let full = argv(command, environment: environment, directory: directory)
        process.executableURL = URL(fileURLWithPath: full[0])
        process.arguments = Array(full.dropFirst())
        if !isFlatpak {
            if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        }
        return process
    }

    /// Runs `command` on the host and returns its exit status and output; nil status on a timeout.
    @discardableResult
    static func run(_ command: [String], input: Data? = nil, timeout: TimeInterval = 20) -> (status: Int32?, output: String) {
        let result = ChildProcess.run(argv(command), input: input, timeout: timeout)
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }

    /// The account's login shell, as the host's account database has it.
    static let loginShell: String = {
        let user = NSUserName()
        let line = run(["/usr/bin/getent", "passwd", user], timeout: 5).output
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        if fields.count >= 7, !fields[6].isEmpty { return String(fields[6]) }
        if let shell = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_shell) }), !shell.isEmpty, !isFlatpak { return shell }
        return "/bin/bash"
    }()

    /// The host's name, for the window title as in `user@host`.
    static let hostName: String = {
        let name = isFlatpak ? run(["/bin/sh", "-c", "hostname 2>/dev/null || cat /etc/hostname"], timeout: 5).output : ProcessInfo.processInfo.hostName
        return name.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")[0]
    }()

    /// How a program on the host runs this app's own executable in helper mode (ssh's askpass and Tailcat proxy).
    /// `flatpak run` finds a per-user install under $HOME, which the shell (or the user) may have changed, so the
    /// user's own Flatpak folder is named.
    static var helperCommand: [String] {
        guard isFlatpak else { return [Bundle.main.executablePath ?? CommandLine.arguments[0]] }
        let userFlatpaks = ProcessInfo.processInfo.environment["FLATPAK_USER_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/flatpak"
        return ["env", "FLATPAK_USER_DIR=" + userFlatpaks, "flatpak", "run", "--command=herbs-terminal", appID]
    }

    /// Where the sandbox sees a path of the host's own system folders. Home folders, removable media, /opt, /srv
    /// and /tmp are shared at the same path; the system folders (/usr, /etc, …) appear under /run/host.
    static func sandboxPath(_ hostPath: String) -> String {
        guard isFlatpak else { return hostPath }
        let normalized = normalizePath(hostPath)
        for top in ["/usr", "/etc", "/bin", "/sbin", "/lib", "/lib32", "/lib64"] where normalized == top || normalized.hasPrefix(top + "/") {
            return "/run/host" + normalized
        }
        return normalized
    }

    /// Entries of the sandbox's own root that the host doesn't have.
    static let sandboxOnlyRootEntries: Set<String> = isFlatpak ? ["app", ".flatpak-info"] : []
}

/// What the host knows about a tab's shell: its folder, the program in the foreground and whether an ssh runs
/// under it. One long-lived `sh` on the host answers, so the app never needs to see the host's process table.
final class HostProcesses: @unchecked Sendable {
    static let shared = HostProcesses()

    struct Report: Equatable, Sendable {
        var directory: String?
        var foregroundPid: Int32 = 0
        var foregroundName: String?
        var foregroundCommand: String?
        var runsSSH = false
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    private static let script = #"""
    while IFS= read -r pid; do
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
      stat=$(cat "/proc/$pid/stat" 2>/dev/null)
      stat=${stat##*) }
      set -- $stat
      fg=${6:-0}
      comm=""; cmd=""
      if [ "$fg" -gt 0 ] 2>/dev/null && [ "$fg" != "$pid" ]; then
        comm=$(cat "/proc/$fg/comm" 2>/dev/null)
        cmd=$(tr '\000\n' '  ' < "/proc/$fg/cmdline" 2>/dev/null)
      fi
      ssh=0
      if command -v pgrep >/dev/null 2>&1; then
        pgrep -x -P "$pid" ssh >/dev/null 2>&1 && ssh=1
      else
        for child in $(cat /proc/$pid/task/*/children 2>/dev/null); do
          [ "$(cat /proc/$child/comm 2>/dev/null)" = ssh ] && ssh=1
        done
      fi
      printf '%s\037%s\037%s\037%s\037%s\n' "$cwd" "$fg" "$comm" "$cmd" "$ssh"
    done
    """#

    private func start() -> Bool {
        if let process, process.isRunning { return true }
        let process = Host.process(["/bin/sh", "-c", Self.script])
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer = Data()
        return true
    }

    /// Asks about `pid` (a host process id); nil when the host doesn't answer within a second.
    func report(for pid: Int32) -> Report? {
        guard pid > 0 else { return nil }
        return lock.withLock {
            guard start(), let input, let output else { return nil }
            do { try input.write(contentsOf: Data("\(pid)\n".utf8)) } catch { process = nil; return nil }
            let deadline = Date().addingTimeInterval(1)
            while !buffer.contains(10) {
                var ready = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
                guard remaining > 0, poll(&ready, 1, remaining) > 0 else { process?.terminate(); process = nil; return nil }
                let chunk = output.availableData
                guard !chunk.isEmpty else { process = nil; return nil }
                buffer.append(chunk)
            }
            let end = buffer.firstIndex(of: 10)!
            let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...end)
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            return Report(directory: fields[0].isEmpty ? nil : fields[0], foregroundPid: Int32(fields[1]) ?? 0,
                          foregroundName: fields[2].isEmpty ? nil : fields[2],
                          foregroundCommand: fields[3].trimmingCharacters(in: .whitespaces).isEmpty ? nil : fields[3].trimmingCharacters(in: .whitespaces),
                          runsSSH: fields[4] == "1")
        }
    }
}
