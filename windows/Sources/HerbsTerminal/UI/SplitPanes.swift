import Foundation
import WinSDK

/// A tab's split panes, as on the Mac and Linux: a leaf is one shell; a split lays its children side by side
/// (`.horizontal`, from Split Vertically) or stacked (`.vertical`, from Split Horizontally) at equal sizes, and
/// panes can be split again either way. The tab itself is its first pane, which owns the tab's number, name, SSH
/// connection and explorer.
@MainActor
final class PaneNode {
    /// The same names Linux saves, so a session file reads the same.
    enum Axis: String { case horizontal, vertical }

    private(set) var pane: TerminalPane?
    private(set) var axis: Axis = .horizontal
    private(set) var children: [PaneNode] = []
    private(set) weak var parent: PaneNode?

    init(pane: TerminalPane) { self.pane = pane }

    init(axis: Axis, children: [PaneNode]) {
        self.axis = axis
        self.children = children
        children.forEach { $0.parent = self }
    }

    /// The shape to save for session restore: each shell's folder, and how the panes are split.
    var saved: SavedPane {
        if let pane { return SavedPane(directory: pane.remote == nil ? pane.location : nil) }
        return SavedPane(axis: axis.rawValue, children: children.map(\.saved))
    }

    /// Rebuilds a saved shape. `first` is the tab's own shell, used for the first leaf; `make` starts the others,
    /// each in its saved folder.
    static func restore(_ saved: SavedPane, first: inout TerminalPane?, make: (String?) -> TerminalPane?) -> PaneNode? {
        if let children = saved.children, !children.isEmpty, let axis = saved.axis.flatMap(Axis.init(rawValue:)) {
            let nodes = children.compactMap { restore($0, first: &first, make: make) }
            if nodes.count == 1 { return nodes[0] }
            return nodes.isEmpty ? nil : PaneNode(axis: axis, children: nodes)
        }
        if let pane = first {
            first = nil
            return PaneNode(pane: pane)
        }
        return make(saved.directory).map(PaneNode.init(pane:))
    }

    /// Every shell in display order (left to right, top to bottom).
    var leaves: [TerminalPane] { pane.map { [$0] } ?? children.flatMap(\.leaves) }

    func leaf(for target: TerminalPane) -> PaneNode? {
        if pane === target { return self }
        for child in children { if let found = child.leaf(for: target) { return found } }
        return nil
    }

    /// Adds `node` next to this leaf: a sibling when the parent already splits along `axis`, otherwise this leaf
    /// becomes a split holding its old shell and the new pane.
    func split(_ axis: Axis, adding node: PaneNode) {
        if let parent, parent.axis == axis, let index = parent.children.firstIndex(where: { $0 === self }) {
            node.parent = parent
            parent.children.insert(node, at: index + 1)
            return
        }
        guard let pane else { return }
        let moved = PaneNode(pane: pane)
        self.pane = nil
        self.axis = axis
        moved.parent = self
        node.parent = self
        children = [moved, node]
    }

    /// Removes this leaf. A split left with one child takes that child's place, so nesting stays minimal.
    func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
        guard parent.children.count == 1, let only = parent.children.first else { return }
        parent.pane = only.pane
        parent.axis = only.axis
        parent.children = only.children
        parent.children.forEach { $0.parent = parent }
    }

    /// Each pane's rectangle within `rect`: equal shares, with a hairline `gap` between neighbours.
    func frames(in rect: RECT, gap: Int32) -> [(TerminalPane, RECT)] {
        if let pane { return [(pane, rect)] }
        let count = Int32(children.count)
        guard count > 0 else { return [] }
        let horizontal = axis == .horizontal
        let total = (horizontal ? rect.right - rect.left : rect.bottom - rect.top) - gap * (count - 1)
        var result: [(TerminalPane, RECT)] = []
        var start = horizontal ? rect.left : rect.top
        for (index, child) in children.enumerated() {
            // The last child takes what rounding left over.
            let size = index == children.count - 1 ? (horizontal ? rect.right : rect.bottom) - start : total / count
            let part = horizontal ? RECT(left: start, top: rect.top, right: start + size, bottom: rect.bottom)
                                  : RECT(left: rect.left, top: start, right: rect.right, bottom: start + size)
            result += child.frames(in: part, gap: gap)
            start += size + gap
        }
        return result
    }
}

/// The panes of one tab: the tree, and which pane has the focus.
@MainActor
final class PaneGroup {
    let root: PaneNode
    weak var focused: TerminalPane?

    init(first: TerminalPane) {
        root = PaneNode(pane: first)
        focused = first
    }

    init(root: PaneNode) {
        self.root = root
        focused = root.leaves.first
    }

    var panes: [TerminalPane] { root.leaves }
    var isSplit: Bool { panes.count > 1 }

    func split(_ pane: TerminalPane, _ axis: PaneNode.Axis, adding new: TerminalPane) {
        root.leaf(for: pane)?.split(axis, adding: PaneNode(pane: new))
        focused = new
    }

    /// Takes `pane` out; the focus moves to the pane that took its place (the next one, or the one before).
    func remove(_ pane: TerminalPane) {
        let order = panes
        guard let index = order.firstIndex(where: { $0 === pane }), let node = root.leaf(for: pane) else { return }
        if node === root { return } // The last pane closes with its tab.
        node.removeFromParent()
        if focused === pane || focused == nil {
            let left = panes
            focused = left.indices.contains(index) ? left[index] : left.last
        }
    }

    /// Select Next / Previous Pane, wrapping around.
    func cycle(_ step: Int) {
        let order = panes
        guard order.count > 1 else { return }
        let index = order.firstIndex { $0 === focused } ?? 0
        focused = order[(index + step + order.count) % order.count]
    }
}
