import SwiftUI
import UniformTypeIdentifiers

/// Main Menu ▸ Appearance: the window's color scheme, then the current tab's profile color preset.
struct ThemeMenu: View {
    @ObservedObject private var library = ThemeLibrary.shared
    @ObservedObject private var profiles = TerminalProfile.shared
    @AppStorage("appearance") private var appearance = "System"
    let profileID: UUID?

    var body: some View {
        Menu("Appearance") {
            Picker("Color scheme", selection: $appearance) {
                ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
            }.pickerStyle(.inline)
            Divider()
            Picker("Color preset", selection: Binding(get: { profiles.settings(for: profileID).theme },
                                                      set: { name in profiles.update(profileID) { $0.theme = name } })) {
                Text("macOS Terminal Basic").tag("")
                ForEach(library.allNames, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.inline)
            Divider()
            Button("Import iTerm2 Color Preset…") {
                if let name = ThemeMenu.importPreset() { profiles.update(profileID) { $0.theme = name } }
            }
            .help("Add colors from an .itermcolors file and use them in this profile.")
            Button("Restore Defaults") { restoreDefaults() }
                .help("Go back to Terminal Basic: font, size, zoom, cursor, colors, transparency and appearance.")
        }
    }

    /// Restores the theming of this tab's profile, its ⌘+ / ⌘− zoom included, and the app appearance.
    private func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore theming defaults for “\(profiles.name(of: profileID))”?"
        alert.informativeText = "Font, size and zoom, cursor, color theme, transparency and appearance go back to the stock Terminal Basic look. Imported presets are kept."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profiles.update(profileID) { $0.restoreTheming() }
        appearance = "System"
    }

    @MainActor
    @discardableResult
    static func importPreset() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "itermcolors") ?? .propertyList]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try ThemeLibrary.shared.importFile(url) }
        catch { NSAlert(error: error).runModal(); return nil }
    }
}
