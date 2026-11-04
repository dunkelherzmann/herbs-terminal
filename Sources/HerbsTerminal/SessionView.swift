import SwiftUI
import HerbsTerminalUI

final class WindowState: ObservableObject {
    @Published var layout = SessionLayout.terminal
    @Published var findRequest = 0
    func find() {
        if layout == .explorer { layout = .terminal }
        findRequest += 1
    }
    @Published var notice: String?
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser
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
                    .background(Color(nsColor: themes.current?.colors["Background Color"] ?? TerminalTypeface.background(dark: colorScheme == .dark)))
                    .frame(minWidth: 280)
            }
            if state.layout != .terminal {
                LocalExplorer(directory: $state.directory).frame(minWidth: 260)
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
        .alert("Feature in development", isPresented: Binding(
            get: { state.notice != nil }, set: { if !$0 { state.notice = nil } }
        )) {
            Button("OK") { state.notice = nil }
        } message: {
            Text((state.notice ?? "This feature") + " is not available in the local workspace build.")
        }

    }
}
