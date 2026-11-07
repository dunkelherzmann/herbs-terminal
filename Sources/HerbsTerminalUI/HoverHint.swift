import AppKit
import SwiftUI

extension View {
    /// A bubble explaining a control: what it is on the first line, what it does below. It appears after a
    /// short rest, also in the titlebar and while Herb's Terminal is in the background, where macOS tooltips are
    /// slow or hidden. VoiceOver reads the same text.
    public func hint(_ text: String) -> some View {
        modifier(HoverHint(text: text))
    }
}

private struct HoverHint: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { HintBubble.shared.schedule(text) } else { HintBubble.shared.hide(text) }
            }
            .simultaneousGesture(TapGesture().onEnded { HintBubble.shared.hide(nil) })
            .onDisappear { HintBubble.shared.hide(text) }
            // The first line repeats the control's name, which VoiceOver already reads.
            .accessibilityHint(text.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? text)
    }
}

/// The one floating bubble shared by every control.
@MainActor
public final class HintBubble {
    public static let shared = HintBubble()
    static let delay: TimeInterval = 0.45

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var pending: DispatchWorkItem?
    private(set) var shownText: String?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 280
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -5),
        ])
        panel.contentView = background
    }

    public func schedule(_ text: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (shownText == nil ? Self.delay : 0.05), execute: work)
    }

    /// Shows `text` at once, as a confirmation, and hides it after `seconds`. VoiceOver announces it.
    public func confirm(_ text: String, for seconds: TimeInterval = 1.5) {
        pending?.cancel()
        show(text)
        let work = DispatchWorkItem { [weak self] in self?.hide(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text.replacingOccurrences(of: "\n", with: ". "), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Hides the bubble if it belongs to `text` (or any bubble for nil).
    public func hide(_ text: String?) {
        pending?.cancel()
        guard text == nil || text == shownText else { return }
        panel.orderOut(nil)
        shownText = nil
    }

    private func show(_ text: String) {
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let styled = NSMutableAttributedString(string: lines[0], attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
        if lines.count > 1 {
            styled.append(NSAttributedString(string: "\n" + lines[1], attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = styled
        let size = label.sizeThatFits(NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        let frameSize = NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 10)

        // Below and right of the pointer, kept on the pointer's screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x + 10, y: mouse.y - 24 - frameSize.height)
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - frameSize.width - 4)
        if origin.y < screen.minY + 4 { origin.y = mouse.y + 18 }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        panel.orderFrontRegardless()
        shownText = text
    }
}
