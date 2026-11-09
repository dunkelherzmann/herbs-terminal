import AppKit
import Testing
@testable import HerbsTerminal

@Test @MainActor
func importedThemeCanBeRestoredAndReset() throws {
    let id = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: id))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".itermcolors")
    defer {
        defaults.removePersistentDomain(forName: id)
        try? FileManager.default.removeItem(at: url)
    }
    let rgb: [String: Any] = ["Color Space": "sRGB", "Red Component": 0.25,
                              "Green Component": 0.5, "Blue Component": 0.75]
    let fields = ["Background Color": rgb, "Ansi 3 Color": rgb, "Cursor Text Color": rgb]
    try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(to: url)
    let library = ThemeLibrary(defaults: defaults)
    let name = try library.importFile(url)
    let restored = ThemeLibrary(defaults: defaults)
    let theme = try #require(restored.theme(named: name))
    #expect(name == id)
    #expect(theme.palette.count == 16)
    #expect(theme.palette[3].green == 32768)
    let shell = LocalShell()
    var settings = ProfileSettings()
    settings.theme = name
    shell.applyColors(dark: true, settings: settings, library: restored)
    #expect(shell.view.nativeBackgroundColor == theme.colors["Background Color"])
    #expect(shell.view.caretTextColor == theme.colors["Cursor Text Color"])
    try Data("broken".utf8).write(to: url)
    #expect(throws: (any Error).self) { try library.importFile(url) }
    #expect(ThemeLibrary(defaults: defaults).theme(named: name) != nil)
    settings.theme = ""
    shell.applyColors(dark: true, settings: settings, library: restored)
    #expect(shell.view.nativeBackgroundColor == .black)
    #expect(shell.view.caretTextColor == nil)
}
