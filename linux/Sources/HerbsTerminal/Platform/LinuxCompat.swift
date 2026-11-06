import Foundation
import Glibc

// Names the shared macOS sources use that Glibc spells differently or doesn't have. Declarations in this module
// take precedence over the imported C ones, so the shared files compile unchanged.

let SOCK_STREAM = Int32(Glibc.SOCK_STREAM.rawValue)
let SHUT_WR = Int32(Glibc.SHUT_WR)
let SHUT_RD = Int32(Glibc.SHUT_RD)

/// macOS's getpeereid: the account on the other end of a Unix socket, from SO_PEERCRED.
func getpeereid(_ socket: Int32, _ uid: UnsafeMutablePointer<uid_t>, _ gid: UnsafeMutablePointer<gid_t>) -> Int32 {
    var credentials = PeerCredentials()
    var length = socklen_t(MemoryLayout<PeerCredentials>.size)
    guard getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 else { return -1 }
    uid.pointee = credentials.uid
    gid.pointee = credentials.gid
    return 0
}

extension sockaddr_in {
    /// BSD's sockaddr_in carries its own length; Linux's doesn't, so the length is dropped.
    init(sin_len: UInt8, sin_family: sa_family_t, sin_port: in_port_t, sin_addr: in_addr,
         sin_zero: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) {
        self.init(sin_family: sin_family, sin_port: sin_port, sin_addr: sin_addr, sin_zero: sin_zero)
    }
}

/// libproc's child listing, from /proc. In the Flatpak the shells run on the host, so `HostProcesses` asks the
/// host instead; this covers processes started inside the app itself.
func proc_listchildpids(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32 {
    var children: [pid_t] = []
    let tasks = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/task")) ?? []
    for task in tasks {
        let text = (try? String(contentsOfFile: "/proc/\(pid)/task/\(task)/children", encoding: .utf8)) ?? ""
        children += text.split(separator: " ").compactMap { pid_t($0) }
    }
    guard let buffer else { return Int32(children.count) }
    let capacity = Int(size) / MemoryLayout<pid_t>.size
    let typed = buffer.assumingMemoryBound(to: pid_t.self)
    for (index, child) in children.prefix(capacity).enumerated() { typed[index] = child }
    return Int32(min(children.count, capacity))
}

/// libproc's process name, from /proc/<pid>/comm.
@discardableResult
func proc_name(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32 {
    guard let buffer, size > 0,
          let name = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return 0 }
    let bytes = Array(name.trimmingCharacters(in: .newlines).utf8.prefix(Int(size) - 1))
    let typed = buffer.assumingMemoryBound(to: UInt8.self)
    for (index, byte) in bytes.enumerated() { typed[index] = byte }
    typed[bytes.count] = 0
    return Int32(bytes.count)
}

/// struct ucred from <sys/socket.h>, which Glibc's Swift module leaves out.
struct PeerCredentials {
    var pid: Int32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
}

/// `Darwin.read` in the shared sources: the C library's read(2).
enum Darwin {
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
}

// Security.framework's random source, which the macOS sources call for tokens and salts.
nonisolated(unsafe) let kSecRandomDefault: OpaquePointer? = nil

@discardableResult
func SecRandomCopyBytes(_ rnd: OpaquePointer?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
    // The system generator reads getrandom(2), the kernel's cryptographic source.
    var generator = SystemRandomNumberGenerator()
    let typed = bytes.assumingMemoryBound(to: UInt8.self)
    for index in 0..<count { typed[index] = UInt8.random(in: .min ... .max, using: &generator) }
    return 0
}
