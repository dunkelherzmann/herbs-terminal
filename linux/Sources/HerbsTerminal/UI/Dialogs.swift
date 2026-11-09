import CGtk
import CHerb
import Foundation

/// Alerts, questions and file pickers, as libadwaita dialogs. Each one waits for the answer like an AppKit alert,
/// but without blocking the main loop: terminals keep running underneath.
@MainActor
enum Dialogs {
    enum Style { case normal, suggested, destructive }

    struct Choice {
        let id: String
        let title: String
        var style: Style = .normal
        init(_ id: String, _ title: String, _ style: Style = .normal) { self.id = id; self.title = title; self.style = style }
    }

    /// The window a dialog belongs to: the given one, or the app's active window.
    static func anchor(_ widget: Widget?) -> Widget? {
        if let widget { return widget }
        guard let app = App.shared.application, let window = gtk_application_get_active_window(c(app)) else { return nil }
        return w(window)
    }

    /// Asks a question; returns the chosen id. `cancel` is what Esc and closing answer. `defaultID` is what Return
    /// chooses; destructive questions keep Cancel as the default. `collect` runs as soon as a button is chosen,
    /// while the dialog still exists: read fields in `extra` there, because they're gone once this returns.
    /// Feature tests (TestBridge): the alerts on screen, so a test can read, fill and answer them.
    struct OpenDialog { let heading: String; let alert: UnsafeMutablePointer<AdwAlertDialog>; let responses: [String]; let fields: [Widget] }
    static var open: [Int: OpenDialog] = [:]
    private static var pendingFields: [Widget] = []
    /// The text fields of the next `ask`'s extra content, in order, so the feature tests' bridge can fill them.
    static func fieldsForNextAsk(_ fields: [Widget]) { pendingFields = fields }

    static func ask(_ parent: Widget?, _ heading: String, _ body: String = "", choices: [Choice], defaultID: String? = nil,
                    cancel: String, extra: Widget? = nil, collect: (() -> Void)? = nil) async -> String {
        let dialog = adw_alert_dialog_new(heading, body.isEmpty ? nil : body)!
        let alert: UnsafeMutablePointer<AdwAlertDialog> = c(dialog)
        for choice in choices {
            adw_alert_dialog_add_response(alert, choice.id, choice.title)
            switch choice.style {
            case .suggested: adw_alert_dialog_set_response_appearance(alert, choice.id, ADW_RESPONSE_SUGGESTED)
            case .destructive: adw_alert_dialog_set_response_appearance(alert, choice.id, ADW_RESPONSE_DESTRUCTIVE)
            case .normal: break
            }
        }
        adw_alert_dialog_set_close_response(alert, cancel)
        adw_alert_dialog_set_default_response(alert, defaultID ?? cancel)
        if let extra { adw_alert_dialog_set_extra_child(alert, extra) }
        let key = Int(bitPattern: UInt(bitPattern: raw(dialog)))
        if TestBridge.isActive { open[key] = OpenDialog(heading: heading, alert: alert, responses: choices.map(\.id), fields: pendingFields) }
        pendingFields = []
        return await withCheckedContinuation { continuation in
            herb_alert_choose(c(dialog), anchor(parent), responseTrampoline, Unmanaged.passRetained(ResponseBox { response in
                open[key] = nil
                collect?()
                continuation.resume(returning: response)
            }).toOpaque())
        }
    }

    /// An alert with one OK button.
    static func tell(_ parent: Widget?, _ heading: String, _ body: String = "") async {
        _ = await ask(parent, heading, body, choices: [Choice("ok", "OK", .suggested)], defaultID: "ok", cancel: "ok")
    }

    static func show(_ parent: Widget?, _ error: Error, heading: String = "Something went wrong") async {
        await tell(parent, heading, error.localizedDescription)
    }

    /// Asks for one or more values. Each field has a visible label; secure fields hide what's typed. Returns nil
    /// when cancelled.
    struct Field {
        let label: String
        var initial = ""
        var placeholder = ""
        var secure = false
        /// Selects the part before the extension, as file managers do for names.
        var selectBaseName = false
    }

