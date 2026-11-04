import SwiftUI

public enum SessionLayout {
    case terminal, split, explorer
}

public struct SessionToolbar<Actions: View>: View {
    @Binding private var layout: SessionLayout
    private let newTab, multiHost, tailcat, remoteControl, search: () -> Void
    private let title, subtitle: String
    private let menu: Actions
    @StateObject private var metrics = HeaderMetrics()
    private let gap: CGFloat = 4
    private let buttonWidth: CGFloat = 30

    public init(layout: Binding<SessionLayout>, title: String = "Terminal", subtitle: String = "~", newTab: @escaping () -> Void,
                multiHost: @escaping () -> Void, tailcat: @escaping () -> Void,
                remoteControl: @escaping () -> Void, search: @escaping () -> Void,
                @ViewBuilder menu: () -> Actions) {
        _layout = layout
        self.title = title
        self.subtitle = subtitle
        self.newTab = newTab
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
                .help([title, subtitle].joined(separator: "\n"))
            }
            HStack(spacing: 0) {
                button("New Tab", "plus.rectangle.on.rectangle", newTab)
                    .keyboardShortcut("t")
                Spacer()
                HStack(spacing: gap) {
                    button("Switch Terminal / Explorer", layout == .explorer ? "terminal" : "folder") {
                        layout = layout == .explorer ? .terminal : .explorer
                    }
                    button("Toggle Split View", "rectangle.split.2x1") {
                        layout = layout == .split ? .terminal : .split
                    }
                    button("Multi-Host Commands", "square.3.layers.3d", multiHost)
                    button("Tailcat Peers", "point.3.connected.trianglepath.dotted", tailcat)
                    button("Remote Control", "desktopcomputer", remoteControl)
                }
                HStack(spacing: gap) {
                    button("Search Terminal", "magnifyingglass", search).keyboardShortcut("f")
                    Menu { menu } label: { glyph("line.3.horizontal") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Main Menu").accessibilityLabel("Main Menu")
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

    private func button(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { glyph(symbol) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
