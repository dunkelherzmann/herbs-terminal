import Foundation
import ucrt
import WinSDK

// The POSIX names the shared SFTP client uses to read ssh's output with a time limit, on Windows pipes.
// Declarations in this module take precedence over the imported ones (WinSDK has its own socket-only `pollfd`),
// so `SFTPClient.swift` compiles unchanged.

struct pollfd {
    var fd: Int32
    var events: Int16
    var revents: Int16
}

let POLLIN: Int16 = 0x0001
let EINTR: Int32 = 4

/// `poll` for a single pipe: waits until it has data, the other end closes, or `timeout` milliseconds pass.
/// Returns 1 when a read won't block, 0 on timeout.
func poll(_ fds: UnsafeMutablePointer<pollfd>, _ count: UInt, _ timeout: Int32) -> Int32 {
    guard count > 0 else { return 0 }
    let handle = HANDLE(bitPattern: _get_osfhandle(fds.pointee.fd))
    let deadline = GetTickCount64() + UInt64(max(0, timeout))
    while true {
        var available: DWORD = 0
        if !PeekNamedPipe(handle, nil, 0, nil, &available, nil) || available > 0 {
            // Data is waiting, or the pipe is broken and a read will report the end.
            fds.pointee.revents = POLLIN
            return 1
        }
        if timeout >= 0, GetTickCount64() >= deadline { return 0 }
        Sleep(available == 0 ? 2 : 0)
    }
}

/// `Darwin.read` in the shared sources: the C runtime's `_read`.
enum Darwin {
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Int(_read(fd, buffer, UInt32(min(count, Int(Int32.max)))))
    }
}

/// The shared `RemoteEndpoint.sshArguments` names a control socket; Windows' OpenSSH has no connection sharing,
/// so it asks for none.
enum SSHControl {
    static let controlPath = "none"
}

extension FileHandle {
    /// The C runtime descriptor for this handle's Windows HANDLE, which the shared SFTP client reads from. Foundation
    /// doesn't offer one on Windows; each handle gets one descriptor, made the first time and kept.
    var fileDescriptor: Int32 {
        let key = ObjectIdentifier(self)
        return descriptorLock.withLock {
            // A freed handle's identity can be reused by a new one: only a descriptor for this very HANDLE counts.
            if let fd = descriptors[key], _get_osfhandle(fd) == Int(bitPattern: _handle) { return fd }
            let fd = _open_osfhandle(Int(bitPattern: _handle), 0x0000 /* _O_RDONLY */ | 0x8000 /* _O_BINARY */)
            descriptors[key] = fd
            return fd
        }
    }
}

private let descriptorLock = NSLock()
private nonisolated(unsafe) var descriptors: [ObjectIdentifier: Int32] = [:]
