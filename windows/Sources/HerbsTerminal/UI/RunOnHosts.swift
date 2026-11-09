import Foundation
import WinSDK

/// One destination for Run Command on Hosts: a saved login, or the tab's live connection.
struct HostTarget: Hashable, Sendable {
    let endpoint: RemoteEndpoint
    let password: String?
    let source: String
    var id: String { "\(endpoint.username)@\(endpoint.host):\(endpoint.port)" }

    static func == (a: HostTarget, b: HostTarget) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HostResult: Sendable {
    enum Outcome: Equatable { case running, succeeded, failed(Int32), notReached(String), cancelled }
    let target: HostTarget
    var outcome: Outcome = .running
    var output = ""
    var seconds: Double = 0
    var id: String { target.id }

    var summary: String {
        let time = String(format: "%.1fs", seconds)
        switch outcome {
        case .running: return "running…"
        case .succeeded: return "exit 0 · \(time)"
        case .failed(let code): return "exit \(code) · \(time)"
        case .notReached(let reason): return "not reached: \(reason)"
        case .cancelled: return "stopped"
        }
    }
}

/// Runs the same command on several hosts at once, as on the Mac and Linux: each over its own non-interactive
/// ssh channel (no terminal, strict host-key checking, one password try, no retries), never typing into a
/// session, and each host reported on its own. Windows' ssh is started through the explorer's relay, so a saved
/// password reaches it only through the password helper.
@MainActor
final class MultiHostRunner {
    var command = ""
    var selected = Set<String>()
    private(set) var results: [HostResult] = []
    private(set) var running = false
    var onChange: (() -> Void)?
    private var processes: [String: Process] = [:]
    private var cancelled = Set<String>()

    nonisolated static let outputLimit = 64 * 1024

    func run(_ targets: [HostTarget]) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !targets.isEmpty, !running else { return }
        running = true
        cancelled = []
        results = targets.map { HostResult(target: $0) }
        onChange?()
        var left = targets.count
        for target in targets {
            let process: Process
            let preamble: String
            do {
                (process, preamble) = try Self.makeProcess(target, command: command)
            } catch {
                finish(HostResult(target: target, outcome: .notReached(error.localizedDescription)))
                left -= 1
                continue
            }
            processes[target.id] = process
            // Started here, on the main thread: a process started on another thread while this one has a file open
            // would inherit that file's handle and keep it open as long as ssh runs.
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            let started = Date()
            do { try process.run() } catch {
                finish(HostResult(target: target, outcome: .notReached(error.localizedDescription)))
                left -= 1
                continue
            }
            let running = ProcessBox(process)
            MainThread.background({ Self.execute(running.process, input: input, output: output, started: started, preamble: preamble, target: target) }) { [weak self] result in
                guard let self else { return }
                if case .success(let value) = result { self.finish(value) }
                left -= 1
                if left == 0 { self.processes = [:]; self.running = false; self.onChange?() }
            }
        }
        if left == 0 { running = false; onChange?() }
    }

    func cancel() {
        for (id, process) in processes where process.isRunning {
            cancelled.insert(id)
            process.terminate()
            if let index = results.firstIndex(where: { $0.id == id }) { results[index].outcome = .cancelled }
        }
        onChange?()
    }

    private func finish(_ result: HostResult) {
        guard let index = results.firstIndex(where: { $0.id == result.id }) else { return }
        if cancelled.contains(result.id) { results[index].output = result.output } else { results[index] = result }
        onChange?()
    }

