import Foundation
import Glibc

/// Short commands the app starts and waits for (host checks, sudo checks, tailcat's key and ping, a remote id
/// lookup). In the Linux app GLib also handles SIGCHLD, and Foundation's Process can miss that its child has
/// ended, so a wait on it may last until its time limit or forever. These commands are started with posix_spawn
/// and the app waits on its own child with waitpid instead.
enum ChildProcess {
    struct Result {
        /// The exit code; -1 if it ended through a signal; nil if it couldn't start or ran past its time limit.
        var status: Int32?
        var output: Data
    }

    /// Runs `argv` (a full path, then its arguments) with `input` on its standard input and returns its output.
    /// `errors` also collects its standard error into the output. On a timeout the command is ended with SIGTERM.
    static func run(_ argv: [String], environment: [String: String]? = nil, input: Data? = nil, errors: Bool = false,
                    timeout: TimeInterval = 20) -> Result {
        guard let path = argv.first else { return Result(status: nil, output: Data()) }
        var inputPipe: [Int32] = [-1, -1], outputPipe: [Int32] = [-1, -1]
        guard pipe2(&inputPipe, O_CLOEXEC) == 0 else { return Result(status: nil, output: Data()) }
        guard pipe2(&outputPipe, O_CLOEXEC) == 0 else {
            close(inputPipe[0]); close(inputPipe[1])
            return Result(status: nil, output: Data())
        }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
        if errors { posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 2) }
        else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }

        let arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let variables = (environment.map { ProcessInfo.processInfo.environment.merging($0) { $1 } } ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let started = posix_spawn(&pid, path, &actions, nil, arguments, envp) == 0
        // The child has its own copies; the app keeps the write end of the input and the read end of the output.
        close(inputPipe[0])
        close(outputPipe[1])
        guard started else {
            close(inputPipe[1]); close(outputPipe[0])
            return Result(status: nil, output: Data())
        }

        // Input and output move on their own threads, so a command that writes a lot before reading can't block.
        let writer = inputPipe[1], reader = outputPipe[0]
        Thread {
            if let input, !input.isEmpty {
                input.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = write(writer, bytes.baseAddress! + offset, bytes.count - offset)
                        if written < 0 { if errno == EINTR { continue }; break }
                        offset += written
                    }
                }
            }
            close(writer)
        }.start()
        let output = OutputBox(), read = DispatchSemaphore(value: 0)
        Thread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Glibc.read(reader, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                output.data.append(contentsOf: buffer[0..<count])
            }
            close(reader)
            read.signal()
        }.start()

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var ended = false
        while !ended {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { ended = true; break }
            if result == -1 && errno != EINTR { return Result(status: nil, output: Data()) }
            if Date() >= deadline {
                kill(pid, SIGTERM)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                return Result(status: nil, output: Data())
            }
            usleep(5_000)
        }
        // A program the command left running in the background can hold the output open; don't wait for it long.
        guard read.wait(timeout: .now() + 2) == .success else { return Result(status: exitCode(status), output: Data()) }
        return Result(status: exitCode(status), output: output.data)
    }

    /// WIFEXITED / WEXITSTATUS, which Swift doesn't import as macros.
    private static func exitCode(_ status: Int32) -> Int32 { status & 0x7f == 0 ? (status >> 8) & 0xff : -1 }

    private final class OutputBox: @unchecked Sendable { var data = Data() }
}
