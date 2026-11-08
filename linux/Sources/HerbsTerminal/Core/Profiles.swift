import Foundation

/// Where the app keeps its own files, for every store that needs one.
enum AppFolders {
    /// Set once at start-up, before any store opens, to keep every file in one private folder (the Windows
    /// parity scene uses it; Linux points its XDG folders there instead).
    nonisolated(unsafe) static var privateBase: URL?

    static var supportBase: URL {
        privateBase ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func support(_ base: URL = supportBase) -> URL {
        base.appendingPathComponent("HerbsTerminal", isDirectory: true)
    }

    static func loginDatabase(_ base: URL = supportBase) -> URL {
        support(base).appendingPathComponent("logins.sqlite3")
    }

    static var cache: URL {
        let base = privateBase?.appendingPathComponent("cache", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HerbsTerminal", isDirectory: true)
    }
}

/// The app's preferences as one JSON file. A file that can't be read is set aside, never overwritten.
final class Preferences: @unchecked Sendable {
    static let shared = Preferences()
    private var values: [String: Any] = [:]
    private let file: URL

    init(file: URL = AppFolders.support().appendingPathComponent("settings.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            if let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                values = decoded
            } else {
                try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            }
        }
    }

    func bool(_ key: String) -> Bool? { values[key] as? Bool }
    func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { values[key] as? String }
    func data(_ key: String) -> Data? { (values[key] as? String).flatMap { Data(base64Encoded: $0) } }

    func set(_ value: Any?, _ key: String) {
        if let data = value as? Data { values[key] = data.base64EncodedString() } else { values[key] = value }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

enum CursorShape: String, CaseIterable, Codable {
    case block, underline, bar
    var title: String { rawValue.capitalized }
}

enum TerminalBell: String, CaseIterable, Codable {
    case audible, visual, both, none
    var title: String {
        switch self {
        case .audible: "Audible"
        case .visual: "Visual (flash)"
        case .both: "Audible and visual"
        case .none: "Off"
        }
    }
}

/// One named profile's look and behavior, like a Terminal or Ptyxis profile. Tabs pick a profile; Bigger / Smaller
/// change its zoom, which is saved, so text keeps its size across sessions.
struct ProfileSettings: Codable, Equatable {
    /// Empty means the stock face, the monospaced font that matches the macOS Terminal Basic look.
    var fontFamily = ""
    var fontSize: Double = 13
    /// Points added by Bigger / Smaller; Default sets it back to 0.
    var zoom: Double = 0
    var cursor: CursorShape = .block
    var cursorBlinks = true
    /// A ThemeLibrary preset name; empty means Basic.
    var theme = ""
    var backgroundOpacity = 1.0
    var scrollbackLines = 10_000
    var bell: TerminalBell = .audible
    /// Typed into the shell when a tab with this profile starts; empty for none.
    var startupCommand = ""
    /// Where new tabs with this profile start; empty follows Settings ▸ Terminal ▸ New tabs open in.
    var startDirectory = ""

    static let sizeRange: ClosedRange<Double> = 6...72
    static let stockFamily = "Adwaita Mono"

    var effectiveSize: Double { min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize + zoom)) }
    var family: String { fontFamily.isEmpty ? Self.stockFamily : fontFamily }
    /// A Pango font description such as "Adwaita Mono 13".
    var fontDescription: String { "\(family) \(effectiveSize.formatted())" }

    func normalized() -> ProfileSettings {
        var copy = self
        copy.fontSize = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize))
        copy.zoom = min(Self.sizeRange.upperBound - copy.fontSize, max(Self.sizeRange.lowerBound - copy.fontSize, zoom))
        copy.scrollbackLines = min(1_000_000, max(100, scrollbackLines))
        copy.backgroundOpacity = min(1, max(0.2, backgroundOpacity))
        return copy
    }

    /// Main Menu ▸ Appearance ▸ Restore Defaults: font, size, zoom, cursor, colors and transparency.
    mutating func restoreTheming() {
        let stock = ProfileSettings()
        fontFamily = stock.fontFamily
        fontSize = stock.fontSize
        zoom = stock.zoom
        cursor = stock.cursor
        cursorBlinks = stock.cursorBlinks
        theme = stock.theme
        backgroundOpacity = stock.backgroundOpacity
    }
}

extension Double {
    func formatted() -> String { self == rounded() ? String(Int(self)) : String(format: "%.1f", self) }
}

struct NamedProfile: Codable, Equatable {
    var id = UUID()
    var name: String
    var settings = ProfileSettings()
}

/// Named profiles plus the app-wide preferences. Settings edits the selected profile.
@MainActor
final class TerminalProfile: ObservableObject {
    static let shared = TerminalProfile()
    static let defaultGrid = (columns: 100, rows: 30)
    static let gridRange = (columns: 20...1000, rows: 5...500)

    private let store: Preferences
    @Published private(set) var profiles: [NamedProfile]
    @Published var defaultProfileID: UUID { didSet { store.set(defaultProfileID.uuidString, "defaultProfileID") } }
    /// The profile Settings is editing; not saved.
    @Published var editingID: UUID

