import Foundation
import SwiftTerm
import WinSDK

/// One terminal: a child window that runs a shell in a pseudo console, keeps the screen in SwiftTerm's emulator
/// and paints it with GDI.
@MainActor
final class TerminalPane: WindowObject, TerminalDelegate {
    static let className = "HerbsTerminalPane"
    private static let blinkTimer: UINT_PTR = 1
    /// Waits a moment after the process ends, so its last words reach the screen before the tab reacts.
    private static let endedTimer: UINT_PTR = 2

    private(set) var hwnd: HWND?
    let terminal: Terminal
    private var session: PseudoConsole?
    private var fonts = FontSet()
    private var colors = Colors()
    private var cursorShape: CursorShape = .block
    private var cursorBlinks = true
    private var cursorVisible = true
    private var cursorBlinkOn = true
    private var focused = false
    private var highSurrogate: WCHAR = 0

    /// Lines scrolled back from the live screen; 0 shows the newest output.
    private var scrollOffset = 0
    /// Selection in scroll-invariant rows (they don't move as output arrives).
    private var selectionStart: Position?
    private var selectionEnd: Position?
    private var selecting = false

    var title = "Terminal"
    /// The tab's number ("Terminal 2"), the lowest free one when it opened.
    var number = 1
    /// A name from Rename Tab; nil shows "Terminal <number>".
    var customName: String?
    var tabName: String { customName ?? "Terminal \(number)" }
    var onTitleChange: ((TerminalPane) -> Void)?
    var onExit: ((TerminalPane) -> Void)?

    init(parent: HWND, settings: ProfileSettings) {
        var options = TerminalOptions(cols: 80, rows: 24)
        options.scrollback = settings.scrollbackLines
        terminal = Terminal(delegate: TerminalDelegateProxy.shared, options: options)
        TerminalDelegateProxy.shared.panes[ObjectIdentifier(terminal)] = self
        hwnd = createWindow(self, className: Self.className, style: DWORD(WS_CHILD | WS_CLIPSIBLINGS), parent: parent)
        apply(settings)
    }

    /// Starts the shell. Call once the pane has its size, so the shell starts with the right grid.
    func start(commandLine: String = ShellChoice.commandLine, directory: String? = nil, environment: [String: String] = [:]) {
        guard let hwnd, session == nil else { return }
        let start = directory ?? ProcessInfo.processInfo.environment["USERPROFILE"]
        do {
            session = try PseudoConsole(commandLine: commandLine, directory: start, extraEnvironment: environment,
                                        columns: terminal.cols, rows: terminal.rows, window: hwnd)
        } catch {
            terminal.feed(text: "\u{1b}[31m\(error.localizedDescription)\u{1b}[0m\r\n")
            invalidate()
        }
    }

    /// The SSH login this tab runs, if it is an SSH tab. The password stays in memory only, for Reconnect.
    private(set) var remote: RemoteEndpoint?
    private var remotePassword: String?
    private var awaitingReconnect = false

    /// Runs ssh to `endpoint` as this tab's process. A password goes to ssh through the askpass broker, once;
    /// without one (or when it's refused) ssh asks in the terminal, and keys from ssh-agent work as usual.
    func startSSH(_ endpoint: RemoteEndpoint, password: String?) {
        remote = endpoint
        remotePassword = password
        title = endpoint.label
        onTitleChange?(self)
        guard let commandLine = SSH.commandLine(endpoint) else {
            terminal.feed(text: "\u{1b}[31mWindows' OpenSSH client isn't installed. Add it in Settings ▸ System ▸ Optional features ▸ OpenSSH Client.\u{1b}[0m\r\n")
            invalidate()
            return
        }
        var environment: [String: String] = [:]
        if let password, !password.isEmpty, let broker = AskpassBroker.shared {
            environment = broker.environment(token: broker.issue(password, for: endpoint.passwordLogins))
        }
        terminal.feed(text: "Connecting to \(endpoint.label)…\r\n")
        start(commandLine: commandLine, environment: environment)
        connectedAt = Date()
    }

    /// Whether this tab is an SSH session that is still running.
    var isConnected: Bool { remote != nil && !awaitingReconnect && isRunning }
    private var disconnecting = false
    private(set) var connectedAt: Date?

    /// Ends the SSH session; the tab stays open and Enter reconnects.
    func disconnect() {
        guard remote != nil, isRunning else { return }
        disconnecting = true
        session?.close()
    }

