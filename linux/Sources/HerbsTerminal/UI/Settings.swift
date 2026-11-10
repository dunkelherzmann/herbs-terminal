import CGtk
import CHerb
import Foundation

/// Settings (Ctrl+,): the profiles every terminal tab follows, like Ptyxis or iTerm2 preferences, on five pages:
/// Profiles, Text, Terminal, Window and Colors.
@MainActor
final class SettingsWindow {
    private static var open: SettingsWindow?
    private let window: ToolWindow
    private let profile = TerminalProfile.shared
    private var token: ObservationToken?
    private var themeToken: ObservationToken?
    private var updating = false
    private var reloaders: [() -> Void] = []

    static func show() {
        if let open { open.window.present(); return }
        let settings = SettingsWindow()
        open = settings
        settings.window.owner = settings
        settings.window.present()
    }

    private init() {
        window = ToolWindow(title: "Settings", width: 660, height: 560, parent: Dialogs.anchor(nil))
        let stack = adw_view_stack_new()!
        add(stack, "profiles", "Profiles", "system-users-symbolic", profilesPage())
        add(stack, "text", "Text", "font-select-symbolic", textPage())
        add(stack, "terminal", "Terminal", "ht-terminal-symbolic", terminalPage())
        add(stack, "window", "Window", "window-new-symbolic", windowPage())
        add(stack, "colors", "Colors", "applications-graphics-symbolic", colorsPage())
        let switcher = adw_view_switcher_new()!
        adw_view_switcher_set_stack(c(switcher), c(stack))
        adw_view_switcher_set_policy(c(switcher), ADW_VIEW_SWITCHER_POLICY_WIDE)
        adw_header_bar_set_title_widget(c(window.header), switcher)
        gtk_widget_set_vexpand(stack, 1)
        append(window.content, stack)
        SettingsBridge.show = { title in
            let names = ["Profiles": "profiles", "Text": "text", "Terminal": "terminal", "Window": "window", "Colors": "colors"]
            guard let name = names[title] else { return nil }
            adw_view_stack_set_visible_child_name(c(stack), name)
            return title
        }
        token = profile.objectWillChange.observe { [weak self] in self?.reload() }
        themeToken = ThemeLibrary.shared.objectWillChange.observe { [weak self] in self?.reload() }
        window.onClose = { Self.open = nil; SettingsBridge.clear() }
        reload()
    }

    private func add(_ stack: Widget, _ name: String, _ title: String, _ icon: String, _ page: Widget) {
        let scroll = scrolled(page)
        adw_view_stack_add_titled_with_icon(c(stack), scroll, name, title, icon)
    }

    private func page() -> Widget {
        let widget = box(.vertical, spacing: 12)
        margins(widget, 20)
        return widget
    }

    private func reload() {
        updating = true
        reloaders.forEach { $0() }
        updating = false
    }

    private func row(_ title: String, _ control: Widget, hint text: String? = nil) -> Widget {
        let caption = label(title, xalign: 1)
        gtk_widget_set_size_request(caption, 150, -1)
        let row = box(.horizontal, spacing: 12, [caption, control])
        if let text { hint(control, text) }
        accessibleLabel(control, String(title.trimmingCharacters(in: CharacterSet(charactersIn: ":"))))
        return row
    }

    private func editingHeader() -> Widget {
        let header = label("", classes: ["caption", "dim-label"])
        hint(header, "Editing profile\nChoose another profile on the Profiles tab.")
        reloaders.append { [weak self] in guard let self else { return }; setLabel(header, "Editing profile: \(self.profile.name(of: self.profile.editingID))") }
        return header
    }

    private func edit(_ change: (inout ProfileSettings) -> Void) {
        guard !updating else { return }
        profile.update(profile.editingID, change)
    }

    // MARK: Profiles

