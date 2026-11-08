import Foundation
import WinSDK

/// One tab's file explorer for this PC, laid out as on the Mac and Linux (Thunar's design): places on the left, a
/// location bar with back, forward, up, home, the editable location and File Actions, the file list, and a status
/// line. File operations go through the Windows shell, so Copy / Cut / Paste work with File Explorer in both
/// directions, Delete uses the Recycle Bin, and name clashes get new names instead of overwriting.
@MainActor
final class ExplorerPane: WindowObject {
    static let className = "HerbsTerminalExplorer"

    private(set) var hwnd: HWND?
    private var list: HWND?
    private var location: HWND?
    private var fonts: (ui: HFONT?, glyph: HFONT?, heading: HFONT?) = (nil, nil, nil)
    private(set) var folder: String
    private var history: [String] = []
    private var future: [String] = []
    private var entries: [FileEntry] = []
    private var showHidden = false
    private var sort: (column: Int, ascending: Bool) = (0, true)
    private var hover: BarItem?
    private var trackingMouse = false
    private var places: [(section: String, items: [Place])] = []
    private var placeRects: [(RECT, Place)] = []
    private var status = ""
    /// Whether `status` reports a problem (drawn in red) or just news, such as "1 item copied".
    private var statusIsError = false
    /// A rename waiting for the in-place edit box to close.
    private var pendingRename: (row: Int, name: String)?

    /// Asks the workspace to open a new tab whose shell starts in a folder.
    var onOpenInTerminal: ((String) -> Void)?
    /// Tells the workspace the location changed (for the toolbar title).
    var onLocationChange: (() -> Void)?

    struct Place {
        let name: String
        let path: String
        let glyph: String
    }

    private enum BarItem: Hashable {
        case back, forward, up, home, actions
    }

    private enum Command: UINT {
        case open = 3100, openInTerminal, openWith, cut, copy, paste, copyPath, rename, delete, deletePermanently
        case properties, showInFileExplorer, newFolder, newFile, showHidden, reload, selectAll, folderProperties
    }

