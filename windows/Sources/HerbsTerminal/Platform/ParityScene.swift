import Foundation
import WinSDK

/// A fixed, private state for comparing this app with the Mac and Linux versions (`parity/parity.json`). It needs
/// both `--parity-scene <name>` and `HERBS_PARITY=1` (set by `parity/windows-scene.ps1`); either alone does nothing.
/// The scene keeps every file of its own in a temporary folder, so it starts from the default settings and never
/// reads or changes the user's settings, logins or files. Its window opens without taking focus.
enum ParityScene {
    static let name: String? = scene(in: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

    static var isActive: Bool { name != nil }

    /// Every platform shows the same title and prompt, whatever the machine is called.
    static let title = "parity@scene"
    static let prompt = "$ "

    private static let temporary = FileManager.default.temporaryDirectory
    /// Where the scene's shell starts.
    static let home = temporary.appendingPathComponent("herbs-parity", isDirectory: true).path.windowsPath
    /// The app's own files during a scene.
    static let appFiles = temporary.appendingPathComponent("herbs-parity-app", isDirectory: true)

    static func scene(in arguments: [String], environment: [String: String]) -> String? {
        guard environment["HERBS_PARITY"] == "1", let index = arguments.firstIndex(of: "--parity-scene"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Points the app's files at the scene's private folder. Runs first thing, before any store is opened.
    static func prepare() {
        guard isActive else { return }
        for folder in [appFiles, URL(fileURLWithPath: home)] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        AppFolders.privateBase = appFiles
    }

    /// Command Prompt with no AutoRun commands, naming its window like the other versions' scenes.
    static let commandLine = "cmd.exe /d /k title \(title)"

    /// `$$$S` is Command Prompt's way of writing "$ ".
    static let shellEnvironment = ["PROMPT": "$$$S"]
}
