import Foundation
import WinSDK

/// A shell running in a Windows pseudo console (ConPTY). Output arrives on a reader thread and is handed to the
/// window over `WM_APP_OUTPUT`; the window drains it with `takeOutput()` on its own thread.
final class PseudoConsole: @unchecked Sendable {
    private var console: HPCON?
    private var input: HANDLE?
    private var output: HANDLE?
    private var process: HANDLE?
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var closed = false
    let processID: DWORD

    /// Starts `commandLine` in `directory` with a `columns` × `rows` console. `notify` is posted to `window`
    /// when output is waiting, and `exited` when the shell ends.
    init(commandLine: String, directory: String?, columns: Int, rows: Int, window: HWND) throws {
        var inputRead: HANDLE?, inputWrite: HANDLE?, outputRead: HANDLE?, outputWrite: HANDLE?
        guard CreatePipe(&inputRead, &inputWrite, nil, 0), CreatePipe(&outputRead, &outputWrite, nil, 0) else {
            throw FileIssue("Couldn't create the pipes for the shell.")
        }
        var console: HPCON?
        let size = COORD(X: SHORT(clamping: columns), Y: SHORT(clamping: rows))
        guard CreatePseudoConsole(size, inputRead, outputWrite, 0, &console) >= 0, let console else {
            CloseHandle(inputRead); CloseHandle(inputWrite); CloseHandle(outputRead); CloseHandle(outputWrite)
            throw FileIssue("Windows couldn't create a pseudo console (needs Windows 10 1809 or later).")
        }
        // The console owns its ends of the pipes now.
        CloseHandle(inputRead)
        CloseHandle(outputWrite)

        var listSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &listSize)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
        defer { list.deallocate() }
        let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(list)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &listSize) else {
            ClosePseudoConsole(console); CloseHandle(inputWrite); CloseHandle(outputRead)
            throw FileIssue("Couldn't prepare the shell's start-up attributes.")
        }
        defer { DeleteProcThreadAttributeList(attributes) }
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE; the macro doesn't reach Swift.
        let pseudoConsoleAttribute = DWORD_PTR(0x0002_0016)
        guard UpdateProcThreadAttribute(attributes, 0, pseudoConsoleAttribute, UnsafeMutableRawPointer(console),
                                        SIZE_T(MemoryLayout<HPCON>.size), nil, nil) else {
            ClosePseudoConsole(console); CloseHandle(inputWrite); CloseHandle(outputRead)
            throw FileIssue("Couldn't attach the pseudo console.")
        }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        // Without this, a shell started from an app whose own output is redirected writes there instead.
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.lpAttributeList = attributes
        var info = PROCESS_INFORMATION()
        var command = commandLine.wide
        let started = withUnsafeMutablePointer(to: &startup) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startupInfo in
                if let directory {
                    return withWide(directory) {
                        CreateProcessW(nil, &command, nil, nil, false, DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT),
                                       nil, $0, startupInfo, &info)
                    }
                }
                return CreateProcessW(nil, &command, nil, nil, false, DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT),
                                      nil, nil, startupInfo, &info)
            }
        }
        guard started else {
            ClosePseudoConsole(console); CloseHandle(inputWrite); CloseHandle(outputRead)
            throw FileIssue("Couldn't start \(commandLine) (error \(GetLastError())).")
        }
        CloseHandle(info.hThread)
        self.console = console
        self.input = inputWrite
        self.output = outputRead
        self.process = info.hProcess
        self.processID = info.dwProcessId

        let windowValue = Int(bitPattern: UnsafeRawPointer(window))
        let reader = Thread { [self] in readLoop(window: windowValue) }
        reader.name = "ConPTY reader"
        reader.start()
        let process = info.hProcess
        let waiter = Thread {
            WaitForSingleObject(process, INFINITE)
            PostMessageW(HWND(bitPattern: windowValue), UINT(WM_APP_EXITED), 0, 0)
        }
        waiter.name = "Shell exit"
        waiter.start()
    }

    private func readLoop(window: Int) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var read: DWORD = 0
            guard let output, ReadFile(output, &buffer, DWORD(buffer.count), &read, nil), read > 0 else { break }
            lock.lock()
            let wasEmpty = pending.isEmpty
            pending.append(contentsOf: buffer[0..<Int(read)])
            lock.unlock()
            if wasEmpty { PostMessageW(HWND(bitPattern: window), UINT(WM_APP_OUTPUT), 0, 0) }
        }
    }

    /// Everything the shell wrote since the last call.
    func takeOutput() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let bytes = pending
        pending.removeAll(keepingCapacity: true)
        return bytes
    }

    func write(_ bytes: [UInt8]) {
        guard let input, !bytes.isEmpty, !closed else { return }
        var offset = 0
        while offset < bytes.count {
            var written: DWORD = 0
            let ok = bytes[offset...].withUnsafeBytes { WriteFile(input, $0.baseAddress, DWORD($0.count), &written, nil) }
            guard ok, written > 0 else { return }
            offset += Int(written)
        }
    }

    func resize(columns: Int, rows: Int) {
        guard let console, !closed else { return }
        ResizePseudoConsole(console, COORD(X: SHORT(clamping: columns), Y: SHORT(clamping: rows)))
    }

    var hasExited: Bool {
        guard let process else { return true }
        return WaitForSingleObject(process, 0) == WAIT_OBJECT_0
    }

    /// Ends the session. ClosePseudoConsole can wait for the output pipe to drain, so it runs off the UI thread;
    /// the reader thread keeps draining until the pipe breaks.
    func close() {
        guard !closed else { return }
        closed = true
        let console = self.console, input = self.input, process = self.process
        self.console = nil
        Thread.detachNewThread {
            if let console { ClosePseudoConsole(console) }
            if let input { CloseHandle(input) }
            if let process { CloseHandle(process) }
        }
    }

    deinit {
        close()
    }
}

let WM_APP_OUTPUT = Int32(WM_APP) + 1
let WM_APP_EXITED = Int32(WM_APP) + 2

struct FileIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The shell new tabs start: PowerShell 7 when it's installed, otherwise Windows PowerShell.
enum DefaultShell {
    static var commandLine: String {
        if let pwsh = find("pwsh.exe") { return "\"\(pwsh)\" -NoLogo" }
        if let powershell = find("powershell.exe") { return "\"\(powershell)\" -NoLogo" }
        return "cmd.exe"
    }

    static func find(_ name: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) * 4)
        let length = withWide(name) { SearchPathW(nil, $0, nil, DWORD(buffer.count), &buffer, nil) }
        guard length > 0, Int(length) < buffer.count else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
    }
}
