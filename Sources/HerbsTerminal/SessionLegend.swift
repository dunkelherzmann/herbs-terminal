import AppKit
import SwiftTerm

@MainActor
final class SessionLegend: ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    private let initialTitle = NSUserName() + "@" + ProcessInfo.processInfo.hostName.components(separatedBy: ".")[0]
    private var reportedTitle = ""
    private var exited = false
    @Published private(set) var title: String
    @Published private(set) var subtitle = "~"

    init() { title = initialTitle }

    func refresh(_ view: LocalProcessTerminalView) {
        let process = view.process!
        var next = reportedTitle.isEmpty ? initialTitle : reportedTitle
        if exited {
            next += " (Exited)"
        } else if process.running {
            let foreground = tcgetpgrp(process.childfd)
            if foreground > 0, foreground != process.shellPid {
                var name = [CChar](repeating: 0, count: 256)
                if proc_name(foreground, &name, UInt32(name.count)) > 0 {
                    let program = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !["sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh"].contains(program) {
                        next += " — " + (commandLine(foreground) ?? program)
                    }
                }
            }
        }
        if title != next { title = next }

        let terminal = view.getTerminal()
        let path = displayLocation(terminal.hostCurrentDocument) ?? displayLocation(terminal.hostCurrentDirectory)
            ?? (process.running ? workingDirectory(process.shellPid) : nil)
        if let path, subtitle != path { subtitle = path }
    }

    private func displayLocation(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value), url.isFileURL else {
            return value.hasPrefix("/") ? (value as NSString).abbreviatingWithTildeInPath : value
        }
        let host = url.host ?? ""
        let local = ProcessInfo.processInfo.hostName
        guard host.isEmpty || [local, local.components(separatedBy: ".")[0], "localhost"].contains(where: {
            $0.caseInsensitiveCompare(host) == .orderedSame
        }) else { return value }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    // KERN_PROCARGS2 contains the executable path, argv, then the environment.
    // Stop at argc so only command arguments are displayed.
    private func commandLine(_ pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0, length > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let payload = bytes[4..<length]
        guard argc > 0, let terminator = payload.firstIndex(of: 0),
              let first = payload[terminator...].firstIndex(where: { $0 != 0 }) else { return nil }
        var rest = payload[first...]
        var args: [String] = []
        for _ in 0..<argc {
            guard let end = rest.firstIndex(of: 0) else { return nil }
            args.append(String(decoding: rest[..<end], as: UTF8.self))
            rest = rest.suffix(from: end + 1)
        }
        return args.joined(separator: " ")
    }

    private func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard pid > 0, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            let path = String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            return path.isEmpty ? nil : (path as NSString).abbreviatingWithTildeInPath
        }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        reportedTitle = title
        refresh(source)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let view = source as? LocalProcessTerminalView { refresh(view) }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        exited = true
        if let view = source as? LocalProcessTerminalView { refresh(view) }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
}
