import Foundation

/// A fixed, private state for comparing this app with its Linux and Windows versions (`parity/parity.json`).
/// It only works in a parity copy of the app (bundle identifier `org.herbsterminal.parity`, made by
/// `macos/parity/copy.sh`), so it has its own settings domain and never touches the user's profiles, logins or
/// saved session. Launch it with `--parity-scene <name>`.
enum ParityScene {
    static let bundleIdentifier = "org.herbsterminal.parity"

    static let name: String? = scene(in: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)

    static var isActive: Bool { name != nil }

    /// The scene's home: a temporary folder for the shell and every file store.
    static let home: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("herbs-parity", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }()

    /// Inside a scene the scene's home is shown as `~`, as on the other platforms.
    static func displayPath(_ path: String) -> String {
        guard isActive else { return path }
        // The kernel reports /private/var/…; Foundation shortens the same folder to /var/….
        func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        let path = plain(path), home = plain(home.path)
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Every platform shows the same title and prompt, whatever the machine is called.
    static let title = "parity@scene"
    static let prompt = "$ "

    static func scene(in arguments: [String], bundleIdentifier: String?) -> String? {
        guard bundleIdentifier == Self.bundleIdentifier,
              let index = arguments.firstIndex(of: "--parity-scene"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `/bin/sh` with no rc files, a fixed prompt and the scene's home.
    static func shellEnvironment() -> [String: String] {
        ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "HerbsTerminal",
         "HOME": home.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PS1": prompt, "SHELL": "/bin/sh"]
    }
}
