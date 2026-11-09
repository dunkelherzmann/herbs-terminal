import CGtk
import CHerb
import Foundation

// A thin Swift layer over the GTK, libadwaita and VTE C APIs: pointer casts, signals as closures, and builders for
// the widgets the app uses everywhere.

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// Casts between GObject pointer types; the target type comes from the C function being called.
@inline(__always) func c<T, U>(_ pointer: UnsafeMutablePointer<U>?) -> UnsafeMutablePointer<T>! {
    pointer.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: T.self) }
}
@inline(__always) func c<U>(_ pointer: UnsafeMutablePointer<U>?) -> OpaquePointer! { pointer.map(OpaquePointer.init) }
@inline(__always) func c<T>(_ pointer: OpaquePointer?) -> UnsafeMutablePointer<T>! { pointer.map(UnsafeMutablePointer<T>.init) }
@inline(__always) func c(_ pointer: OpaquePointer?) -> OpaquePointer! { pointer }
@inline(__always) func c<T>(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T>! { pointer?.assumingMemoryBound(to: T.self) }
@inline(__always) func w<U>(_ pointer: UnsafeMutablePointer<U>?) -> Widget! { c(pointer) }
@inline(__always) func w(_ pointer: OpaquePointer?) -> Widget! { c(pointer) }
@inline(__always) func raw<U>(_ pointer: UnsafeMutablePointer<U>?) -> UnsafeMutableRawPointer? { pointer.map { UnsafeMutableRawPointer($0) } }
@inline(__always) func raw(_ pointer: OpaquePointer?) -> UnsafeMutableRawPointer? { pointer.map { UnsafeMutableRawPointer($0) } }

func string(_ text: UnsafePointer<CChar>?) -> String? { text.map { String(cString: $0) } }

/// Takes a newly allocated C string and frees it.
func takeString(_ text: UnsafeMutablePointer<CChar>?) -> String? {
    guard let text else { return nil }
    defer { g_free(text) }
    return String(cString: text)
}

// MARK: Signals

/// The parameters of one signal emission; index 0 is the emitting object.
struct SignalArgs {
    let values: UnsafePointer<GValue>?
    let count: UInt32
    let result: UnsafeMutablePointer<GValue>?

    func pointer(_ index: UInt32) -> UnsafeMutableRawPointer? { index < count ? herb_value_pointer(values, index) : nil }
    func int(_ index: UInt32) -> Int { index < count ? Int(herb_value_int(values, index)) : 0 }
    func uint(_ index: UInt32) -> UInt32 { index < count ? herb_value_uint(values, index) : 0 }
    func double(_ index: UInt32) -> Double { index < count ? herb_value_double(values, index) : 0 }
    func string(_ index: UInt32) -> String? { index < count ? herb_value_string(values, index).map { String(cString: $0) } : nil }
    func bool(_ index: UInt32) -> Bool { index < count ? herb_value_bool(values, index) != 0 : false }
    func value(_ index: UInt32) -> UnsafePointer<GValue>? { index < count ? values.map { $0 + Int(index) } : nil }
    func returns(_ value: Bool) { herb_return_bool(result, value ? 1 : 0) }
}

final class SignalBox {
    let handler: @MainActor (SignalArgs) -> Void
    init(_ handler: @escaping @MainActor (SignalArgs) -> Void) { self.handler = handler }
}

private let signalTrampoline: HerbCallback = { data, result, count, values in
    let box = Unmanaged<SignalBox>.fromOpaque(data!).takeUnretainedValue()
    let args = SignalArgs(values: values, count: count, result: result)
    MainActor.assumeIsolated { box.handler(args) }
}

private let releaseBox: HerbRelease = { data in
    Unmanaged<AnyObject>.fromOpaque(data!).release()
}

/// Connects `signal` on any GObject to a closure; the closure lives as long as the connection.
@discardableResult
func on(_ object: UnsafeMutableRawPointer?, _ signal: String, after: Bool = false,
        _ handler: @escaping @MainActor (SignalArgs) -> Void) -> UInt {
    guard let object else { return 0 }
    let box = Unmanaged.passRetained(SignalBox(handler)).toOpaque()
    return UInt(herb_connect(object, signal, signalTrampoline, box, releaseBox, after ? 1 : 0))
}

@discardableResult
func on<U>(_ object: UnsafeMutablePointer<U>?, _ signal: String, after: Bool = false,
           _ handler: @escaping @MainActor (SignalArgs) -> Void) -> UInt {
    on(raw(object), signal, after: after, handler)
}

@discardableResult
func on(_ object: OpaquePointer?, _ signal: String, after: Bool = false,
        _ handler: @escaping @MainActor (SignalArgs) -> Void) -> UInt {
    on(raw(object), signal, after: after, handler)
}

func closure(_ handler: @escaping @MainActor (SignalArgs) -> Void) -> UnsafeMutablePointer<GClosure> {
    let box = Unmanaged.passRetained(SignalBox(handler)).toOpaque()
    return herb_closure(signalTrampoline, box, releaseBox)
}

// MARK: Main loop

final class TimerBox {
    let tick: @MainActor () -> Bool
    init(_ tick: @escaping @MainActor () -> Bool) { self.tick = tick }
}

private let timerTrampoline: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
    let box = Unmanaged<TimerBox>.fromOpaque(data!).takeUnretainedValue()
    return MainActor.assumeIsolated { box.tick() } ? 1 : 0
}

