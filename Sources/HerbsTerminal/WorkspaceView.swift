import SwiftUI
import HerbsTerminalUI

@MainActor
final class TerminalTab: Identifiable {
    let id = UUID()
    let number: Int
    let state = WindowState()
    let shell = LocalShell()
    var monitor: Task<Void, Never>?
    init(number: Int, directory: String? = nil) {
        self.number = number
        if let directory { shell.startDirectory = directory }
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selected: TerminalTab
    @Published var showingSSHConnect = false
    @Published var panel: WorkspacePanel?
    let multiHost = MultiHostModel()
    let desktop = RemoteDesktopModel()

    /// Saved logins plus this tab's live connection, for Multi-Host Commands.
    var hostTargets: [HostTarget] {
        var targets: [HostTarget] = []
        if case .connected(let endpoint) = selected.state.connection {
            targets.append(HostTarget(endpoint: endpoint, password: nil, source: "this tab's connection"))
        }
        for login in CredentialStore.shared?.logins ?? [] {
            let target = HostTarget(endpoint: RemoteEndpoint(host: login.host, port: login.port, username: login.username),
                                    password: login.password, source: "saved login")
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }
    private var next = 2

    init() {
        let first = TerminalTab(number: 1)
        tabs = [first]
        selected = first
        configure(first)
    }

    /// Opens a tab, in the current tab's folder when that's a local shell and Settings asks for it.
    func add() {
        var directory: String?
        if TerminalProfile.shared.newTabsInSameFolder, case .local = selected.state.connection {
            directory = selected.shell.currentDirectory
        }
        let tab = TerminalTab(number: next, directory: directory)
        next += 1
        tabs.append(tab)
        selected = tab
        configure(tab)
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === selected }), tabs.count > 1 else { return }
        selected = tabs[(index + offset + tabs.count) % tabs.count]
    }

    /// The workspace part of the terminal's right-click menu.
    private func configure(_ tab: TerminalTab) {
        tab.shell.view.extraMenuItems = { [weak self, weak tab] in
            guard let self, let tab else { return [] }
            let state = tab.state
            var items = [
                ActionMenuItem("New Tab", key: "t") { self.add() },
                ActionMenuItem(state.layout == .split ? "Hide Split View" : "Split View") {
                    state.layout = state.layout == .split ? .terminal : .split
                },
                ActionMenuItem("Show File Explorer") { state.layout = .explorer },
                NSMenuItem.separator(),
            ]
            if case .connected(let endpoint) = state.connection {
                items.append(ActionMenuItem("Disconnect from \(endpoint.label)") { self.disconnect() })
            }
            items.append(ActionMenuItem("Connect via SSH…", key: "k", modifiers: [.command, .shift]) { self.showingSSHConnect = true })
            items += [
                NSMenuItem.separator(),
                ActionMenuItem("Bigger", key: "+") { self.zoom(1) },
                ActionMenuItem("Smaller", key: "-") { self.zoom(-1) },
                ActionMenuItem("Settings…", key: ",") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
            ]
            return items
        }
    }

    func connectSSH(_ login: SSHLogin) {
        connect(RemoteEndpoint(host: login.host, port: login.port, username: login.username), password: login.password)
    }

    /// Starts the login in the selected tab's shell. The explorer follows only once the shared connection
    /// is verified, and returns to local files when the session ends or the link drops.
    func connect(_ endpoint: RemoteEndpoint, password: String?) {
        // A tab already in a remote session gets its own shell: typing a login there would nest it.
        switch selected.state.connection {
        case .connecting, .connected: add()
        default: break
        }
        let tab = selected
        tab.monitor?.cancel()
        tab.state.connection = .connecting(endpoint)
        tab.shell.legend.setRemote(target: "Connecting to \(endpoint.label)…", location: "")
        tab.shell.connectSSH(endpoint, password: password)
        tab.monitor = Task { [weak tab] in
            guard let tab else { return }
            await Workspace.watch(tab, endpoint)
        }
    }

