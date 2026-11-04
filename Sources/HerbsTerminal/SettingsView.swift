import Carbon
import SwiftUI
import HerbsTerminalUI

/// Herb's Terminal ▸ Settings… (⌘,): the profile every terminal tab follows, like Ptyxis or iTerm2 preferences.
struct SettingsView: View {
    var body: some View {
        TabView {
            ProfilesSettings().tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            TextSettings().tabItem { Label("Text", systemImage: "textformat") }
            ShellSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            WindowSettings().tabItem { Label("Window", systemImage: "macwindow") }
            ColorSettings().tabItem { Label("Colors", systemImage: "paintpalette") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

/// Named profiles, like Terminal's and Ptyxis's: pick one to edit it on the other tabs.
private struct ProfilesSettings: View {
    @ObservedObject private var profile = TerminalProfile.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                List(selection: Binding(get: { profile.editingID }, set: { if let id = $0 { profile.editingID = id } })) {
                    ForEach(profile.profiles) { item in
                        HStack {
                            Text(item.name)
                            if item.id == profile.defaultProfileID { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(item.id)
                    }
                }
                .frame(width: 170, height: 230)
                .hint("Profiles\nSelect a profile to edit it here and on the Text, Terminal and Colors tabs.")
                HStack(spacing: 4) {
                    Button { profile.editingID = profile.addProfile(named: "New Profile") } label: { Image(systemName: "plus") }
                        .hint("New Profile\nAdd a profile with the stock Terminal Basic settings.")
                    Button { profile.editingID = profile.addProfile(named: profile.name(of: profile.editingID) + " copy", copying: profile.editingID) } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .hint("Duplicate\nCopy the selected profile.")
                    Button { profile.removeProfile(profile.editingID) } label: { Image(systemName: "minus") }
                        .disabled(profile.profiles.count < 2)
                        .hint("Delete Profile\nRemove the selected profile; tabs using it switch to the default.")
                }
                .buttonStyle(.borderless)
            }
            Form {
                TextField("Name:", text: Binding(get: { profile.name(of: profile.editingID) },
                                                 set: { profile.rename(profile.editingID, to: $0) }))
                    .hint("Name\nHow this profile appears in Shell ▸ New Tab with Profile.")
                TextField("Run command:", text: $profile.startupCommand, prompt: Text("none"))
                    .hint("Startup command\nTyped into the shell when a tab with this profile opens, e.g. `ssh build-box` or `cd ~/src`.")
                TextField("Start in:", text: $profile.startDirectory, prompt: Text("Settings ▸ Terminal ▸ New tabs open in"))
                    .hint("Start folder\nWhere new tabs with this profile start, e.g. ~/Projects. Empty uses the New tabs setting.")
                Button("Use as Default") { profile.defaultProfileID = profile.editingID }
                    .disabled(profile.defaultProfileID == profile.editingID)
                    .hint("Use as Default\nNew windows, and new tabs from the New Tab button, start with this profile.")
            }
        }
    }
}

/// Which profile the Text, Terminal and Colors tabs are editing.
private struct EditingProfileHeader: View {
    @ObservedObject private var profile = TerminalProfile.shared

    var body: some View {
        Text("Editing profile: \(profile.name(of: profile.editingID))")
            .font(.caption).foregroundStyle(.secondary)
            .hint("Editing profile\nChoose another profile on the Profiles tab.")
    }
}

private struct TextSettings: View {
    @ObservedObject private var profile = TerminalProfile.shared
    @ObservedObject private var themes = ThemeLibrary.shared

    var body: some View {
        Form {
            EditingProfileHeader()
            Picker("Font:", selection: $profile.fontFamily) {
                Text("SF Mono Terminal (Basic)").tag("")
                Divider()
                ForEach(TerminalProfile.monospacedFamilies, id: \.self) { Text($0).tag($0) }
            }
            .hint("Font\nThe monospaced typeface used by every terminal tab.")
            HStack {
                TextField("Size:", value: $profile.fontSize, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 140)
                Stepper("", value: $profile.fontSize, in: TerminalProfile.sizeRange, step: 1).labelsHidden()
                Text("pt").foregroundStyle(.secondary)
                if profile.zoom != 0 {
                    Text("zoomed \(profile.zoom > 0 ? "+" : "")\(Int(profile.zoom)) pt").foregroundStyle(.secondary)
                    Button("Reset") { profile.zoom = 0 }
                        .hint("Reset zoom\nClear the ⌘+ / ⌘− zoom kept for this profile (same as ⌘0).")
                }
            }
            .hint("Font size\nPoints, \(Int(TerminalProfile.sizeRange.lowerBound))–\(Int(TerminalProfile.sizeRange.upperBound)). ⌘+ / ⌘− / ⌘0 zoom one tab temporarily.")
            Picker("Cursor:", selection: $profile.cursor) {
                ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .hint("Cursor shape\nHow the text cursor is drawn in the terminal.")
            HStack {
                Slider(value: $profile.backgroundOpacity, in: 0.2...1) { Text("Background opacity:") }
                Text("\(Int(profile.backgroundOpacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .hint("Background opacity\nMake the terminal background see-through.")
            Toggle("Blur behind the terminal", isOn: $profile.blurBackground)
                .hint("Blur\nBlur what's behind a see-through terminal so text stays readable.")
            Toggle("Blinking cursor", isOn: $profile.cursorBlinks)
                .hint("Blinking cursor\nBlink the cursor while the terminal has focus.")
            preview
            Button("Restore Defaults") { profile.resetText() }
                .hint("Restore Defaults\nGo back to the stock Terminal Basic font, size and cursor.")
        }
    }

    private var preview: some View {
        let colors = themes.theme(named: profile.theme)?.colors ?? [:]
        let background = colors["Background Color"] ?? TerminalTypeface.background(dark: true)
        let foreground = colors["Foreground Color"] ?? .white
        return Text("user@host ~ % ls -la\nThe quick brown fox — 0O 1lI {}[]")
            .font(Font(profile.font))
            .foregroundStyle(Color(nsColor: foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: background), in: RoundedRectangle(cornerRadius: 6))
            .hint("Preview\nHow terminal text looks with this font and color theme.")
    }
}

private struct ShellSettings: View {
    @ObservedObject private var profile = TerminalProfile.shared

    var body: some View {
        Form {
            EditingProfileHeader()
            Toggle("Use Option as Meta key", isOn: $profile.optionAsMeta)
                .hint("Option as Meta\nOption+key sends Esc+key (for Emacs and shell word movement) instead of typing special characters.")
            HStack {
                TextField("Scrollback:", value: $profile.scrollbackLines, format: .number)
                    .frame(width: 180)
                Text("lines").foregroundStyle(.secondary)
            }
            .hint("Scrollback\nHow many lines each tab keeps above the screen (100–1,000,000).")
            Picker("Bell:", selection: $profile.bell) {
                ForEach(TerminalBell.allCases) { Text($0.title).tag($0) }
            }
            .hint("Bell\nWhat happens when a program rings the terminal bell.")
            Picker("New tabs open in:", selection: $profile.newTabsInSameFolder) {
                Text("Same folder as the current tab").tag(true)
                Text("Home folder").tag(false)
            }
            .hint("New tabs\nWhere a new local tab's shell starts.")
            Toggle("Restore windows and tabs when Herb's Terminal opens", isOn: $profile.restoreSession)
                .hint("Restore session\nReopen your windows and tabs, with their folders, layouts and names, at launch.")
            Toggle("Ask before closing a tab with running processes", isOn: $profile.askBeforeClosing)
                .hint("Ask before closing\nConfirm before ending a program or SSH session by closing its tab.")
        }
    }
}

private struct WindowSettings: View {
    @ObservedObject private var profile = TerminalProfile.shared

    var body: some View {
        Form {
            Toggle("Show columns × rows while resizing", isOn: $profile.showSizeWhileResizing)
                .hint("Size while resizing\nShow the terminal's size, like 100 × 30, while you resize the window.")
            TextField("Width:", value: $profile.windowWidth, format: .number)
                .hint("Window width\nPoints. New windows open at this size.")
            TextField("Height:", value: $profile.windowHeight, format: .number)
                .hint("Window height\nPoints. New windows open at this size.")
            HStack {
                Button("Apply to Open Windows") { applyToOpenWindows() }
                    .hint("Apply to Open Windows\nResize every open terminal window to this size now.")
                Button("Use Front Window's Size") { useFrontWindow() }
                    .hint("Use Front Window's Size\nCopy the size of the most recently used terminal window.")
                Button("Reset") {
                    profile.windowWidth = TerminalProfile.defaultWindow.width
                    profile.windowHeight = TerminalProfile.defaultWindow.height
                }
                .hint("Reset\nGo back to 960 × 580 points.")
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
    @ObservedObject private var profile = TerminalProfile.shared
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditingProfileHeader()
            Picker("Appearance:", selection: $appearance) {
                ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .hint("Appearance\nLight or dark window chrome; System follows macOS.")
            List(selection: Binding(get: { profile.theme }, set: { profile.theme = $0 ?? "" })) {
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
            .hint("Color theme\nClick a theme to use it in this profile; every tab with the profile follows.")
            HStack {
                Button("Import iTerm2 Preset…") { if let name = ThemeMenu.importPreset() { profile.theme = name } }
                    .hint("Import iTerm2 Preset\nAdd colors from an .itermcolors file.")
                Button("Remove") { library.removeImported(profile.theme); profile.theme = "" }
                    .disabled(!library.isImported(profile.theme))
                    .hint("Remove\nDelete the selected imported preset. Built-in themes cannot be removed.")
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

/// Menu-bar commands with macOS Terminal's shortcuts: View ▸ Bigger / Smaller / Default Font Size,
/// Edit ▸ Clear to Start / Clear Scrollback, and a Shell menu for tabs, SSH, reset and secure entry.
struct TerminalCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @ObservedObject private var secureInput = SecureInput.shared
    @ObservedObject private var profiles = TerminalProfile.shared

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Clear to Start") { workspace?.selected.shell.view.clearToStart() }
                .keyboardShortcut("k").disabled(workspace == nil)
            Button("Clear Scrollback") { workspace?.selected.shell.view.clearHistory() }
                .keyboardShortcut("k", modifiers: [.command, .option]).disabled(workspace == nil)
        }
        CommandGroup(before: .windowList) {
            ForEach(1..<10) { number in
                Button("Show Tab \(number)") { workspace?.selectTab(number: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))))
                    .disabled((workspace?.tabs.count ?? 0) < number)
            }
            Divider()
        }
        CommandMenu("Shell") {
            Button("New Tab") { workspace?.add() }.keyboardShortcut("t").disabled(workspace == nil)
            Toggle("MultiExec", isOn: Binding(get: { workspace?.multiExec ?? false }, set: { workspace?.multiExec = $0 }))
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(workspace == nil)
            Button("Run Command on Hosts…") { workspace?.panel = .multiHost }.disabled(workspace == nil)
            Menu("New Tab with Profile") {
                ForEach(profiles.profiles) { profile in
                    Button(profile.name) { workspace?.add(profile: profile.id) }
                }
            }
            .disabled(workspace == nil)
            Menu("Use Profile") {
                ForEach(profiles.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { workspace.map { TerminalProfile.shared.name(of: $0.selected.shell.profileID) == profile.name } ?? false },
                        set: { if $0 { workspace?.useProfile(profile.id) } }))
                }
            }
            .disabled(workspace == nil)
            Button("New Remote Connection…") { workspace?.showingSSHConnect = true }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(workspace == nil)
            Button("Disconnect") { workspace?.disconnect() }
                .disabled({ if case .connected = workspace?.selected.state.connection { false } else { true } }())
            Divider()
            Button("Show Previous Tab") { workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift]).disabled((workspace?.tabs.count ?? 0) < 2)
            Button("Show Next Tab") { workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift]).disabled((workspace?.tabs.count ?? 0) < 2)
            Button("Rename Tab…") { if let workspace { workspace.rename(workspace.selected) } }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(workspace == nil)
            Button("Move Tab Left") { workspace?.moveSelected(by: -1) }.disabled((workspace?.tabs.count ?? 0) < 2)
            Button("Move Tab Right") { workspace?.moveSelected(by: 1) }.disabled((workspace?.tabs.count ?? 0) < 2)
            Divider()
            Button("Reset") { workspace?.selected.shell.view.reset(hard: false) }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Hard Reset") { workspace?.selected.shell.view.reset(hard: true) }
                .keyboardShortcut("r", modifiers: [.command, .option, .control]).disabled(workspace == nil)
            Divider()
            Toggle("Secure Keyboard Entry", isOn: $secureInput.enabled)
        }
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

/// Shell ▸ Secure Keyboard Entry, as in Terminal: stops other apps from reading what you type.
@MainActor
final class SecureInput: ObservableObject {
    static let shared = SecureInput()
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { EnableSecureEventInput() } else { DisableSecureEventInput() }
        }
    }
}
