import SwiftUI
import HerbsTerminalUI

/// What the File Actions menu can do in one explorer; a nil action shows as disabled.
struct FileActions {
    var upload: (() -> Void)?
    var download: (() -> Void)?
    var transferHelp = ""
    var undoTitle = "Undo", redoTitle = "Redo"
    var undo, redo: (() -> Void)?
    var cut, copy, paste, delete, selectAll: (() -> Void)?
    var deleteHelp = "Move the selected items to the Trash."
    var find: () -> Void = {}
}

/// The explorer's File Actions menu. Its shortcuts are labels only: the menu is built fresh on each click and
/// never attached, so it can't swallow key equivalents. The keys reach the focused file list through the Edit
/// menu instead, which keeps ⌘C / ⌘V copying and pasting text when the terminal has focus.
struct FileActionsMenu: NSViewRepresentable {
    let actions: FileActions

    struct Entry {
        var title = "", key = "", modifiers: NSEvent.ModifierFlags = .command
        var help = ""
        var action: (() -> Void)?
        var separator = false
        static var divider: Entry { Entry(separator: true) }
    }

    var entries: [Entry] {
        let delete = String(UnicodeScalar(NSBackspaceCharacter)!)
        return [
            Entry(title: "Upload File/Folder…", modifiers: [], help: actions.transferHelp, action: actions.upload),
            Entry(title: "Download File/Folder…", modifiers: [], help: actions.transferHelp, action: actions.download),
            .divider,
            Entry(title: actions.undoTitle, key: "z", help: "Reverse the last file change made in this explorer.", action: actions.undo),
            Entry(title: actions.redoTitle, key: "z", modifiers: [.command, .shift], help: "Repeat the change you just undid.", action: actions.redo),
            .divider,
            Entry(title: "Cut", key: "x", help: "Mark the selected items to be moved by Paste.", action: actions.cut),
            Entry(title: "Copy", key: "c", help: "Copy the selected items so Paste duplicates them.", action: actions.copy),
            Entry(title: "Paste", key: "v", help: "Put copied or cut items into this folder.", action: actions.paste),
            Entry(title: "Delete", key: delete, help: actions.deleteHelp, action: actions.delete),
            Entry(title: "Select All", key: "a", help: "Select every item in this folder.", action: actions.selectAll),
            .divider,
            Entry(title: "Find", key: "f", help: "Filter this folder by name.", action: actions.find),
        ]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "File actions")
        let button = NSButton(image: image ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .accessoryBarAction
        button.setAccessibilityHelp("Upload, download, undo, cut, copy, paste, delete, select all and find.")
        button.setAccessibilityLabel("File actions")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.entries = entries }

    // Without this an AppKit button stretches across all the width SwiftUI offers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var entries: [Entry] = []
        private var handlers: [() -> Void] = []

        @objc func show(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            handlers = []
            for entry in entries {
                if entry.separator { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: entry.title, action: #selector(run(_:)), keyEquivalent: entry.key)
                item.keyEquivalentModifierMask = entry.modifiers
                item.target = self
                item.toolTip = entry.help
                item.isEnabled = entry.action != nil
                item.tag = handlers.count
                handlers.append(entry.action ?? {})
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }

        @objc private func run(_ item: NSMenuItem) {
            let handler = handlers[item.tag]
            // Let the menu finish closing before an action opens a panel or an alert.
            DispatchQueue.main.async { handler() }
        }
    }
}

extension View {
    /// Routes the standard Edit commands (and ⌘⌫ / Delete) to a file list while it has focus.
    func fileCommands(_ actions: FileActions, back: @escaping () -> Void) -> some View {
        onCommand(#selector(NSText.cut(_:))) { actions.cut?() }
            .onCommand(#selector(NSText.copy(_:))) { actions.copy?() }
            .onCommand(#selector(NSText.paste(_:))) { actions.paste?() }
            .onCommand(#selector(NSText.selectAll(_:))) { actions.selectAll?() }
            .onCommand(Selector(("undo:"))) { actions.undo?() }
            .onCommand(Selector(("redo:"))) { actions.redo?() }
            .onCommand(#selector(NSResponder.deleteToBeginningOfLine(_:))) { actions.delete?() }
            // Bare Delete is Thunar's BackSpace (Back); ⌘⌫ and Edit ▸ Delete delete.
            .onDeleteCommand {
                if let event = NSApp.currentEvent, event.type == .keyDown, !event.modifierFlags.contains(.command) {
                    back()
                } else {
                    actions.delete?()
                }
            }
    }
}

@MainActor
final class ExplorerFilter: ObservableObject {
    @Published var active = false
    @Published var text = ""

    func matches(_ name: String) -> Bool { text.isEmpty || name.localizedCaseInsensitiveContains(text) }
    func close() { active = false; text = "" }
}

struct FilterBar: View {
    @ObservedObject var filter: ExplorerFilter
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by name", text: $filter.text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { filter.close() }
                .onAppear { DispatchQueue.main.async { focused = true } }
            Button { filter.close() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .hint("Close Find\nShow every item in this folder again (Esc).")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .hint("Find\nShow only items whose name contains this text.")
    }
}

/// Shared between a background transfer and the Cancel button that stops it.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func cancel() { lock.withLock { set = true } }
}

/// Collects byte counts from a background transfer and reports them to the queue about ten times a second.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var reported = Date.distantPast
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func add(_ bytes: Int64) {
        let snapshot: Int64? = lock.withLock {
            done += bytes
            guard Date().timeIntervalSince(reported) > 0.1 else { return nil }
            reported = Date()
            return done
        }
        if let snapshot { report(snapshot) }
    }
}

/// Upload and download progress for the queue, shown under the remote explorer while it has items.
struct TransfersStrip: View {
    @ObservedObject var queue: TransferQueue
    let cancel: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transfers").font(.caption.weight(.semibold))
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .buttonStyle(.link).font(.caption)
                    .hint("Clear Finished\nRemove completed, failed and cancelled transfers from this list.")
            }
            ForEach(queue.items.suffix(4)) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                        .hint(item.isUpload ? "Upload from this Mac to the remote host." : "Download from the remote host to this Mac.")
                    Text(item.name).lineLimit(1).truncationMode(.middle).frame(width: 140, alignment: .leading)
                        .hint(item.route)
                    switch item.state {
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).lineLimit(1).hint(message)
                    case .completed:
                        Text("Done").foregroundStyle(.secondary)
                    case .cancelled:
                        Text("Cancelled").foregroundStyle(.secondary)
                    default:
                        ProgressView(value: item.progressFraction).hint(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
                        Button { cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).hint("Cancel\nStop this transfer and discard the partial copy.")
                    }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(.bar)
    }
}

extension TransferItem {
    var isUpload: Bool { if case .upload = direction { true } else { false } }
    var route: String {
        switch direction {
        case .upload(let local, let remote): "\(local.path) → \(remote)"
        case .download(let remote, let local): "\(remote) → \(local.path)"
        }
    }
}

extension TransferQueue {
    func clearFinished() {
        items.removeAll {
            switch $0.state {
            case .completed, .failed, .cancelled: true
            default: false
            }
        }
    }
}
