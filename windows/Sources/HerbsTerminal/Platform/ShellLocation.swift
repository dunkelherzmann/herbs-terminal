import Foundation
import WinSDK

/// What the title shows beside `user@host`, as on the Mac and Linux: the shell's current folder, and the program
/// running in the foreground with its command line (secrets hidden).
///
/// Windows shells don't tell a terminal their folder on their own. Command Prompt and PowerShell are started with a
/// prompt that also reports it the way Windows Terminal reads it (`ESC ] 9 ; 9 ; "<path>" ESC \`); shells that
/// send the usual `ESC ] 7 ; file://host/path` (WSL, Git Bash with shell integration) are read too. The program
/// is the shell's newest child process, read from the process list.
enum ShellLocation {
    // MARK: Prompt integration

    /// The command line and environment that make `commandLine`'s shell report its folder at every prompt.
    /// Shells this doesn't know, or PowerShell already given a command or script, are left as they are.
    static func integrate(commandLine: String, environment: [String: String]) -> (commandLine: String, environment: [String: String]) {
        var environment = environment
        switch shellKind(commandLine) {
        case .commandPrompt:
            let prompt = environment["PROMPT"] ?? ProcessInfo.processInfo.environment["PROMPT"] ?? "$P$G"
            if !prompt.contains("]9;9;") { environment["PROMPT"] = cmdPromptPrefix + prompt }
            return (commandLine, environment)
        case .powerShell:
            return (commandLine + " -NoExit -EncodedCommand " + encoded(powerShellPrompt), environment)
        case .other:
            return (commandLine, environment)
        }
    }

    /// Command Prompt's codes for ESC ] 9 ; 9 ; "<current folder>" ESC \ — written before the user's own prompt.
    static let cmdPromptPrefix = "$E]9;9;\"$P\"$E\\"

    /// Wraps the prompt PowerShell already has (its own, or one set up by the user's profile, which runs first).
    static let powerShellPrompt = """
        $global:__HerbsPrompt = $function:prompt
        function global:prompt {
            $location = $executionContext.SessionState.Path.CurrentLocation
            $text = & $global:__HerbsPrompt
            if ($location.Provider.Name -eq 'FileSystem') { "$([char]27)]9;9;`"$($location.ProviderPath)`"$([char]27)\\$text" } else { $text }
        }
        """

    enum ShellKind { case commandPrompt, powerShell, other }

    static func shellKind(_ commandLine: String) -> ShellKind {
        let tokens = arguments(commandLine)
        guard let first = tokens.first else { return .other }
        let name = programName(first).lowercased()
        let rest = tokens.dropFirst().map { $0.lowercased() }
        if name == "cmd" { return rest.contains("/c") ? .other : .commandPrompt }
        if name == "pwsh" || name == "powershell" {
            let given = ["-command", "-c", "-file", "-f", "-encodedcommand", "-ec", "-e"]
            return rest.contains(where: given.contains) ? .other : .powerShell
        }
        return .other
    }

    /// PowerShell's -EncodedCommand: the script in UTF-16LE, base64.
    static func encoded(_ script: String) -> String {
        var bytes: [UInt8] = []
        for unit in script.utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        return Data(bytes).base64EncodedString()
    }

    // MARK: Reading the folder

    /// The folder from an OSC 9 payload ("9;\"C:\\path\"" or "9;C:\\path"); other OSC 9 uses (notifications,
    /// progress) give nil.
    static func folder(osc9 payload: String) -> String? {
        guard payload.hasPrefix("9;") else { return nil }
        var path = String(payload.dropFirst(2))
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
        return path.isEmpty ? nil : path
    }

    /// The folder from an OSC 7 file URL ("file://host/C:/Users/me" or "file://host/home/me").
    static func folder(osc7 payload: String) -> String? {
        // Read by hand: Foundation on Windows turns a file URL's path into a Windows path of its own.
        guard payload.lowercased().hasPrefix("file://") else { return payload.isEmpty ? nil : payload }
        let rest = payload.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
        // A Windows drive path comes as "/C:/Users/me".
        if path.count >= 3, path.hasPrefix("/"), Array(path)[2] == ":" {
            return String(path.dropFirst()).replacingOccurrences(of: "/", with: "\\")
        }
        return path.isEmpty ? nil : path
    }

