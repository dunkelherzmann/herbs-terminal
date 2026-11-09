import SwiftUI
import HerbsTerminalUI

enum SessionEndpoint: Equatable {
    case local
    case remote(RemoteEndpoint)
}

/// What the tab's shell is actually connected to, as verified through the shared SSH connection.
enum ConnectionState: Equatable {
    case local
    case connecting(RemoteEndpoint)
    case connected(RemoteEndpoint)
    case failed(String)
}

@MainActor
final class WindowState: ObservableObject {
    @Published var layout = SessionLayout.terminal
    @Published var findRequest = 0
    @Published var explorerFindRequest = 0
    /// Search what fills the window: files when the explorer does, otherwise the terminal's scrollback.
    func find() {
        if layout == .explorer { explorerFindRequest += 1 } else { findRequest += 1 }
    }

    /// Always the terminal, bringing it back if the explorer fills the window.
    func findInTerminal() {
        if layout == .explorer { layout = .terminal }
        findRequest += 1
    }
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser
    @Published var endpoint: SessionEndpoint = .local
    @Published var connection: ConnectionState = .local
    @Published var connectedAt: Date?
    @Published var remoteHome = "/"
    @Published var localHistory = NavigationHistory(FileManager.default.homeDirectoryForCurrentUser.path)
    @Published var remoteDirectory: String = "/"
    @Published var remoteHistory = NavigationHistory("/")
    let localLog = FileOperationLog()
    @Published var remoteViewModel: RemoteExplorerViewModel? = nil
    /// Administrator mode: the explorer's root session, where it runs, and its own location.
    @Published var adminViewModel: RemoteExplorerViewModel?
    @Published var adminTarget: PrivilegedAccess.Target?
    @Published var adminPath = "/"
    @Published var adminHistory = NavigationHistory("/")
    /// The explorer showing in this tab, for the feature tests' bridge (nil while none is on screen).
    var explorerBridge: ExplorerBridge?
}

struct SessionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeLibrary.shared
    @ObservedObject private var profile = TerminalProfile.shared
    @StateObject private var state: WindowState
    @StateObject private var shell: LocalShell

    /// The tab whose split panes fill the terminal area; nil shows `shell` alone.
    private let tab: TerminalTab?

    init(state: @autoclosure @escaping () -> WindowState = WindowState(),
         shell: @autoclosure @escaping () -> LocalShell = LocalShell(), tab: TerminalTab? = nil) {
        _state = StateObject(wrappedValue: state())
        _shell = StateObject(wrappedValue: shell())
        self.tab = tab
    }


    /// The tab's panes, or the single shell.
    @ViewBuilder private var terminalPane: some View {
        if let tab {
            PaneTreeView(node: tab.root, tab: tab) { pane in terminal(pane) }
        } else {
            terminal(shell)
        }
    }

    /// One shell's terminal on its profile's background.
    private func terminal(_ pane: LocalShell) -> some View {
        let settings = profile.settings(for: pane.profileID)
        let theme = themes.theme(named: settings.theme)
        let background = Color(nsColor: theme?.colors["Background Color"] ?? TerminalTypeface.background(dark: colorScheme == .dark))
        return ShellPane(session: pane)
            .padding(.leading, 8)
            .padding(.top, 6)
            // Keep the fill out of the titlebar safe area, or it paints over the session toolbar.
            .background(background.opacity(settings.backgroundOpacity), ignoresSafeAreaEdges: [])
            .background { if settings.blurBackground { BehindWindowBlur() } }
            .overlay { SizeBadge(legend: pane.legend) }
    }

    /// `sidebarWidth` 0 hides the Places side pane.
    private func explorerPane(sidebarWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ConnectionBanner(state: state)
            if let admin = state.adminViewModel {
                AdministratorBanner(state: state)
                RemoteExplorer(currentPath: $state.adminPath, history: $state.adminHistory, viewModel: admin,
                               findRequest: state.explorerFindRequest, localFolder: state.directory,
                               home: state.adminTarget == .local ? FileManager.default.homeDirectoryForCurrentUser.path : state.remoteHome,
                               sidebarWidth: sidebarWidth,
                               administratorToggle: { AdministratorMode.leave(state) }, isAdministrator: true, bridgeHost: state)
                    .id(ObjectIdentifier(admin))
            } else {
                switch state.endpoint {
                case .local:
                    LocalExplorer(directory: $state.directory, history: $state.localHistory,
                                  log: state.localLog, findRequest: state.explorerFindRequest, sidebarWidth: sidebarWidth,
                                  administratorToggle: { Task { await AdministratorMode.enter(state) } }, bridgeHost: state)
                case .remote(let ep):
                    RemoteExplorer(
                        currentPath: $state.remoteDirectory,
                        history: $state.remoteHistory,
                        viewModel: state.remoteViewModel ?? {
                            let vm = RemoteExplorerViewModel(endpoint: ep)
                            state.remoteViewModel = vm
                            return vm
                        }(),
                        findRequest: state.explorerFindRequest,
                        localFolder: state.directory,
                        home: state.remoteHome,
                        sidebarWidth: sidebarWidth,
                        administratorToggle: { Task { await AdministratorMode.enter(state) } },
                        bridgeHost: state
                    )
                }
            }
        }
    }


    /// Below this width the explorer drops its Places side pane rather than clipping its content; below
    /// `compactSidebarWidth` the side pane is narrower.
    static let sidebarMinimumWidth: CGFloat = 560
    static let compactSidebarWidth: CGFloat = 700

    var body: some View {
        // The tab shows either its terminal or its file explorer.
        GeometryReader { geometry in
            let width = geometry.size.width
            if state.layout == .explorer {
                explorerPane(sidebarWidth: width < Self.sidebarMinimumWidth ? 0 : width < Self.compactSidebarWidth ? 140 : 170)
                    .frame(width: width)
                    .clipped()
            } else {
                terminalPane.frame(width: width)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .onChange(of: state.findRequest) {
            DispatchQueue.main.async {
                let item = NSMenuItem()
                item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                (tab?.focusedShell ?? shell).view.performFindPanelAction(item)
            }
        }

    }
}

/// Tells the explorer's user when the files shown are not (yet, or any longer) the tab's remote host.
private struct ConnectionBanner: View {
    @ObservedObject var state: WindowState

    var body: some View {
        switch state.connection {
        case .connecting(let endpoint):
            banner {
                ProgressView().controlSize(.small)
                Text("Connecting to \(endpoint.label)… Showing local files until the login succeeds.")
            }
            .hint("Connecting\nAnswer any password or host-key prompt in the terminal.")
        case .failed(let message):
            banner {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                Spacer()
                Button("Dismiss") { state.connection = .local }
                    .hint("Dismiss\nHide this message.")
            }
        default:
            EmptyView()
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12))
    }
}

/// The blur behind a translucent terminal, like Terminal's "Blur" and Ptyxis's transparency.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Shown while the explorer works as root.
private struct AdministratorBanner: View {
    @ObservedObject var state: WindowState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill").foregroundStyle(.red)
            Text("Administrator mode: changes are made as root on \(state.adminTarget?.label ?? "this Mac").")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Leave") { AdministratorMode.leave(state) }
                .hint("Leave Administrator Mode\nGo back to working with your own account's access.")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.red.opacity(0.15))
    }
}