    private static func watch(_ tab: TerminalTab, _ endpoint: RemoteEndpoint) async {
        let started = Date()
        var connected = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(connected ? 2000 : 500))
            let up = await Task.detached { SSHControl.isConnected(endpoint) }.value
            if up && !connected {
                connected = true
                let home = await Task.detached { (try? SFTPClient(endpoint: endpoint).canonical(".")) ?? "/" }.value
                tab.state.remoteViewModel = RemoteExplorerViewModel(endpoint: endpoint)
                tab.state.remoteDirectory = home
                tab.state.remoteHistory = NavigationHistory(home)
                tab.state.remoteHome = home
                tab.state.connectedAt = Date()
                tab.state.endpoint = .remote(endpoint)
                tab.state.connection = .connected(endpoint)
                tab.shell.legend.setRemote(target: endpoint.label, location: home)
            } else if !up && connected {
                detach(tab, message: nil)
                return
            } else if !up && Date().timeIntervalSince(started) > 2,
                      !hasChildProcess(of: tab.shell.view.process.shellPid, named: "ssh") {
                detach(tab, message: "Couldn't connect to \(endpoint.label). The terminal shows ssh's reason.")
                return
            }
        }
    }

    private static func detach(_ tab: TerminalTab, message: String?) {
        tab.state.endpoint = .local
        tab.state.remoteViewModel = nil
        tab.state.connection = message.map(ConnectionState.failed) ?? .local
        tab.state.connectedAt = nil
        tab.shell.legend.setRemote(target: nil)
    }

    /// Bigger / Smaller like Terminal's View menu: this tab only, until Default Font Size or a profile change.
    /// Terminal's rule: ask before ending tabs that run something other than their login shell.
    static func confirmClosing(_ tabs: [TerminalTab]) -> Bool {
        guard TerminalProfile.shared.askBeforeClosing else { return true }
        let running = tabs.compactMap { tab -> String? in
            if case .connected(let endpoint) = tab.state.connection { return "ssh (\(endpoint.label))" }
            return tab.shell.foregroundProgram
        }
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to terminate running processes in this tab?"
        alert.informativeText = "Closing the tab will terminate: " + running.joined(separator: ", ") + "."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Ends the selected tab's remote session by closing its shared connection; the shell returns to the Mac.
    func disconnect() {
        guard case .connected(let endpoint) = selected.state.connection else { return }
        Task.detached { SSHControl.run(endpoint.sshArguments(["-O", "exit"])) }
    }

    /// The SSH button: connection details while connected, otherwise the Connect sheet.
    func connectButton() {
        if case .connected = selected.state.connection { panel = .connection } else { showingSSHConnect = true }
    }

    func zoom(_ delta: CGFloat) {
        let view = selected.shell.view
        let range = TerminalProfile.sizeRange
        let size = min(range.upperBound, max(range.lowerBound, Double(view.font.pointSize) + Double(delta)))
        view.font = NSFontManager.shared.convert(view.font, toSize: CGFloat(size))
    }

    func resetZoom() { selected.shell.view.font = TerminalProfile.shared.font }

    func close(_ tab: TerminalTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        guard Self.confirmClosing([tab]) else { return }
        if selected === tab { selected = tabs[index == 0 ? 1 : index - 1] }
        tabs.remove(at: index)
        tab.monitor?.cancel()
        tab.shell.close()
    }
}

struct WorkspaceView: View {
    @StateObject private var workspace: Workspace

    init(workspace: @autoclosure @escaping () -> Workspace = Workspace()) {
        _workspace = StateObject(wrappedValue: workspace())
    }
    var body: some View {
        ActiveWorkspace(workspace: workspace, state: workspace.selected.state, legend: workspace.selected.shell.legend)
            .onDisappear { workspace.tabs.forEach { $0.shell.close() } }
    }
}

