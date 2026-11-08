import CGtk
import CHerb
import Foundation
import Glibc

/// One shell in a VTE terminal: the Linux counterpart of the macOS LocalShell, HerbsTerminalView and SessionLegend
/// together. It starts the login shell on the host, follows its title and folder, and adds what macOS Terminal and
/// Ptyxis add on top: a context menu, file drops that type quoted paths, a visual or audible bell, Find, the size
/// badge, and Terminal's Clear and Reset commands.
@MainActor
final class TerminalPane {
    let id = UUID()
    /// The VTE widget.
    let terminal: Widget
    /// What goes into the window: the terminal on its profile's background, with the find bar and size badge.
    let view: Widget
    private let overlay: Widget
    private let padding: Widget
    private let badge: Widget
    private let flashLayer: Widget
    private let findBar: Widget
    private let findEntry: Widget

    var startDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    var profileID: UUID? { didSet { applyProfile() } }
    var settings: ProfileSettings { TerminalProfile.shared.settings(for: profileID) }

    /// The shell's process id on the host, once it has reported it.
    private(set) var shellPid: Int32 = 0
    private var spawnPid: Int32 = 0
    private(set) var started = false
    private(set) var exited = false

    // The title and location the toolbar shows.
    private let initialTitle = ParityScene.isActive ? ParityScene.title : NSUserName() + "@" + Host.hostName
    private var reportedTitle = ""
    private(set) var remoteTarget: String?
    private var remoteLocation: String?
    private(set) var title: String
    private(set) var subtitle = "~"
    let changed = ObjectChange()
    private(set) var columns = 0
    private(set) var rows = 0
    private var hideBadge: UInt32 = 0
    private var lastReport: HostProcesses.Report?

    /// Tells the tab which pane has keyboard focus.
    var onFocus: (() -> Void)?
    /// Called when the shell exits; a split pane closes itself.
    var onExit: (() -> Void)?
    /// Called after the terminal's columns or rows change.
    var onResize: (() -> Void)?
    /// MultiExec: receives what the user types or pastes here, to send on to the other included terminals.
    var broadcast: ((String) -> Void)?
    /// True while the app itself writes to the shell: VTE reports that text through "commit" too, and it must not
    /// be forwarded to the other MultiExec terminals (forwarding it back and forth would never end).
    private var appTyping = false
    /// Text the app types before the shell has started waits here: VTE drops input until the child is attached.
    private var shellReady = false
    private var pendingInput: [String] = []
    /// The workspace part of the right-click menu.
    var extraMenu: ((MenuBuilder) -> Void)?