    private static func makeProcess(_ target: HostTarget, command: String) throws -> (Process, String) {
        let address = try Tailcat.address(for: target.endpoint)
        if address != nil { Tailcat.startSocks() }
        let session = RemoteSession(endpoint: target.endpoint, password: target.password, tailcatAddress: address)
        let setup = try session.relaySetup()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AskpassBroker.executablePath)
        // -T: no terminal, so nothing waits at a prompt. Unknown host keys are refused (relaySetup), not accepted.
        var environment = ProcessInfo.processInfo.environment
        environment["HERBSTERMINAL_RELAY_ERRORS"] = "1"
        process.environment = environment
        process.arguments = [SFTPRelay.flag] + setup.arguments
            + ["-o", "ConnectTimeout=10", "-T", setup.destination, command]
        return (process, setup.preamble)
    }

    nonisolated private static func execute(_ process: Process, input: Pipe, output: Pipe, started: Date, preamble: String,
                                            target: HostTarget) -> HostResult {
        var result = HostResult(target: target)
        try? input.fileHandleForWriting.write(contentsOf: Data(preamble.utf8))
        try? input.fileHandleForWriting.close()
        // Only the first `outputLimit` bytes are kept; the rest is read and dropped, so a command that prints
        // gigabytes can't fill memory.
        var kept = Data(), dropped = false
        let handle = output.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            let room = outputLimit - kept.count
            if room > 0 { kept.append(chunk.prefix(room)) }
            if chunk.count > room { dropped = true }
        }
        process.waitUntilExit()
        result.seconds = Date().timeIntervalSince(started)
        result.output = String(decoding: kept, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
        if dropped { result.output += "\n… output truncated" }
        let status = process.terminationStatus
        if status == 0 {
            result.outcome = .succeeded
        } else if status == 255 || (2...4).contains(status) && result.output.isEmpty {
            // ssh's own failure (or the relay's): the command never ran there.
            let reason = result.output.split(separator: "\n").last.map(String.init) ?? "ssh could not connect."
            result.outcome = .notReached(reason)
        } else {
            result.outcome = .failed(status)
        }
        return result
    }
}

/// A running ssh, handed to the thread that waits for it.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Run Command on Hosts (Main Menu ▸ Shell), laid out as on the Mac and Linux: the hosts with checkboxes, the
/// command, what will run where, the results per host, and Stop, Close and Run.
@MainActor
final class RunOnHostsWindow: WindowObject {
    static let className = "HerbsTerminalRunOnHosts"
    private static var current: RunOnHostsWindow?

    private(set) var hwnd: HWND?
    private let runner: MultiHostRunner
    private let targets: [HostTarget]
    private var font: HFONT?, bold: HFONT?, mono: HFONT?
    private var heading, lockNote, unlock, empty, hostsLabel, list, commandLabel, command, summary, results, stop, close, run: HWND?
    private let hints = HoverHints()

    private enum ID: Int32 { case unlock = 4100, stop, close, run, command, list }

    static func show(owner: HWND?, runner: MultiHostRunner, targets: [HostTarget]) {
        if let window = current?.hwnd { DestroyWindow(window) }
        current = RunOnHostsWindow(owner: owner, runner: runner, targets: targets)
    }

