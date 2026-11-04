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
}

struct SessionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeLibrary.shared
    @StateObject private var state: WindowState
    @StateObject private var shell: LocalShell

    init(state: @autoclosure @escaping () -> WindowState = WindowState(),
         shell: @autoclosure @escaping () -> LocalShell = LocalShell()) {
        _state = StateObject(wrappedValue: state())
        _shell = StateObject(wrappedValue: shell())
    }

    var body: some View {
        HSplitView {
            if state.layout != .explorer {
                ShellPane(session: shell, theme: themes.current)
                    .padding(.leading, 8)
                    .padding(.top, 6)
                    // Keep the fill out of the titlebar safe area, or it paints over the session toolbar.
                    .background(Color(nsColor: themes.current?.colors["Background Color"] ?? TerminalTypeface.background(dark: colorScheme == .dark)),
                                ignoresSafeAreaEdges: [])
                    .frame(minWidth: 280)
            }
            if state.layout != .terminal {
              VStack(spacing: 0) {
                ConnectionBanner(state: state)
                switch state.endpoint {
                case .local:
                    LocalExplorer(directory: $state.directory, history: $state.localHistory,
                                  log: state.localLog, findRequest: state.explorerFindRequest).frame(minWidth: 260)
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
                        home: state.remoteHome
                    ).frame(minWidth: 260)
                }
              }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .onChange(of: state.findRequest) {
            DispatchQueue.main.async {
                let item = NSMenuItem()
                item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                shell.view.performFindPanelAction(item)
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
