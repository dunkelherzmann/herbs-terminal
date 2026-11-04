import AppKit
import SwiftTerm

enum CursorShape: String, CaseIterable, Identifiable, Codable {
    case block, underline, bar
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// One named profile's look and behavior, like a Terminal or Ptyxis profile. Tabs pick a profile; ⌘+ / ⌘−
/// change its zoom, which is saved, so text keeps its size across sessions.
struct ProfileSettings: Codable, Equatable {
    /// Empty means the stock Terminal Basic face (SF Mono Terminal).
    var fontFamily = ""
    /// The Basic profile's 11 pt; `TerminalTypeface.regular` reads the same from Terminal's own profile.
    var fontSize: Double = 11
    /// Points added by Bigger / Smaller (⌘+ / ⌘−); Default Font Size (⌘0) sets it back to 0.
    var zoom: Double = 0
    var cursor: CursorShape = .block
    var cursorBlinks = true
    /// A ThemeLibrary preset name; empty means macOS Terminal Basic.
    var theme = ""
    var backgroundOpacity = 1.0
    var blurBackground = false
    /// Off by default, as in Terminal: Option types special characters unless this is on.
    var optionAsMeta = false
    var scrollbackLines = 10_000
    var bell: TerminalBell = .audible
    /// Typed into the shell when a tab with this profile starts; empty for none.
    var startupCommand = ""
    /// Where new tabs with this profile start; empty follows Settings ▸ Terminal ▸ New tabs open in.
    var startDirectory = ""

    static let sizeRange: ClosedRange<Double> = 6...72

    var effectiveSize: Double { min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize + zoom)) }

    @MainActor var font: NSFont {
        let size = CGFloat(effectiveSize)
        if !fontFamily.isEmpty,
           let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFontManager.shared.convert(TerminalTypeface.regular, toSize: size)
    }

    var cursorStyle: CursorStyle {
        switch (cursor, cursorBlinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    var isTranslucent: Bool { backgroundOpacity < 1 || blurBackground }

    /// Keeps every value in range; applied on each change.
    func normalized() -> ProfileSettings {
        var copy = self
        copy.fontSize = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize))
        copy.zoom = min(Self.sizeRange.upperBound - copy.fontSize, max(Self.sizeRange.lowerBound - copy.fontSize, zoom))
        copy.scrollbackLines = min(1_000_000, max(100, scrollbackLines))
        copy.backgroundOpacity = min(1, max(0.2, backgroundOpacity))
        return copy
    }

    /// Main Menu ▸ Terminal Theme ▸ Restore Defaults: font, size, zoom, cursor, colors and transparency.
    mutating func restoreTheming() {
        let stock = ProfileSettings()
        fontFamily = stock.fontFamily
        fontSize = stock.fontSize
        zoom = stock.zoom
        cursor = stock.cursor
        cursorBlinks = stock.cursorBlinks
        theme = stock.theme
        backgroundOpacity = stock.backgroundOpacity
        blurBackground = stock.blurBackground
    }
}

struct NamedProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings = ProfileSettings()
}

/// Named profiles plus the app-wide preferences. Settings edits the selected profile; the accessors such as
/// `fontSize` read and write that profile.
@MainActor
final class TerminalProfile: ObservableObject {
    static let shared = TerminalProfile()
    static let sizeRange = ProfileSettings.sizeRange
    static let defaultWindow = CGSize(width: 960, height: 580)

    private let defaults: UserDefaults
    @Published private(set) var profiles: [NamedProfile]
    @Published var defaultProfileID: UUID { didSet { defaults.set(defaultProfileID.uuidString, forKey: "defaultProfileID") } }
    /// The profile Settings is editing; not saved.
    @Published var editingID: UUID