private struct ActiveWorkspace: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: WindowState
    @ObservedObject var legend: SessionLegend
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        let tab = workspace.selected
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(workspace.tabs) { item in
                            HStack(spacing: 6) {
                                Button("Terminal \(item.number)") { workspace.selected = item }
                                    .hint("Terminal \(item.number)\nSwitch to this tab's shell and explorer.")
                                Button { workspace.close(item) } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Close Terminal \(item.number)")
                                    .hint("Close Terminal \(item.number)\nEnd this tab's shell and release its resources.")
                            }
                            .padding(6).background(item === tab ? Color.accentColor.opacity(0.18) : .clear,
                                                   in: RoundedRectangle(cornerRadius: 4))
                        }
                    }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            SessionView(state: tab.state, shell: tab.shell).id(tab.id)
        }
        // The toolbar sits in the titlebar as a safe-area inset, so content below sees exactly its height
        // as the top inset; a leftover titlebar inset made sidebars and fills paint over the toolbar.
        .safeAreaInset(edge: .top, spacing: 0) {
            SessionToolbar(layout: $state.layout, title: legend.title, subtitle: legend.subtitle,
                           newTab: workspace.add,
                           connect: workspace.connectButton,
                           connectedTo: { if case .connected(let e) = state.connection { e.label } else { nil } }(),
                           multiHost: { workspace.panel = .multiHost },
                           tailcat: { workspace.panel = .tailcat },
                           remoteControl: { workspace.panel = .remoteDesktop },
                           search: { tab.state.find() }) {
                Button("New Tab", action: workspace.add).help("Open another local terminal in this window.")
                Button("New Window") { openWindow(id: "session") }.help("Open a new HerbsTerminal window.")
                Button("Connect via SSH…") { workspace.showingSSHConnect = true }
                    .help("Open a remote shell (⇧⌘K).")
                Menu("Open Tabs") {
                    ForEach(workspace.tabs) { item in
                        Button("Terminal \(item.number)") { workspace.selected = item }
                    }
                }
                Divider()
                Button("Find in Terminal…") { tab.state.findInTerminal() }.help("Search this tab's scrollback.")
                Menu("Zoom") {
                    Button("Bigger") { workspace.zoom(1) }.help("Larger text in this tab (⌘+).")
                    Button("Smaller") { workspace.zoom(-1) }.help("Smaller text in this tab (⌘−).")
                    Button("Default Font Size") { workspace.resetZoom() }.help("Back to the Settings font size (⌘0).")
                }
                ThemeMenu()
                Picker("Appearance", selection: $appearance) {
                    ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
                }
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.help("Fill the screen with this window.")
                Divider()
                SettingsLink { Text("Settings…") }.help("Font, size, cursor, window size and color themes (⌘,).")
                Button("About HerbsTerminal") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
        }
        .task(id: tab.id) {
            while !Task.isCancelled {
                tab.shell.legend.refresh(tab.shell.view)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // A view presents only one sheet on macOS, so the panels hang off their own background view;
        // sharing the Connect sheet's view left every panel silently unshown.
        .background(EmptyView().sheet(item: $workspace.panel) { panel in
            switch panel {
            case .multiHost:
                MultiHostView(model: workspace.multiHost, targets: workspace.hostTargets) { workspace.panel = nil }
            case .tailcat:
                TailcatPeersView(store: .shared, share: .shared, connect: { peer in
                    do {
                        workspace.connect(try TailcatPeerStore.shared.endpoint(for: peer), password: nil)
                        workspace.panel = nil
                    } catch { TailcatPeerStore.shared.error = error.localizedDescription }
                }) { workspace.panel = nil }
            case .connection:
                ConnectionDetailsView(state: tab.state,
                                      disconnect: { workspace.disconnect(); workspace.panel = nil },
                                      newConnection: { workspace.panel = nil; workspace.showingSSHConnect = true }) { workspace.panel = nil }
            case .remoteDesktop:
                RemoteDesktopView(state: tab.state, model: workspace.desktop,
                                  connect: { workspace.panel = nil; workspace.showingSSHConnect = true }) { workspace.panel = nil }
            }
        })
        .sheet(isPresented: $workspace.showingSSHConnect) {
            SSHConnectView(
                viewModel: SSHConnectViewModel(),
                onConnect: { login in
                    workspace.showingSSHConnect = false
                    workspace.connectSSH(login)
                },
                onDismiss: {
                    workspace.showingSSHConnect = false
                }
            )
        }
        .focusedSceneValue(\.workspace, workspace)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)

    }


}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

enum WorkspacePanel: String, Identifiable {
    case multiHost, tailcat, remoteDesktop, connection
    var id: String { rawValue }
}

/// Shown by the SSH button while the tab is connected.
struct ConnectionDetailsView: View {
    @ObservedObject var state: WindowState
    let disconnect: () -> Void
    let newConnection: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection").font(.headline)
            if case .connected(let endpoint) = state.connection {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Account", endpoint.username)
                    row("Host", endpoint.proxyCommand == nil ? endpoint.host : endpoint.host.replacingOccurrences(of: "tailcat-", with: ""))
                    row("Port", String(endpoint.port))
                    row("Route", endpoint.proxyCommand == nil ? "Direct SSH" : "Tailcat peer")
                    row("Remote home", state.remoteHome)
                    if let since = state.connectedAt {
                        row("Connected", since.formatted(date: .omitted, time: .shortened)
                            + " (" + since.formatted(.relative(presentation: .named)) + ")")
                    }
                    row("Explorer", "Following this host over the shared SSH connection")
                }
                .font(.callout)
            } else {
                Text("This tab isn't connected.").foregroundStyle(.secondary)
            }
            HStack {
                Button("New Connection…", action: newConnection)
                    .hint("New Connection (⇧⌘K)\nConnect to another host in a new tab; this session stays open.")
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                    .hint("Close (Esc)\nClose this panel and stay connected.")
                Button("Disconnect", role: .destructive, action: disconnect)
                    .keyboardShortcut(.defaultAction)
                    .hint("Disconnect (Return)\nEnd the remote session; this tab returns to the Mac's shell and local files.")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