    private func profilesPage() -> Widget {
        let page = page()
        let list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(c(list), GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(list, "boxed-list")
        hint(list, "Profiles\nSelect a profile to edit it here and on the Text, Terminal and Colors tabs.")
        let listScroll = scrolled(list)
        gtk_widget_set_size_request(listScroll, 180, 230)
        gtk_widget_set_vexpand(listScroll, 0)
        let addButton = iconButton("list-add-symbolic", label: "New Profile", hint: "New Profile\nAdd a profile with the stock Basic settings.") { [weak self] in
            guard let self else { return }
            self.profile.editingID = self.profile.addProfile(named: "New Profile")
        }
        let duplicate = iconButton("edit-copy-symbolic", label: "Duplicate", hint: "Duplicate\nCopy the selected profile.") { [weak self] in
            guard let self else { return }
            self.profile.editingID = self.profile.addProfile(named: self.profile.name(of: self.profile.editingID) + " copy", copying: self.profile.editingID)
        }
        let remove = iconButton("list-remove-symbolic", label: "Delete Profile", hint: "Delete Profile\nRemove the selected profile; tabs using it switch to the default.") { [weak self] in
            guard let self else { return }
            self.profile.removeProfile(self.profile.editingID)
        }
        let left = box(.vertical, spacing: 6, [listScroll, box(.horizontal, spacing: 4, [addButton, duplicate, remove])])

        let name = entry()
        let command = entry(placeholder: "none")
        let start = entry(placeholder: "Settings ▸ Terminal ▸ New tabs open in")
        let useDefault = button("Use as Default", hint: "Use as Default\nNew windows, and new tabs from the New Tab button, start with this profile.") { [weak self] in
            guard let self else { return }
            self.profile.defaultProfileID = self.profile.editingID
        }
        on(name, "changed") { [weak self] _ in
            guard let self, !self.updating else { return }
            self.profile.rename(self.profile.editingID, to: text(of: name))
        }
        on(command, "changed") { [weak self] _ in self?.edit { $0.startupCommand = text(of: command) } }
        on(start, "changed") { [weak self] _ in self?.edit { $0.startDirectory = text(of: start) } }
        let form = box(.vertical, spacing: 10, [
            row("Name:", name, hint: "Name\nHow this profile appears in Shell ▸ New Tab with Profile."),
            row("Run command:", command, hint: "Startup command\nTyped into the shell when a tab with this profile opens, e.g. `ssh build-box` or `cd ~/src`."),
            row("Start in:", start, hint: "Start folder\nWhere new tabs with this profile start, e.g. ~/Projects. Empty uses the New tabs setting."),
            useDefault,
        ])
        gtk_widget_set_hexpand(form, 1)
        [name, command, start].forEach { gtk_widget_set_hexpand($0, 1) }
        append(page, box(.horizontal, spacing: 16, [left, form]))
        SettingsBridge.register("Profiles", "Profiles", .list(list) { [weak self] in self?.profile.profiles.map(\.name) ?? [] })
        SettingsBridge.register("Profiles", "New Profile", .button(addButton))
        SettingsBridge.register("Profiles", "Duplicate", .button(duplicate))
        SettingsBridge.register("Profiles", "Delete Profile", .button(remove))
        SettingsBridge.register("Profiles", "Name", .entry(name))
        SettingsBridge.register("Profiles", "Run command", .entry(command))
        SettingsBridge.register("Profiles", "Start in", .entry(start))
        SettingsBridge.register("Profiles", "Use as Default", .button(useDefault))

        var ids: [UUID] = []
        on(list, "row-selected") { [weak self] args in
            guard let self, !self.updating, let row = args.pointer(1) else { return }
            let index = Int(gtk_list_box_row_get_index(c(row)))
            if ids.indices.contains(index), self.profile.editingID != ids[index] { self.profile.editingID = ids[index] }
        }
        reloaders.append { [weak self] in
            guard let self else { return }
            gtk_list_box_remove_all(c(list))
            ids = self.profile.profiles.map(\.id)
            for (index, item) in self.profile.profiles.enumerated() {
                let row = box(.horizontal, spacing: 8, [label(item.name)])
                if item.id == self.profile.defaultProfileID { append(row, label("Default", classes: ["caption", "dim-label"])) }
                margins(row, top: 6, bottom: 6, start: 10, end: 10)
                gtk_list_box_append(c(list), row)
                if item.id == self.profile.editingID, let listRow = gtk_list_box_get_row_at_index(c(list), Int32(index)) {
                    gtk_list_box_select_row(c(list), listRow)
                }
            }
            enable(remove, self.profile.profiles.count > 1)
            enable(useDefault, self.profile.defaultProfileID != self.profile.editingID)
            let settings = self.profile.editing
            if gtk_widget_has_focus(name) == 0, text(of: name) != self.profile.name(of: self.profile.editingID) { setText(name, self.profile.name(of: self.profile.editingID)) }
            if text(of: command) != settings.startupCommand { setText(command, settings.startupCommand) }
            if text(of: start) != settings.startDirectory { setText(start, settings.startDirectory) }
        }
        return page
    }

    // MARK: Text

    static let monospacedFamilies: [String] = {
        guard let map = pango_cairo_font_map_get_default() else { return [] }
        var families: UnsafeMutablePointer<UnsafeMutablePointer<PangoFontFamily>?>?
        var count: Int32 = 0
        pango_font_map_list_families(map, &families, &count)
        defer { g_free(families) }
        var names: [String] = []
        for index in 0..<Int(count) {
            guard let family = families?[index], pango_font_family_is_monospace(family) != 0,
                  let name = string(pango_font_family_get_name(family)) else { continue }
            names.append(name)
        }
        return Set(names).sorted()
    }()

    private func textPage() -> Widget {
        let page = page()
        let families = Self.monospacedFamilies.filter { $0 != ProfileSettings.stockFamily }
        let font = dropDown(["\(ProfileSettings.stockFamily) (Basic)"] + families, selected: 0) { [weak self] index in
            self?.edit { $0.fontFamily = index == 0 ? "" : families[index - 1] }
        }
        let size = spin(value: 11, range: ProfileSettings.sizeRange, step: 1, digits: 1) { [weak self] value in self?.edit { $0.fontSize = value } }
        let zoomLabel = label("", classes: ["dim-label"])
        let zoomReset = button("Reset", hint: "Reset zoom\nClear the Ctrl+Plus / Ctrl+Minus zoom kept for this profile (same as Ctrl+0).") { [weak self] in
            guard let self else { return }
            self.profile.update(self.profile.editingID) { $0.zoom = 0 }
        }
        let sizeRow = box(.horizontal, spacing: 8, [size, label("pt", classes: ["dim-label"]), zoomLabel, zoomReset])
        var cursorButtons: [Widget] = []
        let cursorRow = box(.horizontal, classes: ["linked"])
        for shape in CursorShape.allCases {
            let toggle = gtk_toggle_button_new_with_label(shape.title)!
            if let first = cursorButtons.first { gtk_toggle_button_set_group(c(toggle), c(first)) }
            on(toggle, "toggled") { [weak self] _ in
                if gtk_toggle_button_get_active(c(toggle)) != 0 { self?.edit { $0.cursor = shape } }
            }
            cursorButtons.append(toggle)
            append(cursorRow, toggle)
        }
        let opacity = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0.2, 1, 0.01)!
        gtk_scale_set_draw_value(c(opacity), 0)
        gtk_widget_set_hexpand(opacity, 1)
        let opacityLabel = label("", classes: ["dim-label"])
        gtk_widget_set_size_request(opacityLabel, 44, -1)
        on(opacity, "value-changed") { [weak self] _ in
            let value = gtk_range_get_value(c(opacity))
            setLabel(opacityLabel, "\(Int((value * 100).rounded()))%")
            self?.edit { $0.backgroundOpacity = value }
        }
        let blink = check("Blinking cursor", hint: "Blinking cursor\nBlink the cursor while the terminal has focus.") { [weak self] on in self?.edit { $0.cursorBlinks = on } }
        let preview = label("user@host ~ % ls -la\nThe quick brown fox — 0O 1lI {}[]")
        margins(preview, 10)
        hint(preview, "Preview\nHow terminal text looks with this font and color theme.")
        let restore = button("Restore Defaults", hint: "Restore Defaults\nGo back to the stock Basic font, size and cursor.") { [weak self] in self?.profile.resetText() }
        append(page, editingHeader(),
               row("Font:", font, hint: "Font\nThe monospaced typeface used by every terminal tab."),
               row("Size:", sizeRow, hint: "Font size\nPoints, \(Int(ProfileSettings.sizeRange.lowerBound))–\(Int(ProfileSettings.sizeRange.upperBound)). Ctrl+Plus / Ctrl+Minus / Ctrl+0 zoom."),
               row("Cursor:", cursorRow, hint: "Cursor shape\nHow the text cursor is drawn in the terminal."),
               row("Background opacity:", box(.horizontal, spacing: 8, [opacity, opacityLabel]), hint: "Background opacity\nMake the terminal background see-through."),
               blink, preview, restore)
        var previewStyle = ""
        SettingsBridge.register("Text", "Font", .dropDown(font, ["\(ProfileSettings.stockFamily) (Basic)"] + families))
        SettingsBridge.register("Text", "Size", .spin(size))
        SettingsBridge.register("Text", "Cursor", .toggles(cursorButtons, CursorShape.allCases.map(\.title)))
        SettingsBridge.register("Text", "Background opacity", .scale(opacity, 0.2...1))
        SettingsBridge.register("Text", "Blinking cursor", .check(blink))
        SettingsBridge.register("Text", "Preview", .display { previewStyle })
        SettingsBridge.register("Text", "Restore Defaults", .button(restore))
        reloaders.append { [weak self] in
            guard let self else { return }
            let settings = self.profile.editing
            gtk_drop_down_set_selected(c(font), UInt32(settings.fontFamily.isEmpty ? 0 : (families.firstIndex(of: settings.fontFamily).map { $0 + 1 } ?? 0)))
            gtk_spin_button_set_value(c(size), settings.fontSize)
            setLabel(zoomLabel, settings.zoom == 0 ? "" : "zoomed \(settings.zoom > 0 ? "+" : "")\(Int(settings.zoom)) pt")
            setVisible(zoomReset, settings.zoom != 0)
            for (index, shape) in CursorShape.allCases.enumerated() where shape == settings.cursor {
                gtk_toggle_button_set_active(c(cursorButtons[index]), 1)
            }
            gtk_range_set_value(c(opacity), settings.backgroundOpacity)
            setLabel(opacityLabel, "\(Int((settings.backgroundOpacity * 100).rounded()))%")
            setActive(blink, settings.cursorBlinks)
            let theme = ThemeLibrary.shared.theme(named: settings.theme)
            let colors = theme?.colors ?? TerminalTheme.basic(dark: true)
            let style = "font-family: \"\(settings.family)\"; font-size: \(settings.fontSize)px; color: \((colors["Foreground Color"] ?? RGB(hex: 0xFFFFFF)).css); "
                + "background-color: \((colors["Background Color"] ?? RGB(hex: 0)).css); border-radius: 6px;"
            Styles.setStyle(preview, style)
            previewStyle = style
        }
        return page
    }