/// Calls `tick` every `milliseconds` while it returns true.
@discardableResult
func every(milliseconds: UInt32, _ tick: @escaping @MainActor () -> Bool) -> UInt32 {
    herb_timeout(milliseconds, timerTrampoline, Unmanaged.passRetained(TimerBox(tick)).toOpaque(), releaseBox)
}

/// Runs `work` once after `milliseconds`.
@discardableResult
func after(milliseconds: UInt32, _ work: @escaping @MainActor () -> Void) -> UInt32 {
    every(milliseconds: milliseconds) { work(); return false }
}

/// Runs `work` once the main loop is idle.
func idle(_ work: @escaping @MainActor () -> Void) {
    herb_idle(timerTrampoline, Unmanaged.passRetained(TimerBox { work(); return false }).toOpaque(), releaseBox)
}

func cancelSource(_ id: UInt32) { if id != 0 { g_source_remove(id) } }

// MARK: Callbacks with a string result

final class StringBox {
    let done: @MainActor (String?) -> Void
    init(_ done: @escaping @MainActor (String?) -> Void) { self.done = done }
}

let receivedTrampoline: HerbReceived = { data, text in
    let box = Unmanaged<StringBox>.fromOpaque(data!).takeRetainedValue()
    let value = text.map { String(cString: $0) }
    MainActor.assumeIsolated { box.done(value) }
}

func stringBox(_ done: @escaping @MainActor (String?) -> Void) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(StringBox(done)).toOpaque()
}

/// A drop target for files and folders from file managers or the app itself; `dropped` gets their local paths.
func filesDropTarget(_ dropped: @escaping @MainActor ([String]) -> Void) -> OpaquePointer {
    let target = herb_files_drop_target()!
    on(target, "drop") { args in
        guard let value = args.value(1) else { args.returns(false); return }
        herb_drop_read_paths(value, receivedTrampoline, stringBox { text in
            let paths = text.map { $0.split(separator: "\n").map(String.init) } ?? []
            if !paths.isEmpty { dropped(paths) }
        })
        args.returns(true)
    }
    return target
}

// MARK: Builders

enum Orientation { case horizontal, vertical
    var gtk: GtkOrientation { self == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL }
}

func box(_ orientation: Orientation, spacing: Int32 = 0, _ children: [Widget?] = [], classes: [String] = []) -> Widget {
    let widget = gtk_box_new(orientation.gtk, spacing)!
    for child in children.compactMap({ $0 }) { gtk_box_append(c(widget), child) }
    classes.forEach { gtk_widget_add_css_class(widget, $0) }
    return widget
}

func append(_ container: Widget, _ children: Widget?...) {
    for child in children.compactMap({ $0 }) { gtk_box_append(c(container), child) }
}

