import Foundation
import WinSDK

/// Start-up and the message loop.
@MainActor
enum App {
    private static var workspaces: [Workspace] = []
    /// The open main windows, for the feature tests' bridge.
    static var allWorkspaces: [Workspace] { workspaces }

    static func run() {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        SetCurrentProcessExplicitAppUserModelID(withWide("HerbsTerminal.App") { UnsafeMutablePointer(mutating: $0) })
        registerClass(Workspace.className)
        registerClass(TerminalPane.className, style: UINT(CS_DBLCLKS))
        registerClass(SettingsWindow.className, background: GetSysColorBrush(COLOR_WINDOW))
        registerClass(FormDialog.className, background: GetSysColorBrush(COLOR_WINDOW))
        registerClass(ManageLoginsWindow.className, background: GetSysColorBrush(COLOR_WINDOW))
        registerClass(ExplorerPane.className, style: UINT(CS_DBLCLKS))
        registerClass(TextEditorPane.className)
        registerClass(GetInfoWindow.className, background: GetSysColorBrush(COLOR_WINDOW))
        registerClass(RunOnHostsWindow.className, background: GetSysColorBrush(COLOR_WINDOW))
        registerClass(TailcatPeersWindow.className, background: GetSysColorBrush(COLOR_WINDOW))
        // The folder picker and other shell dialogs need COM on this thread.
        CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue | COINIT_DISABLE_OLE1DDE.rawValue))
        registerClass(MainThread.className)
        MainThread.start()
        DarkMenus.apply(dark: appIsDark)
        SSHLauncher.sweep()
        // The last session's windows, when Settings asks for that; otherwise one new window.
        let saved = ParityScene.isActive || TestScript.active || !TerminalProfile.shared.restoreSession
            ? [] : SavedSession.read().filter { !$0.tabs.isEmpty }
        if saved.isEmpty { newWindow() } else { for window in saved { workspaces.append(Workspace(restoring: window)) } }
        TestBridge.start()

        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if let workspace = workspace(for: message.hwnd), workspace.shortcut(message) { continue }
            if SettingsWindow.dialogMessage(&message) { continue }
            if let logins = ManageLoginsWindow.openWindow, IsDialogMessageW(logins, &message) { continue }
            if let peers = TailcatPeersWindow.open, peers.dialogMessage(&message) { continue }
            if let hosts = RunOnHostsWindow.open, let window = hosts.hwnd, hosts.handleKey(message) || IsDialogMessageW(window, &message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        // Quit: end every shell, then leave without waiting for the reader threads blocked on their pipes.
        for workspace in workspaces { workspace.closeAll() }
        workspaces.removeAll()
        ExitProcess(UINT(message.wParam))
    }

    static func newWindow(restoring saved: SavedWindow? = nil) {
        workspaces.append(Workspace(restoring: saved))
    }

    /// Quit: asks each window to close (each asks first if shells are running); stops at the first that stays.
    /// Set while Quit closes the windows one by one, after the session was saved with all of them.
    private(set) static var isQuitting = false

    static func quit() {
        Workspace.saveSession()
        // Sharing this PC over Tailcat stops when the app quits.
        TailcatShare.shared.stop()
        isQuitting = true
        defer { isQuitting = false }
        for workspace in workspaces {
            guard let hwnd = workspace.hwnd else { continue }
            SendMessageW(hwnd, UINT(WM_CLOSE), 0, 0)
            if workspace.hwnd != nil { return }
        }
    }

    static func windowClosed(_ workspace: Workspace) {
        workspaces.removeAll { $0 === workspace }
        if workspaces.isEmpty { PostQuitMessage(0) }
    }

    private static func workspace(for hwnd: HWND?) -> Workspace? {
        guard let hwnd, let root = GetAncestor(hwnd, UINT(GA_ROOT)) else { return nil }
        return workspaces.first { $0.hwnd == root }
    }
}
