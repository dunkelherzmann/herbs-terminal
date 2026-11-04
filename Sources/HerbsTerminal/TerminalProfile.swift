import AppKit
import SwiftTerm

enum CursorShape: String, CaseIterable, Identifiable {
    case block, underline, bar
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The terminal profile edited in Settings, like a Ptyxis or iTerm2 profile. Every tab follows it.
@MainActor
final class TerminalProfile: ObservableObject {
    static let shared = TerminalProfile()
    static let sizeRange: ClosedRange<Double> = 6...72
    static let defaultWindow = CGSize(width: 960, height: 580)

    private let defaults: UserDefaults
    /// Empty means the stock Terminal Basic face (SF Mono Terminal).
    @Published var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "terminalFontFamily") } }
    @Published var fontSize: Double {
        didSet {
            let clamped = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize))
            if clamped != fontSize { fontSize = clamped; return }
            defaults.set(fontSize, forKey: "terminalFontSize")
        }
    }
    @Published var cursor: CursorShape { didSet { defaults.set(cursor.rawValue, forKey: "terminalCursor") } }
    @Published var cursorBlinks: Bool { didSet { defaults.set(cursorBlinks, forKey: "terminalCursorBlinks") } }
    @Published var windowWidth: Double { didSet { defaults.set(windowWidth, forKey: "windowWidth") } }
    @Published var windowHeight: Double { didSet { defaults.set(windowHeight, forKey: "windowHeight") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontFamily = defaults.string(forKey: "terminalFontFamily") ?? ""
        fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? Double(TerminalTypeface.regular.pointSize)
        cursor = defaults.string(forKey: "terminalCursor").flatMap(CursorShape.init(rawValue:)) ?? .block
        cursorBlinks = defaults.object(forKey: "terminalCursorBlinks") as? Bool ?? true
        windowWidth = defaults.object(forKey: "windowWidth") as? Double ?? Self.defaultWindow.width
        windowHeight = defaults.object(forKey: "windowHeight") as? Double ?? Self.defaultWindow.height
    }

    var font: NSFont {
        let size = CGFloat(fontSize)
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

    /// Changes whenever something a terminal view draws with changes.
    var signature: String { "\(fontFamily)|\(fontSize)|\(cursor.rawValue)|\(cursorBlinks)" }

    func resetText() {
        fontFamily = ""
        fontSize = Double(TerminalTypeface.regular.pointSize)
        cursor = .block
        cursorBlinks = true
    }

    /// Fixed-pitch families installed on this Mac, for the font picker.
    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
    }
}
