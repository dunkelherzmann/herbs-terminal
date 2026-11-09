import CGtk
import CHerb
import Foundation
import Glibc

/// A fixed, private state for comparing this app with the Mac version (`parity/parity.json`). It needs both
/// `--parity-scene <name>` and `HERBS_PARITY=1` (set by `linux/parity/scene.sh`); either alone does nothing.
/// The scene runs as its own non-unique application, keeps every file in a private folder and never touches the
/// user's settings, logins or saved session.
enum ParityScene {
    /// Inside the Flatpak's allowed name prefix, and never the user's running instance.
    static let applicationID = "org.herbsterminal.app.Parity"

    static let name: String? = scene(in: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

    static var isActive: Bool { name != nil }

    /// Where `--parity-capture` saves the window's picture once the scene has settled.
    static let capturePath: String? = isActive ? value(after: "--parity-capture", in: CommandLine.arguments) : nil

    /// The scene's home on the host, where the shell runs.
    static let home = "/tmp/herbs-parity"
    /// The app's own files during a scene (inside the sandbox).
    static let appFiles = "/tmp/herbs-parity-app"

    /// Every platform shows the same title and prompt, whatever the machine is called.
    static let title = "parity@scene"
    static let prompt = "$ "

    static func scene(in arguments: [String], environment: [String: String]) -> String? {
        guard environment["HERBS_PARITY"] == "1" else { return nil }
        return value(after: "--parity-scene", in: arguments)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Points every XDG folder at the scene's private folder. Runs first thing in `main`, before any store is opened.
    static func prepare() {
        guard isActive else { return }
        for (variable, folder) in [("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                                   ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")] {
            let path = appFiles + "/" + folder
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            setenv(variable, path, 1)
        }
    }

    /// A POSIX shell (bash in POSIX mode where there is one, as the Mac's /bin/sh is) with no rc files, a fixed
    /// prompt and the scene's home.
    static var shellEnvironment: [String: String] {
        ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "HerbsTerminal",
         "HOME": home, "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PS1": prompt, "SHELL": "/bin/sh", "ENV": ""]
    }

    /// Controls with an identifier, kept during a scene only. GTK 4.20 doesn't publish the identifier over AT-SPI
    /// (4.22 does), so the scene writes each one's place in the window and the AT-SPI reader matches them by place.
    @MainActor private static var identified: [(widget: UnsafeMutablePointer<GtkWidget>, identifier: String)] = []

    @MainActor static func register(_ widget: UnsafeMutablePointer<GtkWidget>, _ identifier: String) {
        guard isActive else { return }
        g_object_ref(raw(widget))
        identified.append((widget, identifier))
    }

    /// Writes `[{identifier, frame: [x, y, width, height]}]` for every control that is shown.
    @MainActor static func writeIdentifiers(to path: String) {
        var entries: [[String: Any]] = []
        for (widget, identifier) in identified {
            var bounds = [Double](repeating: 0, count: 4)
            if herb_widget_bounds(widget, &bounds) != 0 { entries.append(["identifier": identifier, "frame": bounds]) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            _ = FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Inside a scene the scene's home is shown as `~`, as on the other platforms.
    static func displayPath(_ path: String) -> String? {
        guard isActive else { return nil }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
