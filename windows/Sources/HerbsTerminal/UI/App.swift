import Foundation
import WinSDK

/// Start-up and the message loop.
@MainActor
enum App {
    private static var workspaces: [Workspace] = []

    static func run() {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        SetCurrentProcessExplicitAppUserModelID(withWide("HerbsTerminal.App") { UnsafeMutablePointer(mutating: $0) })
        registerClass(Workspace.className)
        registerClass(TerminalPane.className, style: UINT(CS_DBLCLKS))
        registerClass(SettingsWindow.className, background: GetSysColorBrush(COLOR_WINDOW))
        newWindow()

        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if let workspace = workspace(for: message.hwnd), workspace.shortcut(message) { continue }
            if SettingsWindow.dialogMessage(&message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        // Quit: end every shell, then leave without waiting for the reader threads blocked on their pipes.
        for workspace in workspaces { workspace.closeAll() }
        workspaces.removeAll()
        ExitProcess(UINT(message.wParam))
    }

    static func newWindow() {
        workspaces.append(Workspace())
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