    static func prompt(_ parent: Widget?, _ heading: String, _ body: String = "", fields: [Field], ok: String,
                       okStyle: Style = .suggested) async -> [String]? {
        let list = box(.vertical, spacing: 10)
        var entries: [Widget] = []
        for field in fields {
            let caption = label(field.label, classes: ["caption", "dim-label"])
            let input = entry(placeholder: field.placeholder, text: field.initial, password: field.secure)
            accessibleLabel(input, field.label)
            if field.secure { herb_set_bool(raw(input), "show-peek-icon", 1) }
            herb_set_bool(raw(input), "activates-default", 1)
            append(list, box(.vertical, spacing: 4, [caption, input]))
            entries.append(input)
        }
        if let first = entries.first {
            after(milliseconds: 80) {
                gtk_widget_grab_focus(first)
                if let field = fields.first, field.selectBaseName {
                    let base = (field.initial as NSString).deletingPathExtension
                    gtk_editable_select_region(c(first), 0, Int32((base.isEmpty ? field.initial : base).count))
                }
            }
        }
        var values: [String] = []
        pendingFields = entries
        let answer = await ask(parent, heading, body, choices: [Choice("cancel", "Cancel"), Choice("ok", ok, okStyle)],
                               defaultID: "ok", cancel: "cancel", extra: list, collect: { values = entries.map { text(of: $0) } })
        guard answer == "ok" else { return nil }
        return values
    }

    /// A file or folder name, with the part before the extension selected.
    static func name(_ parent: Widget?, title: String, message: String, initial: String) async -> String? {
        guard let values = await prompt(parent, title, message, fields: [Field(label: "Name", initial: initial, selectBaseName: true)], ok: "OK"),
              let name = values.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    // MARK: Files

    static func openFiles(_ parent: Widget?, title: String, accept: String, folder: String? = nil, folders: Bool = false,
                          multiple: Bool = false, pattern: String? = nil) async -> [String] {
        // The feature tests' bridge stands in for the file chooser.
        if let chosen = TestBridge.takeChosenFiles() { return chosen }
        let window: UnsafeMutablePointer<GtkWindow>? = anchor(parent).flatMap { rootWindow($0) }
        return await withCheckedContinuation { continuation in
            herb_file_open(window, title, accept, folder, folders ? 1 : 0, multiple ? 1 : 0, pattern, receivedTrampoline, stringBox { paths in
                continuation.resume(returning: paths.map { $0.split(separator: "\n").map(String.init) } ?? [])
            })
        }
    }

    static func save(_ parent: Widget?, title: String, folder: String? = nil, name: String) async -> String? {
        if let chosen = TestBridge.takeChosenFiles()?.first {
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: chosen, isDirectory: &folder) && folder.boolValue ? chosen + "/" + name : chosen
        }
        let window: UnsafeMutablePointer<GtkWindow>? = anchor(parent).flatMap { rootWindow($0) }
        return await withCheckedContinuation { continuation in
            herb_file_save(window, title, folder, name, receivedTrampoline, stringBox { continuation.resume(returning: $0) })
        }
    }
}

final class ResponseBox {
    let done: @MainActor (String) -> Void
    init(_ done: @escaping @MainActor (String) -> Void) { self.done = done }
}

private let responseTrampoline: HerbResponse = { data, response in
    let box = Unmanaged<ResponseBox>.fromOpaque(data!).takeRetainedValue()
    let value = response.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated { box.done(value) }
}

/// A small window of its own (Get Info, Manage Logins, Settings…), closed with Esc, with its own header bar.
@MainActor
final class ToolWindow {
    let window: Widget
    let header: Widget
    let content: Widget
    var onClose: (() -> Void)?
    /// The object that runs this window (its buttons call into it with weak references). The window keeps it
    /// alive until it's destroyed; without this, a dialog's controller was freed once shown and its buttons did nothing.
    var owner: AnyObject?

    init(title: String, width: Int32, height: Int32 = -1, resizable: Bool = false, parent: Widget? = nil) {
        window = adw_window_new()!
        gtk_window_set_title(c(window), title)
        gtk_window_set_default_size(c(window), width, height)
        gtk_window_set_resizable(c(window), resizable ? 1 : 0)
        if let parent, let root = rootWindow(parent) { gtk_window_set_transient_for(c(window), root) }
        if let app = App.shared.application { gtk_window_set_application(c(window), c(app)) }
        header = adw_header_bar_new()!
        content = box(.vertical)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(c(toolbar), header)
        adw_toolbar_view_set_content(c(toolbar), content)
        adw_window_set_content(c(window), toolbar)
        let keys = LocalShortcuts(window)
        keys.add("Escape") { [weak self] in self?.close() }
        on(window, "close-request") { [weak self] args in
            self?.onClose?()
            args.returns(false)
        }
        App.shared.retain(self)
        on(window, "destroy") { [weak self] _ in
            guard let self else { return }
            self.owner = nil
            App.shared.release(self)
        }
    }

    func present() { gtk_window_present(c(window)) }
    func close() { gtk_window_close(c(window)) }
}
