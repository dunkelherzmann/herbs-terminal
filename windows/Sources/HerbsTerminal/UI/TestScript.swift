import Foundation
import WinSDK

/// Scripted runs for checking the app without touching the desktop:
///
///   HerbsTerminal.exe --type "dir\r" --type "exit\r" --capture C:\shot.bmp
///
/// Steps run 1.5 s apart, in order:
/// - `--type TEXT` sends TEXT straight to the active terminal (`\r` is Enter, `\e` Escape). Special values:
///   `\t` opens a new tab, `\s` Settings, `\k` Connect via SSH, `\l` Manage Logins, and `\f` followed by
///   `value|value|…#button` fills the open dialog's fields and presses that button (by position).
/// - `--ssh user@host:port` opens an SSH tab directly; `--ssh-password` before it gives the password.
/// - `--capture FILE` saves the main window (and any open Settings, Manage Logins or dialog beside it) as BMPs
///   and quits.
/// The window opens without taking focus, and nothing is typed into other windows.
@MainActor
enum TestScript {
    static let timer: UINT_PTR = 0x7E57
    private static var steps: [Step] = parse(CommandLine.arguments)
    static var active: Bool { !steps.isEmpty }

    private enum Step {
        case type(String), newTab, settings, connect, logins, form([String], Int), ssh(SSHLogin), capture(String)
    }

    private static func parse(_ arguments: [String]) -> [Step] {
        var steps: [Step] = [], capture: String?, password = ""
        var index = 1
        while index < arguments.count - 1 {
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--type":
                switch value {
                case "\\t": steps.append(.newTab)
                case "\\s": steps.append(.settings)
                case "\\k": steps.append(.connect)
                case "\\l": steps.append(.logins)
                default:
                    if value.hasPrefix("\\f") {
                        let body = String(value.dropFirst(2))
                        let parts = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                        let fields = parts[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        steps.append(.form(fields, parts.count > 1 ? Int(parts[1]) ?? 0 : 0))
                    } else {
                        steps.append(.type(value.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}")))
                    }
                }
            case "--ssh-password": password = value
            case "--ssh":
                let target = value.split(separator: "@", maxSplits: 1).map(String.init)
                let hostPort = (target.last ?? "").split(separator: ":").map(String.init)
                steps.append(.ssh(SSHLogin(host: hostPort.first ?? "", port: hostPort.count > 1 ? Int(hostPort[1]) ?? 22 : 22,
                                           username: target.count > 1 ? target[0] : "", password: password)))
            case "--capture": capture = value
            default: index -= 1
            }
            index += 2
        }
        if let capture { steps.append(.capture(capture)) }
        return steps
    }

    /// Runs the next step; false when there are none left. A step that opens a modal dialog returns only when the
    /// dialog closes, so later steps run from inside the dialog's own message loop.
    static func step(_ workspace: Workspace) -> Bool {
        guard !steps.isEmpty else { return false }
        switch steps.removeFirst() {
        case .type(let text): workspace.activePane?.send(text)
        case .newTab: workspace.newTab()
        case .settings: workspace.showSettings()
        case .connect: workspace.showConnect()
        case .logins: workspace.showLogins()
        case .form(let values, let button): FormDialog.current?.scripted(values: values, button: button)
        case .ssh(let login): workspace.connectSSH(login)
        case .capture(let path):
            let base = (path as NSString).deletingPathExtension
            if let hwnd = workspace.hwnd { capture(hwnd, to: path) }
            if let settings = SettingsWindow.openWindow { capture(settings, to: base + "-settings.bmp") }
            if let logins = ManageLoginsWindow.openWindow { capture(logins, to: base + "-logins.bmp") }
            if let dialog = FormDialog.current?.window { capture(dialog, to: base + "-dialog.bmp") }
            PostQuitMessage(0)
        }
        return !steps.isEmpty
    }

    /// Saves the window as a 32-bit BMP, drawn by PrintWindow (works while the window is behind others).
    private static func capture(_ hwnd: HWND, to path: String) {
        var rect = RECT()
        GetWindowRect(hwnd, &rect)
        let width = rect.right - rect.left, height = rect.bottom - rect.top
        let screen = GetDC(nil)
        let dc = CreateCompatibleDC(screen)
        let bitmap = CreateCompatibleBitmap(screen, width, height)
        let old = SelectObject(dc, bitmap)
        PrintWindow(hwnd, dc, 2) // PW_RENDERFULLCONTENT
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var pixels = [UInt8](repeating: 0, count: Int(width * height * 4))
        GetDIBits(dc, bitmap, 0, UINT(height), &pixels, &info, UINT(DIB_RGB_COLORS))
        SelectObject(dc, old)
        DeleteObject(bitmap)
        DeleteDC(dc)
        ReleaseDC(nil, screen)

        // A plain 32-bit BMP: 14-byte file header, 40-byte info header, then top-down rows.
        var file = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        file.append(contentsOf: [0x42, 0x4D])
        le(UInt32(54 + pixels.count)); le(UInt32(0)); le(UInt32(54))
        le(UInt32(40)); le(Int32(width)); le(Int32(-height)); le(UInt16(1)); le(UInt16(32))
        le(UInt32(0)); le(UInt32(pixels.count)); le(Int32(2835)); le(Int32(2835)); le(UInt32(0)); le(UInt32(0))
        file.append(contentsOf: pixels)
        try? file.write(to: URL(fileURLWithPath: path))
    }
}
