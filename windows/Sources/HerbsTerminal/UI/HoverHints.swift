import Foundation
import WinSDK

/// Hover hints for parts of a window that are drawn rather than child controls: each is a rectangle with its text
/// (what it is, its shortcut, what it does), shown after about half a second as on the Mac and Linux.
@MainActor
final class HoverHints {
    private var tooltip: HWND?
    private var ids: [UINT_PTR] = []
    private var signature = ""

    /// The hint of a child control (a button, checkbox or field): the control itself gets the mouse, so a hint on
    /// the window's rectangle under it would never show.
    func set(_ control: HWND?, _ text: String, owner: HWND) {
        guard let control else { return }
        makeTooltip(owner)
        var units = text.wide
        units.withUnsafeMutableBufferPointer { pointer in
            var info = TTTOOLINFOW()
            info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
            info.uFlags = UINT(TTF_IDISHWND | TTF_SUBCLASS)
            info.hwnd = owner
            info.uId = UINT_PTR(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(control))))
            info.lpszText = pointer.baseAddress
            // Adding a control again replaces nothing, so its text is updated instead.
            if controls.contains(info.uId) {
                _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_UPDATETIPTEXTW), 0, LPARAM(Int(bitPattern: $0))) }
            } else {
                _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_ADDTOOLW), 0, LPARAM(Int(bitPattern: $0))) }
                controls.insert(info.uId)
            }
        }
    }

    private var controls = Set<UINT_PTR>()

    private func makeTooltip(_ owner: HWND) {
        guard tooltip == nil else { return }
        tooltip = withWide("tooltips_class32") {
            CreateWindowExW(DWORD(WS_EX_TOPMOST), $0, nil, DWORD(WS_POPUP) | DWORD(TTS_ALWAYSTIP) | DWORD(TTS_NOPREFIX),
                            CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, owner, nil, GetModuleHandleW(nil), nil)
        }
        SendMessageW(tooltip, UINT(TTM_SETMAXTIPWIDTH), 0, LPARAM(scaled(340, dpi: GetDpiForWindow(owner))))
        SendMessageW(tooltip, UINT(TTM_SETDELAYTIME), WPARAM(TTDT_INITIAL), 500)
        SendMessageW(tooltip, UINT(TTM_SETDELAYTIME), WPARAM(TTDT_AUTOPOP), 12_000)
        if appIsDark { withWide("DarkMode_Explorer") { _ = SetWindowTheme(tooltip, $0, nil) } }
    }

    /// Replaces the hints of `owner` with `entries`; nothing is redone while they haven't changed.
    func update(owner: HWND, _ entries: [(id: UINT_PTR, rect: RECT, text: String)]) {
        if tooltip == nil {
            tooltip = withWide("tooltips_class32") {
                CreateWindowExW(DWORD(WS_EX_TOPMOST), $0, nil, DWORD(WS_POPUP) | DWORD(TTS_ALWAYSTIP) | DWORD(TTS_NOPREFIX),
                                CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, owner, nil, GetModuleHandleW(nil), nil)
            }
            SendMessageW(tooltip, UINT(TTM_SETMAXTIPWIDTH), 0, LPARAM(scaled(340, dpi: GetDpiForWindow(owner))))
            SendMessageW(tooltip, UINT(TTM_SETDELAYTIME), WPARAM(TTDT_INITIAL), 500)
            SendMessageW(tooltip, UINT(TTM_SETDELAYTIME), WPARAM(TTDT_AUTOPOP), 12_000)
        }
        let key = entries.map { "\($0.id):\($0.rect.left),\($0.rect.top),\($0.rect.right),\($0.rect.bottom):\($0.text)" }.joined(separator: "|")
        guard key != signature else { return }
        signature = key
        if appIsDark { withWide("DarkMode_Explorer") { _ = SetWindowTheme(tooltip, $0, nil) } }
        for id in ids {
            var info = TTTOOLINFOW()
            info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
            info.hwnd = owner
            info.uId = id
            _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_DELTOOLW), 0, LPARAM(Int(bitPattern: $0))) }
        }
        ids = []
        for entry in entries {
            var units = entry.text.wide
            units.withUnsafeMutableBufferPointer { pointer in
                var info = TTTOOLINFOW()
                info.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
                info.uFlags = UINT(TTF_SUBCLASS)
                info.hwnd = owner
                info.uId = entry.id
                info.rect = entry.rect
                info.lpszText = pointer.baseAddress
                _ = withUnsafeMutablePointer(to: &info) { SendMessageW(tooltip, UINT(TTM_ADDTOOLW), 0, LPARAM(Int(bitPattern: $0))) }
            }
            ids.append(entry.id)
        }
    }

    func release() {
        if let tooltip { DestroyWindow(tooltip) }
        tooltip = nil
        controls = []
    }
}

/// The Open dialog for several files; returns their paths.
@MainActor
func openFiles(owner: HWND?, title: String, filter: [(String, String)] = [("All files (*.*)", "*.*")]) -> [String] {
    var buffer = [WCHAR](repeating: 0, count: 65_536)
    var filterUnits: [WCHAR] = []
    for (name, pattern) in filter { filterUnits += Array(name.utf16) + [0] + Array(pattern.utf16) + [0] }
    filterUnits.append(0)
    return filterUnits.withUnsafeBufferPointer { (filterPointer: UnsafeBufferPointer<WCHAR>) -> [String] in
        withWide(title) { titlePointer in
            buffer.withUnsafeMutableBufferPointer { file in
                var dialog = OPENFILENAMEW()
                dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
                dialog.hwndOwner = owner
                dialog.lpstrFilter = filterPointer.baseAddress
                dialog.lpstrFile = file.baseAddress
                dialog.nMaxFile = DWORD(file.count)
                dialog.lpstrTitle = titlePointer
                dialog.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_ALLOWMULTISELECT)
                guard GetOpenFileNameW(&dialog) else { return [] }
                // One file: its full path. Several: the folder, then each name, NUL-separated, ending with two NULs.
                var parts: [String] = []
                var start = 0
                for index in 0..<file.count where file[index] == 0 {
                    if index == start { break }
                    parts.append(String(decoding: file[start..<index], as: UTF16.self))
                    start = index + 1
                }
                guard parts.count > 1 else { return parts }
                let folder = parts[0]
                return parts.dropFirst().map { folder.hasSuffix("\\") ? folder + $0 : folder + "\\" + $0 }
            }
        }
    }
}

/// Windows' folder picker; returns the chosen folder's path.
@MainActor
func chooseFolder(owner: HWND?, title: String) -> String? {
    var display = [WCHAR](repeating: 0, count: Int(MAX_PATH))
    return withWide(title) { titlePointer in
        display.withUnsafeMutableBufferPointer { name in
            var info = BROWSEINFOW()
            info.hwndOwner = owner
            info.pszDisplayName = name.baseAddress
            info.lpszTitle = titlePointer
            info.ulFlags = UINT(BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE)
            guard let list = SHBrowseForFolderW(&info) else { return nil }
            defer { CoTaskMemFree(UnsafeMutableRawPointer(list)) }
            var path = [WCHAR](repeating: 0, count: 32_768)
            guard SHGetPathFromIDListEx(list, &path, DWORD(path.count), 0) else { return nil }
            return String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
        }
    }
}
