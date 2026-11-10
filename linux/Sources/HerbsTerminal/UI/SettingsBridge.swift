import CGtk
import Foundation

/// The feature tests' view of Settings (R7–R11): each control on a Settings page is registered here with its label
/// and its real widget. The bridge reads a page from the widgets and changes one as a person would (the widget's own
/// setter, which fires the signal its handler listens to). Only the test copy registers anything.
@MainActor
enum SettingsBridge {
    struct Failure: Error, CustomStringConvertible { let description: String }

    struct Control {
        var kind: String
        var value: () -> Any = { NSNull() }
        var set: (Any?) throws -> Void = { _ in }
        var options: () -> [String] = { [] }
        var range: ClosedRange<Double>?
        var enabled: () -> Bool = { true }

        static func spin(_ widget: Widget) -> Control {
            var low = 0.0, high = 0.0
            gtk_spin_button_get_range(c(widget), &low, &high)
            return Control(kind: "number", value: { gtk_spin_button_get_value(c(widget)) },
                           set: { gtk_spin_button_set_value(c(widget), try number($0)) }, range: low...high,
                           enabled: { gtk_widget_get_sensitive(widget) != 0 })
        }

        static func entry(_ widget: Widget) -> Control {
            Control(kind: "text", value: { text(of: widget) }, set: { setText(widget, $0.map { "\($0)" } ?? "") },
                    enabled: { gtk_widget_get_sensitive(widget) != 0 })
        }

        static func check(_ widget: Widget) -> Control {
            Control(kind: "toggle", value: { isActive(widget) }, set: { setActive(widget, ($0 as? Bool) ?? !isActive(widget)) },
                    enabled: { gtk_widget_get_sensitive(widget) != 0 })
        }

        static func scale(_ widget: Widget, _ range: ClosedRange<Double>) -> Control {
            Control(kind: "slider", value: { gtk_range_get_value(c(widget)) }, set: { gtk_range_set_value(c(widget), try number($0)) },
                    range: range, enabled: { gtk_widget_get_sensitive(widget) != 0 })
        }

        static func dropDown(_ widget: Widget, _ items: [String]) -> Control {
            Control(kind: "choice", value: { items.indices.contains(Int(gtk_drop_down_get_selected(c(widget)))) ? items[Int(gtk_drop_down_get_selected(c(widget)))] : "" },
                    set: { title in
                        guard let index = items.firstIndex(where: { $0 == title as? String }) else { throw missing(title, items) }
                        gtk_drop_down_set_selected(c(widget), UInt32(index))
                    },
                    options: { items }, enabled: { gtk_widget_get_sensitive(widget) != 0 })
        }

        /// A row of linked toggle buttons with one pressed, such as the cursor shapes.
        static func toggles(_ widgets: [Widget], _ titles: [String]) -> Control {
            Control(kind: "choice", value: { zip(widgets, titles).first { gtk_toggle_button_get_active(c($0.0)) != 0 }?.1 ?? "" },
                    set: { title in
                        guard let index = titles.firstIndex(where: { $0 == title as? String }) else { throw missing(title, titles) }
                        gtk_toggle_button_set_active(c(widgets[index]), 1)
                    },
                    options: { titles })
        }

        /// A list with one selected row; `names` are its rows' titles, top to bottom.
        static func list(_ widget: Widget, _ names: @escaping () -> [String]) -> Control {
            Control(kind: "choice",
                    value: {
                        guard let row = gtk_list_box_get_selected_row(c(widget)) else { return "" }
                        let index = Int(gtk_list_box_row_get_index(row))
                        return names().indices.contains(index) ? names()[index] : ""
                    },
                    set: { title in
                        guard let index = names().firstIndex(where: { $0 == title as? String }) else { throw missing(title, names()) }
                        gtk_list_box_select_row(c(widget), gtk_list_box_get_row_at_index(c(widget), Int32(index)))
                    },
                    options: names)
        }

        static func button(_ widget: Widget) -> Control {
            Control(kind: "button", set: { _ in _ = gtk_widget_activate(widget) }, enabled: { gtk_widget_get_sensitive(widget) != 0 })
        }

        /// Something shown rather than changed, such as the live preview: `describe` is what it shows.
        static func display(_ describe: @escaping () -> String) -> Control { Control(kind: "display", value: describe) }

        private static func number(_ value: Any?) throws -> Double {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String, let number = Double(text) { return number }
            throw Failure(description: "needs a number, not \(value ?? "nothing")")
        }

        private static func missing(_ title: Any?, _ items: [String]) -> Failure {
            Failure(description: "no item \(title ?? "") (there are: \(items))")
        }
    }

    private static var entries: [(page: String, label: String, control: Control)] = []
    /// Shows a page by its title; set by the open Settings window.
    static var show: ((String) -> String?)?

    static func register(_ page: String, _ label: String, _ control: Control) {
        guard TestBridge.isActive else { return }
        entries.append((page, label, control))
    }

    static func clear() {
        entries = []
        show = nil
    }

    static func page(_ name: String) throws -> [String: Any] {
        guard let show else { throw Failure(description: "Settings isn't open") }
        guard let shown = show(name) else { throw Failure(description: "Settings has no \(name) page") }
        return ["page": shown, "controls": entries.filter { $0.page == shown }.map { report($0.label, $0.control) }]
    }

    static func set(page: String, label: String, value: Any?) throws -> Any {
        guard let show, let shown = show(page) else { throw Failure(description: "Settings isn't open") }
        guard let entry = entries.first(where: { $0.page == shown && $0.label == label }) else {
            throw Failure(description: "Settings ▸ \(shown) has no \(label)")
        }
        guard entry.control.enabled() else { throw Failure(description: "\(label) is greyed out") }
        try entry.control.set(value is NSNull ? nil : value)
        return "ok"
    }

    private static func report(_ label: String, _ control: Control) -> [String: Any] {
        var result: [String: Any] = ["kind": control.kind, "label": label, "enabled": control.enabled()]
        let value = control.value()
        if !(value is NSNull) { result["value"] = value }
        if control.kind == "choice" { result["options"] = control.options() }
        if let range = control.range { result["min"] = range.lowerBound; result["max"] = range.upperBound }
        return result
    }
}