func removeChildren(_ container: Widget) {
    // A focused widget that is removed (a selectable label, say) stays the window's focus, and the next frame
    // crashed inside GTK. Move the focus off anything being removed first.
    if let root = gtk_widget_get_root(container), let focus = gtk_root_get_focus(root),
       focus == container || gtk_widget_is_ancestor(focus, container) != 0 {
        gtk_root_set_focus(root, nil)
    }
    while let child = gtk_widget_get_first_child(container) { gtk_box_remove(c(container), child) }
}

func label(_ text: String, classes: [String] = [], xalign: Float = 0, wrap: Bool = false, selectable: Bool = false,
           ellipsize: PangoEllipsizeMode = PANGO_ELLIPSIZE_NONE) -> Widget {
    let widget = gtk_label_new(text)!
    gtk_label_set_xalign(c(widget), xalign)
    if wrap {
        gtk_label_set_wrap(c(widget), 1)
        gtk_label_set_wrap_mode(c(widget), PANGO_WRAP_WORD_CHAR)
    }
    if selectable { gtk_label_set_selectable(c(widget), 1) }
    gtk_label_set_ellipsize(c(widget), ellipsize)
    classes.forEach { gtk_widget_add_css_class(widget, $0) }
    return widget
}

func setLabel(_ widget: Widget, _ text: String) { gtk_label_set_text(c(widget), text) }

/// A hover bubble: what the control is on the first line (bold), what it does below. Screen readers get the
/// same text as the control's description.
func hint(_ widget: Widget, _ text: String) {
    let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
    // An empty hint clears the bubble; indexing lines[0] here used to crash the app.
    guard !lines.isEmpty else {
        gtk_widget_set_tooltip_markup(widget, nil)
        accessibleDescription(widget, "")
        return
    }
    let escaped = lines.map { takeString(g_markup_escape_text($0, -1)) ?? $0 }
    let markup = escaped.count > 1 ? "<b>\(escaped[0])</b>\n\(escaped[1])" : "<b>\(escaped[0])</b>"
    gtk_widget_set_tooltip_markup(widget, markup)
    accessibleDescription(widget, lines.count > 1 ? lines[1] : lines[0])
}

func accessibleLabel(_ widget: Widget, _ text: String) {
    var value = GValue()
    g_value_init(&value, herb_type_string())
    g_value_set_string(&value, text)
    var property = GTK_ACCESSIBLE_PROPERTY_LABEL
    gtk_accessible_update_property_value(c(widget), 1, &property, &value)
    g_value_unset(&value)
}

/// The control's identifier for assistive tools (AT-SPI AccessibleId), the same string as on the Mac and Windows,
/// so parity checks can match the controls. GTK takes it from the builder id, which only a builder can set.
@MainActor func accessibleID(_ widget: Widget, _ identifier: String) {
    let builder = gtk_builder_new()!
    gtk_builder_expose_object(builder, identifier, UnsafeMutablePointer<GObject>(OpaquePointer(widget)))
    g_object_unref(raw(builder))
    ParityScene.register(widget, identifier)
}

func accessibleDescription(_ widget: Widget, _ text: String) {
    var value = GValue()
    g_value_init(&value, herb_type_string())
    g_value_set_string(&value, text)
    var property = GTK_ACCESSIBLE_PROPERTY_DESCRIPTION
    gtk_accessible_update_property_value(c(widget), 1, &property, &value)
    g_value_unset(&value)
}

/// Pressed / not pressed for toggle-like buttons, for screen readers.
func accessiblePressed(_ widget: Widget, _ pressed: Bool) {
    // GTK reads a tristate state as a plain int (an enum-typed value logged a critical on every update).
    var value = GValue()
    g_value_init(&value, herb_type_int())
    g_value_set_int(&value, pressed ? Int32(GTK_ACCESSIBLE_TRISTATE_TRUE.rawValue) : Int32(GTK_ACCESSIBLE_TRISTATE_FALSE.rawValue))
    var state = GTK_ACCESSIBLE_STATE_PRESSED
    gtk_accessible_update_state_value(c(widget), 1, &state, &value)
    g_value_unset(&value)
}