    // MARK: Terminal

    private func terminalPage() -> Widget {
        let page = page()
        let scrollback = spin(value: 10_000, range: 100...1_000_000, step: 100) { [weak self] value in self?.edit { $0.scrollbackLines = Int(value) } }
        let bell = dropDown(TerminalBell.allCases.map(\.title), selected: 0) { [weak self] index in self?.edit { $0.bell = TerminalBell.allCases[index] } }
        let newTabs = dropDown(["Same folder as the current tab", "Home folder"], selected: 0) { [weak self] index in
            guard let self, !self.updating else { return }
            self.profile.newTabsInSameFolder = index == 0
        }
        let restore = check("Restore windows and tabs when Herb's Terminal opens",
                            hint: "Restore session\nReopen your windows and tabs, with their folders, layouts and names, at launch.") { [weak self] on in
            guard let self, !self.updating else { return }
            self.profile.restoreSession = on
        }
        let ask = check("Ask before closing a tab with running processes",
                        hint: "Ask before closing\nConfirm before ending a program or SSH session by closing its tab.") { [weak self] on in
            guard let self, !self.updating else { return }
            self.profile.askBeforeClosing = on
        }
        append(page, editingHeader(),
               row("Scrollback:", box(.horizontal, spacing: 8, [scrollback, label("lines", classes: ["dim-label"])]),
                   hint: "Scrollback\nHow many lines each tab keeps above the screen (100–1,000,000)."),
               row("Bell:", bell, hint: "Bell\nWhat happens when a program rings the terminal bell."),
               row("New tabs open in:", newTabs, hint: "New tabs\nWhere a new local tab's shell starts."),
               restore, ask)
        SettingsBridge.register("Terminal", "Scrollback", .spin(scrollback))
        SettingsBridge.register("Terminal", "Bell", .dropDown(bell, TerminalBell.allCases.map(\.title)))
        SettingsBridge.register("Terminal", "New tabs open in", .dropDown(newTabs, ["Same folder as the current tab", "Home folder"]))
        SettingsBridge.register("Terminal", "Restore windows and tabs when Herb's Terminal opens", .check(restore))
        SettingsBridge.register("Terminal", "Ask before closing a tab with running processes", .check(ask))
        reloaders.append { [weak self] in
            guard let self else { return }
            let settings = self.profile.editing
            gtk_spin_button_set_value(c(scrollback), Double(settings.scrollbackLines))
            gtk_drop_down_set_selected(c(bell), UInt32(TerminalBell.allCases.firstIndex(of: settings.bell) ?? 0))
            gtk_drop_down_set_selected(c(newTabs), self.profile.newTabsInSameFolder ? 0 : 1)
            setActive(restore, self.profile.restoreSession)
            setActive(ask, self.profile.askBeforeClosing)
        }
        return page
    }