    init(parent: HWND, start: String) {
        folder = start
        hwnd = createWindow(self, className: Self.className, style: DWORD(WS_CHILD) | DWORD(WS_CLIPCHILDREN), parent: parent)
        guard let hwnd else { return }
        var controls = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_LISTVIEW_CLASSES))
        InitCommonControlsEx(&controls)
        makeFonts()
        location = withWide("EDIT") { cls in
            CreateWindowExW(0, cls, nil, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(ES_AUTOHSCROLL) | DWORD(WS_TABSTOP),
                            0, 0, 10, 10, hwnd, HMENU(bitPattern: 1), GetModuleHandleW(nil), nil)
        }
        SendMessageW(location, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(fonts.ui)))), 1)
        list = withWide(WC_LISTVIEWW_NAME) { cls in
            CreateWindowExW(0, cls, nil, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(WS_TABSTOP) | DWORD(LVS_REPORT) |
                            DWORD(LVS_SHOWSELALWAYS) | DWORD(LVS_EDITLABELS) | DWORD(LVS_SHAREIMAGELISTS),
                            0, 0, 10, 10, hwnd, HMENU(bitPattern: 2), GetModuleHandleW(nil), nil)
        }
        SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE), 0, LPARAM(LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_HEADERDRAGDROP))
        SendMessageW(list, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(fonts.ui)))), 1)
        // Windows' own file icons, from the shell's system image list.
        var info = SHFILEINFOW()
        let images = withWide("C:\\") {
            SHGetFileInfoW($0, DWORD(FILE_ATTRIBUTE_DIRECTORY), &info, UINT(MemoryLayout<SHFILEINFOW>.size),
                           UINT(SHGFI_SYSICONINDEX | SHGFI_SMALLICON | SHGFI_USEFILEATTRIBUTES))
        }
        SendMessageW(list, UINT(LVM_SETIMAGELIST), WPARAM(LVSIL_SMALL), LPARAM(Int(bitPattern: UInt(images))))
        let dpi = GetDpiForWindow(hwnd)
        for (index, column) in [("Name", 340.0), ("Date modified", 150.0), ("Type", 160.0), ("Size", 90.0)].enumerated() {
            var item = LVCOLUMNW()
            item.mask = UINT(LVCF_TEXT | LVCF_WIDTH | LVCF_FMT)
            item.fmt = Int32(index == 3 ? LVCFMT_RIGHT : LVCFMT_LEFT)
            item.cx = scaled(column.1, dpi: dpi)
            var title = column.0.wide
            title.withUnsafeMutableBufferPointer { pointer in
                item.pszText = pointer.baseAddress
                _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: $0))) }
            }
        }
        HeaderColors.attach(to: list)
        applyTheme()
        places = Self.standardPlaces()
        navigate(to: start, record: false)
    }

    func close() {
        if let hwnd { DestroyWindow(hwnd) }
        hwnd = nil
        for font in [fonts.ui, fonts.glyph, fonts.heading] where font != nil { DeleteObject(font) }
    }

    func show(_ visible: Bool) {
        guard let hwnd else { return }
        ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE)
        if visible { SetFocus(list) }
    }

    func move(to rect: RECT) {
        guard let hwnd else { return }
        MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, true)
    }

    /// The folder's name for the toolbar title, and its full path for the location beside it.
    var title: String {
        let name = (folder as NSString).lastPathComponent
        return name.isEmpty || name == "\\" ? folder : name
    }

    // MARK: Look

    private var colors: WindowChrome.Colors { WindowChrome.Colors(dark: appIsDark) }

    private func makeFonts() {
        guard let hwnd else { return }
        let dpi = GetDpiForWindow(hwnd)
        func font(_ face: String, _ pixels: Double, _ weight: Int32) -> HFONT? {
            withWide(face) { CreateFontW(-scaled(pixels, dpi: dpi), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0) }
        }
        let face = FontSet.isInstalledAny("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI"
        let icons = FontSet.isInstalledAny("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
        fonts = (font(face, 13, Int32(FW_NORMAL)), font(icons, 14, Int32(FW_NORMAL)), font(face, 11, Int32(FW_SEMIBOLD)))
    }

    /// Light or dark like the rest of the window; the list and its header use Windows' own dark theme.
    func applyTheme() {
        let colors = self.colors
        let dark = appIsDark
        withWide(dark ? "DarkMode_ItemsView" : "ItemsView") { _ = SetWindowTheme(list, $0, nil) }
        let header = HWND(bitPattern: Int(SendMessageW(list, UINT(LVM_GETHEADER), 0, 0)))
        withWide(dark ? "DarkMode_ItemsView" : "ItemsView") { _ = SetWindowTheme(header, $0, nil) }
        let background = dark ? colorRef(28, 28, 28) : colorRef(255, 255, 255)
        SendMessageW(list, UINT(LVM_SETBKCOLOR), 0, LPARAM(background))
        SendMessageW(list, UINT(LVM_SETTEXTBKCOLOR), 0, LPARAM(background))
        SendMessageW(list, UINT(LVM_SETTEXTCOLOR), 0, LPARAM(colors.text))
        HeaderColors.text = colors.text
        withWide(dark ? "DarkMode_CFD" : "CFD") { _ = SetWindowTheme(location, $0, nil) }
        if let hwnd { InvalidateRect(hwnd, nil, true) }
        if let list { InvalidateRect(list, nil, true) }
    }

    // MARK: Layout

    private var dpi: UINT { hwnd.map { GetDpiForWindow($0) } ?? 96 }
    private var placesWidth: Int32 { scaled(190, dpi: dpi) }
    private var barHeight: Int32 { scaled(40, dpi: dpi) }
    private var statusHeight: Int32 { scaled(24, dpi: dpi) }

    private var barRects: [BarItem: RECT] {
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        var rects: [BarItem: RECT] = [:]
        var x = placesWidth + s(8)
        let top = (barHeight - s(28)) / 2
        for item in [BarItem.back, .forward, .up, .home] {
            rects[item] = RECT(left: x, top: top, right: x + s(30), bottom: top + s(28))
            x += s(34)
        }
        var client = RECT()
        if let hwnd { GetClientRect(hwnd, &client) }
        rects[.actions] = RECT(left: client.right - s(8) - s(30), top: top, right: client.right - s(8), bottom: top + s(28))
        return rects
    }

    private func layout() {
        guard let hwnd else { return }
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let bar = barRects
        let left = (bar[.home]?.right ?? 0) + s(8), right = (bar[.actions]?.left ?? client.right) - s(8)
        MoveWindow(location, left, (barHeight - s(26)) / 2, max(10, right - left), s(26), true)
        MoveWindow(list, placesWidth, barHeight, client.right - placesWidth, client.bottom - barHeight - statusHeight, true)
        InvalidateRect(hwnd, nil, false)
    }

    // MARK: Places

    /// Home and the user folders that exist, then This PC and every drive with its label.
    static func standardPlaces() -> [(section: String, items: [Place])] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path.windowsPath
        var mine = [Place(name: "Home", path: home, glyph: "\u{E80F}")]
        let known: [(String, String, String)] = [
            ("Desktop", "{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}", "\u{E7F4}"), ("Documents", "{FDD39AD0-238F-46AF-ADB4-6C85480369C7}", "\u{E8A5}"),
            ("Downloads", "{374DE290-123F-4565-9164-39C4925E467B}", "\u{E896}"), ("Music", "{4BD8D571-6D19-48D3-BE97-422220080E43}", "\u{E8D6}"),
            ("Pictures", "{33E28130-4E1E-4676-835A-98395C3BC3BB}", "\u{EB9F}"), ("Videos", "{18989B1D-99B5-455B-841C-AB7C74E4DDFC}", "\u{E714}"),
        ]
        for (name, id, glyph) in known {
            if let path = knownFolder(id), FileManager.default.fileExists(atPath: path) { mine.append(Place(name: name, path: path, glyph: glyph)) }
        }
        var devices: [Place] = []
        let mask = GetLogicalDrives()
        for index in 0..<26 where mask & (1 << index) != 0 {
            let root = String(UnicodeScalar(UInt8(65 + index))) + ":\\"
            var label = [WCHAR](repeating: 0, count: 261)
            let named = withWide(root) { GetVolumeInformationW($0, &label, DWORD(label.count), nil, nil, nil, nil, 0) }
            let volume = named ? String(decoding: label.prefix { $0 != 0 }, as: UTF16.self) : ""
            let type = withWide(root) { GetDriveTypeW($0) }
            let glyph = type == UINT(DRIVE_REMOVABLE) ? "\u{E88E}" : type == UINT(DRIVE_REMOTE) ? "\u{E8CE}" : "\u{EDA2}"
            devices.append(Place(name: (volume.isEmpty ? "Local Disk" : volume) + " (\(root.prefix(2)))", path: root, glyph: glyph))
        }
        return [("Places", mine), ("Devices", devices)]
    }

    private static func knownFolder(_ id: String) -> String? {
        var guid = GUID()
        guard withWide(id, { CLSIDFromString($0, &guid) }) >= 0 else { return nil }
        var path: PWSTR?
        guard SHGetKnownFolderPath(&guid, 0, nil, &path) >= 0, let path else { return nil }
        defer { CoTaskMemFree(path) }
        return String(wide: path)
    }

    // MARK: Listing

    struct FileEntry {
        var name: String
        var path: String
        var isFolder: Bool
        var isHidden: Bool
        var size: UInt64
        var modified: FILETIME
        var attributes: DWORD
    }

    /// Lists `folder` with FindFirstFileEx, skipping "." and "..".
    static func list(_ folder: String) throws -> [FileEntry] {
        var data = WIN32_FIND_DATAW()
        let pattern = folder.hasSuffix("\\") ? folder + "*" : folder + "\\*"
        let handle = withWide(pattern) {
            FindFirstFileExW($0, FindExInfoBasic, &data, FindExSearchNameMatch, nil, DWORD(FIND_FIRST_EX_LARGE_FETCH))
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw FileIssue(Self.describe(GetLastError(), folder))
        }
        defer { FindClose(handle) }
        var result: [FileEntry] = []
        repeat {
            let name = withUnsafeBytes(of: data.cFileName) { raw in
                String(decoding: raw.bindMemory(to: WCHAR.self).prefix { $0 != 0 }, as: UTF16.self)
            }
            guard name != ".", name != ".." else { continue }
            let attributes = data.dwFileAttributes
            let path = folder.hasSuffix("\\") ? folder + name : folder + "\\" + name
            result.append(FileEntry(name: name, path: path, isFolder: attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
                                    isHidden: attributes & DWORD(FILE_ATTRIBUTE_HIDDEN) != 0 || name.hasPrefix("."),
                                    size: UInt64(data.nFileSizeHigh) << 32 | UInt64(data.nFileSizeLow),
                                    modified: data.ftLastWriteTime, attributes: attributes))
        } while FindNextFileW(handle, &data)
        return result
    }

    private static func describe(_ error: DWORD, _ folder: String) -> String {
        switch Int32(error) {
        case ERROR_ACCESS_DENIED: "You don't have permission to see the contents of “\(folder)”."
        case ERROR_PATH_NOT_FOUND, ERROR_FILE_NOT_FOUND, ERROR_INVALID_NAME: "“\(folder)” doesn't exist."
        case ERROR_NOT_READY: "The drive “\(folder.prefix(2))” isn't ready."
        default: "“\(folder)” couldn't be opened (error \(error))."
        }
    }

    func navigate(to path: String, record: Bool = true) {
        let target = Self.fullPath(path)
        do {
            let found = try Self.list(target)
            if record, target != folder {
                history.append(folder)
                if history.count > 100 { history.removeFirst() }
                future.removeAll()
            }
            folder = target
            entries = found
            status = ""
        } catch {
            status = error.localizedDescription
            statusIsError = true
            if let hwnd { InvalidateRect(hwnd, nil, false) }
            if record { MessageBeep(UINT(MB_ICONWARNING)) }
        }
        withWide(folder) { _ = SetWindowTextW(location, $0) }
        refill(keepSelection: false)
        onLocationChange?()
    }

    func reload() {
        status = ""
        let selected = selectedEntries.map(\.name)
        if let found = try? Self.list(folder) { entries = found }
        refill(keepSelection: false, select: Set(selected))
    }

    private var shown: [FileEntry] {
        let visible = showHidden ? entries : entries.filter { !$0.isHidden }
        return visible.sorted { a, b in
            // Folders first, then the chosen column, names compared the way File Explorer does ("file2" < "file10").
            if a.isFolder != b.isFolder { return a.isFolder }
            let order: Bool
            switch sort.column {
            case 1: order = CompareFileTime([a.modified], [b.modified]) < 0
            case 2: order = typeName(a).localizedStandardCompare(typeName(b)) == .orderedAscending
            case 3: order = a.size < b.size
            default: order = withWide(a.name) { x in withWide(b.name) { y in StrCmpLogicalW(x, y) < 0 } }
            }
            return sort.ascending ? order : !order
        }
    }

    private var rows: [FileEntry] = []

    private func refill(keepSelection: Bool, select: Set<String> = []) {
        rows = shown
        SendMessageW(list, UINT(WM_SETREDRAW), 0, 0)
        SendMessageW(list, UINT(LVM_DELETEALLITEMS), 0, 0)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        for (row, entry) in rows.enumerated() {
            var info = SHFILEINFOW()
            _ = withWide(entry.path) {
                SHGetFileInfoW($0, entry.attributes, &info, UINT(MemoryLayout<SHFILEINFOW>.size),
                               UINT(SHGFI_SYSICONINDEX | SHGFI_SMALLICON | SHGFI_USEFILEATTRIBUTES))
            }
            let cells = [entry.name, formatter.string(from: entry.modified.date), typeName(entry),
                         entry.isFolder ? "" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)]
            for (column, text) in cells.enumerated() {
                var item = LVITEMW()
                item.mask = UINT(LVIF_TEXT) | (column == 0 ? UINT(LVIF_IMAGE | LVIF_STATE) : 0)
                item.iItem = Int32(row)
                item.iSubItem = Int32(column)
                item.iImage = info.iIcon
                if column == 0, select.contains(entry.name) {
                    item.state = UINT(LVIS_SELECTED)
                    item.stateMask = UINT(LVIS_SELECTED)
                }
                if column == 0, entry.isHidden {
                    item.state |= UINT(LVIS_CUT) // Hidden items are drawn faded, as in File Explorer.
                    item.stateMask |= UINT(LVIS_CUT)
                }
                var units = text.wide
                units.withUnsafeMutableBufferPointer { pointer in
                    item.pszText = pointer.baseAddress
                    _ = withUnsafeMutablePointer(to: &item) {
                        SendMessageW(list, UINT(column == 0 ? LVM_INSERTITEMW : LVM_SETITEMW), 0, LPARAM(Int(bitPattern: $0)))
                    }
                }
            }
        }
        SendMessageW(list, UINT(WM_SETREDRAW), 1, 0)
        InvalidateRect(list, nil, true)
        if let hwnd { InvalidateRect(hwnd, nil, false) }
    }

    private var typeNames: [String: String] = [:]

    /// The type as File Explorer names it ("Text Document", "File folder").
    private func typeName(_ entry: FileEntry) -> String {
        let key = entry.isFolder ? "<folder>" : (entry.name as NSString).pathExtension.lowercased()
        if let cached = typeNames[key] { return cached }
        var info = SHFILEINFOW()
        _ = withWide(entry.isFolder ? "folder" : "file." + key) {
            SHGetFileInfoW($0, entry.isFolder ? DWORD(FILE_ATTRIBUTE_DIRECTORY) : DWORD(FILE_ATTRIBUTE_NORMAL), &info,
                           UINT(MemoryLayout<SHFILEINFOW>.size), UINT(SHGFI_TYPENAME | SHGFI_USEFILEATTRIBUTES))
        }
        let name = withUnsafeBytes(of: info.szTypeName) { String(decoding: $0.bindMemory(to: WCHAR.self).prefix { $0 != 0 }, as: UTF16.self) }
        typeNames[key] = name
        return name
    }

    private var selectedRows: [Int] {
        var result: [Int] = []
        var index = -1
        while true {
            index = Int(SendMessageW(list, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: Int64(index)), LPARAM(LVNI_SELECTED)))
            guard index >= 0 else { break }
            result.append(index)
        }
        return result
    }

    private var selectedEntries: [FileEntry] { selectedRows.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }

    // MARK: Navigation

    func goBack() {
        guard let previous = history.popLast() else { return }
        future.append(folder)
        navigate(to: previous, record: false)
    }

    func goForward() {
        guard let next = future.popLast() else { return }
        history.append(folder)
        navigate(to: next, record: false)
    }

    func goUp() {
        let parent = (folder as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != folder else { return }
        let previous = (folder as NSString).lastPathComponent
        navigate(to: parent)
        if let row = rows.firstIndex(where: { $0.name == previous }) { selectRow(row) }
    }

    func goHome() { navigate(to: FileManager.default.homeDirectoryForCurrentUser.path.windowsPath) }

    /// Location-field input: absolute, `~`-relative, or relative to the current folder; `.` and `..` resolve.
    static func resolve(_ input: String, from current: String, home: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "\\")
        guard !text.isEmpty else { return nil }
        if text == "~" || text.hasPrefix("~\\") { text = home + text.dropFirst() }
        let absolute = text.hasPrefix("\\\\") || (text.count >= 2 && text.dropFirst().first == ":")
        return fullPath(absolute ? text : (current.hasSuffix("\\") ? current : current + "\\") + text)
    }

    /// The canonical form of a path: `.` and `..` resolved, a drive root keeping its backslash.
    static func fullPath(_ path: String) -> String {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = withWide(path) { GetFullPathNameW($0, DWORD(buffer.count), &buffer, nil) }
        guard length > 0 else { return path }
        var result = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        if result.count > 3, result.hasSuffix("\\") { result.removeLast() }
        return result
    }

    private func selectRow(_ row: Int) {
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        item.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_SETITEMSTATE), WPARAM(row), LPARAM(Int(bitPattern: $0))) }
        SendMessageW(list, UINT(LVM_ENSUREVISIBLE), WPARAM(row), 0)
    }

    // MARK: Actions

    private func open(_ entry: FileEntry) {
        if entry.isFolder {
            navigate(to: entry.path)
        } else {
            let result = withWide("open") { verb in withWide(entry.path) { file in ShellExecuteW(hwnd, verb, file, nil, nil, SW_SHOWNORMAL) } }
            if Int(bitPattern: UnsafeRawPointer(result)) <= 32 {
                // No app is set for this type: let Windows ask which one to use.
                _ = withWide("openas") { verb in withWide(entry.path) { file in ShellExecuteW(hwnd, verb, file, nil, nil, SW_SHOWNORMAL) } }
            }
        }
    }

    private func perform(_ command: Command) {
        let selection = selectedEntries
        switch command {
        case .open: selection.forEach(open)
        case .openInTerminal: onOpenInTerminal?(selection.first(where: \.isFolder)?.path ?? folder)
        case .openWith:
            if let entry = selection.first {
                _ = withWide("openas") { verb in withWide(entry.path) { file in ShellExecuteW(hwnd, verb, file, nil, nil, SW_SHOWNORMAL) } }
            }
        case .cut, .copy:
            guard !selection.isEmpty else { return }
            ShellClipboard.put(selection.map(\.path), move: command == .cut, owner: hwnd)
            status = "\(selection.count) item\(selection.count == 1 ? "" : "s") \(command == .cut ? "cut" : "copied")"
            statusIsError = false
            if let hwnd { InvalidateRect(hwnd, nil, false) }
        case .paste: paste(into: folder)
        case .copyPath:
            setClipboardText((selection.isEmpty ? [folder] : selection.map(\.path)).joined(separator: "\r\n"), owner: hwnd)
        case .rename:
            if let row = selectedRows.first { SendMessageW(list, UINT(LVM_EDITLABELW), WPARAM(row), 0) }
        case .delete: delete(selection, permanently: false)
        case .deletePermanently: delete(selection, permanently: true)
        case .properties: for entry in selection { _ = withWide(entry.path) { SHObjectProperties(hwnd, DWORD(SHOP_FILEPATH), $0, nil) } }
        case .folderProperties: _ = withWide(folder) { SHObjectProperties(hwnd, DWORD(SHOP_FILEPATH), $0, nil) }
        case .showInFileExplorer:
            let argument = selection.first.map { "/select,\(quoteArgument($0.path))" } ?? quoteArgument(folder)
            _ = withWide("explorer.exe") { exe in withWide(argument) { args in ShellExecuteW(hwnd, nil, exe, args, nil, SW_SHOWNORMAL) } }
        case .newFolder: create(folder: true)
        case .newFile: create(folder: false)
        case .showHidden:
            showHidden.toggle()
            refill(keepSelection: true, select: Set(selection.map(\.name)))
        case .reload: reload()
        case .selectAll:
            var item = LVITEMW()
            item.stateMask = UINT(LVIS_SELECTED)
            item.state = UINT(LVIS_SELECTED)
            _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_SETITEMSTATE), WPARAM(bitPattern: -1), LPARAM(Int(bitPattern: $0))) }
        }
    }

    private func paste(into target: String) {
        guard let (paths, move) = ShellClipboard.get(owner: hwnd), !paths.isEmpty else { return }
        // A folder can't go into itself or anything inside it.
        let lowerTarget = target.lowercased() + "\\"
        if paths.contains(where: { lowerTarget.hasPrefix($0.lowercased() + "\\") }) {
            FormDialog.tell(owner: GetAncestor(hwnd, UINT(GA_ROOT)), title: "Can't paste a folder into itself",
                            message: "Choose a destination outside the folder you copied.")
            return
        }
        let names = paths.map { (($0 as NSString).lastPathComponent) }
        ShellOperation.run(move ? .move : .copy, paths, to: target, owner: hwnd)
        if move { ShellClipboard.clear(owner: hwnd) }
        reload()
        refill(keepSelection: false, select: Set(names))
    }

    private func delete(_ selection: [FileEntry], permanently: Bool) {
        guard !selection.isEmpty else { return }
        if permanently {
            let what = selection.count == 1 ? "“\(selection[0].name)”" : "\(selection.count) items"
            guard FormDialog.ask(owner: GetAncestor(hwnd, UINT(GA_ROOT)), title: "Delete \(what) permanently?",
                                 message: "They won't go to the Recycle Bin. This can't be undone.",
                                 buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Delete")]) == 1 else { return }
        }
        ShellOperation.run(permanently ? .deletePermanently : .recycle, selection.map(\.path), owner: hwnd)
        reload()
    }

    /// New Folder / New File: a free "untitled" name, then straight into renaming it.
    private func create(folder isFolder: Bool) {
        let name = FreeName.next(isFolder ? "untitled folder" : "untitled file", in: folder)
        let path = folder.hasSuffix("\\") ? folder + name : folder + "\\" + name
        let ok: Bool
        if isFolder {
            ok = withWide(path) { CreateDirectoryW($0, nil) }
        } else {
            let handle = withWide(path) { CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil) }
            ok = handle != INVALID_HANDLE_VALUE
            if ok { CloseHandle(handle) }
        }
        guard ok else {
            FormDialog.tell(owner: GetAncestor(hwnd, UINT(GA_ROOT)), title: "Couldn't create “\(name)”",
                            message: Self.describe(GetLastError(), folder))
            return
        }
        reload()
        if let row = rows.firstIndex(where: { $0.name == name }) {
            selectRow(row)
            SetFocus(list)
            SendMessageW(list, UINT(LVM_EDITLABELW), WPARAM(row), 0)
        }
    }

    private func finishRename(row: Int, to newName: String) {
        guard rows.indices.contains(row) else { return }
        let entry = rows[row]
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != entry.name else { return }
        if name.contains(where: { "\\/:*?\"<>|".contains($0) }) {
            FormDialog.tell(owner: GetAncestor(hwnd, UINT(GA_ROOT)), title: "“\(name)” isn't a valid name",
                            message: "Names can't contain any of these characters: \\ / : * ? \" < > |")
            return
        }
        let target = folder.hasSuffix("\\") ? folder + name : folder + "\\" + name
        if FileManager.default.fileExists(atPath: target), name.lowercased() != entry.name.lowercased() {
            FormDialog.tell(owner: GetAncestor(hwnd, UINT(GA_ROOT)), title: "“\(name)” already exists",
                            message: "Choose a different name; nothing is overwritten.")
            return
        }
        ShellOperation.run(.rename, [entry.path], to: target, owner: hwnd)
        reload()
        if let index = rows.firstIndex(where: { $0.name == name }) { selectRow(index) }
    }

    // MARK: Scripted runs

    /// For the test hook: selects the items with these names.
    func select(names: [String]) {
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_SELECTED)
        _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_SETITEMSTATE), WPARAM(bitPattern: -1), LPARAM(Int(bitPattern: $0))) }
        for (row, entry) in rows.enumerated() where names.contains(entry.name) { selectRow(row) }
    }

    /// For the test hook: runs a command by name (cut, copy, paste, delete, deletePermanently, newFolder, newFile,
    /// showHidden, reload, selectAll, up, back). Returns false for an unknown name.
    @discardableResult
    func perform(named name: String) -> Bool {
        switch name {
        case "up": goUp(); return true
        case "back": goBack(); return true
        default: break
        }
        let commands: [String: Command] = [
            "cut": .cut, "copy": .copy, "paste": .paste, "delete": .delete, "deletePermanently": .deletePermanently,
            "newFolder": .newFolder, "newFile": .newFile, "showHidden": .showHidden, "reload": .reload, "selectAll": .selectAll,
            "open": .open,
        ]
        guard let command = commands[name] else { return false }
        perform(command)
        return true
    }

    // MARK: Menus and keys

    private func contextMenu(at screen: POINT, onItem: Bool) {
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        func item(_ title: String, _ command: Command, enabled: Bool = true, checked: Bool = false) {
            var flags = UINT(MF_STRING)
            if !enabled { flags |= UINT(MF_GRAYED) }
            if checked { flags |= UINT(MF_CHECKED) }
            withWide(title) { _ = AppendMenuW(menu, flags, UINT_PTR(command.rawValue), $0) }
        }
        func divider() { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) }
        let selection = selectedEntries
        let canPaste = ShellClipboard.hasFiles
        if onItem, !selection.isEmpty {
            item("Open\tEnter", .open)
            if selection.count == 1 && !selection[0].isFolder { item("Open With…", .openWith) }
            if selection.count == 1 && selection[0].isFolder { item("Open in New Terminal Tab", .openInTerminal) }
            divider()
            item("Cut\tCtrl+X", .cut)
            item("Copy\tCtrl+C", .copy)
            item("Paste\tCtrl+V", .paste, enabled: canPaste)
            item("Copy Path", .copyPath)
            divider()
            item("Rename…\tF2", .rename, enabled: selection.count == 1)
            item("Move to Recycle Bin\tDelete", .delete)
            item("Delete Permanently…\tShift+Delete", .deletePermanently)
            divider()
            item("Show in File Explorer", .showInFileExplorer)
            item("Properties\tAlt+Enter", .properties)
        } else {
            item("New Folder\tCtrl+Shift+N", .newFolder)
            item("New File", .newFile)
            divider()
            item("Paste\tCtrl+V", .paste, enabled: canPaste)
            item("Open in New Terminal Tab", .openInTerminal)
            item("Copy Path", .copyPath)
            divider()
            item("Show Hidden Files\tCtrl+H", .showHidden, checked: showHidden)
            item("Reload\tF5", .reload)
            item("Show in File Explorer", .showInFileExplorer)
            item("Properties", .folderProperties)
        }
        guard let owner = hwnd else { return }
        let chosen = MainMenu.trackPopup(menu, at: screen, owner: owner)
        if let command = Command(rawValue: chosen) { perform(command) }
    }

    /// File Actions, the button at the end of the location bar (as on the Mac and Linux).
    private func fileActionsMenu() {
        guard let hwnd, let rect = barRects[.actions] else { return }
        var point = POINT(x: rect.right, y: rect.bottom + scaled(4, dpi: dpi))
        ClientToScreen(hwnd, &point)
        let menu = CreatePopupMenu()
        defer { DestroyMenu(menu) }
        let selection = selectedEntries
        let items: [(String, Command, Bool)] = [
            ("Cut\tCtrl+X", .cut, !selection.isEmpty), ("Copy\tCtrl+C", .copy, !selection.isEmpty),
            ("Paste\tCtrl+V", .paste, ShellClipboard.hasFiles), ("Move to Recycle Bin\tDelete", .delete, !selection.isEmpty),
            ("", .reload, false), ("Select All\tCtrl+A", .selectAll, true), ("New Folder\tCtrl+Shift+N", .newFolder, true),
            ("New File", .newFile, true), ("", .reload, false),
            (showHidden ? "Hide Hidden Files\tCtrl+H" : "Show Hidden Files\tCtrl+H", .showHidden, true), ("Reload\tF5", .reload, true),
        ]
        for (title, command, enabled) in items {
            if title.isEmpty { AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil); continue }
            withWide(title) { _ = AppendMenuW(menu, UINT(MF_STRING) | (enabled ? 0 : UINT(MF_GRAYED)), UINT_PTR(command.rawValue), $0) }
        }
        let chosen = MainMenu.trackPopup(menu, at: point, owner: hwnd, rightAligned: true)
        if let command = Command(rawValue: chosen) { perform(command) }
    }

    /// Explorer shortcuts, as on Linux (Thunar's), while the file list has the focus. Returns true when handled.
    func handleKey(_ message: MSG) -> Bool {
        guard let list, message.hwnd == list else {
            // In the location field: Enter goes there, Escape puts the current folder back.
            if let location, message.hwnd == location, message.message == UINT(WM_KEYDOWN) {
                if message.wParam == WPARAM(VK_RETURN) {
                    let text = String(windowText: location)
                    let home = FileManager.default.homeDirectoryForCurrentUser.path.windowsPath
                    if let target = Self.resolve(text, from: folder, home: home) { navigate(to: target) }
                    SetFocus(list)
                    return true
                }
                if message.wParam == WPARAM(VK_ESCAPE) {
                    withWide(folder) { _ = SetWindowTextW(location, $0) }
                    SetFocus(list)
                    return true
                }
            }
            return false
        }
        guard message.message == UINT(WM_KEYDOWN) || message.message == UINT(WM_SYSKEYDOWN) else { return false }
        if SendMessageW(list, UINT(LVM_GETEDITCONTROL), 0, 0) != 0 { return false } // Renaming: keys go to the edit box.
        let key = Int32(message.wParam)
        let control = isPressed(VK_CONTROL), shift = isPressed(VK_SHIFT), alt = isPressed(VK_MENU)
        func letter(_ c: Character) -> Bool { key == Int32(c.asciiValue!) }
        switch (control, shift, alt) {
        case (false, false, false):
            switch key {
            case VK_RETURN: perform(.open)
            case VK_BACK: goBack()
            case VK_DELETE: perform(.delete)
            case VK_F2: perform(.rename)
            case VK_F5: perform(.reload)
            default: return false
            }
        case (false, true, false) where key == VK_DELETE: perform(.deletePermanently)
        case (false, false, true):
            switch key {
            case VK_LEFT: goBack()
            case VK_RIGHT: goForward()
            case VK_UP: goUp()
            case VK_HOME: goHome()
            case VK_RETURN: perform(.properties)
            default: return false
            }
        case (true, false, false):
            if letter("C") { perform(.copy) }
            else if letter("X") { perform(.cut) }
            else if letter("V") { perform(.paste) }
            else if letter("A") { perform(.selectAll) }
            else if letter("H") { perform(.showHidden) }
            else if letter("R") { perform(.reload) }
            else if letter("L") { SetFocus(location); SendMessageW(location, UINT(EM_SETSEL), 0, -1) }
            else { return false }
        case (true, true, false) where letter("N"): perform(.newFolder)
        default: return false
        }
        return true
    }

    // MARK: Painting

    private func paint(_ hwnd: HWND) {
        var ps = PAINTSTRUCT()
        guard let screen = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let dc = CreateCompatibleDC(screen)
        let bitmap = CreateCompatibleBitmap(screen, client.right, client.bottom)
        let old = SelectObject(dc, bitmap)
        defer { SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc) }
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        let colors = self.colors
        let dark = appIsDark
        let sideBackground = dark ? colorRef(32, 32, 32) : colorRef(243, 243, 243)
        let barBackground = dark ? colorRef(28, 28, 28) : colorRef(255, 255, 255)
        fill(dc, client, barBackground)
        fill(dc, RECT(left: 0, top: 0, right: placesWidth, bottom: client.bottom), sideBackground)
        fill(dc, RECT(left: placesWidth - 1, top: 0, right: placesWidth, bottom: client.bottom), colors.border)
        fill(dc, RECT(left: placesWidth, top: barHeight - 1, right: client.right, bottom: barHeight), colors.border)
        SetBkMode(dc, TRANSPARENT)

        // Places.
        placeRects = []
        var y = s(10)
        for section in places {
            draw(dc, section.section.uppercased(), RECT(left: s(14), top: y, right: placesWidth - s(8), bottom: y + s(20)),
                 font: fonts.heading, color: colors.dim)
            y += s(22)
            for place in section.items {
                let rect = RECT(left: s(6), top: y, right: placesWidth - s(6), bottom: y + s(28))
                let current = place.path.lowercased() == folder.lowercased()
                if current { roundFill(dc, rect, blend(sideBackground, colors.accent, 0.18), radius: s(4)) }
                draw(dc, place.glyph, RECT(left: rect.left + s(8), top: rect.top, right: rect.left + s(30), bottom: rect.bottom),
                     font: fonts.glyph, color: current ? colors.accentText : colors.text)
                draw(dc, place.name, RECT(left: rect.left + s(34), top: rect.top, right: rect.right - s(4), bottom: rect.bottom),
                     font: fonts.ui, color: colors.text, ellipsis: true)
                placeRects.append((rect, place))
                y += s(30)
            }
            y += s(10)
        }

        // Location bar buttons.
        let glyphs: [BarItem: String] = [.back: "\u{E72B}", .forward: "\u{E72A}", .up: "\u{E74A}", .home: "\u{E80F}", .actions: "\u{E712}"]
        let enabled: [BarItem: Bool] = [.back: !history.isEmpty, .forward: !future.isEmpty,
                                        .up: (folder as NSString).deletingLastPathComponent != folder, .home: true, .actions: true]
        for (item, rect) in barRects {
            if hover == item, enabled[item] == true { roundFill(dc, rect, blend(barBackground, colors.text, 0.1), radius: s(4)) }
            draw(dc, glyphs[item] ?? "", rect, font: fonts.glyph, color: enabled[item] == true ? colors.text : blend(colors.text, barBackground, 0.65),
                 center: true)
        }

        // Status line: item counts, or the last problem.
        let selected = selectedRows.count
        let counts = "\(rows.count) item\(rows.count == 1 ? "" : "s")" + (selected > 0 ? ", \(selected) selected" : "")
            + (showHidden ? "" : (entries.count > rows.count ? " (\(entries.count - rows.count) hidden)" : ""))
        let statusRect = RECT(left: placesWidth + s(10), top: client.bottom - statusHeight, right: client.right - s(10), bottom: client.bottom)
        draw(dc, status.isEmpty ? counts : status, statusRect, font: fonts.ui, color: status.isEmpty || !statusIsError ? colors.dim : colorRef(196, 43, 28), ellipsis: true)
        BitBlt(screen, 0, 0, client.right, client.bottom, dc, 0, 0, DWORD(SRCCOPY))
    }

    private func draw(_ dc: HDC?, _ text: String, _ rect: RECT, font: HFONT?, color: COLORREF, center: Bool = false, ellipsis: Bool = false) {
        let old = SelectObject(dc, font)
        SetTextColor(dc, color)
        var r = rect
        var units = Array(text.utf16)
        var flags = DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX
        if center { flags |= DT_CENTER }
        if ellipsis { flags |= DT_END_ELLIPSIS }
        DrawTextW(dc, &units, Int32(units.count), &r, UINT(flags))
        SelectObject(dc, old)
    }

    private func roundFill(_ dc: HDC?, _ rect: RECT, _ color: COLORREF, radius: Int32) {
        let brush = CreateSolidBrush(color), pen = CreatePen(PS_SOLID, 1, color)
        let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
        RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2)
        SelectObject(dc, oldBrush); SelectObject(dc, oldPen)
        DeleteObject(brush); DeleteObject(pen)
    }

    private func barItem(at point: POINT) -> BarItem? {
        barRects.first { point.x >= $0.value.left && point.x < $0.value.right && point.y >= $0.value.top && point.y < $0.value.bottom }?.key
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_SIZE:
            layout()
            return 0
        case WM_PAINT:
            paint(hwnd)
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SETFOCUS:
            SetFocus(list)
            return 0
        case WM_LBUTTONDOWN:
            let point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            if let item = barItem(at: point) {
                switch item {
                case .back: goBack()
                case .forward: goForward()
                case .up: goUp()
                case .home: goHome()
                case .actions: fileActionsMenu()
                }
            } else if let place = placeRects.first(where: { point.x >= $0.0.left && point.x < $0.0.right && point.y >= $0.0.top && point.y < $0.0.bottom })?.1 {
                navigate(to: place.path)
            }
            SetFocus(list)
            return 0
        case WM_MOUSEMOVE:
            if !trackingMouse {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                trackingMouse = true
            }
            let item = barItem(at: POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam))))
            if item != hover { hover = item; InvalidateRect(hwnd, nil, false) }
            return 0
        case WM_MOUSELEAVE:
            trackingMouse = false
            if hover != nil { hover = nil; InvalidateRect(hwnd, nil, false) }
            return 0
        case WM_XBUTTONUP:
            // The mouse's back and forward buttons.
            if hiWord(wParam) == 1 { goBack() } else { goForward() }
            return LRESULT(1)
        case WM_NOTIFY:
            guard let header = UnsafePointer<NMHDR>(bitPattern: UInt(lParam)), header.pointee.hwndFrom == list else { return nil }
            switch Int32(bitPattern: header.pointee.code) {
            case -3, -114: // NM_DBLCLK, LVN_ITEMACTIVATE
                if Int32(bitPattern: header.pointee.code) == -114 { perform(.open) }
                return 0
            case -5: // NM_RCLICK
                var point = POINT()
                GetCursorPos(&point)
                var client = point
                ScreenToClient(list, &client)
                var hit = LVHITTESTINFO()
                hit.pt = client
                let row = withUnsafeMutablePointer(to: &hit) { SendMessageW(list, UINT(LVM_HITTEST), 0, LPARAM(Int(bitPattern: $0))) }
                contextMenu(at: point, onItem: row >= 0)
                return 0
            case -101: // LVN_ITEMCHANGED: the status line's count
                InvalidateRect(hwnd, nil, false)
                return 0
            case -108: // LVN_COLUMNCLICK
                let column = Int(UnsafePointer<NMLISTVIEW>(bitPattern: UInt(lParam))!.pointee.iSubItem)
                sort = (column, sort.column == column ? !sort.ascending : true)
                refill(keepSelection: true, select: Set(selectedEntries.map(\.name)))
                return 0
            case -175: // LVN_BEGINLABELEDITW
                return 0
            case -176: // LVN_ENDLABELEDITW
                let info = UnsafePointer<NMLVDISPINFOW>(bitPattern: UInt(lParam))!.pointee
                if let text = info.item.pszText {
                    // Rename after the edit box has gone, so dialogs don't fight it for the focus.
                    pendingRename = (Int(info.item.iItem), String(wide: text))
                    PostMessageW(hwnd, UINT(WM_APP_DEFERRED), 0, 0)
                }
                return 0
            default:
                return nil
            }
        case WM_APP_DEFERRED:
            if let rename = pendingRename {
                pendingRename = nil
                finishRename(row: rename.row, to: rename.name)
            }
            return 0
        case WM_CTLCOLOREDIT:
            let dc = HDC(bitPattern: UInt(wParam))
            let dark = appIsDark
            SetTextColor(dc, colors.text)
            SetBkColor(dc, dark ? colorRef(43, 43, 43) : colorRef(255, 255, 255))
            SetDCBrushColor(dc, dark ? colorRef(43, 43, 43) : colorRef(255, 255, 255))
            return LRESULT(Int(bitPattern: UnsafeRawPointer(GetStockObject(DC_BRUSH))))
        default:
            return nil
        }
    }
}