func accessibleSelected(_ widget: Widget, _ selected: Bool) {
    // Selected can be undefined, so GTK reads it as an int too (1, 0, or -1 for undefined).
    var value = GValue()
    g_value_init(&value, herb_type_int())
    g_value_set_int(&value, selected ? 1 : 0)
    var state = GTK_ACCESSIBLE_STATE_SELECTED
    gtk_accessible_update_state_value(c(widget), 1, &state, &value)
    g_value_unset(&value)
}

func button(_ title: String, classes: [String] = [], hint text: String? = nil, _ action: @escaping @MainActor () -> Void) -> Widget {
    let widget = gtk_button_new_with_label(title)!
    classes.forEach { gtk_widget_add_css_class(widget, $0) }
    if let text { hint(widget, text) }
    on(widget, "clicked") { _ in action() }
    return widget
}

func iconButton(_ icon: String, label name: String, hint text: String, classes: [String] = ["flat"],
                _ action: @escaping @MainActor () -> Void) -> Widget {
    let widget = gtk_button_new_from_icon_name(icon)!
    classes.forEach { gtk_widget_add_css_class(widget, $0) }
    hint(widget, text)
    accessibleLabel(widget, name)
    on(widget, "clicked") { _ in action() }
    return widget
}

func image(_ icon: String, pixels: Int32 = 16, classes: [String] = []) -> Widget {
    let widget = gtk_image_new_from_icon_name(icon)!
    gtk_image_set_pixel_size(c(widget), pixels)
    classes.forEach { gtk_widget_add_css_class(widget, $0) }
    return widget
}

func entry(placeholder: String = "", text: String = "", password: Bool = false) -> Widget {
    if password {
        let widget = gtk_password_entry_new()!
        herb_set_string(raw(widget), "placeholder-text", placeholder)
        gtk_editable_set_text(c(widget), text)
        return widget
    }
    let widget = gtk_entry_new()!
    gtk_entry_set_placeholder_text(c(widget), placeholder)
    gtk_editable_set_text(c(widget), text)
    return widget
}

func text(of editable: Widget) -> String { string(gtk_editable_get_text(c(editable))) ?? "" }
func setText(_ editable: Widget, _ value: String) { gtk_editable_set_text(c(editable), value) }

func check(_ title: String, active: Bool = false, hint text: String? = nil, _ toggled: @escaping @MainActor (Bool) -> Void = { _ in }) -> Widget {
    let widget = title.isEmpty ? gtk_check_button_new()! : gtk_check_button_new_with_label(title)!
    gtk_check_button_set_active(c(widget), active ? 1 : 0)
    if let text { hint(widget, text) }
    on(widget, "toggled") { _ in toggled(gtk_check_button_get_active(c(widget)) != 0) }
    return widget
}

func isActive(_ check: Widget) -> Bool { gtk_check_button_get_active(c(check)) != 0 }
func setActive(_ check: Widget, _ value: Bool) { gtk_check_button_set_active(c(check), value ? 1 : 0) }

func toggleButton(icon: String, label name: String, active: Bool, _ toggled: @escaping @MainActor (Bool) -> Void) -> Widget {
    let widget = gtk_toggle_button_new()!
    gtk_button_set_icon_name(c(widget), icon)
    gtk_toggle_button_set_active(c(widget), active ? 1 : 0)
    accessibleLabel(widget, name)
    on(widget, "toggled") { _ in toggled(gtk_toggle_button_get_active(c(widget)) != 0) }
    return widget
}

func separator(_ orientation: Orientation = .horizontal) -> Widget {
    gtk_separator_new(orientation == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL)!
}

func spacer() -> Widget {
    let widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
    gtk_widget_set_hexpand(widget, 1)
    return widget
}

func scrolled(_ child: Widget, horizontal: Bool = false, vertical: Bool = true) -> Widget {
    let widget = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_child(c(widget), child)
    gtk_scrolled_window_set_policy(c(widget), horizontal ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER,
                                   vertical ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER)
    gtk_widget_set_vexpand(widget, 1)
    gtk_widget_set_hexpand(widget, 1)
    return widget
}

