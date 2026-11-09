import SwiftUI

/// A tab's split panes, as in iTerm2: a leaf is one shell; a split lays its children side by side
/// (`.horizontal`) or stacked (`.vertical`) at equal sizes. Panes can be split again in either direction.
@MainActor
final class PaneNode: ObservableObject, Identifiable {
    enum Axis: String, Codable {
        /// Side by side, from Split Vertically (⌘D).
        case horizontal
        /// Stacked, from Split Horizontally (⇧⌘D).
        case vertical
    }

    let id = UUID()
    @Published private(set) var shell: LocalShell?
    @Published private(set) var axis: Axis = .horizontal
    @Published private(set) var children: [PaneNode] = []
    private(set) weak var parent: PaneNode?

    init(shell: LocalShell) { self.shell = shell }

    init(axis: Axis, children: [PaneNode]) {
        self.axis = axis
        self.children = children
        children.forEach { $0.parent = self }
    }

    /// Every shell in display order (left to right, top to bottom).
    var leaves: [LocalShell] { shell.map { [$0] } ?? children.flatMap(\.leaves) }

    func leaf(for target: LocalShell) -> PaneNode? {
        if shell === target { return self }
        for child in children { if let found = child.leaf(for: target) { return found } }
        return nil
    }

    /// Adds `pane` next to this leaf: a sibling when the parent already splits along `axis`, otherwise
    /// this leaf becomes a split holding its old shell and the new pane.
    func split(_ axis: Axis, adding pane: PaneNode) {
        if let parent, parent.axis == axis, let index = parent.children.firstIndex(where: { $0 === self }) {
            pane.parent = parent
            parent.children.insert(pane, at: index + 1)
            return
        }
        guard let shell else { return }
        let moved = PaneNode(shell: shell)
        self.shell = nil
        self.axis = axis
        moved.parent = self
        pane.parent = self
        children = [moved, pane]
    }

    /// Removes this leaf. A split left with one child takes that child's place, so nesting stays minimal.
    func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
        guard parent.children.count == 1, let only = parent.children.first else { return }
        parent.shell = only.shell
        parent.axis = only.axis
        parent.children = only.children
        parent.children.forEach { $0.parent = parent }
    }
}

/// The saved shape of a tab's panes, for session restore.
struct SavedPane: Codable, Equatable {
    var directory: String?
    var axis: PaneNode.Axis?
    var children: [SavedPane]?
}

extension PaneNode {
    var saved: SavedPane {
        if let shell { return SavedPane(directory: shell.currentDirectory ?? shell.startDirectory) }
        return SavedPane(axis: axis, children: children.map(\.saved))
    }

    /// Rebuilds a saved shape. `first` is the tab's existing shell, used for the first leaf; the others
    /// are new shells with `profile`, each in its saved folder when that still exists.
    static func restore(_ saved: SavedPane, first: inout LocalShell?, profile: UUID?) -> PaneNode {
        if let children = saved.children, !children.isEmpty, let axis = saved.axis {
            return PaneNode(axis: axis, children: children.map { restore($0, first: &first, profile: profile) })
        }
        if let shell = first {
            first = nil
            return PaneNode(shell: shell)
        }
        let shell = LocalShell(profileID: profile)
        if let directory = saved.directory, FileManager.default.fileExists(atPath: directory) { shell.startDirectory = directory }
        return PaneNode(shell: shell)
    }
}

/// Draws a pane tree; `content` builds one shell's terminal.
struct PaneTreeView<Content: View>: View {
    @ObservedObject var node: PaneNode
    @ObservedObject var tab: TerminalTab
    let content: (LocalShell) -> Content

    var body: some View {
        if let shell = node.shell {
            content(shell)
                .overlay {
                    // With more than one pane, the focused one is outlined.
                    if tab.root.leaves.count > 1, tab.focusedShell === shell {
                        Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5).allowsHitTesting(false)
                    }
                }
        } else {
            GeometryReader { geometry in
                let count = CGFloat(max(1, node.children.count))
                let along = node.axis == .horizontal ? geometry.size.width : geometry.size.height
                let size = (along - (count - 1)) / count
                if node.axis == .horizontal {
                    HStack(spacing: 0) {
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                            if index > 0 { Divider() }
                            PaneTreeView(node: child, tab: tab, content: content).frame(width: size)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                            if index > 0 { Divider() }
                            PaneTreeView(node: child, tab: tab, content: content).frame(height: size)
                        }
                    }
                }
            }
        }
    }
}