    /// The folder as the title shows it: the home folder and what's inside it start with "~", as on the Mac.
    static func display(_ path: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("\\") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else { return path }
        if path.caseInsensitiveCompare(trimmedHome) == .orderedSame { return "~" }
        let prefix = trimmedHome + "\\"
        if path.lowercased().hasPrefix(prefix.lowercased()) { return "~\\" + path.dropFirst(prefix.count) }
        return path
    }

    // MARK: The program in the foreground

    /// Helpers the console starts beside the shell, which aren't programs the user ran.
    private static let helpers: Set<String> = ["conhost.exe", "openconsole.exe"]

    /// The shell's newest child process, if any.
    static func foregroundChild(of shell: DWORD) -> DWORD? {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var newest: (pid: DWORD, created: UInt64)?
        guard Process32FirstW(snapshot, &entry) else { return nil }
        repeat {
            if entry.th32ParentProcessID == shell, entry.th32ProcessID != shell {
                let name = withUnsafeBytes(of: entry.szExeFile) { raw in
                    String(decoding: raw.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
                }
                if !helpers.contains(name.lowercased()) {
                    let created = creationTime(entry.th32ProcessID)
                    if newest == nil || created >= newest!.created { newest = (entry.th32ProcessID, created) }
                }
            }
        } while Process32NextW(snapshot, &entry)
        return newest?.pid
    }

    private static func creationTime(_ pid: DWORD) -> UInt64 {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return 0 }
        defer { CloseHandle(process) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &created, &exited, &kernel, &user) else { return 0 }
        return UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
    }

    private typealias QueryInformation = @convention(c) (HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG
    private static let queryInformation: QueryInformation? = {
        guard let ntdll = GetModuleHandleW("ntdll.dll".wide),
              let address = GetProcAddress(ntdll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(address, to: QueryInformation.self)
    }()

    /// A process's command line (Windows 8.1 and later let any process read it with limited query rights).
    static func commandLine(of pid: DWORD) -> String? {
        guard let queryInformation, let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(process) }
        let processCommandLineInformation: Int32 = 60
        var needed: ULONG = 0
        _ = queryInformation(process, processCommandLineInformation, nil, 0, &needed)
        guard needed > 0, needed < 1 << 20 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 16)
        defer { buffer.deallocate() }
        guard queryInformation(process, processCommandLineInformation, buffer, needed, &needed) >= 0 else { return nil }
        // A UNICODE_STRING: its length in bytes, then a pointer to the text (inside the same buffer).
        let length = Int(buffer.load(as: UInt16.self))
        let offset = MemoryLayout<UnsafeRawPointer>.alignment
        guard let text = buffer.load(fromByteOffset: offset, as: UnsafePointer<UInt16>?.self) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: text, count: length / 2), as: UTF16.self)
    }

    /// What the title shows for a command line: the program's name without its folder or ".exe", then its
    /// arguments, with passwords and tokens hidden.
    static func titleText(commandLine: String) -> String {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        let tokens = arguments(trimmed)
        guard let first = tokens.first else { return "" }
        // The arguments as written, after the program (which may be quoted).
        var rest = Substring(trimmed)
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            rest = rest.firstIndex(of: "\"").map { rest[rest.index(after: $0)...] } ?? ""
        } else {
            rest = rest.firstIndex(of: " ").map { rest[$0...] } ?? ""
        }
        let arguments = rest.trimmingCharacters(in: .whitespaces)
        let name = programName(first)
        return redactCredentials(arguments.isEmpty ? name : name + " " + arguments)
    }

    /// "C:\Windows\system32\PING.EXE" → "PING"; "ping" → "ping".
    static func programName(_ path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
        return name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// A command line split the simple way: spaces separate, double quotes group.
    static func arguments(_ commandLine: String) -> [String] {
        var result: [String] = [], current = "", quoted = false, started = false
        for character in commandLine {
            if character == "\"" { quoted.toggle(); started = true; continue }
            if character == " " && !quoted {
                if started { result.append(current); current = ""; started = false }
                continue
            }
            current.append(character)
            started = true
        }
        if started { result.append(current) }
        return result
    }
}
