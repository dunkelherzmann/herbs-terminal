import SwiftUI
import HerbsTerminalUI

@MainActor
final class TerminalTab: Identifiable {
    let id = UUID()
    let number: Int
    let state = WindowState()
    let shell = LocalShell()
    init(number: Int) { self.number = number }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selected: TerminalTab
    @Published var showingSSHConnect = false
    private var next = 2

    init() {
        let first = TerminalTab(number: 1)
        tabs = [first]
        selected = first
    }

    func add() {
        let tab = TerminalTab(number: next)
        next += 1
        tabs.append(tab)
        selected = tab
    }

    func connectSSH(_ login: SSHLogin) {
        let tab = selected
        let ep = RemoteEndpoint(host: login.host, port: login.port, username: login.username)
        tab.state.endpoint = .remote(ep)
        tab.state.remoteDirectory = "/"
        tab.state.remoteViewModel = RemoteExplorerViewModel(endpoint: ep)
        tab.shell.connectSSH(login)
    }

    func close(_ tab: TerminalTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if selected === tab { selected = tabs[index == 0 ? 1 : index - 1] }
        tabs.remove(at: index)
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
            SessionToolbar(layout: $state.layout, title: legend.title, subtitle: legend.subtitle,
                           newTab: workspace.add,
                           multiHost: { tab.state.notice = "Multi-host commands" },
                           tailcat: { tab.state.notice = "Tailcat pairing" },
                           remoteControl: { tab.state.notice = "Remote control" },
                           search: { tab.state.find() }) {
                Button("New Tab", action: workspace.add)
                Button("New Window") { openWindow(id: "session") }
                Button("Connect via SSH…") { workspace.showingSSHConnect = true }
                    .keyboardShortcut("k", modifiers: [.command])
                Menu("Open Tabs") {
                    ForEach(workspace.tabs) { item in
                        Button("Terminal \(item.number)") { workspace.selected = item }
                    }
                }
                Divider()
                Button("Find in Terminal…") { tab.state.find() }
                Menu("Zoom") {
                    Button("Zoom In") { zoom(1) }
                    Button("Zoom Out") { zoom(-1) }
                    Button("Actual Size") { tab.shell.view.font = TerminalTypeface.regular }
                }
                ThemeMenu()
                Picker("Appearance", selection: $appearance) {
                    ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
                }
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                Divider()
                Button("About HerbsTerminal") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            if workspace.tabs.count > 1 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(workspace.tabs) { item in
                            HStack(spacing: 6) {
                                Button("Terminal \(item.number)") { workspace.selected = item }
                                Button { workspace.close(item) } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Close Terminal \(item.number)")
                            }
                            .padding(6).background(item === tab ? Color.accentColor.opacity(0.18) : .clear,
                                                   in: RoundedRectangle(cornerRadius: 4))
                        }
                    }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            SessionView(state: tab.state, shell: tab.shell).id(tab.id)
        }
        .task(id: tab.id) {
            while !Task.isCancelled {
                tab.shell.legend.refresh(tab.shell.view)
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)

    }

    private func zoom(_ delta: CGFloat) {
        let view = workspace.selected.shell.view
        let size = min(40, max(6, view.font.pointSize + delta))
        view.font = NSFontManager.shared.convert(view.font, toSize: size)
    }
}