    init(profileID: UUID? = nil) {
        self.profileID = profileID
        title = initialTitle
        terminal = vte_terminal_new()!
        gtk_widget_set_hexpand(terminal, 1)
        gtk_widget_set_vexpand(terminal, 1)
        vte_terminal_set_mouse_autohide(c(terminal), 1)
        vte_terminal_set_scroll_on_keystroke(c(terminal), 1)
        vte_terminal_set_scroll_on_output(c(terminal), 0)
        vte_terminal_set_allow_hyperlink(c(terminal), 1)
        vte_terminal_set_enable_fallback_scrolling(c(terminal), 1)

        padding = box(.vertical, [terminal], classes: ["terminal-pad"])
        overlay = gtk_overlay_new()!
        gtk_overlay_set_child(c(overlay), padding)

        flashLayer = box(.vertical, classes: ["bell-flash"])
        gtk_widget_set_can_target(flashLayer, 0)
        gtk_overlay_add_overlay(c(overlay), flashLayer)

        badge = label("", classes: ["size-badge"])
        gtk_widget_set_halign(badge, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(badge, 0)
        setVisible(badge, false)
        gtk_overlay_add_overlay(c(overlay), badge)

        findEntry = gtk_search_entry_new()!
        herb_set_string(raw(findEntry), "placeholder-text", "Find in terminal")
        gtk_widget_set_hexpand(findEntry, 1)
        findBar = box(.horizontal, spacing: 4, classes: ["find-bar"])
        gtk_widget_set_halign(findBar, GTK_ALIGN_END)
        gtk_widget_set_valign(findBar, GTK_ALIGN_START)
        gtk_widget_set_size_request(findBar, 340, -1)
        setVisible(findBar, false)
        gtk_overlay_add_overlay(c(overlay), findBar)

        view = overlay
        // The pane owns its widgets: they move between the window, split boxes and the MultiExec grid.
        g_object_ref_sink(raw(overlay))
        configureFind()
        configureEvents()
        applyProfile()
        every(milliseconds: 150) { [weak self] in
            guard let self else { return false }
            self.checkSize()
            return true
        }
    }

    // MARK: Profile

    func applyProfile() {
        let settings = settings
        let description = pango_font_description_from_string(settings.fontDescription)
        vte_terminal_set_font(c(terminal), description)
        pango_font_description_free(description)
        let shape: VteCursorShape = switch settings.cursor {
        case .block: VTE_CURSOR_SHAPE_BLOCK
        case .underline: VTE_CURSOR_SHAPE_UNDERLINE
        case .bar: VTE_CURSOR_SHAPE_IBEAM
        }
        vte_terminal_set_cursor_shape(c(terminal), shape)
        vte_terminal_set_cursor_blink_mode(c(terminal), settings.cursorBlinks ? VTE_CURSOR_BLINK_ON : VTE_CURSOR_BLINK_OFF)
        vte_terminal_set_scrollback_lines(c(terminal), Int(settings.scrollbackLines))
        applyColors()
    }

    /// The profile's color preset over Basic's light and dark defaults, with its background opacity.
    func applyColors() {
        let settings = settings
        let dark = Appearance.isDark
        let theme = ThemeLibrary.shared.theme(named: settings.theme)
        let basic = TerminalTheme.basic(dark: dark)
        func color(_ key: String) -> RGB? { theme?.colors[key] ?? basic[key] }
        let foreground = color("Foreground Color")!
        var background = color("Background Color")!
        background.alpha *= settings.backgroundOpacity
        var fg = gdk(foreground), bg = gdk(background)
        let palette = (theme?.palette ?? TerminalTheme.basicPalette).map(gdk)
        palette.withUnsafeBufferPointer { vte_terminal_set_colors(c(terminal), &fg, &bg, $0.baseAddress, 16) }
        if let cursor = color("Cursor Color") { var value = gdk(cursor); vte_terminal_set_color_cursor(c(terminal), &value) }
        if let cursorText = theme?.colors["Cursor Text Color"] { var value = gdk(cursorText); vte_terminal_set_color_cursor_foreground(c(terminal), &value) }
        else { vte_terminal_set_color_cursor_foreground(c(terminal), nil) }
        if let selection = color("Selection Color") { var value = gdk(selection); vte_terminal_set_color_highlight(c(terminal), &value) }
        if let selected = color("Selected Text Color") { var value = gdk(selected); vte_terminal_set_color_highlight_foreground(c(terminal), &value) }
        Styles.setBackground(padding, background)
    }

    private func gdk(_ color: RGB) -> GdkRGBA {
        GdkRGBA(red: Float(color.red), green: Float(color.green), blue: Float(color.blue), alpha: Float(color.alpha))
    }

    // MARK: Starting the shell

    func start() {
        guard !started else { return }
        started = true
        let scene = ParityScene.isActive
        let shell = scene ? "/bin/sh" : Host.loginShell
        let base: [String: String] = scene ? ParityScene.shellEnvironment
            : ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "HerbsTerminal",
               "SHELL": shell, "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        var environment = base
        var arguments: [String] = []
        var login = !scene
        if scene {
            Host.run(["mkdir", "-p", ParityScene.home], timeout: 5)
            if startDirectory == FileManager.default.homeDirectoryForCurrentUser.path { startDirectory = ParityScene.home }
            // flatpak-spawn doesn't hand PS1 to the host shell, so the scene's shell sets it itself.
            // The Mac's /bin/sh is bash in POSIX mode; Ubuntu's is dash, which treats Clear's Ctrl+L redraw as part
            // of the next command and has no job control for the title's program. Scenes use bash the same way.
            arguments = ["-c", "PS1='\(ParityScene.prompt)'; export PS1; "
                         + "if [ -x /bin/bash ]; then exec /bin/bash --posix --norc --noprofile -i; else exec /bin/sh -i; fi"]
        } else if let integrated = ShellIntegration.launch(shell: shell, environment: base) {
            environment = integrated.environment
            arguments = integrated.arguments
            login = integrated.execName.hasPrefix("-")
        }
        if login { arguments.insert("-l", at: 0) }
        // The shell writes its own process id first, so the app can ask the host about it later.
        let pidFile = SSHControl.directory.appendingPathComponent("pid-\(id.uuidString)").path
        let inner = ["/bin/sh", "-c", "printf %s \"$$\" > \"$1\"; shift; exec \"$@\"", "sh", pidFile, shell] + arguments
        let argv: [String]
        var envv: [String]? = nil
        let directory: String
        if Host.isFlatpak {
            // Job control and the foreground checks need the PTY as the shell's controlling terminal. Some Flatpak
            // versions hand it over already; then taking it again fails ("Operation not permitted") and the shell
            // would end at once. Otherwise setsid --ctty takes it on the host, as Ptyxis's host agent does.
            let claim = ["/bin/sh", "-c", "if (exec </dev/tty) 2>/dev/null || ! command -v setsid >/dev/null 2>&1; then exec \"$@\"; "
                         + "else exec setsid --ctty --wait \"$@\"; fi", "sh"]
            argv = Host.argv(claim + inner, environment: environment, directory: startDirectory)
            directory = "/"
        } else {
            argv = inner
            envv = ProcessInfo.processInfo.environment.merging(environment) { $1 }.map { "\($0.key)=\($0.value)" }
            directory = startDirectory
        }
        spawn(argv, environment: envv, directory: directory)
        readPid(from: pidFile, attempts: 50)
        let command = settings.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { sendQuietly(command + "\n") }
    }

    private func spawn(_ argv: [String], environment: [String]?, directory: String) {
        var args = argv.map { strdup($0) } + [nil]
        var env = environment.map { $0.map { strdup($0) } + [nil] }
        let box = Unmanaged.passRetained(SpawnBox { [weak self] pid, error in
            guard let self else { return }
            if let error {
                self.feed("\r\nHerb's Terminal couldn't start the shell: \(error)\r\n")
            } else {
                self.spawnPid = pid
                self.shellReady = true
                let pending = self.pendingInput
                self.pendingInput = []
                pending.forEach(self.sendQuietly)
            }
        }).toOpaque()
        args.withUnsafeMutableBufferPointer { argPointer in
            if env != nil {
                env!.withUnsafeMutableBufferPointer { envPointer in
                    herb_vte_spawn(c(terminal), directory, argPointer.baseAddress, envPointer.baseAddress, Host.isFlatpak ? 1 : 0, spawnTrampoline, box)
                }
            } else {
                herb_vte_spawn(c(terminal), directory, argPointer.baseAddress, nil, Host.isFlatpak ? 1 : 0, spawnTrampoline, box)
            }
        }
        args.forEach { free($0) }
        env?.forEach { free($0) }
    }

    private func readPid(from file: String, attempts: Int) {
        if let text = try? String(contentsOfFile: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            shellPid = pid
            try? FileManager.default.removeItem(atPath: file)
            refresh()
            return
        }
        guard attempts > 0, !exited else { return }
        after(milliseconds: 100) { [weak self] in self?.readPid(from: file, attempts: attempts - 1) }
    }

    func close() {
        guard started else { return }
        started = false
        if spawnPid > 0 { kill(spawnPid, SIGHUP) }
        if !Host.isFlatpak, shellPid > 0 { kill(shellPid, SIGHUP) }
    }

    // MARK: Typing

    /// Text the app types on its own (the ssh launcher, a startup command, Clear's redraw) is for this tab only.
    func sendQuietly(_ text: String) {
        guard shellReady else { pendingInput.append(text); return }
        appTyping = true
        defer { appTyping = false }
        vte_terminal_feed_child(c(terminal), text, -1)
    }

    /// Feature tests: text arrives as if typed on the keyboard (VTE reports it through "commit", like a key press).
    func typeAsKeyboard(_ text: String) { vte_terminal_feed_child(c(terminal), text, -1) }

    /// Feature tests: what the terminal shows, scrollback included, as plain text.
    var screenText: String {
        // The rows the terminal holds, scrollback included, are the range of its vertical adjustment.
        // A hard reset can leave the adjustment behind the cursor, so the cursor's row bounds the range too.
        let adjustment = gtk_scrollable_get_vadjustment(c(terminal))
        var column = 0, row = 0
        vte_terminal_get_cursor_position(c(terminal), &column, &row)
        let last = max(Int(gtk_adjustment_get_upper(adjustment)), row + 1)
        let first = max(min(Int(gtk_adjustment_get_lower(adjustment)), row), last - 2000)
        guard let text = vte_terminal_get_text_range_format(c(terminal), VTE_FORMAT_TEXT, first, 0, last, 0, nil) else { return "" }
        defer { g_free(text) }
        return String(cString: text)
    }

    /// User input from elsewhere (a drop, a paste): this shell, and the other MultiExec terminals.
    func sendAsUser(_ text: String) {
        sendQuietly(text)
        broadcast?(text)
    }

    /// Output shown in the terminal, as if the program had printed it.
    func feed(_ text: String) {
        vte_terminal_feed(c(terminal), text, -1)
    }

    func focus() { gtk_widget_grab_focus(terminal) }

    // MARK: What the shell is doing

    /// The shell's current folder: as the shell reports it (OSC 7), or as the host sees it.
    var currentDirectory: String? {
        if let uri = vte_terminal_ref_termprop_uri(c(terminal), VTE_TERMPROP_CURRENT_DIRECTORY_URI) {
            defer { g_uri_unref(uri) }
            let text = g_uri_to_string(uri)
            defer { g_free(text) }
            if let url = string(text).flatMap({ URL(string: $0) }), url.isFileURL { return url.path }
        }
        return lastReport?.directory
    }

    /// The program running in the foreground instead of the shell, if any (asked before closing).
    var foregroundProgram: String? {
        guard started, !exited, shellPid > 0, let report = HostProcesses.shared.report(for: shellPid) else { return nil }
        lastReport = report
        guard report.foregroundPid > 0, report.foregroundPid != shellPid else { return nil }
        return report.foregroundName
    }

    /// Whether an interactive ssh is running under the shell.
    func runsSSH() async -> Bool {
        let pid = shellPid
        guard pid > 0 else { return false }
        return await Task.detached { HostProcesses.shared.report(for: pid)?.runsSSH ?? false }.value
    }

    func setRemote(target: String?, location: String? = nil) {
        remoteTarget = target
        remoteLocation = location
        if let target {
            title = target
            subtitle = location ?? "/"
        } else {
            // Titles reported while connected came from the remote shell; when the session ends (exit or a
            // dropped link) the tab is back on this computer and shows its user@host until the local shell names it.
            reportedTitle = ""
            title = initialTitle
            subtitle = "~"
        }
        changed.send()
        refresh()
    }

    /// Updates the title and location from the shell's reports and the program in the foreground.
    func refresh() {
        guard remoteTarget == nil else {
            if let remoteLocation, subtitle != remoteLocation { subtitle = remoteLocation; changed.send() }
            return
        }
        let pid = shellPid
        Task { [weak self] in
            let report = pid > 0 && !(self?.exited ?? true) ? await Task.detached { HostProcesses.shared.report(for: pid) }.value : nil
            guard let self, self.remoteTarget == nil else { return }
            if let report { self.lastReport = report }
            var next = self.reportedTitle.isEmpty ? self.initialTitle : self.reportedTitle
            if self.exited {
                next += " (Exited)"
            } else if let report, report.foregroundPid > 0, report.foregroundPid != pid, let program = report.foregroundName,
                      !["sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh", "dash"].contains(program) {
                next += " — " + redactCredentials(report.foregroundCommand ?? program)
            }
            let path = self.currentDirectory.map(Self.abbreviate)
            var didChange = false
            if self.title != next { self.title = next; didChange = true }
            if let path, self.subtitle != path { self.subtitle = path; didChange = true }
            if didChange { self.changed.send() }
        }
    }

    static func abbreviate(_ path: String) -> String {
        if let scene = ParityScene.displayPath(path) { return scene }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: Size

    private func checkSize() {
        let newColumns = Int(vte_terminal_get_column_count(c(terminal)))
        let newRows = Int(vte_terminal_get_row_count(c(terminal)))
        guard newColumns != columns || newRows != rows, gtk_widget_get_mapped(terminal) != 0 else { return }
        let first = columns == 0
        columns = newColumns
        rows = newRows
        onResize?()
        changed.send()
        guard !first, TerminalProfile.shared.showSizeWhileResizing else { return }
        setLabel(badge, "\(columns) × \(rows)")
        accessibleLabel(badge, "\(columns) columns by \(rows) rows")
        setVisible(badge, true)
        cancelSource(hideBadge)
        hideBadge = after(milliseconds: 1200) { [weak self] in self.map { setVisible($0.badge, false); $0.hideBadge = 0 } }
    }

    /// One character cell in pixels.
    var cellSize: (width: Int, height: Int) {
        (Int(vte_terminal_get_char_width(c(terminal))), Int(vte_terminal_get_char_height(c(terminal))))
    }

    // MARK: Terminal commands

    /// Terminal's Clear to Start: drops the scrollback and the screen. The shell is asked to redraw its prompt only
    /// when it is in the foreground, so full-screen programs aren't sent a stray Ctrl-L.
    func clearToStart() {
        // VTE moves an erased screen into the scrollback, so the screen goes first and the scrollback after it.
        feed("\u{1B}[2J\u{1B}[3J\u{1B}[H")
        if shellIsForeground { sendQuietly("\u{0C}") }
    }

    /// Terminal's Clear Scrollback: keeps the screen, forgets everything above it.
    func clearHistory() { feed("\u{1B}[3J") }

    /// Reset restores modes and colors left behind by a program; Hard Reset also clears the screen.
    func reset(hard: Bool) {
        vte_terminal_reset(c(terminal), 1, hard ? 1 : 0)
        if shellIsForeground { sendQuietly("\u{0C}") }
    }

    private var shellIsForeground: Bool { foregroundProgram == nil }

    func copy() { vte_terminal_copy_clipboard_format(c(terminal), VTE_FORMAT_TEXT) }

    func paste() {
        herb_clipboard_read_text(c(clipboard()), receivedTrampoline, stringBox { [weak self] text in
            guard let self, let text else { return }
            self.appTyping = true
            vte_terminal_paste_text(c(self.terminal), text)
            self.appTyping = false
            self.broadcast?(text)
        })
    }

    /// Pastes with shell metacharacters escaped, so pasted text is taken literally.
    func pasteEscaped() {
        herb_clipboard_read_text(c(clipboard()), receivedTrampoline, stringBox { [weak self] text in
            guard let self, let text else { return }
            self.sendAsUser(shellQuote(text))
        })
    }

    func selectAll() { vte_terminal_select_all(c(terminal)) }

    /// Everything the terminal holds: the scrollback and the screen, without the empty lines below the last output.
    func sessionText() -> String {
        let adjustment = gtk_scrollable_get_vadjustment(c(terminal))
        let first = Int(gtk_adjustment_get_lower(adjustment))
        let last = Int(gtk_adjustment_get_upper(adjustment))
        var length: gsize = 0
        let text = takeString(vte_terminal_get_text_range_format(c(terminal), VTE_FORMAT_TEXT, first, 0, last, Int(vte_terminal_get_column_count(c(terminal))), &length)) ?? ""
        var lines = text.components(separatedBy: "\n")
        while let line = lines.last, line.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Find

    func showFind() {
        setVisible(findBar, true)
        gtk_widget_grab_focus(findEntry)
    }

    private func configureFind() {
        let previous = iconButton("go-up-symbolic", label: "Previous match", hint: "Previous (Shift+Return)\nFind the match above.") { [weak self] in
            if let self { vte_terminal_search_find_previous(c(self.terminal)) }
        }
        let next = iconButton("go-down-symbolic", label: "Next match", hint: "Next (Return)\nFind the match below.") { [weak self] in
            if let self { vte_terminal_search_find_next(c(self.terminal)) }
        }
        let done = iconButton("window-close-symbolic", label: "Close Find", hint: "Done (Esc)\nClose Find and go back to typing.") { [weak self] in
            self?.hideFind()
        }
        append(findBar, findEntry, previous, next, done)
        on(findEntry, "search-changed") { [weak self] _ in self?.search() }
        on(findEntry, "activate") { [weak self] _ in if let self { vte_terminal_search_find_previous(c(self.terminal)) } }
        on(findEntry, "next-match") { [weak self] _ in if let self { vte_terminal_search_find_previous(c(self.terminal)) } }
        on(findEntry, "previous-match") { [weak self] _ in if let self { vte_terminal_search_find_next(c(self.terminal)) } }
        on(findEntry, "stop-search") { [weak self] _ in self?.hideFind() }
        vte_terminal_search_set_wrap_around(c(terminal), 1)
    }

    private func hideFind() {
        setVisible(findBar, false)
        vte_terminal_search_set_regex(c(terminal), nil, 0)
        focus()
    }

    private func search() {
        let text = gtkText(findEntry)
        guard !text.isEmpty else { vte_terminal_search_set_regex(c(terminal), nil, 0); return }
        // A literal, case-insensitive search: PCRE2_CASELESS | PCRE2_MULTILINE, the text quoted with \Q…\E.
        let pattern = "\\Q" + text.replacingOccurrences(of: "\\E", with: "\\E\\\\E\\Q") + "\\E"
        var error: UnsafeMutablePointer<GError>?
        let regex = vte_regex_new_for_search(pattern, -1, 0x0000_0008 | 0x0000_0400, &error)
        if let error { g_error_free(error) }
        guard let regex else { return }
        vte_terminal_search_set_regex(c(terminal), regex, 0)
        vte_regex_unref(regex)
        vte_terminal_search_find_previous(c(terminal))
    }

    private func gtkText(_ editable: Widget) -> String { string(gtk_editable_get_text(c(editable))) ?? "" }

    // MARK: Events

    private func configureEvents() {
        on(terminal, "commit") { [weak self] args in
            guard let self, !self.appTyping, let text = args.string(1) else { return }
            self.broadcast?(text)
        }
        on(terminal, "window-title-changed") { [weak self] _ in
            guard let self else { return }
            self.reportedTitle = string(vte_terminal_get_termprop_string(c(self.terminal), VTE_TERMPROP_XTERM_TITLE, nil)) ?? ""
            self.refresh()
        }
        on(terminal, "current-directory-uri-changed") { [weak self] _ in self?.refresh() }
        on(terminal, "child-exited") { [weak self] _ in
            guard let self else { return }
            self.exited = true
            self.refresh()
            idle { [weak self] in self?.onExit?() }
        }
        on(terminal, "bell") { [weak self] _ in self?.bell() }
        // Taking the keyboard focus (a click, or keyboard pane switching) marks the pane focused.
        let focusController = gtk_event_controller_focus_new()!
        on(focusController, "enter") { [weak self] _ in self?.onFocus?() }
        gtk_widget_add_controller(terminal, focusController)
        onClick(terminal, button: 3) { [weak self] _, x, y in self?.showMenu(x: x, y: y) }

        let shortcuts = LocalShortcuts(terminal, capture: true)
        shortcuts.add("<Control><Shift>c") { [weak self] in self?.copy() }
        shortcuts.add("<Control><Shift>v|<Shift>Insert") { [weak self] in self?.paste() }
        shortcuts.add("<Control><Shift>a") { [weak self] in self?.selectAll() }

        // Like Terminal: dropped files and folders are typed as shell-quoted paths, followed by a space.
        gtk_widget_add_controller(terminal, filesDropTarget { [weak self] paths in
            self?.sendAsUser(paths.map(shellQuote).joined(separator: " ") + " ")
            self?.focus()
        })
    }

    private func showMenu(x: Double, y: Double) {
        onFocus?()
        let menu = MenuBuilder()
        menu.item("Copy", "win.copy")
        menu.item("Paste", "win.paste")
        menu.item("Paste Escaped Text", "win.paste-escaped")
        menu.item("Select All", "win.select-all")
        menu.divider()
        menu.item("Find…", "win.find")
        menu.item("Clear to Start", "win.clear-to-start")
        menu.item("Clear Scrollback", "win.clear-scrollback")
        menu.item("Reset", "win.reset")
        menu.divider()
        extraMenu?(menu)
        popUp(menu.finish(), on: terminal, x: x, y: y)
    }

    // MARK: Bell

    private var lastFlash = Date.distantPast

    private func bell() {
        switch settings.bell {
        case .none: return
        case .audible: gtk_widget_error_bell(terminal)
        case .visual: flash()
        case .both: gtk_widget_error_bell(terminal); flash()
        }
    }

    /// At most two flashes a second (WCAG 2.3.1), and a gentler, slower fade with reduced motion.
    private func flash() {
        guard Date().timeIntervalSince(lastFlash) >= 0.5 else { return }
        lastFlash = Date()
        let slow = !Appearance.animationsEnabled
        gtk_widget_add_css_class(flashLayer, slow ? "flash-on-slow" : "flash-on")
        after(milliseconds: 30) { [weak self] in
            guard let self else { return }
            gtk_widget_remove_css_class(self.flashLayer, "flash-on")
            gtk_widget_remove_css_class(self.flashLayer, "flash-on-slow")
        }
    }
}

final class SpawnBox {
    let done: @MainActor (Int32, String?) -> Void
    init(_ done: @escaping @MainActor (Int32, String?) -> Void) { self.done = done }
}

private let spawnTrampoline: HerbSpawned = { data, pid, error in
    let box = Unmanaged<SpawnBox>.fromOpaque(data!).takeRetainedValue()
    let message = error.map { String(cString: $0) }
    MainActor.assumeIsolated { box.done(pid, message) }
}

// MARK: SSH from a pane

extension TerminalPane {
    /// Starts ssh to `endpoint` from this shell. The login becomes the master of a shared connection that the
    /// explorer and transfers reuse; a saved password goes through AskpassBroker.
    ///
    /// Only the path of a private one-shot launcher is typed. The launcher erases that echoed line, deletes itself
    /// and execs ssh, so tokens and options never show on screen or in the shell history.
    func connectSSH(_ endpoint: RemoteEndpoint, password: String?) {
        start()
        var environment: [String: String] = [:]
        if let password, !password.isEmpty, let broker = AskpassBroker.shared {
            environment = broker.environment(token: broker.issue(password, for: SSHControl.passwordLogins(endpoint)))
            if Host.isFlatpak, let wrapper = try? Self.hostAskpass() { environment["SSH_ASKPASS"] = wrapper }
        }
        let arguments = SSHControl.masterOptions + endpoint.sshArguments()
        do {
            let launcher = try Self.writeLauncher(label: endpoint.label, environment: environment, arguments: arguments)
            // Ctrl-U drops anything half-typed at the prompt; the leading space keeps the line out of history in
            // shells that ignore space-prefixed commands.
            sendQuietly("\u{15} " + shellQuote(launcher.path) + "\n")
        } catch {
            feed("\r\nHerb's Terminal couldn't start ssh: \(error.localizedDescription)\r\n")
        }
    }

    static func writeLauncher(label: String, environment: [String: String], arguments: [String],
                              in directory: URL = SSHControl.directory) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let url = directory.appendingPathComponent("c-" + bytes.map { String(format: "%02x", $0) }.joined())
        let exports = environment.keys.sorted().map { "export \($0)=\(shellQuote(environment[$0]!))" }
        let script = (["#!/bin/sh",
                       "printf '\\033[1A\\r\\033[2K'",
                       "rm -f -- \"$0\""]
                      + exports
                      + ["printf '%s\\n' \(shellQuote("Connecting to \(label)…"))",
                         "exec /usr/bin/ssh " + arguments.map(shellQuote).joined(separator: " ")])
            .joined(separator: "\n") + "\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            throw FileIssue("Can't write the ssh launcher in \(directory.path).")
        }
        return url
    }

    /// ssh on the host can't run the sandboxed executable directly, so its SSH_ASKPASS is this small script: it
    /// asks the app (through `flatpak run`) for the saved password, and asks anything else on the terminal.
    static func hostAskpass(in directory: URL = SSHControl.directory) throws -> String {
        let url = directory.appendingPathComponent("askpass")
        let helper = Host.helperCommand.map(shellQuote).joined(separator: " ")
        let script = """
        #!/bin/sh
        # Herb's Terminal: hands ssh a saved password once; every other question (a new host's fingerprint, a retry,
        # a one-time code) is asked here on the terminal. The app is asked only for passwords, and never asks itself.
        case "$1" in
          *assword*) if answer=$(HERBSTERMINAL_ASK_ON_TERMINAL=no \(helper) "$1" 2>/dev/null </dev/null); then printf '%s\\n' "$answer"; exit 0; fi ;;
        esac
        printf '%s' "$1" > /dev/tty 2>/dev/null || exit 1
        case "$1" in *assword*|*assphrase*|*ode*|*PIN*|*OTP*|*oken*) secret=1 ;; *) secret=0 ;; esac
        [ "$secret" = 1 ] && stty -echo < /dev/tty
        IFS= read -r answer < /dev/tty
        if [ "$secret" = 1 ]; then stty echo < /dev/tty; printf '\\n' > /dev/tty; fi
        printf '%s\\n' "$answer"

        """
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw FileIssue("Can't write the password helper in \(directory.path).")
            }
        }
        return url.path
    }
}
