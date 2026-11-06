import Foundation
import WinSDK

/// Scripted runs for checking the app without touching the desktop:
///
///   HerbsTerminal.exe --type "dir\r" --type "exit\r" --capture C:\shot.bmp
///
/// Each `--type` goes straight to the active terminal 1.5 s apart (`\r` is Enter, `\e` is Escape, `\t` alone
/// opens a new tab); `--capture` then saves the window as a BMP and quits. The window opens without taking focus,
/// and nothing is typed into other windows.
@MainActor
enum TestScript {
    static let timer: UINT_PTR = 0x7E57
    private static var steps: [Step] = parse(CommandLine.arguments)
    static var active: Bool { !steps.isEmpty }

    private enum Step {
        case type(String), newTab, capture(String)
    }

    private static func parse(_ arguments: [String]) -> [Step] {
        var steps: [Step] = [], capture: String?
        var index = 1
        while index < arguments.count - 1 {
            switch arguments[index] {
            case "--type":
                let text = arguments[index + 1]
                if text == "\\t" { steps.append(.newTab) } else {
                    steps.append(.type(text.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}")))
                }
            case "--capture": capture = arguments[index + 1]
            default: index -= 1
            }
            index += 2
        }
        if let capture { steps.append(.capture(capture)) }
        return steps
    }

    /// Runs the next step; false when there are none left.
    static func step(_ workspace: Workspace) -> Bool {
        guard !steps.isEmpty else { return false }
        switch steps.removeFirst() {
        case .type(let text): workspace.activePane?.send(text)
        case .newTab: workspace.newTab()
        case .capture(let path):
            if let hwnd = workspace.hwnd { capture(hwnd, to: path) }
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