    // MARK: Shell menu commands

    /// Everything in the terminal, scrollback included, as text.
    func exportText() -> String {
        String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
    }

    /// Clear to Start: empties the screen and scrollback, then asks the shell to draw its prompt again.
    func clearToStart() {
        terminal.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
        terminal.clearScrollback()
        scrollOffset = 0
        clearSelection()
        session?.write([0x0C])
        invalidate()
    }

    func clearScrollback() {
        terminal.clearScrollback()
        scrollOffset = 0
        clearSelection()
        invalidate()
    }

    func reset(hard: Bool) {
        if hard { terminal.resetToInitialState() } else { terminal.softReset() }
        scrollOffset = 0
        clearSelection()
        invalidate()
    }

    private func reconnect() {
        guard let remote else { return }
        awaitingReconnect = false
        session?.close()
        session = nil
        terminal.feed(text: "\r\n")
        startSSH(remote, password: remotePassword)
    }

    /// The process ended. A shell that exits closes its tab; an SSH session that ends with an error stays
    /// open with its last output, so the reason can be read, and Enter reconnects.
    private func processEnded() {
        let code = session?.exitCode ?? 0
        connectedAt = nil
        if let remote, disconnecting {
            disconnecting = false
            awaitingReconnect = true
            terminal.feed(text: "\r\n\u{1b}[7m Disconnected from \(remote.label). Press Enter to reconnect, or Ctrl+Shift+W to close the tab. \u{1b}[0m\r\n")
            invalidate()
            onTitleChange?(self)
            return
        }
        if let remote, code != 0 {
            awaitingReconnect = true
            onTitleChange?(self)
            terminal.feed(text: "\r\n\u{1b}[7m Connection to \(remote.label) ended (exit code \(code)). Press Enter to reconnect, or Ctrl+Shift+W to close the tab. \u{1b}[0m\r\n")
            invalidate()
            return
        }
        onExit?(self)
    }

    func close() {
        session?.close()
        session = nil
        TerminalDelegateProxy.shared.panes[ObjectIdentifier(terminal)] = nil
        fonts.release()
        if let hwnd { DestroyWindow(hwnd) }
        hwnd = nil
    }

    var isRunning: Bool { !awaitingReconnect && (session.map { !$0.hasExited } ?? false) }

    // MARK: Appearance

    func apply(_ settings: ProfileSettings) {
        let dpi = hwnd.map { GetDpiForWindow($0) } ?? 96
        let family = settings.fontFamily.isEmpty ? FontSet.stockFamily : settings.fontFamily
        fonts.release()
        fonts = FontSet(family: family, points: settings.effectiveSize, dpi: dpi)
        colors = Colors(theme: settings.theme.isEmpty ? nil : ThemeLibrary.shared.theme(named: settings.theme))
        cursorShape = settings.cursor
        cursorBlinks = settings.cursorBlinks
        if let hwnd {
            KillTimer(hwnd, Self.blinkTimer)
            if cursorBlinks { SetTimer(hwnd, Self.blinkTimer, 530, nil) }
        }
        layout()
    }

    var cellSize: (width: Int32, height: Int32) { (fonts.cellWidth, fonts.cellHeight) }

    var background: COLORREF { colors.background }

