import AppKit
import SwiftTerm

struct InvalidTheme: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

final class TerminalTheme {
    let colors: [String: NSColor]
    let palette: [SwiftTerm.Color]

    init(data: Data) throws {
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
    @Published var selection: String { didSet { defaults.set(selection, forKey: "terminalTheme") } }
    var current: TerminalTheme? { presets[selection] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: "terminalPresets") as? [String: Data] ?? [:]
        let loaded = saved.compactMapValues { try? TerminalTheme(data: $0) }
        presets = loaded
        let name = defaults.string(forKey: "terminalTheme") ?? ""
        selection = loaded[name] == nil ? "" : name
    }

    func importFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let theme = try TerminalTheme(data: data)
        let name = url.deletingPathExtension().lastPathComponent
        var saved = defaults.dictionary(forKey: "terminalPresets") as? [String: Data] ?? [:]
        saved[name] = data
        defaults.set(saved, forKey: "terminalPresets")
        presets[name] = theme
        selection = name
    }
}