let WM_APP_DEFERRED = Int32(WM_APP) + 3

/// Files on the Windows clipboard, in the format File Explorer uses (CF_HDROP plus "Preferred DropEffect"), so
/// copying and cutting work between Herb's Terminal and File Explorer both ways.
@MainActor
enum ShellClipboard {
    private static let dropEffect = withWide("Preferred DropEffect") { RegisterClipboardFormatW($0) }

    static var hasFiles: Bool { IsClipboardFormatAvailable(UINT(CF_HDROP)) }

    static func put(_ paths: [String], move: Bool, owner: HWND?) {
        guard OpenClipboard(owner) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        // DROPFILES, then the paths as one double-NUL-terminated wide string.
        let list: [UInt16] = paths.flatMap { Array($0.utf16) + [0] } + [0]
        let headerSize = MemoryLayout<DROPFILES>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE | GMEM_ZEROINIT), SIZE_T(headerSize + list.count * 2)),
              let locked = GlobalLock(memory) else { return }
        var header = DROPFILES()
        header.pFiles = DWORD(headerSize)
        header.fWide = true
        withUnsafeBytes(of: &header) { locked.copyMemory(from: $0.baseAddress!, byteCount: headerSize) }
        list.withUnsafeBytes { (locked + headerSize).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        GlobalUnlock(memory)
        if SetClipboardData(UINT(CF_HDROP), memory) == nil { GlobalFree(memory) }
        if let effect = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(4)), let pointer = GlobalLock(effect) {
            pointer.storeBytes(of: DWORD(move ? DROPEFFECT_MOVE : DROPEFFECT_COPY), as: DWORD.self)
            GlobalUnlock(effect)
            if SetClipboardData(dropEffect, effect) == nil { GlobalFree(effect) }
        }
    }

    /// The files on the clipboard and whether they were cut.
    static func get(owner: HWND?) -> ([String], Bool)? {
        guard OpenClipboard(owner) else { return nil }
        defer { CloseClipboard() }
        guard let data = GetClipboardData(UINT(CF_HDROP)) else { return nil }
        let drop = HDROP(OpaquePointer(data))
        let count = DragQueryFileW(drop, 0xFFFF_FFFF, nil, 0)
        var paths: [String] = []
        for index in 0..<count {
            let length = DragQueryFileW(drop, index, nil, 0)
            var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
            DragQueryFileW(drop, index, &buffer, UINT(buffer.count))
            paths.append(String(decoding: buffer.prefix(Int(length)), as: UTF16.self))
        }
        var move = false
        if let effect = GetClipboardData(dropEffect), let pointer = GlobalLock(effect) {
            move = pointer.load(as: DWORD.self) & DWORD(DROPEFFECT_MOVE) != 0
            GlobalUnlock(effect)
        }
        return (paths, move)
    }

    static func clear(owner: HWND?) {
        guard OpenClipboard(owner) else { return }
        EmptyClipboard()
        CloseClipboard()
    }
}

