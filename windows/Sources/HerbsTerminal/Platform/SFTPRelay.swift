import Foundation
import WinSDK

/// `HerbsTerminal.exe --sftp-relay <ssh arguments>`: how the explorer starts ssh for a host's files. The first line
/// on standard input is `<pipe> <token>` for the password helper (or `-` without a saved password); the relay
/// sets the helper's variables for ssh alone, starts it without a window on the same standard input and output,
/// and waits for it. The token thus never appears in a command line or in the app's own environment, and a job
/// object ends ssh when the relay ends.
enum SFTPRelay {
    static let flag = "--sftp-relay"

    static func run(_ sshArguments: [String]) -> Int32 {
        let input = GetStdHandle(STD_INPUT_HANDLE)
        // Byte by byte, so nothing after the line is consumed: the rest belongs to ssh.
        var line = [UInt8]()
        var byte: UInt8 = 0
        var read: DWORD = 0
        while ReadFile(input, &byte, 1, &read, nil), read == 1, byte != 10 {
            line.append(byte)
            if line.count > 1024 { return 2 }
        }
        let parts = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        if parts.count == 2 {
            let variables = ["SSH_ASKPASS": AskpassBroker.executablePath, "SSH_ASKPASS_REQUIRE": "force", "HERBSTERMINAL_HELPER": "askpass",
                             "HERBSTERMINAL_SECRET_PIPE": String(parts[0]), "HERBSTERMINAL_SECRET_TOKEN": String(parts[1])]
            for (name, value) in variables { withWide(name) { n in withWide(value) { v in _ = SetEnvironmentVariableW(n, v) } } }
        }
        guard let ssh = SSH.executable else { return 3 }

        // ssh gets the relay's own standard input and output. Its error output goes nowhere, except for Run Command
        // on Hosts, which asks for it (HERBSTERMINAL_RELAY_ERRORS) to show why a host wasn't reached.
        let output = GetStdHandle(STD_OUTPUT_HANDLE)
        var errors: HANDLE? = nil
        if ProcessInfo.processInfo.environment["HERBSTERMINAL_RELAY_ERRORS"] == "1" {
            errors = GetStdHandle(STD_ERROR_HANDLE)
            if errors == INVALID_HANDLE_VALUE { errors = nil }
        }
        for handle in [input, output, errors] where handle != nil { SetHandleInformation(handle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) }
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.hStdInput = input
        startup.hStdOutput = output
        startup.hStdError = errors
        var info = PROCESS_INFORMATION()
        var command = ([ssh] + sshArguments).map(quoteArgument).joined(separator: " ").wide
        let job = CreateJobObjectW(nil, nil)
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        let flags = DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_SUSPENDED) | DWORD(CREATE_UNICODE_ENVIRONMENT)
        guard CreateProcessW(nil, &command, nil, nil, true, flags, nil, nil, &startup, &info) else { return 4 }
        AssignProcessToJobObject(job, info.hProcess)
        ResumeThread(info.hThread)
        CloseHandle(info.hThread)
        WaitForSingleObject(info.hProcess, INFINITE)
        var code: DWORD = 0
        GetExitCodeProcess(info.hProcess, &code)
        CloseHandle(info.hProcess)
        return Int32(bitPattern: code)
    }
}
