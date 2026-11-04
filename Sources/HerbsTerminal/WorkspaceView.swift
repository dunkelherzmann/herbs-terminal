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
        tab.state.remoteHistory = NavigationHistory("/")
        tab.state.remoteViewModel = RemoteExplorerViewModel(endpoint: ep)
        tab.shell.connectSSH(login)
    }

    /// Bigger / Smaller like Terminal's View menu: this tab only, until Default Font Size or a profile change.
    func zoom(_ delta: CGFloat) {
        let view = selected.shell.view
        let range = TerminalProfile.sizeRange
        let size = min(range.upperBound, max(range.lowerBound, Double(view.font.pointSize) + Double(delta)))
        view.font = NSFontManager.shared.convert(view.font, toSize: CGFloat(size))
    }

    func resetZoom() { selected.shell.view.font = TerminalProfile.shared.font }

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
            if workspace.tabs.count > 1 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(workspace.tabs) { item in
                            HStack(spacing: 6) {
                                Button("Terminal \(item.number)") { workspace.selected = item }
                                    .help("Terminal \(item.number)\nSwitch to this tab's shell and explorer.")
                                Button { workspace.close(item) } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Close Terminal \(item.number)")
                                    .help("Close Terminal \(item.number)\nEnd this tab's shell and release its resources.")
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
                           connect: { workspace.showingSSHConnect = true },
                           multiHost: { tab.state.notice = "Multi-host commands" },
                           tailcat: { tab.state.notice = "Tailcat pairing" },
                           remoteControl: { tab.state.notice = "Remote control" },
                           search: { tab.state.find() }) {
                Button("New Tab", action: workspace.add).help("Open another local terminal in this window.")
                Button("New Window") { openWindow(id: "session") }.help("Open a new HerbsTerminal window.")
                Button("Connect via SSH…") { workspace.showingSSHConnect = true }
                    .help("Open a remote shell in this tab (⌘K).")
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