/// Copy, move, rename and delete through the Windows shell: its progress window for long jobs, the Recycle Bin, and
/// new names on clashes ("name - Copy"), never overwriting.
@MainActor
enum ShellOperation {
    enum Kind { case copy, move, rename, recycle, deletePermanently }

    @discardableResult
    static func run(_ kind: Kind, _ paths: [String], to target: String? = nil, owner: HWND?) -> Bool {
        var from: [UInt16] = paths.flatMap { Array($0.utf16) + [0] } + [0]
        var to: [UInt16] = (target.map { Array($0.utf16) + [0] } ?? []) + [0]
        var operation = SHFILEOPSTRUCTW()
        operation.hwnd = owner.flatMap { GetAncestor($0, UINT(GA_ROOT)) }
        switch kind {
        case .copy: operation.wFunc = UINT(FO_COPY)
        case .move: operation.wFunc = UINT(FO_MOVE)
        case .rename: operation.wFunc = UINT(FO_RENAME)
        case .recycle, .deletePermanently: operation.wFunc = UINT(FO_DELETE)
        }
        var flags = FOF_NOCONFIRMMKDIR
        switch kind {
        case .copy, .move: flags |= FOF_RENAMEONCOLLISION | FOF_ALLOWUNDO
        case .rename: flags |= FOF_ALLOWUNDO
        // Recycling asks nothing (it can be restored); Windows still warns if an item is too big to recycle.
        case .recycle: flags |= FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_WANTNUKEWARNING
        case .deletePermanently: flags |= FOF_NOCONFIRMATION // Already confirmed in our own dialog.
        }
        operation.fFlags = FILEOP_FLAGS(flags)
        return from.withUnsafeMutableBufferPointer { fromPointer in
            to.withUnsafeMutableBufferPointer { toPointer in
                operation.pFrom = UnsafePointer(fromPointer.baseAddress)
                operation.pTo = target == nil ? nil : UnsafePointer(toPointer.baseAddress)
                return SHFileOperationW(&operation) == 0 && !operation.fAnyOperationsAborted.boolValue
            }
        }
    }
}

