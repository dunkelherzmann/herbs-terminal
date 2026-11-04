import AppKit
import CoreText

@MainActor
enum TerminalTypeface {
    static let basic: [String: Any] = {
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        guard let resources = Bundle(url: app)?.resourceURL else { return [:] }
        let fonts = resources.appendingPathComponent("Fonts")
        for url in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where ["ttf", "otf"].contains(url.pathExtension) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let profile = resources.appendingPathComponent("Initial Settings/Basic.terminal")
        guard let data = try? Data(contentsOf: profile),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return values
    }()

    static let regular: NSFont = {
        if let data = basic["Font"] as? Data,
           let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) {
            return font
        }
        return .monospacedSystemFont(ofSize: 11, weight: .regular)
    }()

    static func background(dark: Bool) -> NSColor {
        color("BackgroundColor", fallback: dark ? .black : .white)
    }

    static func color(_ key: String, fallback: NSColor) -> NSColor {
        guard let data = basic[key] as? Data,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return fallback }
        return color
    }
}
