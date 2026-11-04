import SwiftUI
import UniformTypeIdentifiers

struct ThemeMenu: View {
    @ObservedObject private var library = ThemeLibrary.shared

    var body: some View {
        Menu("Terminal Theme") {
            Picker("Color preset", selection: $library.selection) {
                Text("macOS Terminal Basic").tag("")
                ForEach(library.presets.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.inline)
            Divider()
            Button("Import iTerm2 Color Preset…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "itermcolors") ?? .propertyList]
                panel.prompt = "Import"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try library.importFile(url) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }
}
