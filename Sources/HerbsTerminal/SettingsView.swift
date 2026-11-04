import SwiftUI

/// HerbsTerminal ▸ Settings… (⌘,): the profile every terminal tab follows, like Ptyxis or iTerm2 preferences.
struct SettingsView: View {
    var body: some View {
        TabView {
            TextSettings().tabItem { Label("Text", systemImage: "textformat") }
            WindowSettings().tabItem { Label("Window", systemImage: "macwindow") }
            ColorSettings().tabItem { Label("Colors", systemImage: "paintpalette") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct TextSettings: View {
    @ObservedObject private var profile = TerminalProfile.shared
    @ObservedObject private var themes = ThemeLibrary.shared

    var body: some View {
        Form {
            Picker("Font:", selection: $profile.fontFamily) {
                Text("SF Mono Terminal (Basic)").tag("")
                Divider()
                ForEach(TerminalProfile.monospacedFamilies, id: \.self) { Text($0).tag($0) }
            }
            .help("Font\nThe monospaced typeface used by every terminal tab.")
            HStack {
                TextField("Size:", value: $profile.fontSize, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 140)
                Stepper("", value: $profile.fontSize, in: TerminalProfile.sizeRange, step: 1).labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }
            .help("Font size\nPoints, \(Int(TerminalProfile.sizeRange.lowerBound))–\(Int(TerminalProfile.sizeRange.upperBound)). ⌘+ / ⌘− / ⌘0 zoom one tab temporarily.")
            Picker("Cursor:", selection: $profile.cursor) {
                ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Cursor shape\nHow the text cursor is drawn in the terminal.")
            Toggle("Blinking cursor", isOn: $profile.cursorBlinks)
                .help("Blinking cursor\nBlink the cursor while the terminal has focus.")
            preview
            Button("Restore Defaults") { profile.resetText() }
                .help("Restore Defaults\nGo back to the stock Terminal Basic font, size and cursor.")
        }
    }

    private var preview: some View {
        let colors = themes.current?.colors ?? [:]
        let background = colors["Background Color"] ?? TerminalTypeface.background(dark: true)
        let foreground = colors["Foreground Color"] ?? .white
        return Text("user@host ~ % ls -la\nThe quick brown fox — 0O 1lI {}[]")
            .font(Font(profile.font))
            .foregroundStyle(Color(nsColor: foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: background), in: RoundedRectangle(cornerRadius: 6))
            .help("Preview\nHow terminal text looks with this font and color theme.")
    }
}

private struct WindowSettings: View {
    @ObservedObject private var profile = TerminalProfile.shared

    var body: some View {
        Form {
            TextField("Width:", value: $profile.windowWidth, format: .number)
                .help("Window width\nPoints. New windows open at this size.")
            TextField("Height:", value: $profile.windowHeight, format: .number)
                .help("Window height\nPoints. New windows open at this size.")
            HStack {
                Button("Apply to Open Windows") { applyToOpenWindows() }
                    .help("Apply to Open Windows\nResize every open terminal window to this size now.")
                Button("Use Front Window's Size") { useFrontWindow() }
                    .help("Use Front Window's Size\nCopy the size of the most recently used terminal window.")
                Button("Reset") {
                    profile.windowWidth = TerminalProfile.defaultWindow.width
                    profile.windowHeight = TerminalProfile.defaultWindow.height
                }
                .help("Reset\nGo back to 960 × 580 points.")
            }
        }
    }

    private var sessionWindows: [NSWindow] {
        NSApp.orderedWindows.filter { $0.identifier?.rawValue.hasPrefix("session") == true }
    }

    private func applyToOpenWindows() {
        for window in sessionWindows where !window.styleMask.contains(.fullScreen) {
            window.setContentSize(NSSize(width: profile.windowWidth, height: profile.windowHeight))
        }
    }

    private func useFrontWindow() {
        guard let size = sessionWindows.first?.contentLayoutRect.size else { return }
        profile.windowWidth = size.width.rounded()
        profile.windowHeight = size.height.rounded()
    }
}

private struct ColorSettings: View {
    @ObservedObject private var library = ThemeLibrary.shared
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Appearance:", selection: $appearance) {
                ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .help("Appearance\nLight or dark window chrome; System follows macOS.")
            List(selection: $library.selection) {
                row("macOS Terminal Basic", theme: nil).tag("")
                ForEach(library.allNames, id: \.self) { name in
                    row(name, theme: library.theme(named: name)).tag(name)
                        .contextMenu {
                            if library.isImported(name) {
                                Button("Remove Imported Preset") { library.removeImported(name) }
                            }
                        }
                }
            }
            .frame(height: 260)
            .help("Color theme\nClick a theme to apply it to every terminal tab.")
            HStack {
                Button("Import iTerm2 Preset…") { ThemeMenu.importPreset() }
                    .help("Import iTerm2 Preset\nAdd colors from an .itermcolors file.")
                Button("Remove") { library.removeImported(library.selection) }
                    .disabled(!library.isImported(library.selection))
                    .help("Remove\nDelete the selected imported preset. Built-in themes cannot be removed.")
            }
        }
    }

    private func row(_ name: String, theme: TerminalTheme?) -> some View {
        let colors = theme?.colors ?? [:]
        let background = colors["Background Color"] ?? TerminalTypeface.background(dark: true)
        let foreground = colors["Foreground Color"] ?? .white
        return HStack {
            Text("Aa").font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(nsColor: foreground))
                .frame(width: 34, height: 20)
                .background(Color(nsColor: background), in: RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { index in
                    Circle().fill(Color(nsColor: colors["Ansi \(index) Color"] ?? ansiFallback(index))).frame(width: 9, height: 9)
                }
            }
            Text(name)
            if theme != nil && !library.isImported(name) { Text("Built-in").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func ansiFallback(_ index: Int) -> NSColor {
        let c = SwiftTermPalette.basic[index]
        return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
    }
}

/// Terminal.app's first eight ANSI colors, for the Basic swatch.
enum SwiftTermPalette {
    static let basic: [(Int, Int, Int)] = [(0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
                                           (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205)]
}

/// View ▸ Bigger / Smaller / Default Font Size, with Terminal's shortcuts, plus the SSH sheet.
struct TerminalCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Bigger") { workspace?.zoom(1) }.keyboardShortcut("+")
                .disabled(workspace == nil)
            Button("Smaller") { workspace?.zoom(-1) }.keyboardShortcut("-")
                .disabled(workspace == nil)
            Button("Default Font Size") { workspace?.resetZoom() }.keyboardShortcut("0")
                .disabled(workspace == nil)
            Divider()
        }
    }
}