func dropDown(_ items: [String], selected: Int, _ changed: @escaping @MainActor (Int) -> Void) -> Widget {
    var pointers = items.map { strdup($0) } + [nil]
    let widget = pointers.withUnsafeMutableBufferPointer { buffer in
        gtk_drop_down_new_from_strings(UnsafePointer(OpaquePointer(buffer.baseAddress!)))!
    }
    pointers.forEach { free($0) }
    gtk_drop_down_set_selected(c(widget), UInt32(max(0, selected)))
    on(widget, "notify::selected") { _ in changed(Int(gtk_drop_down_get_selected(c(widget)))) }
    return widget
}

func spin(value: Double, range: ClosedRange<Double>, step: Double = 1, digits: UInt32 = 0,
          _ changed: @escaping @MainActor (Double) -> Void) -> Widget {
    let widget = gtk_spin_button_new_with_range(range.lowerBound, range.upperBound, step)!
    gtk_spin_button_set_digits(c(widget), digits)
    gtk_spin_button_set_value(c(widget), value)
    on(widget, "value-changed") { _ in changed(gtk_spin_button_get_value(c(widget))) }
    return widget
}

func grid(rowSpacing: UInt32 = 6, columnSpacing: UInt32 = 12) -> Widget {
    let widget = gtk_grid_new()!
    gtk_grid_set_row_spacing(c(widget), rowSpacing)
    gtk_grid_set_column_spacing(c(widget), columnSpacing)
    return widget
}

func attach(_ grid: Widget, _ child: Widget, column: Int32, row: Int32, width: Int32 = 1) {
    gtk_grid_attach(c(grid), child, column, row, width, 1)
}

func margins(_ widget: Widget, _ all: Int32) { margins(widget, top: all, bottom: all, start: all, end: all) }
func margins(_ widget: Widget, top: Int32 = 0, bottom: Int32 = 0, start: Int32 = 0, end: Int32 = 0) {
    gtk_widget_set_margin_top(widget, top)
    gtk_widget_set_margin_bottom(widget, bottom)
    gtk_widget_set_margin_start(widget, start)
    gtk_widget_set_margin_end(widget, end)
}

func setVisible(_ widget: Widget, _ visible: Bool) { gtk_widget_set_visible(widget, visible ? 1 : 0) }
func enable(_ widget: Widget, _ enabled: Bool) { gtk_widget_set_sensitive(widget, enabled ? 1 : 0) }

/// The bold first line and secondary second line of headings and notices.
func setAttributes(_ label: Widget, weight: Int32 = 0, points: Double = 0) {
    let list = herb_attrs(weight, points)
    gtk_label_set_attributes(c(label), list)
    pango_attr_list_unref(list)
}

// MARK: Gestures and keys

/// A click handler: `count` is 1 for a click, 2 for a double-click; `button` 1 is primary, 3 secondary.
func onClick(_ widget: Widget, button: UInt32 = 1, capture: Bool = false,
             _ handler: @escaping @MainActor (_ count: Int, _ x: Double, _ y: Double) -> Void) {
    let gesture = gtk_gesture_click_new()!
    gtk_gesture_single_set_button(c(gesture), button)
    if capture { gtk_event_controller_set_propagation_phase(c(gesture), GTK_PHASE_CAPTURE) }
    on(gesture, "pressed") { args in handler(args.int(1), args.double(2), args.double(3)) }
    gtk_widget_add_controller(widget, c(gesture))
}

/// Keyboard shortcuts that act only while `widget` (or a child) has focus.
@MainActor
final class LocalShortcuts {
    let controller: OpaquePointer

    init(_ widget: Widget, capture: Bool = false) {
        controller = c(gtk_shortcut_controller_new())
        gtk_shortcut_controller_set_scope(c(controller), GTK_SHORTCUT_SCOPE_LOCAL)
        if capture { gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE) }
        gtk_widget_add_controller(widget, controller)
    }

    /// `trigger` in GTK's syntax, e.g. "<Control>c" or "Delete"; several may be joined with "|".
    func add(_ trigger: String, _ action: @escaping @MainActor () -> Void) {
        let shortcut = gtk_shortcut_new(gtk_shortcut_trigger_parse_string(trigger),
                                        gtk_callback_action_new(shortcutTrampoline, Unmanaged.passRetained(TimerBox { action(); return true }).toOpaque(),
                                                                releaseCallback))
        gtk_shortcut_controller_add_shortcut(c(controller), shortcut)
    }
}

