import CGtk
import Foundation

/// A tab's split panes, as in iTerm2: a leaf is one shell; a split lays its children side by side (`.horizontal`)
/// or stacked (`.vertical`) at equal sizes. Panes can be split again in either direction.
@MainActor
final class PaneNode {
    enum Axis: String, Codable {
        /// Side by side, from Split Vertically.
        case horizontal
        /// Stacked, from Split Horizontally.
        case vertical
    }

    let id = UUID()
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

    var saved: SavedPane {
        if let pane { return SavedPane(directory: pane.currentDirectory ?? pane.startDirectory) }
        return SavedPane(axis: axis.rawValue, children: children.map(\.saved))
    }

    /// Rebuilds a saved shape. `first` is the tab's existing shell, used for the first leaf; the others are new
    /// shells with `profile`, each in its saved folder when that still exists.
    static func restore(_ saved: SavedPane, first: inout TerminalPane?, profile: UUID?) -> PaneNode {
        if let children = saved.children, !children.isEmpty, let axis = saved.axis.flatMap(Axis.init(rawValue:)) {
            return PaneNode(axis: axis, children: children.map { restore($0, first: &first, profile: profile) })
        }
        if let pane = first {
            first = nil
            return PaneNode(pane: pane)
        }
        let pane = TerminalPane(profileID: profile)
        if let directory = saved.directory, FileManager.default.fileExists(atPath: directory) { pane.startDirectory = directory }
        return PaneNode(pane: pane)
    }

    /// The widgets for this subtree: equal-sized boxes with a hairline between panes, the focused pane outlined.
    func build(focused: TerminalPane?, outline: Bool) -> Widget {
        if let pane {
            unparent(pane.view)
            let holder = box(.vertical, [pane.view])
            gtk_widget_set_hexpand(holder, 1)
            gtk_widget_set_vexpand(holder, 1)
            if outline, pane === focused { gtk_widget_add_css_class(pane.view, "focused-pane") }
            else { gtk_widget_remove_css_class(pane.view, "focused-pane") }
            return holder
        }
        let container = box(axis == .horizontal ? .horizontal : .vertical)
        gtk_box_set_homogeneous(c(container), 1)
        for (index, child) in children.enumerated() {
            let widget = child.build(focused: focused, outline: outline)
            if index > 0 { gtk_widget_add_css_class(widget, axis == .horizontal ? "pane-divider-start" : "pane-divider-top") }
            append(container, widget)
        }
        return container
    }
}

/// Takes a widget out of the box holding it; widgets the app reuses are kept alive by their owners.
func unparent(_ widget: Widget) {
    guard let parent = gtk_widget_get_parent(widget) else { return }
    gtk_box_remove(c(parent), widget)
}
