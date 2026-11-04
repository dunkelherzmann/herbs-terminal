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
    try library.importFile(url)
    let restored = ThemeLibrary(defaults: defaults)
    let theme = try #require(restored.current)
    #expect(restored.selection == id)
    #expect(theme.palette.count == 16)
    #expect(theme.palette[3].green == 32768)
    let shell = LocalShell()
    shell.applyColors(dark: true, theme: theme)
    #expect(shell.view.nativeBackgroundColor == theme.colors["Background Color"])
    #expect(shell.view.caretTextColor == theme.colors["Cursor Text Color"])
    try Data("broken".utf8).write(to: url)
    #expect(throws: (any Error).self) { try library.importFile(url) }
    #expect(ThemeLibrary(defaults: defaults).current != nil)
    restored.selection = ""
    shell.applyColors(dark: true, theme: restored.current)
    #expect(shell.view.nativeBackgroundColor == .black)
    #expect(shell.view.caretTextColor == nil)
    #expect(ThemeLibrary(defaults: defaults).current == nil)
}
