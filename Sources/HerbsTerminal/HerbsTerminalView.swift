import AppKit
import SwiftTerm

/// SwiftTerm's view with what macOS Terminal and Ptyxis add on top: a context menu, file drops that type
/// quoted paths, a visual or audible bell, and Terminal's Clear and Reset commands.
final class HerbsTerminalView: LocalProcessTerminalView {
    /// Workspace commands (new tab, explorer, SSH…) appended below the editing items of the context menu.
    var extraMenuItems: () -> [NSMenuItem] = { [] }
    var bellMode: TerminalBell = .audible
    /// MultiExec: receives what the user types or pastes here, to send to the other included tabs.
    var broadcast: ((ArraySlice<UInt8>) -> Void)?
    private var quiet = false

    /// User input (keys, paste, drops) goes to this shell and, in MultiExec, to the other included tabs.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        if !quiet { broadcast?(data) }
    }

    /// Replies the emulator itself sends to the program (cursor reports and the like) stay in this tab.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        quiet = true
        defer { quiet = false }
        super.send(source: source, data: data)
    }

    /// Text the app types on its own (the ssh launcher, a startup command, Clear's redraw) is for this tab only.
    func sendQuietly(_ text: String) {
        quiet = true
        defer { quiet = false }
        send(txt: text)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v").target = self
        menu.addItem(ActionMenuItem("Paste Escaped Text", key: "v", modifiers: [.command, .control]) { [weak self] in self?.pasteEscaped() })
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a").target = self
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        find.target = self
        menu.addItem(find)
        menu.addItem(ActionMenuItem("Clear to Start", key: "k") { [weak self] in self?.clearToStart() })
        menu.addItem(ActionMenuItem("Clear Scrollback", key: "k", modifiers: [.command, .option]) { [weak self] in self?.clearHistory() })
        menu.addItem(ActionMenuItem("Reset", key: "r", modifiers: [.command, .option]) { [weak self] in self?.reset(hard: false) })
        let extras = extraMenuItems()
        if !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }
        return menu
    }

    // MARK: Terminal commands

    /// Terminal's Clear to Start (⌘K): drops the scrollback and the screen. The shell is asked to redraw its
    /// prompt only when it is in the foreground, so full-screen programs aren't sent a stray Ctrl-L.
    func clearToStart() {
        let terminal = getTerminal()
        terminal.clearScrollback()
        feed(text: "\u{1B}[2J\u{1B}[H")
        if shellIsForeground { sendQuietly("\u{0C}") }
    }

    /// Terminal's Clear Scrollback (⌥⌘K): keeps the screen, forgets everything above it.
    func clearHistory() {
        getTerminal().clearScrollback()
        setNeedsDisplay(bounds)
    }

    /// Reset (⌥⌘R) restores modes and colors left behind by a program; Hard Reset also clears the screen.
    func reset(hard: Bool) {
        if hard { getTerminal().resetToInitialState() } else { getTerminal().softReset() }
        if shellIsForeground { sendQuietly("\u{0C}") }
    }

    private var shellIsForeground: Bool {
        guard process.running else { return false }
        return tcgetpgrp(process.childfd) == process.shellPid
    }

    /// Pastes with shell metacharacters escaped, so pasted text is taken literally.
    func pasteEscaped() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        send(txt: shellQuote(text))
    }

    // MARK: Bell

    override func bell(source: Terminal) {
        switch bellMode {
        case .none: return
        case .audible: NSSound.beep()
        case .visual: flash()
        case .both: NSSound.beep(); flash()
        }
    }

    private func flash() {
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            overlay.animator().alphaValue = 0
        }, completionHandler: { overlay.removeFromSuperview() })
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    /// Like Terminal: dropped files and folders are typed as shell-quoted paths, followed by a space.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        send(txt: urls.map { shellQuote($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }
}

enum TerminalBell: String, CaseIterable, Identifiable, Codable {
    case audible, visual, both, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audible: "Audible"
        case .visual: "Visual (flash)"
        case .both: "Audible and visual"
        case .none: "Off"
        }
    }
}

/// An NSMenuItem that runs a closure, for menus built in code.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
         state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
        self.state = state
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
