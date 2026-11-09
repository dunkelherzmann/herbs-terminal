import SwiftUI

@MainActor
final class HeaderMetrics: ObservableObject {
    @Published var height: CGFloat = 32
}

// Use AppKit's actual button center, including changes in titlebar style or window size.
struct HeaderMeasurement: NSViewRepresentable {
    let metrics: HeaderMetrics

    final class Probe: NSView {
        weak var metrics: HeaderMetrics?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            measure()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measure()
        }

        private func measure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, let metrics,
                      let close = window.standardWindowButton(.closeButton),
                      !window.styleMask.contains(.fullScreen) else { return }
                let top = convert(bounds, to: nil).maxY
                let center = close.convert(close.bounds, to: nil).midY
                let height = 2 * (top - center)
                guard (20...80).contains(height), abs(metrics.height - height) >= 0.5 else { return }
                metrics.height = height
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.metrics = metrics
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.needsLayout = true }
}