private let shortcutTrampoline: GtkShortcutFunc = { _, _, data in
    let box = Unmanaged<TimerBox>.fromOpaque(data!).takeUnretainedValue()
    return MainActor.assumeIsolated { box.tick() } ? 1 : 0
}

private let releaseCallback: GDestroyNotify = { data in
    Unmanaged<AnyObject>.fromOpaque(data!).release()
}

// MARK: Actions and menus

/// A GAction on a window or the application, with an optional state for check items.
@MainActor
@discardableResult
func addAction(_ map: OpaquePointer?, _ name: String, enabled: Bool = true, _ activate: @escaping @MainActor () -> Void) -> OpaquePointer {
    let action = g_simple_action_new(name, nil)!
    g_simple_action_set_enabled(action, enabled ? 1 : 0)
    on(action, "activate") { _ in activate() }
    g_action_map_add_action(map, c(action))
    g_object_unref(raw(action))
    return action
}

/// A stateful boolean action, shown as a check item in menus.
@MainActor
@discardableResult
func addToggleAction(_ map: OpaquePointer?, _ name: String, state: Bool, _ changed: @escaping @MainActor (Bool) -> Void) -> OpaquePointer {
    let action = g_simple_action_new_stateful(name, nil, g_variant_new_boolean(state ? 1 : 0))!
    on(action, "activate") { _ in
        let now = g_variant_get_boolean(g_action_get_state(c(action))) != 0
        g_simple_action_set_state(action, g_variant_new_boolean(now ? 0 : 1))
        changed(!now)
    }
    g_action_map_add_action(map, c(action))
    g_object_unref(raw(action))
    return action
}

/// A radio-style action with a string state, for "Color scheme" and the like.
@MainActor
@discardableResult
func addChoiceAction(_ map: OpaquePointer?, _ name: String, state: String, _ changed: @escaping @MainActor (String) -> Void) -> OpaquePointer {
    let action = g_simple_action_new_stateful(name, g_variant_type_new("s"), g_variant_new_string(state))!
    on(action, "activate") { args in
        guard let parameter = args.pointer(1) else { return }
        let value = String(cString: g_variant_get_string(OpaquePointer(parameter), nil))
        g_simple_action_set_state(action, g_variant_new_string(value))
        changed(value)
    }
    g_action_map_add_action(map, c(action))
    g_object_unref(raw(action))
    return action
}

func setActionState(_ action: OpaquePointer?, _ value: Bool) {
    g_simple_action_set_state(action, g_variant_new_boolean(value ? 1 : 0))
}

func setActionState(_ action: OpaquePointer?, _ value: String) {
    g_simple_action_set_state(action, g_variant_new_string(value))
}

func setActionEnabled(_ action: OpaquePointer?, _ enabled: Bool) {
    g_simple_action_set_enabled(action, enabled ? 1 : 0)
}

/// Builds a GMenu: items are (label, detailed action), `nil` labels start a new section.
final class MenuBuilder {
    let menu = g_menu_new()!
    private var section = g_menu_new()!

    func item(_ title: String, _ action: String, accel: String? = nil) {
        let item = g_menu_item_new(title, action)!
        if let accel { g_menu_item_set_attribute_value(item, "accel", g_variant_new_string(accel)) }
        g_menu_append_item(section, item)
        g_object_unref(raw(item))
    }

    func item(_ title: String, _ action: String, target: String) {
        let item = g_menu_item_new(title, nil)!
        g_menu_item_set_action_and_target_value(item, action, g_variant_new_string(target))
        g_menu_append_item(section, item)
        g_object_unref(raw(item))
    }

