import SwiftUI

private struct ToolbarPreview: View {
    @StateObject private var state = PreviewState()

    var body: some View {
        HSplitView {
            if state.layout != .explorer { pane("Terminal", symbol: "terminal") }
            if state.layout != .terminal { pane("File Explorer", symbol: "folder") }
        }
        .frame(minWidth: 700, minHeight: 320)
        .navigationTitle("Local Session")
        .safeAreaInset(edge: .top, spacing: 0) {
            SessionToolbar(layout: $state.layout, newTab: { state.panel = "New Tab" },
                           multiHost: { state.panel = "Multi-Host Commands" },
                           tailcat: { state.panel = "Tailcat Peers" }, search: { state.panel = "Find" }) {
                Button("New Window") { state.panel = "New Window" }
            }
        }
        .sheet(isPresented: Binding(get: { state.panel != nil }, set: { if !$0 { state.panel = nil } })) {
            VStack(spacing: 16) {
                Text(state.panel ?? "").font(.headline)
                Text("Toolbar preview").foregroundStyle(.secondary)
                Button("Close") { state.panel = nil }
            }
            .padding(32)
        }
    }

    private func pane(_ name: String, symbol: String) -> some View {
        Label(name, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class PreviewState: ObservableObject {
    @Published var layout = SessionLayout.terminal
    @Published var panel: String?
}

struct SessionToolbar_Previews: PreviewProvider {
    static var previews: some View { ToolbarPreview() }
}