    // MARK: Window

    private func windowPage() -> Widget {
        let page = page()
        let badge = check("Show columns × rows while resizing",
                          hint: "Size while resizing\nShow the terminal's size, like 100 × 30, while you resize the window.") { [weak self] on in
            guard let self, !self.updating else { return }
            self.profile.showSizeWhileResizing = on
        }
        let range = TerminalProfile.gridRange
        let columns = spin(value: 120, range: Double(range.columns.lowerBound)...Double(range.columns.upperBound)) { [weak self] value in
            guard let self, !self.updating else { return }
            self.profile.windowColumns = Int(value)
        }
        let rows = spin(value: 32, range: Double(range.rows.lowerBound)...Double(range.rows.upperBound)) { [weak self] value in
            guard let self, !self.updating else { return }
            self.profile.windowRows = Int(value)
        }
        let apply = button("Apply to Open Windows", hint: "Apply to Open Windows\nResize every open terminal window to this many columns and rows now.") { [weak self] in
            guard let self else { return }
            Workspace.all.forEach { $0.resize(columns: self.profile.windowColumns, rows: self.profile.windowRows) }
        }
        let front = button("Use Front Window's Size", hint: "Use Front Window's Size\nCopy the columns and rows of the most recently used terminal window.") { [weak self] in
            guard let self, let workspace = Workspace.all.last else { return }
            let pane = workspace.selected.focused
            guard pane.columns > 0, pane.rows > 0 else { return }
            self.profile.windowColumns = pane.columns
            self.profile.windowRows = pane.rows
        }
        let reset = button("Reset", hint: "Reset\nGo back to \(TerminalProfile.defaultGrid.columns) × \(TerminalProfile.defaultGrid.rows).") { [weak self] in
            self?.profile.windowColumns = TerminalProfile.defaultGrid.columns
            self?.profile.windowRows = TerminalProfile.defaultGrid.rows
        }
        append(page, badge,
               row("Columns:", columns, hint: "Columns\nCharacters per line in new windows: the first number the size badge shows."),
               row("Rows:", rows, hint: "Rows\nLines of text in new windows: the second number the size badge shows."),
               box(.horizontal, spacing: 8, [apply, front, reset]))
        SettingsBridge.register("Window", "Show columns × rows while resizing", .check(badge))
        SettingsBridge.register("Window", "Columns", .spin(columns))
        SettingsBridge.register("Window", "Rows", .spin(rows))
        SettingsBridge.register("Window", "Apply to Open Windows", .button(apply))
        SettingsBridge.register("Window", "Use Front Window's Size", .button(front))
        SettingsBridge.register("Window", "Reset", .button(reset))
        reloaders.append { [weak self] in
            guard let self else { return }
            setActive(badge, self.profile.showSizeWhileResizing)
            gtk_spin_button_set_value(c(columns), Double(self.profile.windowColumns))
            gtk_spin_button_set_value(c(rows), Double(self.profile.windowRows))
        }
        return page
    }

