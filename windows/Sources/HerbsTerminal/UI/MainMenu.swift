import Foundation
import WinSDK

/// The Main Menu, item for item as on Linux (where the Mac's menu bar becomes its Shell submenu). Commands the
/// Windows version doesn't have yet are shown greyed out, so the menu reads the same on every platform.
enum MenuCommand: UINT {
    case newTab = 100, newWindow, connect, findInTerminal
    case zoomIn, zoomOut, zoomReset
    case schemeSystem, schemeLight, schemeDark, presetBasic, importPreset, restoreTheming
    case exportSession, splitVertical, splitHorizontal, closePane, nextPane, previousPane
    case multiExec, runOnHosts, newRemoteConnection, disconnect
    case previousTab, nextTab, renameTab, moveTabLeft, moveTabRight
    case clearToStart, clearScrollback, reset, hardReset
    case fullScreen, settings, manageLogins, about, quit
    case restoreDefaultSize, makeSizeDefault, closeTab, takeScreenshot
    // Ranges for lists: tabs and color presets.
    static let firstTab: UINT = 1000
    static let firstPreset: UINT = 2000
}

@MainActor
enum MainMenu {
    /// Builds the menu for `workspace` and shows it at `point` (screen coordinates). Returns the chosen command id.
    static func show(for workspace: Workspace, at point: POINT, owner: HWND) -> UINT {
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        func item(_ menu: HMENU?, _ title: String, _ command: MenuCommand, enabled: Bool = true, checked: Bool = false) {
            item(menu, title, command.rawValue, enabled: enabled, checked: checked)
        }
        func item(_ menu: HMENU?, _ title: String, _ id: UINT, enabled: Bool = true, checked: Bool = false) {
            var flags = UINT(MF_STRING)
            if !enabled { flags |= UINT(MF_GRAYED) }
            if checked { flags |= UINT(MF_CHECKED) }
            withWide(title) { _ = AppendMenuW(menu, flags, UINT_PTR(id), $0) }
        }
        func divider(_ menu: HMENU?) { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }
        func submenu(_ menu: HMENU?, _ title: String, _ build: (HMENU?) -> Void) {
            let sub = CreatePopupMenu()
            build(sub)
            withWide(title) { _ = AppendMenuW(menu, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(sub)))), $0) }
        }

        let pane = workspace.activePane
        item(menu, "New Tab\tCtrl+Shift+T", .newTab)
        item(menu, "New Window\tCtrl+Shift+N", .newWindow)
        item(menu, "Connect via SSH…\tCtrl+Shift+K", .connect)
        submenu(menu, "Open Tabs") { sub in
            for (index, name) in workspace.tabNames.enumerated() {
                item(sub, name, MenuCommand.firstTab + UINT(index), checked: index == workspace.activeIndex)
            }
        }
        divider(menu)
        item(menu, "Find in Terminal…\tCtrl+Shift+F", .findInTerminal, enabled: false)
        submenu(menu, "Zoom") { sub in
            item(sub, "Bigger\tCtrl+=", .zoomIn)
            item(sub, "Smaller\tCtrl+-", .zoomOut)
            item(sub, "Default\tCtrl+0", .zoomReset)
        }
        submenu(menu, "Appearance") { sub in
            let scheme = TerminalProfile.shared.appearance
            item(sub, "System", .schemeSystem, checked: scheme != "Light" && scheme != "Dark")
            item(sub, "Light", .schemeLight, checked: scheme == "Light")
            item(sub, "Dark", .schemeDark, checked: scheme == "Dark")
            divider(sub)
            let theme = TerminalProfile.shared.settings(for: nil).theme
            item(sub, "macOS Terminal Basic", .presetBasic, checked: theme.isEmpty)
            for (index, name) in ThemeLibrary.shared.allNames.enumerated() {
                item(sub, name, MenuCommand.firstPreset + UINT(index), checked: theme == name)
            }
            divider(sub)
            item(sub, "Import iTerm2 Color Preset…", .importPreset)
            item(sub, "Restore Defaults", .restoreTheming)
        }
        submenu(menu, "Shell") { sub in
            item(sub, "Export Session…\tCtrl+Shift+S", .exportSession, enabled: pane != nil)
            item(sub, "Take Screenshot\tCtrl+Alt+S", .takeScreenshot)
            submenu(sub, "New Tab with Profile") { profiles in
                for profile in TerminalProfile.shared.profiles { item(profiles, profile.name, MenuCommand.newTab.rawValue, enabled: false) }
            }
            submenu(sub, "Use Profile") { profiles in
                for profile in TerminalProfile.shared.profiles { item(profiles, profile.name, MenuCommand.newTab.rawValue, enabled: false) }
            }
            divider(sub)
            let terminal = pane != nil && pane?.showingExplorer == false
            let split = pane?.group?.isSplit == true
            item(sub, "Split Vertically\tCtrl+Shift+E", .splitVertical, enabled: terminal)
            item(sub, "Split Horizontally\tCtrl+Shift+O", .splitHorizontal, enabled: terminal)
            item(sub, "Close Pane\tCtrl+Alt+W", .closePane, enabled: terminal && split)
            item(sub, "Select Next Pane\tCtrl+Alt+Right", .nextPane, enabled: terminal && split)
            item(sub, "Select Previous Pane\tCtrl+Alt+Left", .previousPane, enabled: terminal && split)
            divider(sub)
            item(sub, "MultiExec\tCtrl+Shift+M", .multiExec, checked: workspace.multiExec)
            item(sub, "Run Command on Hosts…", .runOnHosts, enabled: false)
            item(sub, "New Remote Connection…", .newRemoteConnection)
            item(sub, "Disconnect", .disconnect, enabled: pane?.isConnected ?? false)
            divider(sub)
            item(sub, "Show Previous Tab\tCtrl+Page Up", .previousTab, enabled: workspace.tabNames.count > 1)
            item(sub, "Show Next Tab\tCtrl+Page Down", .nextTab, enabled: workspace.tabNames.count > 1)
            item(sub, "Rename Tab…\tCtrl+Shift+I", .renameTab)
            item(sub, "Move Tab Left\tCtrl+Shift+Page Up", .moveTabLeft, enabled: workspace.activeIndex > 0)
            item(sub, "Move Tab Right\tCtrl+Shift+Page Down", .moveTabRight, enabled: workspace.activeIndex < workspace.tabNames.count - 1)
            divider(sub)
            item(sub, "Clear to Start\tCtrl+Shift+L", .clearToStart)
            item(sub, "Clear Scrollback\tCtrl+Alt+K", .clearScrollback)
            item(sub, "Reset\tCtrl+Alt+R", .reset)
            item(sub, "Hard Reset\tCtrl+Alt+Shift+R", .hardReset)
        }
        item(menu, "Toggle Full Screen\tF11", .fullScreen)
        divider(menu)
        item(menu, "Settings…\tCtrl+,", .settings)
        item(menu, "Manage Logins…", .manageLogins)
        item(menu, "About Herb's Terminal", .about)
        item(menu, "Quit\tCtrl+Shift+Q", .quit)

        return track(menu, UINT(TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RIGHTBUTTON), point, owner)
    }

    /// A small menu of `items` (title, command) at `point`; returns the chosen command.
    static func popUp(_ items: [(String, MenuCommand?)], at point: POINT, owner: HWND) -> MenuCommand? {
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        for (title, command) in items {
            if let command {
                withWide(title) { _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(command.rawValue), $0) }
            } else {
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            }
        }
        return MenuCommand(rawValue: track(menu, UINT(TPM_RETURNCMD | TPM_RIGHTBUTTON), point, owner))
    }

    /// Shows `menu` at `point` and returns the chosen command id (0 for none).
    static func trackPopup(_ menu: HMENU?, at point: POINT, owner: HWND, rightAligned: Bool = false) -> UINT {
        track(menu, UINT(TPM_RETURNCMD | TPM_RIGHTBUTTON | (rightAligned ? TPM_RIGHTALIGN : TPM_LEFTALIGN)), point, owner)
    }

    private typealias TrackPopupMenuExFunction = @convention(c) (HMENU?, UINT, Int32, Int32, HWND?, UnsafeMutableRawPointer?) -> Int32

    /// TrackPopupMenuEx with TPM_RETURNCMD returns the chosen command's id in its BOOL. Swift imports that BOOL as a
    /// Bool, which loses the id, so the function is called through a pointer typed to return the plain integer.
    private static func track(_ menu: HMENU?, _ flags: UINT, _ point: POINT, _ owner: HWND) -> UINT {
        guard let user32 = withWide("user32.dll", { GetModuleHandleW($0) }),
              let address = GetProcAddress(user32, "TrackPopupMenuEx") else { return 0 }
        let function = unsafeBitCast(address, to: TrackPopupMenuExFunction.self)
        return UINT(bitPattern: function(menu, flags, point.x, point.y, owner, nil))
    }
}

/// Lets menus, scroll bars and hints follow the app's dark mode. Windows has no public switch for menus; this uses
/// the same uxtheme entry points Windows Terminal and File Explorer use, and does nothing if they're missing.
enum DarkMenus {
    private typealias SetPreferredAppMode = @convention(c) (Int32) -> Int32
    private typealias FlushMenuThemes = @convention(c) () -> Void

    static func apply(dark: Bool) {
        guard let uxtheme = withWide("uxtheme.dll", { LoadLibraryW($0) }) else { return }
        // Ordinals 135 (SetPreferredAppMode) and 136 (FlushMenuThemes), present since Windows 10 1903.
        if let set = GetProcAddress(uxtheme, UnsafePointer<CChar>(bitPattern: 135)) {
            _ = unsafeBitCast(set, to: SetPreferredAppMode.self)(dark ? 2 : 3) // ForceDark : ForceLight
        }
        if let flush = GetProcAddress(uxtheme, UnsafePointer<CChar>(bitPattern: 136)) {
            unsafeBitCast(flush, to: FlushMenuThemes.self)()
        }
    }
}
