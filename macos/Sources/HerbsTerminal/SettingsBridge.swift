import AppKit
import SwiftUI

/// The feature tests' view of Settings (R7–R11). SwiftUI keeps its own controls out of the window's in-process
/// accessibility tree, so each control on a Settings page registers itself here while it's on screen, with its label
/// and the same binding or action it uses: the bridge reads a page as it's shown and changes a control the way the
/// control would. It does nothing outside the test copy.
@MainActor
enum SettingsBridge {
    static let pages = ["Profiles", "Text", "Terminal", "Window", "Colors"]

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// One control: what kind it is, and how the bridge reads and changes it.
    struct Control {
        var kind: String
        var value: () -> Any = { NSNull() }
        var set: (Any?) throws -> Void = { _ in }
        var options: () -> [String] = { [] }
        var range: ClosedRange<Double>?
        var enabled: () -> Bool = { true }

        static func toggle(_ binding: Binding<Bool>) -> Control {
            Control(kind: "toggle", value: { binding.wrappedValue }, set: { binding.wrappedValue = ($0 as? Bool) ?? !binding.wrappedValue })
        }

        static func text(_ binding: Binding<String>) -> Control {
            Control(kind: "text", value: { binding.wrappedValue }, set: { binding.wrappedValue = $0.map { "\($0)" } ?? "" })
        }

        static func number(_ binding: Binding<Double>, _ range: ClosedRange<Double>) -> Control {
            Control(kind: "number", value: { binding.wrappedValue }, set: { binding.wrappedValue = try number($0) }, range: range)
        }

        static func number(_ binding: Binding<Int>, _ range: ClosedRange<Int>) -> Control {
            Control(kind: "number", value: { binding.wrappedValue }, set: { binding.wrappedValue = Int(try number($0)) },
                    range: Double(range.lowerBound)...Double(range.upperBound))
        }

        static func slider(_ binding: Binding<Double>, _ range: ClosedRange<Double>) -> Control {
            Control(kind: "slider", value: { binding.wrappedValue },
                    set: { binding.wrappedValue = min(range.upperBound, max(range.lowerBound, try number($0))) }, range: range)
        }

        /// A popup, segmented control or list with one selection: its items' titles and the values they stand for.
        static func choice<Value: Equatable>(_ binding: Binding<Value>, _ items: @escaping () -> [(String, Value)]) -> Control {
            Control(kind: "choice", value: { items().first { $0.1 == binding.wrappedValue }?.0 ?? "" },
                    set: { title in
                        guard let item = items().first(where: { $0.0 == title as? String }) else {
                            throw Failure(description: "no item \(title ?? "") (there are: \(items().map(\.0)))")
                        }
                        binding.wrappedValue = item.1
                    },
                    options: { items().map(\.0) })
        }

        static func button(enabled: @escaping () -> Bool = { true }, _ action: @escaping () -> Void) -> Control {
            Control(kind: "button", set: { _ in action() }, enabled: enabled)
        }

        /// Something shown rather than changed, such as the live preview: `describe` is what it shows.
        static func display(_ describe: @escaping () -> String) -> Control { Control(kind: "display", value: describe) }

        private static func number(_ value: Any?) throws -> Double {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String, let number = Double(text) { return number }
            throw Failure(description: "needs a number, not \(value ?? "nothing")")
        }
    }

    /// A control on screen; `count` covers the moment SwiftUI shows a page's new view before removing the old one.
    private struct Entry { let page: String; let label: String; var control: Control; var count: Int }
    private static var entries: [Entry] = []

    static func register(page: String, label: String, control: Control) {
        if let index = entries.firstIndex(where: { $0.page == page && $0.label == label }) {
            entries[index].control = control
            entries[index].count += 1
        } else {
            entries.append(Entry(page: page, label: label, control: control, count: 1))
        }
    }

    static func unregister(page: String, label: String) {
        guard let index = entries.firstIndex(where: { $0.page == page && $0.label == label }) else { return }
        entries[index].count -= 1
        if entries[index].count <= 0 { entries.remove(at: index) }
    }

    private static var window: NSWindow? { NSApp.windows.first { $0.isVisible && pages.contains($0.title) } }

    /// Shows the page `name` (one of `pages`) and reports the controls on it.
    static func page(_ name: String) throws -> [String: Any] {
        guard let window else { throw Failure(description: "Settings isn't open") }
        if window.title != name {
            guard let item = window.toolbar?.items.first(where: { $0.label == name }), let action = item.action else {
                throw Failure(description: "Settings has no \(name) page")
            }
            NSApp.sendAction(action, to: item.target, from: item)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return ["page": window.title, "pages": window.toolbar?.items.map(\.label).filter { pages.contains($0) } ?? [],
                "controls": entries.filter { $0.page == window.title }.map(report)]
    }

    /// Changes the control labelled `label` on the page that's shown.
    static func set(label: String, value: Any?) throws -> Any {
        guard let window else { throw Failure(description: "Settings isn't open") }
        guard let entry = entries.first(where: { $0.page == window.title && $0.label == label }) else {
            throw Failure(description: "Settings ▸ \(window.title) has no \(label)")
        }
        guard entry.control.enabled() else { throw Failure(description: "\(label) is greyed out") }
        try entry.control.set(value is NSNull ? nil : value)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return "ok"
    }

    private static func report(_ entry: Entry) -> [String: Any] {
        let control = entry.control
        var result: [String: Any] = ["kind": control.kind, "label": entry.label, "enabled": control.enabled()]
        let value = control.value()
        if !(value is NSNull) { result["value"] = value }
        if control.kind == "choice" { result["options"] = control.options() }
        if let range = control.range { result["min"] = range.lowerBound; result["max"] = range.upperBound }
        return result
    }
}

/// Registers the control it's attached to with `SettingsBridge` while it's on screen (test copy only).
private struct SettingsBridgeEntry: ViewModifier {
    let page: String, label: String, control: () -> SettingsBridge.Control

    func body(content: Content) -> some View {
        if TestBridge.isActive {
            content
                .onAppear { SettingsBridge.register(page: page, label: label, control: control()) }
                .onDisappear { SettingsBridge.unregister(page: page, label: label) }
        } else {
            content
        }
    }
}

extension View {
    /// Makes this Settings control reachable by the feature tests under `label`, on `page`.
    func bridged(_ page: String, _ label: String, _ control: @escaping @autoclosure () -> SettingsBridge.Control) -> some View {
        modifier(SettingsBridgeEntry(page: page, label: label, control: control))
    }
}