    @Published var askBeforeClosing: Bool { didSet { store.set(askBeforeClosing, "terminalAskBeforeClosing") } }
    @Published var newTabsInSameFolder: Bool { didSet { store.set(newTabsInSameFolder, "terminalNewTabSameFolder") } }
    @Published var restoreSession: Bool { didSet { store.set(restoreSession, "restoreSession") } }
    @Published var showSizeWhileResizing: Bool { didSet { store.set(showSizeWhileResizing, "showSizeWhileResizing") } }
    @Published var windowColumns: Int { didSet { store.set(windowColumns, "windowColumns") } }
    @Published var windowRows: Int { didSet { store.set(windowRows, "windowRows") } }
    /// System, Light or Dark.
    @Published var appearance: String { didSet { store.set(appearance, "appearance") } }

    init(store: Preferences = .shared) {
        self.store = store
        let stored = store.data("terminalProfiles")
        var loaded = stored.flatMap { try? JSONDecoder().decode([NamedProfile].self, from: $0) } ?? []
        if let stored, loaded.isEmpty {
            // Saving below replaces what couldn't be read; keep a copy instead of losing the profiles.
            store.set(stored, "terminalProfiles.unreadable-\(Int(Date().timeIntervalSince1970))")
        }
        if loaded.isEmpty { loaded = [NamedProfile(name: "Basic")] }
        profiles = loaded
        let savedDefault = store.string("defaultProfileID").flatMap(UUID.init(uuidString:))
        let defaultID = loaded.contains { $0.id == savedDefault } ? savedDefault! : loaded[0].id
        defaultProfileID = defaultID
        editingID = defaultID
        askBeforeClosing = store.bool("terminalAskBeforeClosing") ?? true
        newTabsInSameFolder = store.bool("terminalNewTabSameFolder") ?? true
        restoreSession = store.bool("restoreSession") ?? true
        showSizeWhileResizing = store.bool("showSizeWhileResizing") ?? true
        windowColumns = store.int("windowColumns") ?? Self.defaultGrid.columns
        windowRows = store.int("windowRows") ?? Self.defaultGrid.rows
        appearance = store.string("appearance") ?? "System"
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { store.set(data, "terminalProfiles") }
        store.set(defaultProfileID.uuidString, "defaultProfileID")
    }

    var defaultProfile: NamedProfile { profiles.first { $0.id == defaultProfileID } ?? profiles[0] }

    /// A tab's profile; a missing or deleted one falls back to the default.
    func settings(for id: UUID?) -> ProfileSettings {
        (id.flatMap { id in profiles.first { $0.id == id } } ?? defaultProfile).settings
    }

    func name(of id: UUID?) -> String { (id.flatMap { id in profiles.first { $0.id == id } } ?? defaultProfile).name }

    func update(_ id: UUID?, _ change: (inout ProfileSettings) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == (id ?? defaultProfileID) }) else { return }
        var settings = profiles[index].settings
        change(&settings)
        profiles[index].settings = settings.normalized()
        save()
    }

    @discardableResult
    func addProfile(named name: String, copying source: UUID? = nil) -> UUID {
        let base = source.map { settings(for: $0) } ?? ProfileSettings()
        let profile = NamedProfile(name: uniqueName(name), settings: base)
        profiles.append(profile)
        save()
        return profile.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        save()
    }

    /// The last profile can't be removed; tabs using a removed profile fall back to the default.
    func removeProfile(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id { defaultProfileID = profiles[0].id }
        if editingID == id { editingID = defaultProfileID }
        save()
    }

    private func uniqueName(_ name: String) -> String {
        var candidate = name, index = 2
        while profiles.contains(where: { $0.name == candidate }) { candidate = "\(name) \(index)"; index += 1 }
        return candidate
    }

    var editing: ProfileSettings {
        get { settings(for: editingID) }
        set { update(editingID) { $0 = newValue } }
    }

    func resetText() {
        update(editingID) { settings in
            let stock = ProfileSettings()
            settings.fontFamily = stock.fontFamily
            settings.fontSize = stock.fontSize
            settings.zoom = 0
            settings.cursor = stock.cursor
            settings.cursorBlinks = stock.cursorBlinks
        }
    }
}

// MARK: Colors

struct RGB: Equatable, Codable {
    var red, green, blue: Double
    var alpha = 1.0

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var css: String {
        String(format: "rgba(%d,%d,%d,%.3f)", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()), alpha)
    }
}

struct InvalidTheme: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// A color preset: the named colors of an iTerm2 preset, with the 16 ANSI colors.
struct TerminalTheme {
    let colors: [String: RGB]

    var palette: [RGB] { (0..<16).map { colors["Ansi \($0) Color"] ?? TerminalTheme.basicPalette[$0] } }

    init(colors: [String: RGB]) { self.colors = colors }

