import AppKit
import SwiftTerm

struct InvalidTheme: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

final class TerminalTheme {
    let colors: [String: NSColor]
    let palette: [SwiftTerm.Color]

    convenience init(data: Data) throws {
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InvalidTheme(reason: "Expected an iTerm2 color preset.")
        }
        let ansi = (0..<16).map { "Ansi \($0) Color" }
        var colors: [String: NSColor] = [:]
        for key in ansi + ["Foreground Color", "Background Color", "Cursor Color", "Cursor Text Color", "Selection Color", "Selected Text Color"] {
            guard let field = fields[key] else { continue }
            guard let entry = field as? [String: Any],
                  let r = entry["Red Component"] as? Double, let g = entry["Green Component"] as? Double,
                  let b = entry["Blue Component"] as? Double else {
                throw InvalidTheme(reason: "Invalid RGB components in \(key).")
            }
            let alpha = entry["Alpha Component"] as? Double ?? 1
            guard [r, g, b, alpha].allSatisfy({ (0...1).contains($0) }) else {
                throw InvalidTheme(reason: "Color components in \(key) must be between 0 and 1.")
            }
            switch entry["Color Space"] as? String {
            case "sRGB": colors[key] = NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            case "P3", "Display P3": colors[key] = NSColor(displayP3Red: r, green: g, blue: b, alpha: alpha)
            default: colors[key] = NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
            }
        }
        guard !colors.isEmpty else { throw InvalidTheme(reason: "The file contains no supported terminal colors.") }
        self.init(colors: colors)
    }

    init(colors: [String: NSColor]) {
        let ansi = (0..<16).map { "Ansi \($0) Color" }
        self.colors = colors
        palette = ansi.enumerated().map { index, key in
            guard let c = colors[key]?.usingColorSpace(.sRGB) else { return SwiftTerm.Color.terminalAppColors[index] }
            func channel(_ value: CGFloat) -> UInt16 { UInt16((max(0, min(1, value)) * 65535).rounded()) }
            return SwiftTerm.Color(red: channel(c.redComponent), green: channel(c.greenComponent), blue: channel(c.blueComponent))
        }
    }
}

@MainActor
final class ThemeLibrary: ObservableObject {
    static let shared = ThemeLibrary()
    private let defaults: UserDefaults
    @Published private(set) var presets: [String: TerminalTheme]
    // Which theme a tab shows is part of its profile (ProfileSettings.theme); this holds the presets.

    func theme(named name: String) -> TerminalTheme? { presets[name] ?? Self.builtIn[name] }

    /// Classic palettes shipped with the app; imported presets with the same name take precedence.
    static let builtIn: [String: TerminalTheme] = {
        func theme(_ fg: String, _ bg: String, _ cursor: String, _ selection: String, _ ansi: String) -> TerminalTheme {
            func color(_ hex: Substring) -> NSColor {
                let v = Int(hex, radix: 16) ?? 0
                return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                               blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            }
            var colors: [String: NSColor] = [
                "Foreground Color": color(Substring(fg)), "Background Color": color(Substring(bg)),
                "Cursor Color": color(Substring(cursor)), "Cursor Text Color": color(Substring(bg)),
                "Selection Color": color(Substring(selection)), "Selected Text Color": color(Substring(fg)),
            ]
            for (index, hex) in ansi.split(separator: " ").enumerated() { colors["Ansi \(index) Color"] = color(hex) }
            return TerminalTheme(colors: colors)
        }
        let solarized = "073642 dc322f 859900 b58900 268bd2 d33682 2aa198 eee8d5 002b36 cb4b16 586e75 657b83 839496 6c71c4 93a1a1 fdf6e3"
        let tango = "2e3436 cc0000 4e9a06 c4a000 3465a4 75507b 06989a d3d7cf 555753 ef2929 8ae234 fce94f 729fcf ad7fa8 34e2e2 eeeeec"
        return [
            "Solarized Dark": theme("839496", "002b36", "93a1a1", "073642", solarized),
            "Solarized Light": theme("657b83", "fdf6e3", "586e75", "eee8d5", solarized),
            "Tango Dark": theme("d3d7cf", "2e3436", "d3d7cf", "555753", tango),
            "Tango Light": theme("2e3436", "eeeeec", "2e3436", "d3d7cf", tango),
            "Gruvbox Dark": theme("ebdbb2", "282828", "ebdbb2", "504945",
                                  "282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2"),
            "Nord": theme("d8dee9", "2e3440", "d8dee9", "434c5e",
                          "3b4252 bf616a a3be8c ebcb8b 81a1c1 b48ead 88c0d0 e5e9f0 4c566a bf616a a3be8c ebcb8b 81a1c1 b48ead 8fbcbb eceff4"),
        ]
    }()

    var allNames: [String] { Set(presets.keys).union(Self.builtIn.keys).sorted() }
    func isImported(_ name: String) -> Bool { presets[name] != nil }

    func removeImported(_ name: String) {
        var saved = defaults.dictionary(forKey: "terminalPresets") as? [String: Data] ?? [:]
        saved[name] = nil
        defaults.set(saved, forKey: "terminalPresets")
        presets[name] = nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: "terminalPresets") as? [String: Data] ?? [:]
        let loaded = saved.compactMapValues { try? TerminalTheme(data: $0) }
        presets = loaded
    }

    /// Adds an .itermcolors preset and returns its name, for the caller to assign to a profile.
    @discardableResult
    func importFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        _ = try TerminalTheme(data: data)
        let name = url.deletingPathExtension().lastPathComponent
        var saved = defaults.dictionary(forKey: "terminalPresets") as? [String: Data] ?? [:]
        saved[name] = data
        defaults.set(saved, forKey: "terminalPresets")
        presets[name] = try TerminalTheme(data: data)
        return name
    }
}