    func submenu(_ title: String, _ build: (MenuBuilder) -> Void) {
        let builder = MenuBuilder()
        build(builder)
        g_menu_append_submenu(section, title, c(builder.finish()))
    }

    func divider() {
        if g_menu_model_get_n_items(c(section)) > 0 {
            g_menu_append_section(menu, nil, c(section))
            g_object_unref(raw(section))
            section = g_menu_new()!
        }
    }

    func finish() -> OpaquePointer {
        divider()
        g_object_unref(raw(section))
        return menu
    }
}

/// GTK draws each item of a popover menu as an internal button, and AT-SPI reports those buttons without a name.
/// Each time a menu button's menu (or a popover menu) opens, its items are named after their own labels.
func nameMenuItems(_ menuButton: Widget) {
    guard let popover = gtk_menu_button_get_popover(c(menuButton)) else { return }
    nameMenuItems(popover: w(popover))
}

func nameMenuItems(popover: Widget) {
    guard g_object_get_data(c(popover), "herb-names-items") == nil else { return }
    g_object_set_data(c(popover), "herb-names-items", UnsafeMutableRawPointer(bitPattern: 1))
    on(popover, "map") { _ in nameItems(in: popover) }
}

private func nameItems(in widget: Widget) {
    var child = gtk_widget_get_first_child(widget)
    while let current = child {
        if string(gtk_widget_get_css_name(current)) == "modelbutton" {
            if let text = firstLabelText(current) {
                // A "labelled by" relation would win over the label, so it goes first.
                gtk_accessible_reset_relation(c(current), GTK_ACCESSIBLE_RELATION_LABELLED_BY)
                accessibleLabel(current, text)
            }
        } else {
            nameItems(in: current)
        }
        child = gtk_widget_get_next_sibling(current)
    }
}

/// The item's own text: the first label in it (the shortcut comes after).
private func firstLabelText(_ widget: Widget) -> String? {
    var child = gtk_widget_get_first_child(widget)
    while let current = child {
        if string(gtk_widget_get_css_name(current)) == "label", let text = string(gtk_label_get_text(c(current))), !text.isEmpty {
            return text
        }
        if let text = firstLabelText(current) { return text }
        child = gtk_widget_get_next_sibling(current)
    }
    return nil
}

/// Pops a menu up at a point in `widget` (a right-click), or under it.
func popUp(_ model: OpaquePointer, on widget: Widget, x: Double? = nil, y: Double? = nil) {
    let popover = gtk_popover_menu_new_from_model(c(model))!
    nameMenuItems(popover: popover)
    gtk_widget_set_parent(popover, widget)
    gtk_popover_set_has_arrow(c(popover), 0)
    if let x, let y {
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(c(popover), &rect)
        gtk_widget_set_halign(popover, GTK_ALIGN_START)
    }
    on(popover, "closed") { _ in idle { gtk_widget_unparent(popover) } }
    gtk_popover_popup(c(popover))
}

// MARK: Windows

func rootWindow(_ widget: Widget?) -> UnsafeMutablePointer<GtkWindow>? {
    guard let widget, let root = gtk_widget_get_root(widget) else { return nil }
    return c(UnsafeMutableRawPointer(root))
}

/// Shows a CSS stylesheet for the whole app.
func loadCSS(_ css: String) {
    let provider = gtk_css_provider_new()!
    gtk_css_provider_load_from_string(provider, css)
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), c(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
}

func rgba(_ hex: UInt32, alpha: Double = 1) -> GdkRGBA {
    GdkRGBA(red: Float((hex >> 16) & 0xFF) / 255, green: Float((hex >> 8) & 0xFF) / 255, blue: Float(hex & 0xFF) / 255, alpha: Float(alpha))
}

func clipboard(of widget: Widget? = nil) -> OpaquePointer? {
    if let widget { return gdk_widget_get_clipboard_compat(widget) }
    return gdk_display_get_clipboard(gdk_display_get_default())
}

private func gdk_widget_get_clipboard_compat(_ widget: Widget) -> OpaquePointer? {
    gtk_widget_get_clipboard(widget)
}

func setClipboardText(_ text: String) {
    gdk_clipboard_set_text(clipboard(), text)
}