    func show(_ visible: Bool) {
        guard let hwnd else { return }
        ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE)
        if visible { SetFocus(hwnd) }
    }

    func move(to rect: RECT) {
        guard let hwnd else { return }
        MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, true)
    }

    /// Fits the grid to the window: whole cells, at least 2 × 1.
    private func layout() {
        guard let hwnd else { return }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let padding = Self.padding(hwnd)
        let columns = max(2, Int((rect.right - 2 * padding) / max(1, fonts.cellWidth)))
        let rows = max(1, Int((rect.bottom - 2 * padding) / max(1, fonts.cellHeight)))
        if columns != terminal.cols || rows != terminal.rows {
            terminal.resize(cols: columns, rows: rows)
            session?.resize(columns: columns, rows: rows)
            scrollOffset = min(scrollOffset, maxScrollOffset)
        }
        invalidate()
    }

    static func padding(_ hwnd: HWND) -> Int32 { scaled(4, dpi: GetDpiForWindow(hwnd)) }

    private func invalidate() {
        if let hwnd { InvalidateRect(hwnd, nil, false) }
    }

    // MARK: Scrollback

    /// Scroll-invariant row of the first live screen row.
    private var liveTop: Int { terminal.buffer.totalLinesTrimmed + terminal.buffer.yDisp }
    private var maxScrollOffset: Int { terminal.isCurrentBufferAlternate ? 0 : terminal.buffer.yDisp }
    private var viewTop: Int { liveTop - scrollOffset }

    private func scroll(by lines: Int) {
        let offset = max(0, min(maxScrollOffset, scrollOffset + lines))
        if offset != scrollOffset {
            scrollOffset = offset
            invalidate()
        }
    }

    // MARK: Messages

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_PAINT:
            paint(hwnd)
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_SIZE:
            layout()
            return 0
        case WM_APP_OUTPUT:
            drainOutput()
            return 0
        case WM_APP_EXITED:
            drainOutput()
            SetTimer(hwnd, Self.endedTimer, 200, nil)
            return 0
        case WM_TIMER where wParam == Self.endedTimer:
            KillTimer(hwnd, Self.endedTimer)
            drainOutput()
            processEnded()
            return 0
        case WM_TIMER:
            cursorBlinkOn.toggle()
            invalidateCursor()
            return 0
        case WM_SETFOCUS:
            focused = true
            CreateCaret(hwnd, nil, 1, fonts.cellHeight) // Lets screen readers and IMEs find the cursor.
            restartBlink()
            return 0
        case WM_KILLFOCUS:
            focused = false
            DestroyCaret()
            invalidate()
            return 0
        case WM_MOUSEACTIVATE:
            SetFocus(hwnd)
            return LRESULT(MA_ACTIVATE)
        case WM_KEYDOWN, WM_SYSKEYDOWN:
            if keyDown(Int32(wParam), system: Int32(message) == WM_SYSKEYDOWN) { return 0 }
            return nil
        case WM_CHAR:
            character(WCHAR(truncatingIfNeeded: wParam), alt: false)
            return 0
        case WM_SYSCHAR:
            // Alt+letter: ESC then the letter, as terminals send Meta.
            character(WCHAR(truncatingIfNeeded: wParam), alt: true)
            return 0
        case WM_MOUSEWHEEL:
            wheel(hiWord(wParam))
            return 0
        case WM_LBUTTONDOWN:
            SetFocus(hwnd)
            SetCapture(hwnd)
            let cell = self.cell(at: lParam)
            if isPressed(VK_SHIFT), selectionStart != nil {
                selectionEnd = cell
            } else {
                selectionStart = cell
                selectionEnd = cell
            }
            selecting = true
            invalidate()
            return 0
        case WM_MOUSEMOVE:
            if selecting {
                selectionEnd = cell(at: lParam)
                autoScroll(lParam)
                invalidate()
            }
            return 0
        case WM_LBUTTONUP:
            selecting = false
            ReleaseCapture()
            if selectionStart == selectionEnd { clearSelection() }
            return 0
        case WM_LBUTTONDBLCLK:
            selectWord(at: cell(at: lParam))
            return 0
        case WM_RBUTTONUP:
            // As in Windows Terminal: right-click copies a selection, or pastes when there is none.
            if hasSelection { copySelection() } else { paste() }
            return 0
        case WM_DPICHANGED_AFTERPARENT:
            apply(TerminalProfile.shared.settings(for: nil))
            return 0
        case WM_GETDLGCODE:
            return LRESULT(DLGC_WANTALLKEYS | DLGC_WANTCHARS | DLGC_WANTTAB | DLGC_WANTARROWS)
        default:
            return nil
        }
    }

    private func drainOutput() {
        guard let bytes = session?.takeOutput(), !bytes.isEmpty else { return }
        let before = liveTop
        terminal.feed(byteArray: bytes)
        // Keep scrolled-back text still while new output arrives.
        if scrollOffset > 0 { scrollOffset = min(maxScrollOffset, scrollOffset + (liveTop - before)) }
        restartBlink()
        invalidate()
    }

    private func restartBlink() {
        cursorBlinkOn = true
        if let hwnd, cursorBlinks {
            KillTimer(hwnd, Self.blinkTimer)
            SetTimer(hwnd, Self.blinkTimer, 530, nil)
        }
        invalidateCursor()
    }

    private func invalidateCursor() {
        guard let hwnd else { return }
        let cursor = terminal.getCursorLocation()
        let padding = Self.padding(hwnd)
        var rect = RECT(left: padding + Int32(cursor.x) * fonts.cellWidth - 2, top: padding + Int32(cursor.y + scrollOffset) * fonts.cellHeight,
                        right: padding + Int32(cursor.x + 2) * fonts.cellWidth + 2, bottom: padding + Int32(cursor.y + scrollOffset + 1) * fonts.cellHeight)
        InvalidateRect(hwnd, &rect, false)
    }

    // MARK: Input

    func send(_ bytes: [UInt8]) {
        if awaitingReconnect {
            if bytes == [13] { reconnect() }
            return
        }
        if scrollOffset != 0 { scrollOffset = 0; invalidate() }
        session?.write(bytes)
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    /// Keys that WM_CHAR doesn't cover: arrows, editing keys, function keys, and the copy/paste shortcuts.
    /// Returns true when the key was handled.
    private func keyDown(_ key: Int32, system: Bool) -> Bool {
        let shift = isPressed(VK_SHIFT), control = isPressed(VK_CONTROL), alt = isPressed(VK_MENU)
        let modifier = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)

        // Clipboard, as in Windows Terminal: Ctrl+C copies when text is selected, Ctrl+V pastes.
        if control && !alt {
            switch key {
            case Int32(UInt8(ascii: "C")) where shift || hasSelection:
                copySelection()
                return true
            case Int32(UInt8(ascii: "V")):
                paste()
                return true
            default: break
            }
        }
        if shift && !control && !alt {
            switch key {
            case VK_PRIOR: scroll(by: terminal.rows - 1); return true
            case VK_NEXT: scroll(by: -(terminal.rows - 1)); return true
            case VK_INSERT: paste(); return true
            default: break
            }
        }
        if control && shift && (key == VK_HOME || key == VK_END) {
            scroll(by: key == VK_HOME ? maxScrollOffset : -scrollOffset)
            return true
        }

        func csi(_ final: String, _ number: Int? = nil) -> String {
            if modifier > 1 { return "\u{1b}[\(number ?? 1);\(modifier)\(final)" }
            return number.map { "\u{1b}[\($0)\(final)" } ?? "\u{1b}[\(final)"
        }
        func cursorKey(_ final: String) -> String {
            modifier == 1 && terminal.applicationCursor ? "\u{1b}O\(final)" : csi(final)
        }
        func tilde(_ number: Int) -> String {
            modifier > 1 ? "\u{1b}[\(number);\(modifier)~" : "\u{1b}[\(number)~"
        }

        let sequence: String? = switch key {
        case VK_UP: cursorKey("A")
        case VK_DOWN: cursorKey("B")
        case VK_RIGHT: cursorKey("C")
        case VK_LEFT: cursorKey("D")
        case VK_HOME: cursorKey("H")
        case VK_END: cursorKey("F")
        case VK_INSERT: tilde(2)
        case VK_DELETE: tilde(3)
        case VK_PRIOR: tilde(5)
        case VK_NEXT: tilde(6)
        case VK_F1: modifier > 1 ? csi("P") : "\u{1b}OP"
        case VK_F2: modifier > 1 ? csi("Q") : "\u{1b}OQ"
        case VK_F3: modifier > 1 ? csi("R") : "\u{1b}OR"
        case VK_F4 where !alt: modifier > 1 ? csi("S") : "\u{1b}OS"
        case VK_F5: tilde(15)
        case VK_F6: tilde(17)
        case VK_F7: tilde(18)
        case VK_F8: tilde(19)
        case VK_F9: tilde(20)
        case VK_F10: tilde(21)
        case VK_F11: tilde(23)
        case VK_F12: tilde(24)
        default: nil
        }
        if let sequence {
            send(sequence)
            return true
        }
        // Keys whose WM_CHAR is ambiguous or missing.
        switch key {
        case VK_BACK:
            send(control ? [0x08] : alt ? [0x1b, 0x7f] : [0x7f])
            return true
        case VK_TAB where shift && !control:
            send("\u{1b}[Z")
            return true
        case Int32(UInt8(ascii: "2")) where control && !alt, VK_SPACE where control && !alt:
            send([0]) // Ctrl+Space and Ctrl+2: NUL
            return true
        default:
            return false
        }
    }

    private func character(_ unit: WCHAR, alt: Bool) {
        switch unit {
        case 0x08, 0x7F:
            return // Handled in keyDown.
        case 0xD800...0xDBFF:
            highSurrogate = unit
            return
        case 0xDC00...0xDFFF:
            guard highSurrogate != 0 else { return }
            let text = String(decoding: [highSurrogate, unit], as: UTF16.self)
            highSurrogate = 0
            send((alt ? "\u{1b}" : "") + text)
        default:
            if unit == 0x09 && isPressed(VK_SHIFT) { return } // Shift+Tab went out as CSI Z.
            if unit == 0x20 && isPressed(VK_CONTROL) { return } // Ctrl+Space went out as NUL.
            let text = String(decoding: [unit], as: UTF16.self)
            send((alt ? "\u{1b}" : "") + text)
        }
    }

    func paste() {
        guard let hwnd, var text = clipboardText(hwnd), !text.isEmpty else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.bracketedPasteMode {
            text = "\u{1b}[200~" + text.replacingOccurrences(of: "\u{1b}[201~", with: "") + "\u{1b}[201~"
        }
        send(text)
    }

    private func wheel(_ delta: Int) {
        let lines = max(1, abs(delta) / 40) * (delta > 0 ? 1 : -1)
        if terminal.isCurrentBufferAlternate {
            // Full-screen programs without mouse reporting (less, man) scroll with the arrow keys.
            let key = delta > 0 ? (terminal.applicationCursor ? "\u{1b}OA" : "\u{1b}[A") : (terminal.applicationCursor ? "\u{1b}OB" : "\u{1b}[B")
            session?.write(Array(String(repeating: key, count: abs(lines)).utf8))
        } else {
            scroll(by: lines)
        }
    }

    // MARK: Selection

    var hasSelection: Bool { selectionStart != nil && selectionEnd != nil && selectionStart != selectionEnd }

    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        invalidate()
    }

    /// The cell under a mouse position, in scroll-invariant rows.
    private func cell(at lParam: LPARAM) -> Position {
        let padding = hwnd.map(Self.padding) ?? 0
        let x = Int32(loWord(lParam)) - padding, y = Int32(hiWord(lParam)) - padding
        let column = max(0, min(terminal.cols, Int((x + fonts.cellWidth / 2) / max(1, fonts.cellWidth))))
        let row = max(0, min(terminal.rows - 1, Int(y >= 0 ? y / max(1, fonts.cellHeight) : -1)))
        return Position(col: column, row: viewTop + row)
    }

    private func autoScroll(_ lParam: LPARAM) {
        let y = hiWord(lParam)
        var rect = RECT()
        if let hwnd { GetClientRect(hwnd, &rect) }
        if y < 0 { scroll(by: 1) } else if y > Int(rect.bottom) { scroll(by: -1) }
    }

    private var orderedSelection: (Position, Position)? {
        guard let a = selectionStart, let b = selectionEnd, a != b else { return nil }
        return (a.row, a.col) <= (b.row, b.col) ? (a, b) : (b, a)
    }

    private func isSelected(column: Int, row: Int) -> Bool {
        guard let (start, end) = orderedSelection else { return false }
        if row < start.row || row > end.row { return false }
        if row == start.row && column < start.col { return false }
        if row == end.row && column >= end.col { return false }
        return true
    }

    private func selectedText() -> String {
        guard let (start, end) = orderedSelection else { return "" }
        var lines: [String] = []
        for row in start.row...end.row {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let from = row == start.row ? start.col : 0
            let to = row == end.row ? end.col : terminal.cols
            var text = line.translateToString(trimRight: false, startCol: from, endCol: to, skipNullCellsFollowingWide: true)
            if row != end.row || to >= terminal.cols { text = String(text.reversed().drop(while: { $0 == " " }).reversed()) }
            if line.isWrapped, let previous = lines.popLast() { text = previous + text }
            lines.append(text)
        }
        return lines.joined(separator: "\r\n")
    }

    func copySelection() {
        guard hasSelection, let hwnd else { return }
        setClipboardText(selectedText(), owner: hwnd)
        clearSelection()
    }

    private func selectWord(at position: Position) {
        guard let line = terminal.getScrollInvariantLine(row: position.row) else { return }
        let characters = Array(line.translateToString(trimRight: false, skipNullCellsFollowingWide: false))
        guard position.col < characters.count else { return }
        func isWord(_ c: Character) -> Bool { !c.isWhitespace && !"\"'`()[]{}<>|;,".contains(c) }
        guard isWord(characters[position.col]) else { return }
        var start = position.col, end = position.col
        while start > 0 && isWord(characters[start - 1]) { start -= 1 }
        while end < characters.count && isWord(characters[end]) { end += 1 }
        selectionStart = Position(col: start, row: position.row)
        selectionEnd = Position(col: end, row: position.row)
        invalidate()
    }

    // MARK: Painting

    private func paint(_ hwnd: HWND) {
        var ps = PAINTSTRUCT()
        guard let screen = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let width = client.right, height = client.bottom
        guard width > 0, height > 0 else { return }

        // Double-buffered: draw into a bitmap, then copy it out in one go.
        let dc = CreateCompatibleDC(screen)
        let bitmap = CreateCompatibleBitmap(screen, width, height)
        let oldBitmap = SelectObject(dc, bitmap)
        defer {
            SelectObject(dc, oldBitmap)
            DeleteObject(bitmap)
            DeleteDC(dc)
        }
        fill(dc, client, colors.background)
        SetBkMode(dc, TRANSPARENT)
        let oldFont = SelectObject(dc, fonts.normal)
        defer { SelectObject(dc, oldFont) }

        let padding = Self.padding(hwnd)
        let cw = fonts.cellWidth, ch = fonts.cellHeight
        let top = viewTop
        let cursor = terminal.getCursorLocation()
        let cursorRow = cursor.y + scrollOffset

        for screenRow in 0..<terminal.rows {
            let y = padding + Int32(screenRow) * ch
            guard let line = terminal.getScrollInvariantLine(row: top + screenRow) else { continue }
            var column = 0
            while column < terminal.cols {
                // A run of cells with the same look, drawn with one ExtTextOutW call.
                let first = line[column]
                let selected = isSelected(column: column, row: top + screenRow)
                let look = colors.resolve(first.attribute, selected: selected)
                var text: [WCHAR] = []
                var advances: [Int32] = []
                let runStart = column
                while column < terminal.cols {
                    let cell = line[column]
                    if column > runStart {
                        let otherSelected = isSelected(column: column, row: top + screenRow)
                        if cell.attribute != first.attribute || otherSelected != selected { break }
                    }
                    let cells = max(1, Int(cell.width))
                    let character = terminal.getCharacter(for: cell)
                    let units = character == "\u{0}" ? [WCHAR(0x20)] : Array(String(character).utf16)
                    for (index, unit) in units.enumerated() {
                        text.append(unit)
                        advances.append(index == 0 ? Int32(cells) * cw : 0)
                    }
                    column += cells
                }
                let x = padding + Int32(runStart) * cw
                let runRect = RECT(left: x, top: y, right: padding + Int32(column) * cw, bottom: y + ch)
                if look.background != colors.background { fill(dc, runRect, look.background) }
                if !look.invisible {
                    SelectObject(dc, fonts.font(bold: look.bold, italic: look.italic))
                    SetTextColor(dc, look.foreground)
                    var clip = runRect
                    _ = ExtTextOutW(dc, x, y, UINT(ETO_CLIPPED), &clip, text, UINT(text.count), &advances)
                    if look.underline { fill(dc, RECT(left: x, top: y + ch - max(1, ch / 14) - 1, right: runRect.right, bottom: y + ch - 1), look.foreground) }
                    if look.strike { fill(dc, RECT(left: x, top: y + ch / 2, right: runRect.right, bottom: y + ch / 2 + max(1, ch / 14)), look.foreground) }
                }
            }
            if screenRow == cursorRow && cursorVisible { drawCursor(dc, line: line, column: cursor.x, x: padding + Int32(cursor.x) * cw, y: y) }
        }
        if focused { SetCaretPos(padding + Int32(cursor.x) * cw, padding + Int32(cursorRow) * ch) }
        BitBlt(screen, 0, 0, width, height, dc, 0, 0, DWORD(SRCCOPY))
    }

    private func drawCursor(_ dc: HDC?, line: BufferLine, column: Int, x: Int32, y: Int32) {
        let cw = fonts.cellWidth, ch = fonts.cellHeight
        let column = min(column, terminal.cols - 1)
        let cell = line[column]
        let width = max(1, Int32(cell.width)) * cw
        let thickness = max(2, ch / 10)
        guard focused else {
            // Unfocused: a hollow block that doesn't blink.
            let brush = CreateSolidBrush(colors.cursor)
            var rect = RECT(left: x, top: y, right: x + width, bottom: y + ch)
            FrameRect(dc, &rect, brush)
            DeleteObject(brush)
            return
        }
        guard cursorBlinkOn || !cursorBlinks else { return }
        switch cursorShape {
        case .block:
            fill(dc, RECT(left: x, top: y, right: x + width, bottom: y + ch), colors.cursor)
            let look = colors.resolve(cell.attribute, selected: false)
            SelectObject(dc, fonts.font(bold: look.bold, italic: look.italic))
            SetTextColor(dc, colors.cursorText)
            let character = terminal.getCharacter(for: cell)
            var units = character == "\u{0}" ? [WCHAR(0x20)] : Array(String(character).utf16)
            var clip = RECT(left: x, top: y, right: x + width, bottom: y + ch)
            _ = ExtTextOutW(dc, x, y, UINT(ETO_CLIPPED), &clip, &units, UINT(units.count), nil)
        case .underline:
            fill(dc, RECT(left: x, top: y + ch - thickness, right: x + width, bottom: y + ch), colors.cursor)
        case .bar:
            fill(dc, RECT(left: x, top: y, right: x + thickness, bottom: y + ch), colors.cursor)
        }
    }

    /// Shells set their executable's full path as the title; the tab shows just its name ("powershell").
    static func tabTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Terminal" }
        if trimmed.lowercased().hasSuffix(".exe"), trimmed.contains("\\") {
            let name = trimmed.split(separator: "\\").last.map(String.init) ?? trimmed
            return String(name.dropLast(4))
        }
        return trimmed
    }

    // MARK: TerminalDelegate

    nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session?.write(Array(data)) }
    }

    nonisolated func setTerminalTitle(source: Terminal, title: String) {
        MainActor.assumeIsolated {
            // An SSH tab keeps its user@host until the remote shell names itself; ssh.exe's own path isn't news.
            let named = Self.tabTitle(title)
            if let remote, named == "Terminal" || title.lowercased().hasSuffix("ssh.exe") {
                self.title = remote.label
            } else {
                self.title = named
            }
            onTitleChange?(self)
        }
    }

    nonisolated func showCursor(source: Terminal) { MainActor.assumeIsolated { cursorVisible = true; invalidate() } }
    nonisolated func hideCursor(source: Terminal) { MainActor.assumeIsolated { cursorVisible = false; invalidate() } }

    nonisolated func bell(source: Terminal) {
        MainActor.assumeIsolated {
            switch TerminalProfile.shared.settings(for: nil).bell {
            case .audible, .both: MessageBeep(UINT(MB_OK))
            case .visual, .none: break
            }
            if let parent = hwnd.flatMap({ GetAncestor($0, UINT(GA_ROOT)) }), GetForegroundWindow() != parent {
                var flash = FLASHWINFO(cbSize: UINT(MemoryLayout<FLASHWINFO>.size), hwnd: parent,
                                       dwFlags: DWORD(FLASHW_TRAY | FLASHW_TIMERNOFG), uCount: 3, dwTimeout: 0)
                FlashWindowEx(&flash)
            }
        }
    }
}

/// SwiftTerm holds its delegate weakly and calls it during `feed`; this forwards each call to its pane.
final class TerminalDelegateProxy: TerminalDelegate, @unchecked Sendable {
    static let shared = TerminalDelegateProxy()
    var panes: [ObjectIdentifier: TerminalPane] = [:]

    private func pane(_ source: Terminal) -> TerminalPane? { panes[ObjectIdentifier(source)] }

    func send(source: Terminal, data: ArraySlice<UInt8>) { pane(source)?.send(source: source, data: data) }
    func setTerminalTitle(source: Terminal, title: String) { pane(source)?.setTerminalTitle(source: source, title: title) }
    func showCursor(source: Terminal) { pane(source)?.showCursor(source: source) }
    func hideCursor(source: Terminal) { pane(source)?.hideCursor(source: source) }
    func bell(source: Terminal) { pane(source)?.bell(source: source) }
}

func fill(_ dc: HDC?, _ rect: RECT, _ color: COLORREF) {
    SetDCBrushColor(dc, color)
    var r = rect
    FillRect(dc, &r, unsafeBitCast(GetStockObject(DC_BRUSH), to: HBRUSH.self))
}
