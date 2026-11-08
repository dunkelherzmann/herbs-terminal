import Foundation

/// How a tab's shell wants dropped file paths quoted. On the Mac and Linux every shell is POSIX; on Windows the
/// tab may run PowerShell, Command Prompt, WSL, Git Bash, or ssh to a POSIX host.
enum DropQuoting: Equatable {
    case powerShell, commandPrompt, posix, wsl

    /// Picks the quoting from the executable a local tab started.
    init(commandLine: String) {
        let first = commandLine.hasPrefix("\"")
            ? String(commandLine.dropFirst().prefix { $0 != "\"" })
            : String(commandLine.prefix { $0 != " " })
        let name = ((first as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        switch name {
        case "cmd": self = .commandPrompt
        case "wsl", "ubuntu", "debian", "kali": self = .wsl
        case "bash", "sh", "zsh", "fish", "ssh": self = .posix
        default: self = .powerShell // PowerShell 7 and Windows PowerShell, the default shells.
        }
    }

    /// The paths as the shell should receive them: quoted where needed, separated and followed by a space.
    func typed(_ paths: [String]) -> String {
        paths.map(quote).joined(separator: " ") + " "
    }

    func quote(_ path: String) -> String {
        switch self {
        case .powerShell:
            // Single quotes are literal in PowerShell; a quote inside is doubled.
            if Self.isPlain(path, extra: "\\:") { return path }
            return "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
        case .commandPrompt:
            // Windows names can't contain a double quote, so wrapping in them is always safe.
            if Self.isPlain(path, extra: "\\:") { return path }
            return "\"" + path + "\""
        case .posix:
            return Self.posixQuote(path)
        case .wsl:
            return Self.posixQuote(Self.wslPath(path))
        }
    }

    /// C:\Users\herb → /mnt/c/Users/herb, as WSL mounts Windows drives.
    static func wslPath(_ path: String) -> String {
        let characters = Array(path)
        guard characters.count >= 2, characters[1] == ":", characters[0].isLetter else {
            return path.replacingOccurrences(of: "\\", with: "/")
        }
        let rest = String(characters.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        return "/mnt/" + String(characters[0]).lowercased() + (rest.isEmpty ? "/" : rest)
    }

    /// The Mac's `shellQuote`: plain words stay as they are, anything else goes in single quotes.
    static func posixQuote(_ word: String) -> String {
        if isPlain(word, extra: "") { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isPlain(_ word: String, extra: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%,+".contains($0) || extra.contains($0) }
    }
}