/// Free "untitled" names: "untitled folder", then "untitled folder 2", 3, … as on the Mac and Linux.
enum FreeName {
    static func next(_ base: String, in folder: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let join = { (name: String) in folder.hasSuffix("\\") ? folder + name : folder + "\\" + name }
        if !exists(join(base)) { return base }
        var number = 2
        while exists(join("\(base) \(number)")) { number += 1 }
        return "\(base) \(number)"
    }
}

extension String {
    /// Foundation's "/"-separated form of a Windows path, back with backslashes.
    var windowsPath: String {
        var path = replacingOccurrences(of: "/", with: "\\")
        if path.hasPrefix("\\"), path.dropFirst().first?.isLetter == true, path.dropFirst(2).first == ":" { path.removeFirst() }
        if path.count > 3, path.hasSuffix("\\") { path.removeLast() }
        return path
    }

    /// A window's text.
    init(windowText window: HWND) {
        let length = GetWindowTextLengthW(window)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(window, &buffer, length + 1)
        self = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }
}

extension FILETIME {
    var date: Date {
        let ticks = UInt64(dwHighDateTime) << 32 | UInt64(dwLowDateTime)
        // FILETIME counts 100 ns intervals since 1601-01-01; Unix time starts 11 644 473 600 s later.
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
    }
}