    // MARK: Colors

    private func colorsPage() -> Widget {
        let page = page()
        var schemeButtons: [Widget] = []
        let schemes = box(.horizontal, classes: ["linked"])
        for scheme in ["System", "Light", "Dark"] {
            let toggle = gtk_toggle_button_new_with_label(scheme)!
            if let first = schemeButtons.first { gtk_toggle_button_set_group(c(toggle), c(first)) }
            on(toggle, "toggled") { [weak self] _ in
                guard let self, !self.updating, gtk_toggle_button_get_active(c(toggle)) != 0 else { return }
                self.profile.appearance = scheme
            }
            schemeButtons.append(toggle)
            append(schemes, toggle)
        }
        let list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(c(list), GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(list, "boxed-list")
        hint(list, "Color theme\nClick a theme to use it in this profile; every tab with the profile follows.")
        let listScroll = scrolled(list)
        gtk_widget_set_size_request(listScroll, -1, 260)
        gtk_widget_set_vexpand(listScroll, 0)
        let importButton = button("Import iTerm2 Preset…", hint: "Import iTerm2 Preset\nAdd colors from an .itermcolors file.") { [weak self] in
            guard let self else { return }
            Task { if let name = await ThemeImport.run(self.window.window) { self.edit { $0.theme = name } } }
        }
        let remove = button("Remove", hint: "Remove\nDelete the selected imported preset. Built-in themes cannot be removed.") { [weak self] in
            guard let self else { return }
            ThemeLibrary.shared.removeImported(self.profile.editing.theme)
            self.edit { $0.theme = "" }
        }
        append(page, editingHeader(), row("Appearance:", schemes, hint: "Appearance\nLight or dark window chrome; System follows the desktop."),
               listScroll, box(.horizontal, spacing: 8, [importButton, remove]))
        var names: [String] = []
        SettingsBridge.register("Colors", "Appearance", .toggles(schemeButtons, ["System", "Light", "Dark"]))
        SettingsBridge.register("Colors", "Color theme", .list(list) { names.map { $0.isEmpty ? "macOS Terminal Basic" : $0 } })
        SettingsBridge.register("Colors", "Import iTerm2 Preset…", .button(importButton))
        SettingsBridge.register("Colors", "Remove", .button(remove))
        on(list, "row-selected") { [weak self] args in
            guard let self, !self.updating, let row = args.pointer(1) else { return }
            let index = Int(gtk_list_box_row_get_index(c(row)))
            if names.indices.contains(index) { self.edit { $0.theme = names[index] } }
        }
        onClick(list, button: 3) { [weak self] _, x, y in
            guard let self, let row = gtk_list_box_get_row_at_y(c(list), Int32(y)) else { return }
            let index = Int(gtk_list_box_row_get_index(row))
            guard names.indices.contains(index), ThemeLibrary.shared.isImported(names[index]) else { return }
            let name = names[index]
            let popover = gtk_popover_new()!
            gtk_popover_set_child(c(popover), button("Remove Imported Preset", classes: ["flat"]) {
                gtk_popover_popdown(c(popover))
                ThemeLibrary.shared.removeImported(name)
                if self.profile.editing.theme == name { self.edit { $0.theme = "" } }
            })
            gtk_widget_set_parent(popover, list)
            var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
            gtk_popover_set_pointing_to(c(popover), &rect)
            on(popover, "closed") { _ in idle { gtk_widget_unparent(popover) } }
            gtk_popover_popup(c(popover))
        }
        reloaders.append { [weak self] in
            guard let self else { return }
            for (index, scheme) in ["System", "Light", "Dark"].enumerated() where scheme == self.profile.appearance {
                gtk_toggle_button_set_active(c(schemeButtons[index]), 1)
            }
            gtk_list_box_remove_all(c(list))
            names = [""] + ThemeLibrary.shared.allNames
            let current = self.profile.editing.theme
            for (index, name) in names.enumerated() {
                let theme = ThemeLibrary.shared.theme(named: name)
                let colors = theme?.colors ?? TerminalTheme.basic(dark: true)
                let swatch = label("Aa", classes: ["theme-swatch"], xalign: 0.5)
                Styles.setStyle(swatch, "color: \((colors["Foreground Color"] ?? RGB(hex: 0xFFFFFF)).css); background-color: \((colors["Background Color"] ?? RGB(hex: 0)).css);")
                let dots = box(.horizontal, spacing: 2)
                let palette = theme?.palette ?? TerminalTheme.basicPalette
                for color in palette.prefix(8) {
                    let dot = box(.horizontal)
                    gtk_widget_set_size_request(dot, 9, 9)
                    gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
                    Styles.setStyle(dot, "background-color: \(color.css); border-radius: 5px; min-width: 9px; min-height: 9px;")
                    append(dots, dot)
                }
                let row = box(.horizontal, spacing: 10, [swatch, dots, label(name.isEmpty ? "macOS Terminal Basic" : name)])
                if theme != nil, !ThemeLibrary.shared.isImported(name) { append(row, label("Built-in", classes: ["caption", "dim-label"])) }
                margins(row, top: 6, bottom: 6, start: 10, end: 10)
                gtk_list_box_append(c(list), row)
                if name == current, let listRow = gtk_list_box_get_row_at_index(c(list), Int32(index)) { gtk_list_box_select_row(c(list), listRow) }
            }
            enable(remove, ThemeLibrary.shared.isImported(current))
        }
        return page
    }
}
