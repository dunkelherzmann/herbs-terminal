import SwiftUI

/// Thunar-style back/forward history for one explorer pane, keyed by POSIX path.
struct NavigationHistory: Equatable {
    static let limit = 100
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    private(set) var current: String

    init(_ start: String) { current = start }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Records a new location. Revisiting the current one is ignored; anything else clears forward history.
    mutating func visit(_ path: String) {
        guard path != current else { return }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
        current = path
    }

    mutating func goBack() -> String? {
        guard let previous = back.popLast() else { return nil }
        forward.append(current)
        current = previous
        return previous
    }

    mutating func goForward() -> String? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        current = next
        return next
    }
}

struct PathSegment: Equatable {
    let name: String
    let path: String
}

/// The clickable path buttons for a location, root first.
func pathSegments(_ path: String) -> [PathSegment] {
    var segments = [PathSegment(name: "/", path: "/")]
    var built = ""
    for part in normalizePath(path).split(separator: "/") {
        built += "/" + part
        segments.append(PathSegment(name: String(part), path: built))
    }
    return segments
}

/// Collapses `.`, `..`, repeated and trailing slashes without touching the filesystem.
func normalizePath(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
        if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
}

func parentPath(_ path: String) -> String { normalizePath(path + "/..") }

/// Resolves location-field input: absolute, `~`-relative, or relative to the current folder.
func resolveLocation(_ input: String, from current: String, home: String?) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text == "~" || text.hasPrefix("~/") {
        guard let home else { return nil }
        return normalizePath(home + text.dropFirst())
    }
    return normalizePath(text.hasPrefix("/") ? text : remoteJoin(current, text))
}

// SwiftUI's @State macro is unavailable under the native build system, so view state lives in small objects.
@MainActor
final class LocationField: ObservableObject {
    @Published var editing = false
    @Published var text = ""
}

@MainActor
final class ListSelection<ID: Hashable>: ObservableObject {
    @Published var ids = Set<ID>()
}

/// Back, forward, up, home, path buttons or an editable location, reload and hidden files.
struct LocationBar<Trailing: View>: View {
    let path: String
    @Binding var history: NavigationHistory
    let home: String?
    @Binding var showHidden: Bool
    let go: (String) -> Void
    let reload: () -> Void
    @ViewBuilder var trailing: Trailing

    @StateObject private var field = LocationField()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button { if let p = history.goBack() { go(p) } } label: { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("[").disabled(!history.canGoBack).help("Back (⌘[)\nReturn to the folder you were in before.")
            Button { if let p = history.goForward() { go(p) } } label: { Label("Forward", systemImage: "chevron.right") }
                .keyboardShortcut("]").disabled(!history.canGoForward).help("Forward (⌘])\nGo forward again after using Back.")
            // Shortcut actions can outlive a render, so read the live history rather than `path`.
            Button { visit(parentPath(history.current)) } label: { Label("Parent folder", systemImage: "arrow.up") }
                .keyboardShortcut(.upArrow).disabled(path == "/").help("Open Parent (⌘↑)\nGo up to the folder that contains this one.")
            if let home {
                Button { visit(home) } label: { Label("Home folder", systemImage: "house") }
                    .keyboardShortcut("h", modifiers: [.command, .shift]).help("Home (⇧⌘H)\nGo to your home folder.")
            }
            if field.editing {
                TextField("Location", text: $field.text)
                    .help("Location\nPress Return to go there, Esc to cancel.")
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit {
                        if let target = resolveLocation(field.text, from: history.current, home: home) { visit(target) }
                        field.editing = false
                    }
                    .onExitCommand { field.editing = false }
                    // Fill and focus once the field is in the window; the shortcut's action can hold a stale path.
                    .onAppear {
                        field.text = history.current
                        DispatchQueue.main.async { fieldFocused = true }
                    }
            } else {
                // Anchored to the trailing edge so the current folder is always visible; a new id per path
                // re-applies the anchor (scrollTo ran before layout and left the last segment hidden).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(pathSegments(path).enumerated()), id: \.offset) { index, segment in
                            if index > 1 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                            Button(segment.name) { visit(segment.path) }
                                .buttonStyle(.plain)
                                .fontWeight(segment.path == normalizePath(path) ? .semibold : .regular)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                .help("\(segment.path)\nClick to open this folder.")
                        }
                    }
                }
                // Long paths start scrolled to the end; short ones stay left-aligned.
                .defaultScrollAnchor(.trailing, for: .initialOffset)
                .defaultScrollAnchor(.leading, for: .alignment)
                .id(path)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { startEditing() } label: { Label("Edit location", systemImage: "character.cursor.ibeam") }
                .keyboardShortcut("l").help("Open Location (⌘L)\nType a path to go to: absolute, ~/… or relative to this folder.")
            Button { reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r").help("Reload (⌘R)\nList this folder again to pick up changes.")
            Toggle(isOn: $showHidden) { Label("Show hidden files", systemImage: "eye") }
                .toggleStyle(.button).keyboardShortcut(".", modifiers: [.command, .shift])
                .help(showHidden ? "Hide Hidden Files (⇧⌘.)\nStop showing items whose names start with a dot."
                                  : "Show Hidden Files (⇧⌘.)\nAlso list items whose names start with a dot.")
            trailing
        }
        .labelStyle(.iconOnly)
        .padding(8)
    }

    private func visit(_ target: String) {
        history.visit(target)
        go(target)
    }

    private func startEditing() {
        field.editing = true
    }
}