/// The list's column headings in the app's text color. A list view's header draws its own text, dim grey in dark
/// mode, so the list is subclassed to answer the header's custom-draw notification.
@MainActor
enum HeaderColors {
    static var text: COLORREF = colorRef(0, 0, 0)

    static func attach(to list: HWND?) {
        guard let list else { return }
        SetWindowSubclass(list, { window, message, wParam, lParam, _, _ in
            if message == UINT(WM_NOTIFY), let header = UnsafePointer<NMHDR>(bitPattern: UInt(lParam)),
               Int32(bitPattern: header.pointee.code) == -12 /* NM_CUSTOMDRAW */,
               header.pointee.hwndFrom == HWND(bitPattern: Int(SendMessageW(window, UINT(LVM_GETHEADER), 0, 0))) {
                let draw = UnsafeMutablePointer<NMCUSTOMDRAW>(mutating: UnsafeRawPointer(header).assumingMemoryBound(to: NMCUSTOMDRAW.self))
                switch draw.pointee.dwDrawStage {
                case DWORD(CDDS_PREPAINT): return LRESULT(CDRF_NOTIFYITEMDRAW)
                case DWORD(CDDS_ITEMPREPAINT):
                    SetTextColor(draw.pointee.hdc, MainActor.assumeIsolated { HeaderColors.text })
                    return 0 // CDRF_DEFAULT
                default: break
                }
            }
            return DefSubclassProc(window, message, wParam, lParam)
        }, 0x48_54, 0)
    }
}
