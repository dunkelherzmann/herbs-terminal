import CHerbUIA
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
    /// Looks for the program running in the foreground, for the title.
    private static let programTimer: UINT_PTR = 3
    private static let badgeTimer: UINT_PTR = 4
    /// The size badge: shown while the grid changes size, gone 1.2 s after the last change (Settings ▸ Window).
    private(set) var showingBadge = false
    private var hasGrid = false
    var badgeText: String { "\(terminal.cols) × \(terminal.rows)" }

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

    var title = TerminalPane.userAtHost
    /// The title the shell gave itself, shown before the program in the foreground.
    private var baseTitle = TerminalPane.userAtHost
    /// The program running in the foreground of a local tab, with its arguments (secrets hidden).
    private(set) var foregroundProgram: String?
    /// The shell's current folder as it last reported it, shown beside the title.
    private(set) var location: String?
    /// The folder beside the title: the shell's current folder, with the home folder as "~".
    var subtitle: String {
        // This PC's folder means nothing while the shell is on a host.
        guard let location, remote == nil else { return "" }
        return ShellLocation.display(location, home: ParityScene.isActive ? ParityScene.home : (ProcessInfo.processInfo.environment["USERPROFILE"] ?? ""))
    }
    /// The tab's number ("Terminal 2"), the lowest free one when it opened.
    var number = 1
    /// A name from Rename Tab; nil shows "Terminal <number>".
    var customName: String?
    var tabName: String { customName ?? "Terminal \(number)" }
    var onTitleChange: ((TerminalPane) -> Void)?
    var onExit: ((TerminalPane) -> Void)?

    /// The pane's named profile; nil is the default profile, whichever that is.
    private(set) var profileID: Foundation.UUID?

    /// Use Profile: the pane takes another profile's look and settings at once.
    func use(profile id: Foundation.UUID?) {
        profileID = id
        apply(TerminalProfile.shared.settings(for: id))
    }

    convenience init(parent: HWND, profileID: Foundation.UUID?) {
        self.init(parent: parent, settings: TerminalProfile.shared.settings(for: profileID))
        self.profileID = profileID
    }

    init(parent: HWND, settings: ProfileSettings) {
        var options = TerminalOptions(cols: 80, rows: 24)
        options.scrollback = settings.scrollbackLines
        terminal = Terminal(delegate: TerminalDelegateProxy.shared, options: options)
        TerminalDelegateProxy.shared.panes[ObjectIdentifier(terminal)] = self
        // The shell's folder, reported at each prompt (see ShellLocation).
        terminal.registerOscHandler(code: 9) { [weak self] payload in
            MainActor.assumeIsolated { self?.setLocation(ShellLocation.folder(osc9: String(decoding: payload, as: UTF8.self))) }
        }
        terminal.registerOscHandler(code: 7) { [weak self] payload in
            MainActor.assumeIsolated { self?.setLocation(ShellLocation.folder(osc7: String(decoding: payload, as: UTF8.self))) }
        }
        hwnd = createWindow(self, className: Self.className, style: DWORD(WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN), parent: parent)
        // Files and folders dropped from File Explorer are typed as paths, as on the Mac and Linux.
        if let hwnd { DragAcceptFiles(hwnd, true) }
        apply(settings)
        startupCommand = settings.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The profile's startup command, typed into a local shell when it starts.
    private var startupCommand = ""

    /// This tab's file explorer, made the first time it's shown, and whether it's showing instead of the terminal.
    var explorer: ExplorerPane?
    var showingExplorer = false
    /// Split panes: set on a tab's first pane once it has been split (see `PaneGroup`).
    var group: PaneGroup?
    /// Tells the workspace this pane took the keyboard focus (for split panes).
    var onFocus: ((TerminalPane) -> Void)?
    /// Selected text, for the feature tests' bridge.
    var bridgeSelection: String { selectedText() }
    /// The focused pane of a split tab is outlined in the accent color, as on the Mac and Linux.
    var outlined = false {
        didSet { if outlined != oldValue { invalidate() } }
    }

    /// The command line this tab's process was started with, which decides how dropped paths are quoted.
    private(set) var commandLine = ""

    /// The shell dropped paths are quoted for.
    var dropQuoting: DropQuoting {
        if remote != nil { return .posix }
        return DropQuoting(commandLine: commandLine)
    }

    /// Starts the shell. Call once the pane has its size, so the shell starts with the right grid.
    func start(commandLine: String = ShellChoice.commandLine, directory: String? = nil, environment: [String: String] = [:]) {
        guard let hwnd, session == nil else { return }
        self.commandLine = commandLine
        let start = directory ?? ProcessInfo.processInfo.environment["USERPROFILE"]
        // A local shell reports its folder at every prompt; until it does, the title shows where it started.
        let launch = remote == nil ? ShellLocation.integrate(commandLine: commandLine, environment: environment) : (commandLine: commandLine, environment: environment)
        if remote == nil { location = start }
        do {
            session = try PseudoConsole(commandLine: launch.commandLine, directory: start, extraEnvironment: launch.environment,
                                        columns: terminal.cols, rows: terminal.rows, window: hwnd)
            if remote == nil {
                SetTimer(hwnd, Self.programTimer, 1000, nil)
                // Waits in the console's input until the shell reads it, like typing ahead.
                if !startupCommand.isEmpty { session?.write(Array((startupCommand + "\r").utf8)) }
            }
        } catch {
            terminal.feed(text: "\u{1b}[31m\(error.localizedDescription)\u{1b}[0m\r\n")
            invalidate()
        }
    }

    /// The host this tab's shell is connected to through ssh, while that ssh runs; nil in a local shell. As on the
    /// Mac and Linux, ssh runs inside the tab's own shell: Connect via SSH types a launcher there, and an `ssh`
    /// typed there is followed the same way. When ssh ends, the tab is back at its shell.
    private(set) var remote: RemoteEndpoint?
    /// The password the login used, when it came from Connect via SSH or a saved login (for the explorer's own
    /// channel and Run Command on Hosts). Kept in memory only.
    private(set) var remotePassword: String?
    private(set) var connectedAt: Date?
    /// Tells the workspace the tab's connection started or ended (the explorer follows it).
    var onRemoteChange: ((TerminalPane) -> Void)?
    /// The login Connect via SSH just typed a launcher for, until its ssh shows up.
    private var expected: (endpoint: RemoteEndpoint, password: String?)?
    /// The ssh process the tab follows.
    private var sshProcess: DWORD?
    private var launcherPath: String?
    /// Whether the shell has written anything yet (its prompt), and how long ago it last did.
    private var hasOutput = false
    private var lastOutput = Date.distantPast
    private var lastOutputAge: TimeInterval { Date().timeIntervalSince(lastOutput) }

    /// Connect via SSH: types the path of a private launcher into this tab's shell (see `SSHLauncher`). A saved
    /// password reaches ssh only through the password helper; without one ssh asks in the terminal, and keys from
    /// ssh-agent work as usual.
    func connectSSH(_ endpoint: RemoteEndpoint, password: String?, waited: Int = 0) {
        // A new tab's shell draws its prompt first, so the launcher knows how much of the screen its line takes.
        if !hasOutput, waited < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.connectSSH(endpoint, password: password, waited: waited + 1) }
            return
        }
        if waited > 0, waited < 50, lastOutputAge < 0.3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.connectSSH(endpoint, password: password, waited: waited + 1) }
            return
        }
        guard let path = SSHLauncher.write(endpoint, password: password, lines: { text in
            // The rows the typed line fills after the prompt, so the launcher can clear exactly those.
            let column = self.terminal.getCursorLocation().x
            return (column + text.count) / max(1, self.terminal.cols) + 1
        }, shell: dropQuoting) else {
            terminal.feed(text: "\u{1b}[31mWindows' OpenSSH client isn't installed. Add it in Settings ▸ System ▸ Optional features ▸ OpenSSH Client.\u{1b}[0m\r\n")
            invalidate()
            return
        }
        expected = (endpoint, password)
        launcherPath = path
        // Typed by the app, so MultiExec doesn't send it to the other terminals.
        sendQuietly(Array((SSHLauncher.typed(path, for: dropQuoting) + "\r").utf8))
        if let hwnd { SetTimer(hwnd, Self.programTimer, 300, nil) } // Notice the ssh soon.
    }

    /// Whether this tab's shell is in an SSH session.
    var isConnected: Bool { remote != nil && sshProcess != nil }

    /// Ends the SSH session; the tab is back at its own shell.
    func disconnect() {
        guard let sshProcess, let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, sshProcess) else { return }
        TerminateProcess(process, 0)
        CloseHandle(process)
        followSSH()
    }

    /// Follows the ssh running under the shell: a new one connects the tab (to the login Connect via SSH started, or
    /// to where a typed ssh goes, resolved with `ssh -G`), and its end returns the tab to this PC.
    private func followSSH() {
        guard let session, !session.hasExited else { return }
        let found = ShellLocation.sshUnder(session.processID)
        if let found {
            guard found.pid != sshProcess else { return }
            sshProcess = found.pid
            if let expected {
                self.expected = nil
                // The launcher has done its part; it goes now even if the session is cut short later.
                if let launcherPath { try? FileManager.default.removeItem(atPath: launcherPath); self.launcherPath = nil }
                setRemote(expected.endpoint, password: expected.password)
            } else if let endpoint = ShellLocation.resolveSSH(found.commandLine) {
                // A typed ssh: a saved login for the same account gives the explorer its password.
                let saved = CredentialStore.shared?.logins.first {
                    $0.host == endpoint.host && $0.port == endpoint.port && $0.username == endpoint.username
                }
                setRemote(endpoint, password: saved?.password.isEmpty == false ? saved?.password : nil)
            }
        } else if sshProcess != nil {
            sshProcess = nil
            setRemote(nil, password: nil)
        }
    }

    private func setRemote(_ endpoint: RemoteEndpoint?, password: String?) {
        guard endpoint != remote || password != remotePassword else { return }
        remote = endpoint
        remotePassword = password
        connectedAt = endpoint == nil ? nil : Date()
        // As on the Mac and Linux, an SSH tab is titled with the account it connected to.
        if let endpoint { title = endpoint.label } else { title = ""; composeLocalTitle() }
        onRemoteChange?(self)
        onTitleChange?(self)
        if let hwnd { SetTimer(hwnd, Self.programTimer, 1000, nil) }
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

    /// The shell ended: the pane closes, then its tab, as on the Mac.
    private func processEnded() {
        sshProcess = nil
        if remote != nil { setRemote(nil, password: nil) }
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

    var isRunning: Bool { session.map { !$0.hasExited } ?? false }

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
        if visible && IsWindowVisible(hwnd) { hasGrid = true }
        if visible { SetFocus(hwnd) }
    }

    func move(to rect: RECT) {
        guard let hwnd else { return }
        MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, true)
    }

    /// Fits the grid to the window: whole cells, at least 2 × 1.
    private func layout() {
        guard let hwnd else { return }
        layoutFind()
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let inset = Self.inset(hwnd)
        let columns = max(2, Int((rect.right - inset.left - inset.right) / max(1, fonts.cellWidth)))
        let rows = max(1, Int((rect.bottom - inset.top - inset.bottom) / max(1, fonts.cellHeight)))
        if columns != terminal.cols || rows != terminal.rows {
            terminal.resize(cols: columns, rows: rows)
            session?.resize(columns: columns, rows: rows)
            scrollOffset = min(scrollOffset, maxScrollOffset)
            // Not when the pane first gets its size, as on Linux.
            if hasGrid, TerminalProfile.shared.showSizeWhileResizing {
                showingBadge = true
                SetTimer(hwnd, Self.badgeTimer, 1200, nil)
            }
        }
        // Sizes taken while the window is still opening (hidden) don't count as resizing.
        if rect.right > 0 && rect.bottom > 0 && IsWindowVisible(hwnd) { hasGrid = true }
    }

    /// The pane has its first size: later changes of the grid show the size badge.
    func markSized() { hasGrid = true
        invalidate()
    }

    /// Space between the window and the text, as on the Mac: 8 px on the left and 6 px on top (4 px elsewhere).
    static func inset(_ hwnd: HWND) -> (left: Int32, top: Int32, right: Int32, bottom: Int32) {
        let dpi = GetDpiForWindow(hwnd)
        return (scaled(8, dpi: dpi), scaled(6, dpi: dpi), scaled(4, dpi: dpi), scaled(4, dpi: dpi))
    }

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
        case WM_TIMER where wParam == Self.badgeTimer:
            KillTimer(hwnd, Self.badgeTimer)
            showingBadge = false
            invalidate()
            return 0
        case WM_TIMER where wParam == Self.programTimer:
            followSSH()
            refreshForegroundProgram()
            return 0
        case WM_TIMER:
            cursorBlinkOn.toggle()
            invalidateCursor()
            return 0
        case WM_SETFOCUS:
            focused = true
            onFocus?(self)
            CreateCaret(hwnd, nil, 1, fonts.cellHeight) // Lets screen readers and IMEs find the cursor.
            restartBlink()
            return 0
        case WM_KILLFOCUS:
            focused = false
            DestroyCaret()
            invalidate()
            return 0
        case WM_DROPFILES:
            // Like Terminal on the Mac: each dropped item as a shell-quoted path, followed by a space.
            let drop = HDROP(OpaquePointer(bitPattern: UInt(wParam)))
            let count = DragQueryFileW(drop, 0xFFFF_FFFF, nil, 0)
            var paths: [String] = []
            for index in 0..<count {
                let length = DragQueryFileW(drop, index, nil, 0)
                var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
                DragQueryFileW(drop, index, &buffer, UINT(buffer.count))
                paths.append(String(decoding: buffer.prefix(Int(length)), as: UTF16.self))
            }
            DragFinish(drop)
            if !paths.isEmpty {
                send(dropQuoting.typed(paths))
                SetForegroundWindow(GetAncestor(hwnd, UINT(GA_ROOT)))
                SetFocus(hwnd)
            }
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
            // The right-click menu, as on the Mac and Linux.
            var point = POINT(x: Int32(loWord(lParam)), y: Int32(hiWord(lParam)))
            ClientToScreen(hwnd, &point)
            SetFocus(hwnd)
            onContextMenu?(self, point)
            return 0
        case WM_COMMAND:
            switch Int32(wParam & 0xFFFF) {
            case FindID.previous.rawValue: findStep(up: true)
            case FindID.next.rawValue: findStep(up: false)
            case FindID.done.rawValue: hideFind()
            case FindID.field.rawValue where Int32((wParam >> 16) & 0xFFFF) == EN_CHANGE: search()
            default: break
            }
            return 0
        case WM_CTLCOLOREDIT, WM_CTLCOLORSTATIC, WM_CTLCOLORBTN:
            return DialogTheme.colors(message, wParam)
        case WM_DPICHANGED_AFTERPARENT:
            apply(TerminalProfile.shared.settings(for: profileID))
            return 0
        case WM_GETDLGCODE:
            return LRESULT(DLGC_WANTALLKEYS | DLGC_WANTCHARS | DLGC_WANTTAB | DLGC_WANTARROWS)
        default:
            return nil
        }
    }

    private func drainOutput() {
        guard let bytes = session?.takeOutput(), !bytes.isEmpty else { return }
        hasOutput = true
        lastOutput = Date()
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
        let inset = Self.inset(hwnd)
        var rect = RECT(left: inset.left + Int32(cursor.x) * fonts.cellWidth - 2, top: inset.top + Int32(cursor.y + scrollOffset) * fonts.cellHeight,
                        right: inset.left + Int32(cursor.x + 2) * fonts.cellWidth + 2, bottom: inset.top + Int32(cursor.y + scrollOffset + 1) * fonts.cellHeight)
        InvalidateRect(hwnd, &rect, false)
    }

    // MARK: Input

    func send(_ bytes: [UInt8]) {
        if scrollOffset != 0 { scrollOffset = 0; invalidate() }
        session?.write(bytes)
        broadcast?(bytes)
    }

    /// MultiExec: receives what the user types or pastes here, to send to the other included terminals. Text the
    /// app types itself, and the emulator's replies to programs, go straight to the session and aren't sent on.
    var broadcast: (([UInt8]) -> Void)?

    /// Typing that MultiExec forwards from another terminal.
    func sendQuietly(_ bytes: [UInt8]) {
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

    /// Select All: the whole scrollback and screen.
    func selectAll() {
        selectionStart = Position(col: 0, row: terminal.buffer.totalLinesTrimmed)
        selectionEnd = Position(col: terminal.cols, row: liveTop + terminal.rows - 1)
        invalidate()
    }

    /// Paste Escaped Text: the clipboard's text quoted for this tab's shell, so it's taken literally.
    func pasteEscaped() {
        guard let hwnd, let text = clipboardText(hwnd), !text.isEmpty else { return }
        send(dropQuoting.literal(text))
    }

    /// The right-click menu: the workspace builds it, so it holds the window's commands too.
    var onContextMenu: ((TerminalPane, POINT) -> Void)?

    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        invalidate()
    }

    /// The cell under a mouse position, in scroll-invariant rows.
    private func cell(at lParam: LPARAM) -> Position {
        let inset = hwnd.map(Self.inset) ?? (left: 0, top: 0, right: 0, bottom: 0)
        let x = Int32(loWord(lParam)) - inset.left, y = Int32(hiWord(lParam)) - inset.top
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

    // MARK: Size badge

    /// "100 × 30" in the middle of the terminal, in its own font at 18 px and semibold, on a rounded card, as on Linux.
    private func drawBadge(_ dc: HDC?, width: Int32, height: Int32) {
        guard let hwnd else { return }
        let dpi = GetDpiForWindow(hwnd)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        let font = withWide(TerminalProfile.shared.settings(for: profileID).family) {
            CreateFontW(-s(18), 0, 0, 0, Int32(FW_SEMIBOLD), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0)
        }
        defer { DeleteObject(font) }
        let old = SelectObject(dc, font)
        defer { SelectObject(dc, old) }
        var text = badgeText.wide
        var size = SIZE()
        GetTextExtentPoint32W(dc, text, Int32(text.count - 1), &size)
        let cardWidth = size.cx + s(28), cardHeight = size.cy + s(16)
        let left = (width - cardWidth) / 2, top = (height - cardHeight) / 2
        let chrome = WindowChrome.Colors(dark: appIsDark)
        let brush = CreateSolidBrush(chrome.background), pen = CreatePen(PS_SOLID, 1, chrome.border)
        let oldBrush = SelectObject(dc, brush), oldPen = SelectObject(dc, pen)
        RoundRect(dc, left, top, left + cardWidth, top + cardHeight, s(16), s(16))
        SelectObject(dc, oldBrush)
        SelectObject(dc, oldPen)
        DeleteObject(brush)
        DeleteObject(pen)
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, chrome.text)
        var rect = RECT(left: left, top: top, right: left + cardWidth, bottom: top + cardHeight)
        DrawTextW(dc, &text, -1, &rect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
    }

    // MARK: Find in Terminal

    private enum FindID: Int32 { case field = 0x4E01, previous, next, done }
    private var findControls: (field: HWND?, previous: HWND?, next: HWND?, done: HWND?, font: HFONT?, glyph: HFONT?)?
    private var findHints = HoverHints()
    private var matches: [(row: Int, start: Int, end: Int)] = []
    private var currentMatch: Int?

    var isFinding: Bool { findControls.map { IsWindowVisible($0.field) } ?? false }
    var findText: String { findControls?.field.map { String(windowText: $0) } ?? "" }
    var findMatchCount: Int { matches.count }

    /// The find bar at the top right of the terminal, as on Linux: the search text, Previous, Next and Done. It
    /// finds as you type, ignores case, wraps around and searches the scrollback.
    func showFind() {
        guard let hwnd else { return }
        if findControls == nil {
            let dpi = GetDpiForWindow(hwnd)
            let font = withWide("Segoe UI") { CreateFontW(-scaled(12, dpi: dpi), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0,
                                                          DWORD(CLEARTYPE_QUALITY), 0, $0) }
            let glyph = withWide("Segoe Fluent Icons") { CreateFontW(-scaled(11, dpi: dpi), 0, 0, 0, Int32(FW_NORMAL), 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0,
                                                                     DWORD(CLEARTYPE_QUALITY), 0, $0) }
            func make(_ cls: String, _ text: String, _ style: DWORD, _ id: FindID, _ chosen: HFONT?) -> HWND? {
                let control = withWide(cls) { c in
                    withWide(text) { t in
                        CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_TABSTOP) | style, 0, 0, 10, 10, hwnd,
                                        HMENU(bitPattern: Int(id.rawValue)), GetModuleHandleW(nil), nil)
                    }
                }
                SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(chosen)))), 1)
                withWide(appIsDark ? (cls == "EDIT" ? "DarkMode_CFD" : "DarkMode_Explorer") : (cls == "EDIT" ? "CFD" : "Explorer")) { _ = SetWindowTheme(control, $0, nil) }
                return control
            }
            let field = make("EDIT", "", DWORD(ES_AUTOHSCROLL) | DWORD(WS_BORDER), .field, font)
            _ = withWide("Find in terminal") { SendMessageW(field, UINT(EM_SETCUEBANNER), 1, LPARAM(Int(bitPattern: $0))) }
            let previous = make("BUTTON", "\u{E70E}", DWORD(BS_PUSHBUTTON), .previous, glyph)
            let next = make("BUTTON", "\u{E70D}", DWORD(BS_PUSHBUTTON), .next, glyph)
            let done = make("BUTTON", "\u{E711}", DWORD(BS_PUSHBUTTON), .done, glyph)
            for (control, name) in [(previous, "Previous match"), (next, "Next match"), (done, "Close Find")] {
                // Screen readers read the button's name, not its glyph.
                if let control { _ = withWide(name) { herb_set_accessible_name(UnsafeMutableRawPointer(control), $0) } }
            }
            findHints.set(field, "Find in Terminal\nType to find text in this terminal and its scrollback.", owner: hwnd)
            findHints.set(previous, "Previous (Return)\nFind the match above.", owner: hwnd)
            findHints.set(next, "Next (Shift+Return)\nFind the match below.", owner: hwnd)
            findHints.set(done, "Done (Esc)\nClose Find and go back to typing.", owner: hwnd)
            findControls = (field, previous, next, done, font, glyph)
        }
        layoutFind()
        guard let controls = findControls else { return }
        for control in [controls.field, controls.previous, controls.next, controls.done] { ShowWindow(control, SW_SHOW) }
        SetFocus(controls.field)
        SendMessageW(controls.field, UINT(EM_SETSEL), 0, -1)
        search()
    }

    func hideFind() {
        guard let controls = findControls else { return }
        for control in [controls.field, controls.previous, controls.next, controls.done] { ShowWindow(control, SW_HIDE) }
        matches = []
        currentMatch = nil
        clearSelection()
        if let hwnd { SetFocus(hwnd) }
    }

    private func layoutFind() {
        guard let hwnd, let controls = findControls else { return }
        let dpi = GetDpiForWindow(hwnd)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let width = min(s(340), rect.right - s(16)), top = s(6)
        var x = rect.right - s(8) - width
        let fieldWidth = width - 3 * s(30)
        MoveWindow(controls.field, x, top, fieldWidth, s(26), true)
        x += fieldWidth + s(2)
        for button in [controls.previous, controls.next, controls.done] {
            MoveWindow(button, x, top, s(28), s(26), true)
            x += s(30)
        }
    }

    /// Finds every match of the text, then shows the last one (the one nearest the prompt), as Linux does.
    private func search() {
        let needle = findText.lowercased()
        matches = []
        currentMatch = nil
        guard !needle.isEmpty else { clearSelection(); return }
        let first = terminal.buffer.totalLinesTrimmed, last = liveTop + terminal.rows - 1
        if first <= last {
            for row in first...last {
                guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
                // One character per column, so a match's index is its column.
                let text = Array(line.translateToString(trimRight: false, skipNullCellsFollowingWide: false).lowercased())
                let pattern = Array(needle)
                guard pattern.count <= text.count else { continue }
                var index = 0
                while index + pattern.count <= text.count {
                    if Array(text[index..<index + pattern.count]) == pattern {
                        matches.append((row, index, index + pattern.count))
                        index += pattern.count
                    } else {
                        index += 1
                    }
                }
            }
        }
        if matches.isEmpty { clearSelection(); MessageBeep(UINT(MB_OK)); return }
        show(match: matches.count - 1)
    }

    /// Previous goes up (older output), Next goes down; both wrap around.
    private func findStep(up: Bool) {
        guard !matches.isEmpty else { search(); return }
        let index = currentMatch ?? matches.count
        show(match: (index + (up ? -1 : 1) + matches.count) % matches.count)
    }

    private func show(match index: Int) {
        currentMatch = index
        let match = matches[index]
        selectionStart = Position(col: match.start, row: match.row)
        selectionEnd = Position(col: match.end, row: match.row)
        // Scrolled so the match is on screen, near the middle when it was off screen.
        if match.row < viewTop || match.row >= viewTop + terminal.rows {
            scrollOffset = max(0, min(maxScrollOffset, liveTop - match.row + terminal.rows / 2))
        }
        invalidate()
    }

    /// For the feature tests' bridge: opens Find with `text` typed in, or steps through the matches.
    func bridgeFind(_ text: String) {
        showFind()
        if let field = findControls?.field { withWide(text) { _ = SetWindowTextW(field, $0) } }
        search()
    }
    func bridgeFindStep(up: Bool) { findStep(up: up) }

    /// Keys in the find field: Return finds the previous match, Shift+Return the next, Esc closes the bar.
    func handleFindKey(_ message: MSG) -> Bool {
        guard let controls = findControls, message.hwnd == controls.field, message.message == UINT(WM_KEYDOWN) else { return false }
        switch Int32(message.wParam) {
        case VK_RETURN: findStep(up: !isPressed(VK_SHIFT)); return true
        case VK_ESCAPE: hideFind(); return true
        default: return false
        }
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

        let inset = Self.inset(hwnd)
        let cw = fonts.cellWidth, ch = fonts.cellHeight
        let top = viewTop
        let cursor = terminal.getCursorLocation()
        let cursorRow = cursor.y + scrollOffset

        for screenRow in 0..<terminal.rows {
            let y = inset.top + Int32(screenRow) * ch
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
                let x = inset.left + Int32(runStart) * cw
                let runRect = RECT(left: x, top: y, right: inset.left + Int32(column) * cw, bottom: y + ch)
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
            if screenRow == cursorRow && cursorVisible { drawCursor(dc, line: line, column: cursor.x, x: inset.left + Int32(cursor.x) * cw, y: y) }
        }
        if focused { SetCaretPos(inset.left + Int32(cursor.x) * cw, inset.top + Int32(cursorRow) * ch) }
        if showingBadge { drawBadge(dc, width: width, height: height) }
        if outlined {
            let line = max(1, scaled(1.5, dpi: GetDpiForWindow(hwnd)))
            let accent = systemAccentColor
            fill(dc, RECT(left: 0, top: 0, right: width, bottom: line), accent)
            fill(dc, RECT(left: 0, top: height - line, right: width, bottom: height), accent)
            fill(dc, RECT(left: 0, top: 0, right: line, bottom: height), accent)
            fill(dc, RECT(left: width - line, top: 0, right: width, bottom: height), accent)
        }
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

    /// A local tab shows user@host, as on the Mac and Linux, and the running program's name beside it. Shells
    /// report their own path ("C:\…\pwsh.exe"), and Command Prompt adds the command line while it runs
    /// ("C:\…\cmd.exe - ping -n 5 host"); only the program's name is shown, never its arguments, which can
    /// hold passwords.
    static let userAtHost: String = {
        if ParityScene.isActive { return ParityScene.title }
        let environment = ProcessInfo.processInfo.environment
        return (environment["USERNAME"] ?? "user") + "@" + (environment["COMPUTERNAME"] ?? "localhost").lowercased()
    }()

    static func localTitle(reported: String) -> String {
        // While a command runs, Command Prompt shows "<title> - <command line>"; the program in the foreground
        // is read from the process list instead (see refreshForegroundProgram), so only the title part counts.
        let trimmed = (reported.components(separatedBy: " - ").first ?? reported).trimmingCharacters(in: .whitespaces)
        let isShellPath = trimmed.lowercased().hasSuffix(".exe") && trimmed.contains("\\")
        if trimmed.isEmpty || isShellPath || trimmed == userAtHost { return userAtHost }
        return userAtHost + " — " + trimmed
    }

    // MARK: Title and location

    private func setLocation(_ folder: String?) {
        // A remote shell's folders are the host's, not this PC's.
        guard remote == nil, let folder, folder != location else { return }
        location = folder
        onTitleChange?(self)
    }

    /// A local tab's title: the shell's title, and the program in the foreground beside it, as on the Mac.
    private func composeLocalTitle() {
        let next = foregroundProgram.map { baseTitle + " — " + $0 } ?? baseTitle
        guard next != title else { return }
        title = next
        onTitleChange?(self)
    }

    /// What closing this tab would end, as the Mac's question lists it: the program in the foreground, or the
    /// SSH session. Nil for a local shell with nothing running.
    var runningProgram: String? {
        if let remote, isConnected { return "ssh (\(remote.label))" }
        refreshForegroundProgram()
        return foregroundProgram.map { String($0.split(separator: " ").first ?? Substring($0)) }
    }

    private func refreshForegroundProgram() {
        guard remote == nil, let session, !session.hasExited else { return }
        let program = ShellLocation.foregroundChild(of: session.processID)
            .flatMap(ShellLocation.commandLine(of:)).map(ShellLocation.titleText(commandLine:))
        guard program != foregroundProgram else { return }
        foregroundProgram = program?.isEmpty == true ? nil : program
        composeLocalTitle()
    }

    // MARK: TerminalDelegate

    nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session?.write(Array(data)) }
    }

    nonisolated func setTerminalTitle(source: Terminal, title: String) {
        MainActor.assumeIsolated {
            if let remote {
                // As on the Mac and Linux, an SSH tab is titled with the account it connected to, whatever the
                // remote shell calls itself.
                self.title = remote.label
            } else {
                baseTitle = Self.localTitle(reported: title)
                composeLocalTitle()
                return
            }
            onTitleChange?(self)
        }
    }

    nonisolated func showCursor(source: Terminal) { MainActor.assumeIsolated { cursorVisible = true; invalidate() } }
    nonisolated func hideCursor(source: Terminal) { MainActor.assumeIsolated { cursorVisible = false; invalidate() } }

    nonisolated func bell(source: Terminal) {
        MainActor.assumeIsolated {
            switch TerminalProfile.shared.settings(for: profileID).bell {
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
