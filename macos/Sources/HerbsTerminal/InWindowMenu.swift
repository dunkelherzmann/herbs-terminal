import AppKit

/// Every menu lives in the window, not in the macOS menu bar (SPECIFICATION.md §2): wide screens make the trip to the
/// top of the screen long. SwiftUI keeps building the full menu bar from `TerminalCommands`; every menu but the app
/// menu (the one macOS always shows) is hidden, and the Main Menu in the toolbar shows them instead.
///
/// Hidden menus take no shortcuts, so every key with ⌘ or ⌃ is routed here: the key window first (the terminal,
/// fields and sheets), as AppKit does, then the menu bar with its menus briefly shown again, so AppKit matches the
/// key exactly as it always has. SwiftUI refreshes a menu only when it is about to open, so each one is asked to
/// first; otherwise a command would run with the state of the last time its menu was looked at.
@MainActor
enum InWindowMenu {
    private static var observer: NSObjectProtocol?
    private static var monitor: Any?

    static func start() {
        // SwiftUI rebuilds the menu bar when commands change: hide its menus again after every pass of the event loop.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                                          queue: nil) { _ in
            MainActor.assumeIsolated { hideMenus() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { route(event) } ? nil : event
        }
        hideMenus()
    }

    private static func hideMenus() {
        guard let bar = NSApp.mainMenu else { return }
        for item in bar.items.dropFirst() where !item.isHidden { item.isHidden = true }
    }

    /// Returns whether the event was handled.
    static func route(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) || modifiers.contains(.control), let bar = NSApp.mainMenu else { return false }
        if let window = NSApp.keyWindow, window.performKeyEquivalent(with: event) { return true }
        // Ctrl keys typed in the terminal (⌃A, ⌃E…) pass straight on unless some menu item uses that key.
        let keys = Set([event.charactersIgnoringModifiers, event.characters].compactMap { $0?.lowercased() })
        guard uses(bar, keys, control: modifiers.contains(.control) && !modifiers.contains(.command)) else { return false }
        refresh(bar)
        for item in bar.items { item.isHidden = false }
        defer { hideMenus() }
        return bar.performKeyEquivalent(with: event)
    }

    /// Whether an item uses one of `keys`; with `control` (a ⌃ key without ⌘), only items that use ⌃ count.
    private static func uses(_ menu: NSMenu, _ keys: Set<String>, control: Bool) -> Bool {
        menu.items.contains { item in
            (!item.keyEquivalent.isEmpty && keys.contains(item.keyEquivalent.lowercased())
                && (!control || item.keyEquivalentModifierMask.contains(.control)))
                || item.submenu.map { uses($0, keys, control: control) } == true
        }
    }

    private static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
    }

    /// The menu bar's visible titles and the menus the shortcuts reach (for the feature tests).
    static var report: [String: [String]] {
        let items = NSApp.mainMenu?.items ?? []
        return ["bar": items.filter { !$0.isHidden }.map(\.title), "full": items.map(\.title)]
    }
}