    /// Ask before closing a tab whose shell is running another program or a remote session.
    @Published var askBeforeClosing: Bool { didSet { defaults.set(askBeforeClosing, forKey: "terminalAskBeforeClosing") } }
    /// New tabs start in the current tab's folder (Terminal's "Same working directory") or in home.
    @Published var newTabsInSameFolder: Bool { didSet { defaults.set(newTabsInSameFolder, forKey: "terminalNewTabSameFolder") } }
    /// Reopen windows and tabs, with their folders and layouts, at launch.
    @Published var restoreSession: Bool { didSet { defaults.set(restoreSession, forKey: "restoreSession") } }
    /// Show the terminal's columns × rows while the window is resized.
    @Published var showSizeWhileResizing: Bool { didSet { defaults.set(showSizeWhileResizing, forKey: "showSizeWhileResizing") } }
    @Published var windowWidth: Double { didSet { defaults.set(windowWidth, forKey: "windowWidth") } }
    @Published var windowHeight: Double { didSet { defaults.set(windowHeight, forKey: "windowHeight") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = defaults.data(forKey: "terminalProfiles").flatMap { try? JSONDecoder().decode([NamedProfile].self, from: $0) } ?? []
        if loaded.isEmpty { loaded = [NamedProfile(name: "Basic", settings: Self.legacySettings(defaults))] }
        profiles = loaded
        let savedDefault = defaults.string(forKey: "defaultProfileID").flatMap(UUID.init(uuidString:))
        let defaultID = loaded.contains { $0.id == savedDefault } ? savedDefault! : loaded[0].id
        defaultProfileID = defaultID
        editingID = defaultID
        askBeforeClosing = defaults.object(forKey: "terminalAskBeforeClosing") as? Bool ?? true
        newTabsInSameFolder = defaults.object(forKey: "terminalNewTabSameFolder") as? Bool ?? true
        restoreSession = defaults.object(forKey: "restoreSession") as? Bool ?? true
        showSizeWhileResizing = defaults.object(forKey: "showSizeWhileResizing") as? Bool ?? true
        windowWidth = defaults.object(forKey: "windowWidth") as? Double ?? Self.defaultWindow.width
        windowHeight = defaults.object(forKey: "windowHeight") as? Double ?? Self.defaultWindow.height
        save()
    }

    /// Settings from before named profiles existed become the first profile.
    private static func legacySettings(_ defaults: UserDefaults) -> ProfileSettings {
        var settings = ProfileSettings()
        settings.fontFamily = defaults.string(forKey: "terminalFontFamily") ?? settings.fontFamily
        settings.fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? settings.fontSize
        settings.cursor = defaults.string(forKey: "terminalCursor").flatMap(CursorShape.init(rawValue:)) ?? settings.cursor
        settings.cursorBlinks = defaults.object(forKey: "terminalCursorBlinks") as? Bool ?? settings.cursorBlinks
        settings.optionAsMeta = defaults.object(forKey: "terminalOptionAsMeta") as? Bool ?? settings.optionAsMeta
        settings.scrollbackLines = defaults.object(forKey: "terminalScrollback") as? Int ?? settings.scrollbackLines
        settings.bell = defaults.string(forKey: "terminalBell").flatMap(TerminalBell.init(rawValue:)) ?? settings.bell
        settings.backgroundOpacity = defaults.object(forKey: "terminalBackgroundOpacity") as? Double ?? settings.backgroundOpacity
        settings.blurBackground = defaults.object(forKey: "terminalBlurBackground") as? Bool ?? settings.blurBackground
        settings.theme = defaults.string(forKey: "terminalTheme") ?? settings.theme
        return settings.normalized()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "terminalProfiles") }
        defaults.set(defaultProfileID.uuidString, forKey: "defaultProfileID")
    }

    // MARK: Profiles

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

    // MARK: The profile Settings edits

    var editing: ProfileSettings {
        get { settings(for: editingID) }
        set { update(editingID) { $0 = newValue } }
    }

    var fontFamily: String { get { editing.fontFamily } set { editing.fontFamily = newValue } }
    var fontSize: Double { get { editing.fontSize } set { editing.fontSize = newValue } }
    var zoom: Double { get { editing.zoom } set { editing.zoom = newValue } }
    var cursor: CursorShape { get { editing.cursor } set { editing.cursor = newValue } }
    var cursorBlinks: Bool { get { editing.cursorBlinks } set { editing.cursorBlinks = newValue } }
    var theme: String { get { editing.theme } set { editing.theme = newValue } }
    var optionAsMeta: Bool { get { editing.optionAsMeta } set { editing.optionAsMeta = newValue } }
    var scrollbackLines: Int { get { editing.scrollbackLines } set { editing.scrollbackLines = newValue } }
    var bell: TerminalBell { get { editing.bell } set { editing.bell = newValue } }
    var backgroundOpacity: Double { get { editing.backgroundOpacity } set { editing.backgroundOpacity = newValue } }
    var blurBackground: Bool { get { editing.blurBackground } set { editing.blurBackground = newValue } }
    var startupCommand: String { get { editing.startupCommand } set { editing.startupCommand = newValue } }
    var startDirectory: String { get { editing.startDirectory } set { editing.startDirectory = newValue } }
    var font: NSFont { editing.font }
    var cursorStyle: CursorStyle { editing.cursorStyle }
    var isTranslucent: Bool { editing.isTranslucent }

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

    /// Fixed-pitch families installed on this Mac, for the font picker.
    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
    }
}

extension ProfileSettings {
    /// A see-through terminal needs a non-opaque window; an opaque one keeps the cheaper default.
    func applyTransparency(to window: NSWindow) {
        window.isOpaque = !isTranslucent
        window.backgroundColor = isTranslucent ? .clear : .windowBackgroundColor
    }
}
