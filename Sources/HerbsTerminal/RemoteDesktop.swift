import AppKit
import SwiftUI
import HerbsTerminalUI

enum DesktopProtocol: String, CaseIterable, Identifiable {
    case vnc, rdp
    var id: String { rawValue }
    var title: String { self == .vnc ? "Screen Sharing (VNC)" : "Remote Desktop (RDP)" }
    var defaultPort: Int { self == .vnc ? 5900 : 3389 }
    var detail: String {
        self == .vnc ? "macOS Screen Sharing or a Linux VNC server; opens in Screen Sharing."
                     : "Windows Remote Desktop; opens in Windows App (Microsoft Remote Desktop)."
    }

    /// The local URL the viewer app opens once the service is forwarded to `port` on this Mac.
    func url(port: Int, username: String) -> URL? {
        switch self {
        case .vnc:
            var parts = URLComponents()
            parts.scheme = "vnc"; parts.user = username; parts.host = "127.0.0.1"; parts.port = port
            return parts.url
        case .rdp:
            // Microsoft's rdp:// form, with its colons percent-encoded: Foundation rejects them literally.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: ":&=")
            let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
            return URL(string: "rdp://full%20address=s%3A127.0.0.1%3A\(port)&username=s%3A\(user)")
        }
    }
}

/// Opens the active host's desktop through an SSH port forward on the tab's shared connection, so the
/// desktop service never needs to be exposed on the network. Desktop credentials can differ from SSH's.
@MainActor
final class RemoteDesktopModel: ObservableObject {
    @Published var kind: DesktopProtocol = .vnc { didSet { remotePort = kind.defaultPort } }
    @Published var remotePort = DesktopProtocol.vnc.defaultPort
    @Published var status: String?
    @Published var failed = false
    @Published private(set) var forwards: [(endpoint: RemoteEndpoint, spec: String, title: String)] = []

    func open(_ endpoint: RemoteEndpoint) async {
        failed = false
        status = "Forwarding \(kind.title) from \(endpoint.label)…"
        let kind = kind, remotePort = remotePort
        guard let local = Self.freeLocalPort() else { return report("No free local port for the forward.") }
        guard let url = kind.url(port: local, username: endpoint.username) else { return report("Invalid desktop address.") }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            return report(kind == .rdp ? "No app on this Mac opens rdp:// links. Install Windows App from the App Store."
                                       : "No app on this Mac opens vnc:// links.")
        }
        let spec = "127.0.0.1:\(local):localhost:\(remotePort)"
        let code = await Task.detached { SSHControl.run(endpoint.sshArguments(["-O", "forward", "-L", spec])) }.value
        guard code == 0 else {
            return report("The SSH connection refused the forward. Check that the tab is still connected and the server allows TCP forwarding.")
        }
        forwards.append((endpoint, spec, "\(kind.title) — \(endpoint.label):\(remotePort) → 127.0.0.1:\(local)"))
        NSWorkspace.shared.open(url)
        status = "Opened \(kind.title). If the viewer can't connect, \(endpoint.label) has no \(kind == .vnc ? "VNC/Screen Sharing" : "RDP") service on port \(remotePort)."
    }

    func close(_ index: Int) async {
        let forward = forwards.remove(at: index)
        _ = await Task.detached { SSHControl.run(forward.endpoint.sshArguments(["-O", "cancel", "-L", forward.spec])) }.value
    }

    private func report(_ message: String) {
        status = message
        failed = true
    }

    nonisolated static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }
}

struct RemoteDesktopView: View {
    @ObservedObject var state: WindowState
    @ObservedObject var model: RemoteDesktopModel
    let connect: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remote Control").font(.headline)
            if case .connected(let endpoint) = state.connection {
                Text("Open the desktop of \(endpoint.label) through this tab's SSH connection. The shell and transfers keep running.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Desktop service:", selection: $model.kind) {
                    ForEach(DesktopProtocol.allCases) { Text($0.title).tag($0) }
                }
                .hint("Desktop service\nVNC for macOS and Linux hosts, RDP for Windows hosts.")
                Text(model.kind.detail).font(.caption).foregroundStyle(.secondary)
                TextField("Port on the host:", value: $model.remotePort, format: .number.grouping(.never))
                    .frame(width: 220)
                    .hint("Port\nWhere the desktop service listens on the host: 5900 for VNC, 3389 for RDP.")
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(model.failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.forwards.isEmpty {
                    Divider()
                    Text("Open desktop forwards").font(.caption.weight(.semibold))
                    ForEach(Array(model.forwards.enumerated()), id: \.offset) { index, forward in
                        HStack {
                            Text(forward.title).font(.caption).lineLimit(1)
                            Spacer()
                            Button("Close") { Task { await model.close(index) } }
                                .hint("Close\nStop forwarding this desktop service.")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
                        .hint("Done (Esc)\nClose this panel. Open desktops stay forwarded until you close them or leave ssh.")
                    Button("Open Desktop") { Task { await model.open(endpoint) } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .hint("Open Desktop (Return)\nForward the service over SSH and open it in the viewer app.")
                }
            } else {
                Text("Remote Control opens the desktop of the host this tab is connected to. Connect the tab via SSH first; the desktop is then carried over that connection.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                        .hint("Cancel (Esc)\nClose without connecting.")
                    Button("Connect via SSH…", action: connect).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .hint("Connect via SSH\nOpen a remote shell in this tab, then come back here.")
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
