import AppKit
import SwiftTerm

@MainActor
final class SessionLegend: ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    private let initialTitle = ParityScene.isActive ? ParityScene.title
        : NSUserName() + "@" + ProcessInfo.processInfo.hostName.components(separatedBy: ".")[0]
    private var reportedTitle = ""
    private var exited = false
    private(set) var remoteTarget: String? = nil
    private(set) var remoteLocation: String? = nil
    @Published private(set) var title: String
    @Published private(set) var subtitle = "~"
    @Published private(set) var columns = 0
    @Published private(set) var rows = 0
    /// True for a moment after the terminal's size changes.
    @Published private(set) var showingSize = false
    private var hideSize: DispatchWorkItem?

    init() { title = initialTitle }

    func setRemote(target: String?, location: String? = nil) {
        self.remoteTarget = target
        self.remoteLocation = location
        if let target {
            self.title = target
            self.subtitle = location ?? "/"
        } else {
            // Titles reported while connected came from the remote shell; when the session ends (exit or a
            // dropped link) the tab is back on this Mac and shows its user@host until the local shell names it.
            reportedTitle = ""
            self.title = initialTitle
            self.subtitle = "~"
        }
    }

    func refresh(_ view: LocalProcessTerminalView) {
        guard remoteTarget == nil else {
            if let remoteLocation, subtitle != remoteLocation { subtitle = remoteLocation }
            return
        }
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
                        next += " — " + redactCredentials(commandLine(foreground) ?? program)
                    }
                }
            }
        }
        if title != next { title = next }

        let terminal = view.getTerminal()
        let path = displayLocation(terminal.hostCurrentDocument) ?? displayLocation(terminal.hostCurrentDirectory)
            ?? (process.running ? workingDirectory(process.shellPid) : nil)
        if let path = path.map(ParityScene.displayPath), subtitle != path { subtitle = path }
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
    /// Called when the shell exits; a split pane closes itself.
    var onExit: (() -> Void)?
    /// Called after the terminal's columns or rows change.
    var onResize: (() -> Void)?

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        exited = true
        DispatchQueue.main.async { [weak self] in self?.onExit?() }
        if let view = source as? LocalProcessTerminalView { refresh(view) }
    }
    /// Shows "columns × rows" briefly when the terminal is resized, as Terminal does in its title.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        let first = columns == 0
        columns = newCols
        rows = newRows
        onResize?()
        guard !first else { return }   // not when the tab first opens
        showingSize = true
        hideSize?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.showingSize = false }
        hideSize = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hide)
    }
}

/// Hides secrets a command line may carry before it is shown as the window title: `user:password@host`
/// in a destination or URL, and the values of `-p`/`--password`/`*_TOKEN=`-style arguments.
func redactCredentials(_ commandLine: String) -> String {
    var text = commandLine
    let patterns = [
        #"([A-Za-z][A-Za-z0-9+.-]*://)?([^\s:/@]+):[^\s@/]+@"#: "$1$2:•••@",
        #"(?i)(--?(?:pass(?:word)?|token|secret|api[-_]?key)[= ])\S+"#: "$1•••",
        #"(?i)\b([A-Z0-9_]*(?:PASS(?:WORD)?|TOKEN|SECRET|KEY)=)\S+"#: "$1•••",
    ]
    for (pattern, template) in patterns {
        text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return text
}
