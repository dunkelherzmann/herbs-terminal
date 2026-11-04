import SwiftUI

public enum SessionLayout {
    case terminal, split, explorer
}

public struct SessionToolbar<Actions: View>: View {
    @Binding private var layout: SessionLayout
    private let newTab, connect, multiHost, tailcat, remoteControl, search: () -> Void
    private let title, subtitle: String
    private let menu: Actions
    @StateObject private var metrics = HeaderMetrics()
    private let gap: CGFloat = 4
    private let buttonWidth: CGFloat = 30

    public init(layout: Binding<SessionLayout>, title: String = "Terminal", subtitle: String = "~", newTab: @escaping () -> Void,
                connect: @escaping () -> Void = {}, multiHost: @escaping () -> Void, tailcat: @escaping () -> Void,
                remoteControl: @escaping () -> Void, search: @escaping () -> Void,
                @ViewBuilder menu: () -> Actions) {
        _layout = layout
        self.title = title
        self.subtitle = subtitle
        self.newTab = newTab
        self.connect = connect
        self.multiHost = multiHost
        self.tailcat = tailcat
        self.remoteControl = remoteControl
        self.search = search
        self.menu = menu()
    }

    public var body: some View {
        ZStack {
            GeometryReader { geometry in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: max(0, geometry.size.width - 510 - 2 * buttonWidth))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .help("Active session\n" + [title, subtitle].joined(separator: " "))
            }
            HStack(spacing: 0) {
                HStack(spacing: gap) {
                    button("New Tab", "plus.rectangle.on.rectangle",
                           help: "New Tab (⌘T)\nOpen another local terminal in this window.", newTab)
                        .keyboardShortcut("t")
                    button("Connect via SSH", "network",
                           help: "Connect via SSH (⌘K)\nOpen a remote shell with a saved or new login; the explorer follows that host.", connect)
                        .keyboardShortcut("k")
                }
                Spacer()
                HStack(spacing: gap) {
                    button("Switch Terminal / Explorer", layout == .explorer ? "terminal" : "folder",
                           help: layout == .explorer ? "Show Terminal\nReplace the file explorer with this tab's shell." : "Show File Explorer\nBrowse files on the host this tab is connected to.") {
                        layout = layout == .explorer ? .terminal : .explorer
                    }
                    button("Toggle Split View", "rectangle.split.2x1",
                           help: "Split View\nShow the shell and the file explorer side by side.") {
                        layout = layout == .split ? .terminal : .split
                    }
                    button("Multi-Host Commands", "square.3.layers.3d",
                           help: "Multi-Host Commands\nSend one command to several hosts (in development).", multiHost)
                    button("Tailcat Peers", "point.3.connected.trianglepath.dotted",
                           help: "Tailcat Peers\nPair with and reach peer machines (in development).", tailcat)
                    button("Remote Control", "desktopcomputer",
                           help: "Remote Control\nOpen the remote desktop of this host (in development).", remoteControl)
                }
                HStack(spacing: gap) {
                    button("Search", "magnifyingglass",
                           help: layout == .explorer ? "Find Files (⌘F)\nFilter this folder by name." : "Search Terminal (⌘F)\nFind text in this tab's scrollback.", search)
                        .keyboardShortcut("f")
                    Menu { menu } label: { glyph("line.3.horizontal") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Main Menu\nTabs, windows, zoom, themes, appearance and settings.").accessibilityLabel("Main Menu")
                }
                .padding(.leading, gap * 2 + buttonWidth)
            }
            .padding(.leading, 82).padding(.trailing, 10)
        }
        .frame(height: metrics.height)
        .background(HeaderMeasurement(metrics: metrics))
        .background(.bar)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .regular))
            .frame(width: buttonWidth, height: 28)
            .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 5))
    }

    private func button(_ title: String, _ symbol: String, help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { glyph(symbol) }
            .buttonStyle(.plain).help(help).accessibilityLabel(title)
    }
}