    private init(owner: HWND?, runner: MultiHostRunner, targets: [HostTarget]) {
        self.runner = runner
        self.targets = targets
        var controls = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_LISTVIEW_CLASSES))
        InitCommonControlsEx(&controls)
        let dpi = owner.map { GetDpiForWindow($0) } ?? 96
        var rect = RECT(left: 0, top: 0, right: scaled(580, dpi: dpi), bottom: scaled(640, dpi: dpi))
        let style = DWORD(WS_OVERLAPPEDWINDOW)
        AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (rect.right - rect.left)) / 2
            y = ownerRect.top + scaled(40, dpi: dpi)
        }
        hwnd = createWindow(self, className: Self.className, title: "Run Command on Hosts", style: style, exStyle: DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: owner)
        guard let hwnd else { return }
        func makeFont(_ name: String, _ size: Double, _ weight: Int32) -> HFONT? {
            withWide(name) { CreateFontW(-scaled(size, dpi: dpi), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0) }
        }
        font = makeFont("Segoe UI", 12, Int32(FW_NORMAL))
        bold = makeFont("Segoe UI", 15, Int32(FW_SEMIBOLD))
        mono = makeFont(TerminalProfile.shared.settings(for: nil).family, 12, Int32(FW_NORMAL))

        heading = control("STATIC", "Multi-Host Commands", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), font: bold)
        if let store = CredentialStore.shared, store.isLocked {
            lockNote = control("STATIC", "Saved logins are locked with your Administrator Password.", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX))
            unlock = control("BUTTON", "Unlock…", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), id: .unlock)
            hints.set(unlock, "Unlock\nEnter the Administrator Password, then reopen Run Command on Hosts to pick saved hosts.", owner: hwnd)
        }
        if targets.isEmpty {
            empty = control("STATIC", "No hosts yet. Save a login in Connect via SSH, or connect this tab, and it appears here.",
                            DWORD(SS_LEFT) | DWORD(SS_NOPREFIX))
        } else {
            hostsLabel = control("STATIC", "Hosts", DWORD(SS_LEFT))
            list = control(WC_LISTVIEWW_NAME, "", DWORD(LVS_REPORT) | DWORD(LVS_NOCOLUMNHEADER) | DWORD(LVS_SINGLESEL) | DWORD(WS_BORDER) | DWORD(WS_TABSTOP),
                           id: .list)
            SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE), 0, LPARAM(LVS_EX_FULLROWSELECT | LVS_EX_CHECKBOXES | LVS_EX_DOUBLEBUFFER))
            for (index, width) in [330.0, 190.0].enumerated() {
                var column = LVCOLUMNW()
                column.mask = UINT(LVCF_WIDTH)
                column.cx = scaled(width, dpi: dpi)
                _ = withUnsafeMutablePointer(to: &column) { SendMessageW(list, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: $0))) }
            }
            for (row, target) in targets.enumerated() {
                let title = target.endpoint.label + (target.endpoint.port == 22 ? "" : ":\(target.endpoint.port)")
                for (column, text) in [title, target.source].enumerated() {
                    var item = LVITEMW()
                    item.mask = UINT(LVIF_TEXT)
                    item.iItem = Int32(row)
                    item.iSubItem = Int32(column)
                    var units = text.wide
                    units.withUnsafeMutableBufferPointer { pointer in
                        item.pszText = pointer.baseAddress
                        _ = withUnsafeMutablePointer(to: &item) {
                            SendMessageW(list, UINT(column == 0 ? LVM_INSERTITEMW : LVM_SETITEMW), 0, LPARAM(Int(bitPattern: $0)))
                        }
                    }
                }
                setChecked(row, runner.selected.contains(target.id))
            }
            hints.set(list, "Hosts\nCheck the hosts the command runs on.", owner: hwnd)
            commandLabel = control("STATIC", "Command to run on each host", DWORD(SS_LEFT))
            command = control("EDIT", runner.command, DWORD(ES_MULTILINE) | DWORD(ES_AUTOVSCROLL) | DWORD(ES_WANTRETURN) | DWORD(WS_BORDER)
                              | DWORD(WS_VSCROLL) | DWORD(WS_TABSTOP), id: .command, font: mono)
            hints.set(command, "Command\nRuns once per host in that account's login shell, without a terminal. Nothing is retried.", owner: hwnd)
            summary = control("STATIC", "", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX))
        }
        results = control("EDIT", "", DWORD(ES_MULTILINE) | DWORD(ES_READONLY) | DWORD(ES_AUTOVSCROLL) | DWORD(WS_VSCROLL) | DWORD(WS_BORDER)
                          | DWORD(WS_TABSTOP), font: mono)
        stop = control("BUTTON", "Stop", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), id: .stop)
        close = control("BUTTON", "Close", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), id: .close)
        run = control("BUTTON", "Run", DWORD(BS_DEFPUSHBUTTON) | DWORD(WS_TABSTOP), id: .run)
        hints.set(stop, "Stop\nEnd the command on hosts that are still running it.", owner: hwnd)
        hints.set(close, "Close (Esc)\nClose this panel.", owner: hwnd)
        hints.set(run, "Run (Ctrl+Enter)\nSend the command to every selected host at once.", owner: hwnd)
        runner.onChange = { [weak self] in self?.refresh() }
        layout()
        refresh()
        DialogTheme.apply(to: hwnd)
        // Multi-line fields take the explorer's theme, so their scroll bars follow light and dark too.
        for field in [command, results] where field != nil {
            withWide(appIsDark ? "DarkMode_Explorer" : "Explorer") { _ = SetWindowTheme(field, $0, nil) }
        }
        ShowWindow(hwnd, TestScript.active || ParityScene.isActive ? SW_SHOWNOACTIVATE : SW_SHOW)
        TestDesktop.place(hwnd)
        if command != nil, !(TestScript.active || ParityScene.isActive) { SetFocus(command) }
    }

    private func control(_ cls: String, _ text: String, _ style: DWORD, id: ID? = nil, font chosen: HFONT? = nil) -> HWND? {
        let window = withWide(cls) { c in
            withWide(text) { t in
                CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style, 0, 0, 10, 10, hwnd,
                                HMENU(bitPattern: Int(id?.rawValue ?? 0)), GetModuleHandleW(nil), nil)
            }
        }
        SendMessageW(window, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(chosen ?? font)))), 1)
        return window
    }

    private func setChecked(_ row: Int, _ on: Bool) {
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_STATEIMAGEMASK)
        item.state = UINT((on ? 2 : 1) << 12)
        _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_SETITEMSTATE), WPARAM(row), LPARAM(Int(bitPattern: $0))) }
    }

    private func isChecked(_ row: Int) -> Bool {
        (SendMessageW(list, UINT(LVM_GETITEMSTATE), WPARAM(row), LPARAM(LVIS_STATEIMAGEMASK)) >> 12) == 2
    }

    private var chosen: [HostTarget] { targets.filter { runner.selected.contains($0.id) } }

    private func layout() {
        guard let hwnd else { return }
        let dpi = GetDpiForWindow(hwnd)
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        let margin = s(20), width = rect.right - 2 * margin
        var y = margin
        MoveWindow(heading, margin, y, width, s(24), true)
        y += s(32)
        if lockNote != nil {
            MoveWindow(lockNote, margin, y + s(5), width - s(100), s(20), true)
            MoveWindow(unlock, rect.right - margin - s(90), y, s(90), s(28), true)
            y += s(38)
        }
        if empty != nil {
            MoveWindow(empty, margin, y, width, s(40), true)
            y += s(48)
        }
        if list != nil {
            MoveWindow(hostsLabel, margin, y, width, s(18), true)
            y += s(22)
            MoveWindow(list, margin, y, width, s(140), true)
            // The host takes what the source column leaves.
            var inside = RECT()
            GetClientRect(list, &inside)
            SendMessageW(list, UINT(LVM_SETCOLUMNWIDTH), 1, LPARAM(s(170)))
            SendMessageW(list, UINT(LVM_SETCOLUMNWIDTH), 0, LPARAM(max(s(100), inside.right - s(170))))
            y += s(152)
            MoveWindow(commandLabel, margin, y, width, s(18), true)
            y += s(22)
            MoveWindow(command, margin, y, width, s(64), true)
            y += s(72)
            MoveWindow(summary, margin, y, width, s(36), true)
            y += s(44)
        }
        let buttonTop = rect.bottom - margin - s(30)
        MoveWindow(results, margin, y, width, max(s(40), buttonTop - s(12) - y), true)
        MoveWindow(stop, margin, buttonTop, s(84), s(30), true)
        MoveWindow(run, rect.right - margin - s(84), buttonTop, s(84), s(30), true)
        MoveWindow(close, rect.right - margin - s(84) * 2 - s(8), buttonTop, s(84), s(30), true)
    }

    private func refresh() {
        guard hwnd != nil else { return }
        let chosen = chosen
        let text = chosen.isEmpty ? "Select at least one host."
            : "Will run on \(chosen.map(\.endpoint.label).joined(separator: ", ")) — each account's login shell, non-interactive (no TTY)."
        withWide(text) { _ = SetWindowTextW(summary, $0) }
        EnableWindow(run, !runner.running && !chosen.isEmpty && !runner.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        ShowWindow(stop, runner.running ? SW_SHOW : SW_HIDE)
        // One block per host: its outcome, then what it printed.
        let blocks = runner.results.map { result -> String in
            let mark: String
            switch result.outcome {
            case .running: mark = "…"
            case .succeeded: mark = "✓"
            case .failed: mark = "✗"
            case .notReached: mark = "⚠"
            case .cancelled: mark = "■"
            }
            var block = "\(mark) \(result.target.endpoint.label)  —  \(result.summary)"
            if !result.output.isEmpty { block += "\n" + result.output }
            return block
        }
        let shown = blocks.joined(separator: "\n\n").replacingOccurrences(of: "\n", with: "\r\n")
        ShowWindow(results, runner.results.isEmpty ? SW_HIDE : SW_SHOW)
        withWide(shown) { _ = SetWindowTextW(results, $0) }
    }

    /// For the feature tests' bridge: what the window shows.
    var bridgeState: [String: Any] {
        ["hosts": targets.map(\.id), "selected": chosen.map(\.id), "running": runner.running,
         "results": runner.results.map { ["host": $0.id, "summary": $0.summary, "output": $0.output] as [String: Any] }]
    }

    /// For the feature tests' bridge: ticks hosts, sets the command and runs it, as the controls would.
    func bridgeRun(hosts: [String], command text: String) {
        runner.selected = Set(hosts)
        for (row, target) in targets.enumerated() { setChecked(row, runner.selected.contains(target.id)) }
        runner.command = text
        withWide(text) { _ = SetWindowTextW(command, $0) }
        runner.run(chosen)
    }

    static var open: RunOnHostsWindow? { current?.hwnd == nil ? nil : current }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if let themed = DialogTheme.handle(hwnd, message, wParam) { return themed }
        switch Int32(message) {
        case WM_SIZE:
            layout()
            return 0
        case WM_COMMAND:
            let id = Int32(wParam & 0xFFFF), code = Int32((wParam >> 16) & 0xFFFF)
            if id == IDCANCEL { DestroyWindow(hwnd); return 0 }
            switch ID(rawValue: id) {
            case .run?: runner.run(chosen)
            case .stop?: runner.cancel()
            case .close?: DestroyWindow(hwnd)
            case .unlock?:
                if let store = CredentialStore.shared, LoginVaultPrompts.unlock(store, owner: hwnd) { DestroyWindow(hwnd) }
            case .command? where code == EN_CHANGE:
                runner.command = String(windowText: command!)
                refresh()
            default: break
            }
            return 0
        case WM_NOTIFY:
            if let header = UnsafePointer<NMHDR>(bitPattern: UInt(lParam)), header.pointee.hwndFrom == list,
               Int32(bitPattern: header.pointee.code) == -101 /* LVN_ITEMCHANGED */ {
                for (row, target) in targets.enumerated() {
                    if isChecked(row) { runner.selected.insert(target.id) } else { runner.selected.remove(target.id) }
                }
                refresh()
            }
            return nil
        case WM_DESTROY:
            runner.onChange = nil
            hints.release()
            for item in [font, bold, mono] where item != nil { DeleteObject(item) }
            if Self.current === self { Self.current = nil }
            return 0
        default:
            return nil
        }
    }

    /// Ctrl+Enter runs (Enter makes a new line in the command); Esc closes. Returns true when handled.
    func handleKey(_ message: MSG) -> Bool {
        guard let hwnd, message.message == UINT(WM_KEYDOWN), IsChild(hwnd, message.hwnd) else { return false }
        if message.wParam == WPARAM(VK_RETURN), isPressed(VK_CONTROL) {
            if IsWindowEnabled(run) { runner.run(chosen) }
            return true
        }
        if message.wParam == WPARAM(VK_ESCAPE) { DestroyWindow(hwnd); return true }
        return false
    }
}
