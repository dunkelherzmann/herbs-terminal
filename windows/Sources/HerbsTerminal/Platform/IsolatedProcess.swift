import Foundation
import WinSDK

/// Starts child processes that inherit only the handles they're given. Foundation's `Process` lets a child inherit
/// every inheritable handle the app has open at that moment, so an SFTP relay started while a file was being
/// written (a save, a download, the settings) kept that file open, and locked, for as long as the relay ran.
enum ChildLaunch {
    /// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, which the Windows headers build with a macro Swift doesn't import.
    private static let handleList = DWORD_PTR(0x0002_0002)

    /// Runs `command` with these standard handles, and no others, inherited. Returns nil when it can't start.
    static func start(_ command: [String], input: HANDLE?, output: HANDLE?, error: HANDLE?, flags: DWORD) -> PROCESS_INFORMATION? {
        var handles: [HANDLE] = []
        for handle in [input, output, error] {
            guard let handle, handle != INVALID_HANDLE_VALUE, !handles.contains(handle) else { continue }
            SetHandleInformation(handle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT))
            handles.append(handle)
        }
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { storage.deallocate() }
        let attributes = OpaquePointer(storage)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else { return nil }
        defer { DeleteProcThreadAttributeList(attributes) }
        let values = UnsafeMutablePointer<HANDLE?>.allocate(capacity: max(1, handles.count))
        defer { values.deallocate() }
        for (index, handle) in handles.enumerated() { values[index] = handle }
        if !handles.isEmpty {
            guard UpdateProcThreadAttribute(attributes, 0, handleList, UnsafeMutableRawPointer(values),
                                            SIZE_T(handles.count * MemoryLayout<HANDLE>.size), nil, nil) else { return nil }
        }
        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.StartupInfo.hStdInput = input
        startup.StartupInfo.hStdOutput = output
        startup.StartupInfo.hStdError = error
        startup.lpAttributeList = attributes
        var info = PROCESS_INFORMATION()
        var line = command.map(quoteArgument).joined(separator: " ").wide
        let started = withUnsafeMutablePointer(to: &startup) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startupInfo in
                CreateProcessW(nil, &line, nil, nil, handles.isEmpty ? false : true, flags | DWORD(EXTENDED_STARTUPINFO_PRESENT),
                               nil, nil, startupInfo, &info)
            }
        }
        return started ? info : nil
    }
}

/// A child process with pipes for its standard input and output (its error output goes nowhere), which inherits
/// nothing else: what `SFTPClient` runs the SFTP relay as.
final class IsolatedProcess: @unchecked Sendable {
    /// The child's standard input, and its standard output.
    let input: FileHandle
    let output: FileHandle
    private let process: HANDLE

    init(executable: String, arguments: [String]) throws {
        var inRead: HANDLE?, inWrite: HANDLE?, outRead: HANDLE?, outWrite: HANDLE?
        guard CreatePipe(&inRead, &inWrite, nil, 0), CreatePipe(&outRead, &outWrite, nil, 0),
              let inRead, let inWrite, let outRead, let outWrite else {
            throw FileIssue("Couldn't start \((executable as NSString).lastPathComponent): no pipe (error \(GetLastError())).")
        }
        let null = withWide("NUL") {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        defer {
            // The child has its own copies of its ends now.
            CloseHandle(inRead)
            CloseHandle(outWrite)
            if let null, null != INVALID_HANDLE_VALUE { CloseHandle(null) }
        }
        guard let info = ChildLaunch.start([executable] + arguments, input: inRead, output: outWrite, error: null,
                                           flags: DWORD(CREATE_NO_WINDOW)) else {
            let code = GetLastError()
            CloseHandle(inWrite)
            CloseHandle(outRead)
            throw FileIssue("Couldn't start \((executable as NSString).lastPathComponent) (error \(code)).")
        }
        CloseHandle(info.hThread)
        process = info.hProcess
        input = FileHandle(fileDescriptor: _open_osfhandle(Int(bitPattern: inWrite), _O_WRONLY | _O_BINARY), closeOnDealloc: true)
        output = FileHandle(fileDescriptor: _open_osfhandle(Int(bitPattern: outRead), _O_RDONLY | _O_BINARY), closeOnDealloc: true)
    }

    var isRunning: Bool { WaitForSingleObject(process, 0) == WAIT_TIMEOUT }
    func terminate() { TerminateProcess(process, 1) }
    deinit { CloseHandle(process) }
}
