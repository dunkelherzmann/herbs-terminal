import CGtk
import CHerb
import Foundation

/// A plain-text editor shown as a tab in the terminal window: monospaced, with undo, Find, line wrapping and a
/// status line. Ctrl+S saves; closing the tab with unsaved changes asks first.
@MainActor
final class TextEditor {
    let source: TextFileSource
    let view: Widget
    private(set) var isEdited = false
    var onFailure: (() -> Void)?
    var onChange: (() -> Void)?
    weak var windowOwner: AnyObject?
    var window: Widget?

    private let textView: Widget
    private let buffer: OpaquePointer
    private let status: Widget
    private let wrap: Widget
    private let saveButton: Widget
    private let findBar: Widget
    private let findEntry: Widget
    private let search: OpaquePointer
    private var encoding: String.Encoding = .utf8
    private var loadedVersion: TextFileSource.Version?
    private var loaded = false

    init(source: TextFileSource) {
        self.source = source
        textView = gtk_source_view_new()!
        buffer = c(gtk_text_view_get_buffer(c(textView)))
        gtk_text_view_set_monospace(c(textView), 1)
        gtk_text_view_set_editable(c(textView), 0)
        gtk_text_view_set_left_margin(c(textView), 6)
        gtk_text_view_set_top_margin(c(textView), 6)
        gtk_text_view_set_right_margin(c(textView), 6)
        let settings = TerminalProfile.shared.defaultProfile.settings
        Styles.setFont(textView, family: settings.family, points: max(12, settings.effectiveSize))
        let scroll = scrolled(textView, horizontal: true)

        status = label("Loading…", classes: ["editor-status"], ellipsize: PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(status, 1)
        let wraps = Preferences.shared.bool("editorWrapsLines") ?? true
        wrap = check("Wrap Lines", active: wraps, hint: "Wrap Lines\nWrap long lines at the edge instead of scrolling sideways.")
        saveButton = gtk_button_new_with_label("Save")!
        hint(saveButton, "Save (Ctrl+S)\nWrite your changes to the file.")
        enable(saveButton, false)
        let bar = box(.horizontal, spacing: 10, [status, wrap, saveButton], classes: ["editor-bar"])

        findEntry = gtk_search_entry_new()!
        herb_set_string(raw(findEntry), "placeholder-text", "Find")
        gtk_widget_set_hexpand(findEntry, 1)
        findBar = box(.horizontal, spacing: 4, classes: ["find-bar"])
        gtk_widget_set_halign(findBar, GTK_ALIGN_END)
        gtk_widget_set_valign(findBar, GTK_ALIGN_START)
        gtk_widget_set_size_request(findBar, 340, -1)
        setVisible(findBar, false)
        search = gtk_source_search_context_new(c(buffer), nil)
        gtk_source_search_settings_set_wrap_around(gtk_source_search_context_get_settings(search), 1)

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(c(overlay), scroll)
        gtk_overlay_add_overlay(c(overlay), findBar)
        gtk_widget_set_vexpand(overlay, 1)
        view = box(.vertical, [overlay, separator(), bar])
        g_object_ref_sink(raw(view))
        applyWrap(wraps)
        configure()
    }

    private func configure() {
        on(wrap, "toggled") { [weak self] _ in
            guard let self else { return }
            Preferences.shared.set(isActive(self.wrap), "editorWrapsLines")
            self.applyWrap(isActive(self.wrap))
        }
        on(saveButton, "clicked") { [weak self] _ in self?.save() }
        on(buffer, "changed") { [weak self] _ in
            guard let self, self.loaded else { return }
            self.setEdited(true)
            self.updateStatus()
        }
        on(buffer, "notify::cursor-position") { [weak self] _ in if self?.loaded == true { self?.updateStatus() } }
        let keys = LocalShortcuts(view)
        keys.add("<Control>s") { [weak self] in self?.save() }
        keys.add("<Control>f") { [weak self] in self?.find() }
        let previous = iconButton("go-up-symbolic", label: "Previous match", hint: "Previous (Shift+Return)\nFind the match above.") { [weak self] in self?.step(forward: false) }
        let next = iconButton("go-down-symbolic", label: "Next match", hint: "Next (Return)\nFind the match below.") { [weak self] in self?.step(forward: true) }
        let done = iconButton("window-close-symbolic", label: "Close Find", hint: "Done (Esc)\nClose Find and go back to editing.") { [weak self] in self?.closeFind() }
        append(findBar, findEntry, previous, next, done)
        on(findEntry, "search-changed") { [weak self] _ in
            guard let self else { return }
            gtk_source_search_settings_set_search_text(gtk_source_search_context_get_settings(self.search), text(of: self.findEntry))
            self.step(forward: true)
        }
        on(findEntry, "activate") { [weak self] _ in self?.step(forward: true) }
        on(findEntry, "next-match") { [weak self] _ in self?.step(forward: true) }
        on(findEntry, "previous-match") { [weak self] _ in self?.step(forward: false) }
        on(findEntry, "stop-search") { [weak self] _ in self?.closeFind() }
    }

    private func applyWrap(_ wraps: Bool) {
        gtk_text_view_set_wrap_mode(c(textView), wraps ? GTK_WRAP_WORD_CHAR : GTK_WRAP_NONE)
    }

    func load() async {
        do {
            let data = try await source.read()
            guard data.count <= TextCodec.sizeLimit else {
                throw FileIssue("“\(source.name)” is larger than \(TextCodec.sizeLimit / 1_048_576) MB, too big to edit here.")
            }
            guard let decoded = TextCodec.decode(data) else {
                throw FileIssue("“\(source.name)” doesn't look like a text file, so it wasn't opened for editing.")
            }
            loadedVersion = try? await source.version()
            encoding = decoded.encoding
            gtk_text_buffer_begin_irreversible_action(c(buffer))
            gtk_text_buffer_set_text(c(buffer), decoded.text, -1)
            gtk_text_buffer_end_irreversible_action(c(buffer))
            var start = GtkTextIter()
            gtk_text_buffer_get_start_iter(c(buffer), &start)
            gtk_text_buffer_place_cursor(c(buffer), &start)
            gtk_text_view_set_editable(c(textView), 1)
            loaded = true
            setEdited(false)
            focus()
            updateStatus()
        } catch {
            setLabel(status, error.localizedDescription)
            await Dialogs.show(window, error, heading: "The file couldn't be opened")
            onFailure?()
        }
    }

    func focus() { idle { [weak self] in self.map { gtk_widget_grab_focus($0.textView) } } }

    func find() {
        setVisible(findBar, true)
        gtk_widget_grab_focus(findEntry)
    }

    private func closeFind() {
        setVisible(findBar, false)
        gtk_source_search_settings_set_search_text(gtk_source_search_context_get_settings(search), nil)
        gtk_widget_grab_focus(textView)
    }

    private func step(forward: Bool) {
        var insert = GtkTextIter(), start = GtkTextIter(), end = GtkTextIter()
        var selectionStart = GtkTextIter(), selectionEnd = GtkTextIter()
        gtk_text_buffer_get_selection_bounds(c(buffer), &selectionStart, &selectionEnd)
        insert = forward ? selectionEnd : selectionStart
        var wrapped: gboolean = 0
        let found = forward
            ? gtk_source_search_context_forward(search, &insert, &start, &end, &wrapped)
            : gtk_source_search_context_backward(search, &insert, &start, &end, &wrapped)
        guard found != 0 else { return }
        gtk_text_buffer_select_range(c(buffer), &start, &end)
        gtk_text_view_scroll_to_iter(c(textView), &start, 0.1, 0, 0, 0)
    }

    private var currentText: String {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(c(buffer), &start, &end)
        return takeString(gtk_text_buffer_get_text(c(buffer), &start, &end, 1)) ?? ""
    }

    /// Saves, after checking that nobody changed the file since it was opened or last saved.
    func save() { Task { _ = await saveNow() } }

    func saveNow() async -> Bool {
        guard loaded else { return false }
        guard let data = currentText.data(using: encoding) else {
            await Dialogs.tell(window, "The file couldn't be saved",
                               "Some characters can't be saved in \(TextCodec.name(of: encoding)). Remove them, or save a copy in UTF-8.")
            return false
        }
        if let current = try? await source.version(), let loadedVersion, current != loadedVersion {
            let answer = await Dialogs.ask(window, "“\(source.name)” changed since you opened it.", "Saving replaces those changes with yours.",
                                           choices: [.init("cancel", "Cancel"), .init("save", "Save Anyway", .destructive)], cancel: "cancel")
            guard answer == "save" else { return false }
        }
        do {
            try await source.write(data)
            loadedVersion = try? await source.version()
            setEdited(false)
            updateStatus()
            return true
        } catch {
            await Dialogs.show(window, error, heading: "The file couldn't be saved")
            return false
        }
    }

    /// Before the tab closes: true when it may close (saved, nothing to save, or changes discarded).
    func confirmClose() async -> Bool {
        guard isEdited else { return true }
        let answer = await Dialogs.ask(window, "Do you want to save the changes to “\(source.name)”?", "Your changes will be lost if you don't save them.",
                                       choices: [.init("discard", "Don't Save", .destructive), .init("cancel", "Cancel"), .init("save", "Save", .suggested)],
                                       defaultID: "save", cancel: "cancel")
        switch answer {
        case "save": return await saveNow()
        case "discard": return true
        default: return false
        }
    }

    private func setEdited(_ edited: Bool) {
        enable(saveButton, edited)
        guard isEdited != edited else { return }
        isEdited = edited
        onChange?()
    }

    private func updateStatus() {
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(c(buffer), &cursor, gtk_text_buffer_get_insert(c(buffer)))
        let line = Int(gtk_text_iter_get_line(&cursor)) + 1
        let column = Int(gtk_text_iter_get_line_offset(&cursor)) + 1
        let lines = Int(gtk_text_buffer_get_line_count(c(buffer)))
        let endings = currentText.contains("\r\n") ? "CRLF" : "LF"
        setLabel(status, "Line \(line), Column \(column) · \(lines) line\(lines == 1 ? "" : "s") · \(TextCodec.name(of: encoding)) · \(endings)")
    }
}