    /// Reads an .itermcolors file; a damaged file is rejected as a whole.
    init(data: Data) throws {
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InvalidTheme(reason: "Expected an iTerm2 color preset.")
        }
        let ansi = (0..<16).map { "Ansi \($0) Color" }
        var colors: [String: RGB] = [:]
        for key in ansi + ["Foreground Color", "Background Color", "Cursor Color", "Cursor Text Color", "Selection Color", "Selected Text Color"] {
            guard let field = fields[key] else { continue }
            func number(_ name: String) -> Double? { ((field as? [String: Any])?[name] as? NSNumber)?.doubleValue }
            guard let r = number("Red Component"), let g = number("Green Component"), let b = number("Blue Component") else {
                throw InvalidTheme(reason: "Invalid RGB components in \(key).")
            }
            let alpha = number("Alpha Component") ?? 1
            guard [r, g, b, alpha].allSatisfy({ (0...1).contains($0) }) else {
                throw InvalidTheme(reason: "Color components in \(key) must be between 0 and 1.")
            }
            colors[key] = RGB(red: r, green: g, blue: b, alpha: alpha)
        }
        guard !colors.isEmpty else { throw InvalidTheme(reason: "The file contains no supported terminal colors.") }
        self.colors = colors
    }

    /// macOS Terminal's ANSI palette, which the Basic profile uses.
    static let basicPalette: [RGB] = [
        0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
        0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
    ].map { RGB(hex: $0) }

    /// Basic's own colors: black on white, or light text on Terminal's dark background.
    static func basic(dark: Bool) -> [String: RGB] {
        dark ? ["Foreground Color": RGB(hex: 0xDFDFDF), "Background Color": RGB(hex: 0x1E1E1E), "Cursor Color": RGB(hex: 0x8E8E8E),
                "Selection Color": RGB(hex: 0x3F638B), "Selected Text Color": RGB(hex: 0xFFFFFF)]
             : ["Foreground Color": RGB(hex: 0x000000), "Background Color": RGB(hex: 0xFFFFFF), "Cursor Color": RGB(hex: 0x929292),
                "Selection Color": RGB(hex: 0xB3D7FF), "Selected Text Color": RGB(hex: 0x000000)]
    }
}

@MainActor
final class ThemeLibrary: ObservableObject {
    static let shared = ThemeLibrary()
    private let folder: URL
    @Published private(set) var presets: [String: TerminalTheme] = [:]

    func theme(named name: String) -> TerminalTheme? { presets[name] ?? Self.builtIn[name] }

    /// Classic palettes shipped with the app; imported presets with the same name take precedence.
    static let builtIn: [String: TerminalTheme] = {
        func theme(_ fg: UInt32, _ bg: UInt32, _ cursor: UInt32, _ selection: UInt32, _ ansi: [UInt32]) -> TerminalTheme {
            var colors: [String: RGB] = [
                "Foreground Color": RGB(hex: fg), "Background Color": RGB(hex: bg), "Cursor Color": RGB(hex: cursor),
                "Cursor Text Color": RGB(hex: bg), "Selection Color": RGB(hex: selection), "Selected Text Color": RGB(hex: fg),
            ]
            for (index, hex) in ansi.enumerated() { colors["Ansi \(index) Color"] = RGB(hex: hex) }
            return TerminalTheme(colors: colors)
        }
        let solarized: [UInt32] = [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                                   0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]
        let tango: [UInt32] = [0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
                               0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec]
        return [
            "Solarized Dark": theme(0x839496, 0x002b36, 0x93a1a1, 0x073642, solarized),
            "Solarized Light": theme(0x657b83, 0xfdf6e3, 0x586e75, 0xeee8d5, solarized),
            "Tango Dark": theme(0xd3d7cf, 0x2e3436, 0xd3d7cf, 0x555753, tango),
            "Tango Light": theme(0x2e3436, 0xeeeeec, 0x2e3436, 0xd3d7cf, tango),
            "Gruvbox Dark": theme(0xebdbb2, 0x282828, 0xebdbb2, 0x504945,
                                  [0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
                                   0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2]),
            "Nord": theme(0xd8dee9, 0x2e3440, 0xd8dee9, 0x434c5e,
                          [0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                           0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]),
        ]
    }()

    var allNames: [String] { Set(presets.keys).union(Self.builtIn.keys).sorted() }
    func isImported(_ name: String) -> Bool { presets[name] != nil }

    init(folder: URL = AppFolders.support().appendingPathComponent("color-presets", isDirectory: true)) {
        self.folder = folder
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "itermcolors" {
            if let data = try? Data(contentsOf: file), let theme = try? TerminalTheme(data: data) {
                presets[file.deletingPathExtension().lastPathComponent] = theme
            }
        }
    }

    func removeImported(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".itermcolors"))
        presets[name] = nil
    }

    /// Adds an .itermcolors preset and returns its name, for the caller to assign to a profile.
    @discardableResult
    func importFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let theme = try TerminalTheme(data: data)
        let name = url.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name + ".itermcolors"), options: .atomic)
        presets[name] = theme
        return name
    }
}
