import CGtk
import CHerb
import Foundation

/// A tab's explorer: the banners for a connection in progress or Administrator mode, then the explorer for where the
/// tab is: this computer, its SSH host, or a root session on either.
@MainActor
final class ExplorerHost {
    let view: Widget
    private weak var tab: TerminalTab?
    private weak var workspace: Workspace?
    private let banners: Widget
    private let body: Widget
    private var local: ExplorerView?
    private var remote: ExplorerView?
    private var admin: ExplorerView?
    private var current: ExplorerView?

    init(tab: TerminalTab, workspace: Workspace) {
        self.tab = tab
        self.workspace = workspace
        banners = box(.vertical)
        body = box(.vertical)
        gtk_widget_set_vexpand(body, 1)
        view = box(.vertical, [banners, body])
        g_object_ref_sink(raw(view))
        rebuild()
    }

    /// Shows the explorer that matches the tab's connection and Administrator mode.
    func rebuild() {
        guard let tab, let workspace else { return }
        let state = tab.state
        removeChildren(banners)
        switch state.connection {
        case .connecting(let endpoint):
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(c(spinner))
            let banner = box(.horizontal, spacing: 8, [spinner, label("Connecting to \(endpoint.label)… Showing local files until the login succeeds.")],
                             classes: ["banner-warn"])
            hint(banner, "Connecting\nAnswer any password or host-key prompt in the terminal.")
            append(banners, banner)
        case .failed(let message):
            let dismiss = button("Dismiss", classes: ["flat"], hint: "Dismiss\nHide this message.") { [weak self, weak tab] in
                tab?.state.connection = .local
                self?.rebuild()
            }
            append(banners, box(.horizontal, spacing: 8, [image("dialog-warning-symbolic", classes: ["warning"]), label(message, wrap: true), spacer(), dismiss],
                                classes: ["banner-warn"]))
        default:
            break
        }
        let next: ExplorerView
        if let adminModel = state.adminModel {
            let leave = button("Leave", classes: ["flat"], hint: "Leave Administrator Mode\nGo back to working with your own account's access.") { [weak self] in
                self.map { AdministratorMode.leave($0) }
            }
            append(banners, box(.horizontal, spacing: 8, [image("changes-allow-symbolic", classes: ["error"]),
                                                          label("Administrator mode: changes are made as root on \(state.adminTarget?.label ?? "this computer")."),
                                                          spacer(), leave], classes: ["banner-admin"]))
            if admin?.remoteModel !== adminModel {
                admin = ExplorerView(kind: .remote(adminModel), tab: tab, workspace: workspace, host: self, administrator: true)
            }
            next = admin!
        } else if case .remote = state.endpoint, let model = state.remoteModel {
            if remote?.remoteModel !== model { remote = ExplorerView(kind: .remote(model), tab: tab, workspace: workspace, host: self) }
            next = remote!
            admin = nil
        } else {
            if local == nil { local = ExplorerView(kind: .local, tab: tab, workspace: workspace, host: self) }
            next = local!
            remote = nil
            admin = nil
        }
        if current !== next {
            if let current { unparent(current.view) }
            removeChildren(body)
            append(body, next.view)
            current = next
            next.reload()
        }
    }

    func focus() { current?.focus() }
    func find() { current?.showFilter() }
    var tabState: TabState? { tab?.state }
}

/// One explorer pane in Thunar's layout: Places on the left, then the location bar, the file list and, for hosts,
/// the transfers. The same view shows this computer's files and a host's.
@MainActor
final class ExplorerView {
    enum Kind {
        case local
        case remote(RemoteExplorerModel)
    }

    struct Entry {
        let name: String
        let isFolder: Bool
        let size: Int64?
    }

    let kind: Kind
    let view: Widget
    private weak var tab: TerminalTab?
    private weak var workspace: Workspace?
    private weak var host: ExplorerHost?
    private let isAdministrator: Bool

    private let sidebar: Widget
    private let sidebarScroll: Widget
    private let places: Widget
    private let locationBox: Widget
    private let segments: Widget
    private let segmentScroll: Widget
    private let locationEntry: Widget
    private let back, forward, up, home, hiddenToggle, bookmark: Widget
    private var lock: Widget?
    private let actionsButton: Widget
    private let filterBar: Widget
    private let filterEntry: Widget
    private let working: Widget
    private let workingLabel: Widget
    private let errorBox: Widget
    private let list: Widget
    private let listScroll: Widget
    private let transfers: Widget
    private let group: OpaquePointer
    private var actions: [String: OpaquePointer] = [:]
    private var entries: [Entry] = []
    private var visible: [Entry] = []
    private var filterText = ""
    private var tokens: [ObservationToken] = []
    private var localShowHidden: Bool { get { Preferences.shared.bool("explorerShowHidden") ?? false } set { Preferences.shared.set(newValue, "explorerShowHidden") } }
    private var loadGeneration = 0
    private var workingTitle: String?
    private var localError: String?

    var remoteModel: RemoteExplorerModel? { if case .remote(let model) = kind { model } else { nil } }

    init(kind: Kind, tab: TerminalTab, workspace: Workspace, host: ExplorerHost, administrator: Bool = false) {
        self.kind = kind
        self.tab = tab
        self.workspace = workspace
        self.host = host
        isAdministrator = administrator

        places = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(c(places), GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(places, "navigation-sidebar")
        sidebarScroll = scrolled(places)
        gtk_widget_set_size_request(sidebarScroll, 170, -1)
        gtk_widget_set_hexpand(sidebarScroll, 0)
        sidebar = box(.horizontal, [sidebarScroll, separator(.vertical)], classes: ["places"])
        gtk_widget_set_hexpand(sidebar, 0)

        back = gtk_button_new_from_icon_name("go-previous-symbolic")!
        forward = gtk_button_new_from_icon_name("go-next-symbolic")!
        up = gtk_button_new_from_icon_name("go-up-symbolic")!
        home = gtk_button_new_from_icon_name("go-home-symbolic")!
        hiddenToggle = gtk_toggle_button_new()!
        gtk_button_set_icon_name(c(hiddenToggle), "view-reveal-symbolic")
        bookmark = gtk_toggle_button_new()!
        gtk_button_set_icon_name(c(bookmark), "bookmark-new-symbolic")
        segments = box(.horizontal, spacing: 2)
        segmentScroll = scrolled(segments, horizontal: true, vertical: false)
        gtk_scrolled_window_set_policy(c(segmentScroll), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        gtk_widget_set_vexpand(segmentScroll, 0)
        locationEntry = HerbsTerminal.entry(placeholder: "Location")
        gtk_widget_set_hexpand(locationEntry, 1)
        setVisible(locationEntry, false)
        actionsButton = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(c(actionsButton), "view-more-symbolic")
        locationBox = box(.horizontal, spacing: 4, classes: ["location-bar"])

        filterEntry = gtk_search_entry_new()!
        herb_set_string(raw(filterEntry), "placeholder-text", "Filter by name")
        gtk_widget_set_hexpand(filterEntry, 1)
        filterBar = box(.horizontal, spacing: 6)
        margins(filterBar, top: 4, bottom: 4, start: 10, end: 10)
        setVisible(filterBar, false)

        workingLabel = label("", classes: ["dim-label", "caption"])
        let spinner = gtk_spinner_new()!
        gtk_spinner_start(c(spinner))
        working = box(.horizontal, spacing: 8, [spinner, workingLabel])
        margins(working, top: 5, bottom: 5, start: 10, end: 10)
        setVisible(working, false)

        errorBox = box(.vertical, spacing: 8)
        margins(errorBox, 16)
        gtk_widget_set_valign(errorBox, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(errorBox, 1)
        setVisible(errorBox, false)

        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(c(list), GTK_SELECTION_MULTIPLE)
        gtk_list_box_set_activate_on_single_click(c(list), 0)
        gtk_widget_add_css_class(list, "rich-list")
        listScroll = scrolled(list)
        transfers = box(.vertical, spacing: 4, classes: ["transfers"])
        setVisible(transfers, false)

        let main = box(.vertical, [locationBox, separator(), filterBar, working, errorBox, listScroll, transfers])
        gtk_widget_set_hexpand(main, 1)
        view = box(.horizontal, [sidebar, main])
        g_object_ref_sink(raw(view))
        group = c(g_simple_action_group_new())
        gtk_widget_insert_action_group(view, "explorer", c(group))

        buildLocationBar()
        buildFilter()
        installActions()
        installShortcuts()
        configureList()
        if case .remote(let model) = kind {
            model.showHidden = Preferences.shared.bool("explorerShowHidden") ?? false
            model.onAlert = { [weak self] message in
                Task { await Dialogs.tell(self?.view, "File action failed", message) }
            }
            tokens.append(model.changed.observe { [weak self] in self?.modelChanged() })
            tokens.append(model.queue.objectWillChange.observe { [weak self] in self?.scheduleTransfers() })
        }
        every(milliseconds: 400) { [weak self] in
            guard let self else { return false }
            self.adaptSidebar()
            return true
        }
    }

    // MARK: Where we are

    private var state: TabState? { tab?.state }

    private var path: String {
        get {
            guard let state else { return "/" }
            if isAdministrator { return state.adminPath }
            switch kind {
            case .local: return state.directory.path
            case .remote: return state.remoteDirectory
            }
        }
        set {
            guard let state else { return }
            if isAdministrator { state.adminPath = newValue; return }
            switch kind {
            case .local: state.directory = URL(fileURLWithPath: newValue, isDirectory: true)
            case .remote: state.remoteDirectory = newValue
            }
        }
    }

    private var history: NavigationHistory {
        get {
            guard let state else { return NavigationHistory("/") }
            if isAdministrator { return state.adminHistory }
            switch kind {
            case .local: return state.localHistory
            case .remote: return state.remoteHistory
            }
        }
        set {
            guard let state else { return }
            if isAdministrator { state.adminHistory = newValue; return }
            switch kind {
            case .local: state.localHistory = newValue
            case .remote: state.remoteHistory = newValue
            }
        }
    }

    private var homePath: String {
        guard let state else { return "/" }
        if isAdministrator { return state.adminTarget == .local ? LocalPlaces.home : state.remoteHome }
        switch kind {
        case .local: return LocalPlaces.home
        case .remote: return state.remoteHome
        }
    }

    private var hostLabel: String { remoteModel?.endpoint.label ?? "this computer" }

    private var bookmarks: BookmarkList {
        if let model = remoteModel {
            return BookmarkList(raw: Preferences.shared.string("remoteExplorerBookmarks") ?? "", scope: "\(model.endpoint.label):\(model.endpoint.port)")
        }
        return BookmarkList(raw: Preferences.shared.string("explorerBookmarks") ?? "", scope: "")
    }

    private func toggleBookmark(_ target: String) {
        var list = bookmarks
        list.toggle(normalizePath(target))
        Preferences.shared.set(list.raw, remoteModel == nil ? "explorerBookmarks" : "remoteExplorerBookmarks")
        updateChrome()
    }

    private func visit(_ target: String) {
        var current = history
        current.visit(target)
        history = current
        go(target)
    }

    private func go(_ target: String) {
        path = normalizePath(target)
        closeFilter()
        reload()
    }

    func focus() { gtk_widget_grab_focus(list) }

    // MARK: Listing

    func reload() {
        updateChrome()
        switch kind {
        case .remote(let model):
            Task { await model.load(path: path) }
        case .local:
            loadGeneration += 1
            let generation = loadGeneration, folder = path, hidden = localShowHidden
            localError = nil
            Task {
                let result: Result<[Entry], Error> = await Task.detached { Result { try Self.listLocal(folder, showHidden: hidden) } }.value
                guard generation == self.loadGeneration else { return }
                switch result {
                case .success(let items): self.entries = items; self.localError = nil
                case .failure(let error): self.entries = []; self.localError = error.localizedDescription
                }
                self.renderList()
            }
        }
    }

    nonisolated private static func listLocal(_ folder: String, showHidden: Bool) throws -> [Entry] {
        let real = Host.sandboxPath(folder)
        var names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: real) }
        catch { throw FileIssue("“\((folder as NSString).lastPathComponent.isEmpty ? "/" : (folder as NSString).lastPathComponent)” couldn't be opened: \(Self.reason(error))") }
        if normalizePath(folder) == "/" { names.removeAll { Host.sandboxOnlyRootEntries.contains($0) } }
        return names.filter { showHidden || !$0.hasPrefix(".") }.map { name in
            let url = URL(fileURLWithPath: Host.sandboxPath(remoteJoin(folder, name)))
            let folder = opensAsFolder(url)
            let size = folder ? nil : ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
            return Entry(name: name, isFolder: folder, size: size)
        }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func reason(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.lowercased().contains("permission") { return "Permission denied." }
        return text
    }

    private func modelChanged() {
        guard let model = remoteModel else { return }
        if model.isLoading { return }
        entries = model.entries.map { Entry(name: $0.name, isFolder: $0.attributes.directory, size: $0.attributes.size.map(Int64.init)) }
        renderList()
        updateChrome()
    }

    private var errorMessage: String? {
        switch kind {
        case .local: localError
        case .remote(let model): model.errorMessage
        }
    }

    private func renderList() {
        gtk_list_box_remove_all(c(list))
        removeChildren(errorBox)
        if let error = errorMessage {
            setVisible(listScroll, false)
            setVisible(errorBox, true)
            append(errorBox, label(error, classes: remoteModel == nil ? [] : ["error-text"], xalign: 0.5, wrap: true))
            if remoteModel != nil {
                append(errorBox, centered(button("Retry", hint: "Retry\nList this remote folder again.") { [weak self] in self?.reload() }))
            }
            if !isAdministrator, isPermissionError(error) {
                append(errorBox, centered(button("Open with Administrator Mode…",
                                                 hint: "Administrator Mode\nOpen this folder as root with sudo.") { [weak self] in self?.toggleAdministrator() }))
            }
            return
        }
        setVisible(errorBox, false)
        setVisible(listScroll, true)
        visible = entries.filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
        for entry in visible {
            let icon = image(entry.isFolder ? "folder-symbolic" : "text-x-generic-symbolic")
            let name = label(entry.name, classes: entry.name.hasPrefix(".") ? ["hidden-file"] : [], ellipsize: PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_set_hexpand(name, 1)
            let row = box(.horizontal, spacing: 8, [icon, name])
            if !entry.isFolder, let size = entry.size { append(row, label(formatBytes(size), classes: ["file-size"])) }
            margins(row, top: 3, bottom: 3, start: 6, end: 6)
            gtk_list_box_append(c(list), row)
            let help = remoteModel == nil
                ? (entry.isFolder ? "Folder\nDouble-click or press Return to open it."
                                  : "File\nDouble-click or press Return to open it: text files in the text editor, others in their own app.")
                : (entry.isFolder ? "Remote folder\nDouble-click or press Return to open it."
                                  : "Remote file\nDouble-click to edit a text file here; Download from File Actions copies any file to this computer.")
            hint(row, help)
        }
        updateActionStates()
    }

    private func centered(_ widget: Widget) -> Widget {
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
        return widget
    }

    private var selectedNames: [String] {
        var names: [String] = []
        var index: Int32 = 0
        while let row = gtk_list_box_get_row_at_index(c(list), index) {
            if gtk_list_box_row_is_selected(row) != 0, visible.indices.contains(Int(index)) { names.append(visible[Int(index)].name) }
            index += 1
        }
        return names
    }

    private func entry(_ name: String) -> Entry? { visible.first { $0.name == name } }
    private func full(_ name: String) -> String { remoteJoin(path, name) }
    private func localURL(_ name: String) -> URL { URL(fileURLWithPath: Host.sandboxPath(full(name))) }

    private func select(_ names: Set<String>) {
        gtk_list_box_unselect_all(c(list))
        for (index, entry) in visible.enumerated() where names.contains(entry.name) {
            if let row = gtk_list_box_get_row_at_index(c(list), Int32(index)) { gtk_list_box_select_row(c(list), row) }
        }
    }

    // MARK: Location bar and side pane

    private func buildLocationBar() {
        for (widget, name, help) in [
            (back, "Back", "Back (Alt+Left)\nReturn to the folder you were in before."),
            (forward, "Forward", "Forward (Alt+Right)\nGo forward again after using Back."),
            (up, "Parent folder", "Open Parent (Alt+Up)\nGo up to the folder that contains this one."),
            (home, "Home folder", "Home (Alt+Home)\nGo to your home folder."),
        ] {
            gtk_widget_add_css_class(widget, "flat")
            accessibleLabel(widget, name)
            hint(widget, help)
        }
        on(back, "clicked") { [weak self] _ in self?.goBack() }
        on(forward, "clicked") { [weak self] _ in self?.goForward() }
        on(up, "clicked") { [weak self] _ in self.map { $0.visit(parentPath($0.history.current)) } }
        on(home, "clicked") { [weak self] _ in self.map { $0.visit($0.homePath) } }
        let edit = iconButton("document-edit-symbolic", label: "Edit location",
                              hint: "Open Location (Ctrl+L)\nType a path to go to: absolute, ~/… or relative to this folder.") { [weak self] in self?.startEditing() }
        let reloadButton = iconButton("view-refresh-symbolic", label: "Reload", hint: "Reload (Ctrl+R)\nList this folder again to pick up changes.") { [weak self] in
            self?.reload()
        }
        gtk_widget_add_css_class(hiddenToggle, "flat")
        accessibleLabel(hiddenToggle, "Show hidden files")
        on(hiddenToggle, "toggled") { [weak self] _ in
            guard let self else { return }
            let on = gtk_toggle_button_get_active(c(self.hiddenToggle)) != 0
            guard on != self.showHidden else { return }
            self.setShowHidden(on)
        }
        gtk_widget_add_css_class(bookmark, "flat")
        accessibleLabel(bookmark, "Bookmark")
        on(bookmark, "clicked") { [weak self] _ in self.map { $0.toggleBookmark($0.history.current) } }
        gtk_widget_add_css_class(actionsButton, "flat")
        hint(actionsButton, "File Actions\nUpload, download, undo, cut, copy, paste, delete, select all and find.")
        accessibleLabel(actionsButton, "File actions")
        gtk_widget_set_hexpand(segmentScroll, 1)
        append(locationBox, back, forward, up, home, segmentScroll, locationEntry, edit, reloadButton, hiddenToggle, bookmark)
        // The lock: Administrator mode, offered in every explorer.
        // A real toggle button, so screen readers announce whether Administrator mode is on.
        let lock = gtk_toggle_button_new()!
        gtk_button_set_icon_name(c(lock), isAdministrator ? "changes-allow-symbolic" : "changes-prevent-symbolic")
        gtk_toggle_button_set_active(c(lock), isAdministrator ? 1 : 0)
        gtk_widget_add_css_class(lock, "flat")
        if isAdministrator { gtk_widget_add_css_class(lock, "error") }
        accessibleLabel(lock, "Administrator mode")
        accessiblePressed(lock, isAdministrator)
        hint(lock, isAdministrator ? "Leave Administrator Mode\nGo back to working with your own account's access."
                                   : "Administrator Mode\nWork as root with sudo: open and change any file. Asks for the sudo password.")
        on(lock, "clicked") { [weak self] _ in
            guard let self else { return }
            // The click only asks: the lock shows Administrator mode once it has started (a cancelled password leaves it off).
            gtk_toggle_button_set_active(c(lock), self.isAdministrator ? 1 : 0)
            self.toggleAdministrator()
        }
        self.lock = lock
        append(locationBox, lock, actionsButton)

        on(locationEntry, "activate") { [weak self] _ in
            guard let self else { return }
            if let target = resolveLocation(text(of: self.locationEntry), from: self.history.current, home: self.homePath) { self.visit(target) }
            self.stopEditing()
        }
        let keys = LocalShortcuts(locationEntry)
        keys.add("Escape") { [weak self] in self?.stopEditing() }

        on(places, "row-activated") { [weak self] args in
            guard let self, let row = args.pointer(1) else { return }
            let index = Int(gtk_list_box_row_get_index(c(row)))
            if self.placeTargets.indices.contains(index), let target = self.placeTargets[index] { self.visit(target) }
        }
        onClick(places, button: 3) { [weak self] _, x, y in
            guard let self, let row = gtk_list_box_get_row_at_y(c(self.places), Int32(y)) else { return }
            let index = Int(gtk_list_box_row_get_index(row))
            guard self.placeRemovable.indices.contains(index), self.placeRemovable[index], let target = self.placeTargets[index] else { return }
            let menu = MenuBuilder()
            menu.item("Remove Bookmark", "explorer.remove-bookmark", target: target)
            popUp(menu.finish(), on: self.places, x: x, y: y)
        }
    }

    private var showHidden: Bool { remoteModel?.showHidden ?? localShowHidden }

    private func setShowHidden(_ on: Bool) {
        localShowHidden = on
        remoteModel?.showHidden = on
        reload()
    }

    private func startEditing() {
        setText(locationEntry, history.current)
        setVisible(segmentScroll, false)
        setVisible(locationEntry, true)
        gtk_widget_grab_focus(locationEntry)
    }

    private func stopEditing() {
        setVisible(locationEntry, false)
        setVisible(segmentScroll, true)
        focus()
    }

    private func goBack() {
        var current = history
        if let previous = current.goBack() { history = current; go(previous) }
    }

    private func goForward() {
        var current = history
        if let next = current.goForward() { history = current; go(next) }
    }

    private var placeTargets: [String?] = []
    private var placeRemovable: [Bool] = []

    /// The location bar's state and the side pane, for the current folder.
    private func updateChrome() {
        let current = normalizePath(path)
        enable(back, history.canGoBack)
        enable(forward, history.canGoForward)
        enable(up, current != "/")
        removeChildren(segments)
        for (index, segment) in pathSegments(current).enumerated() {
            if index > 1 { append(segments, image("go-next-symbolic", pixels: 10, classes: ["dim-label"])) }
            let widget = button(segment.name, classes: segment.path == current ? ["flat", "path-segment", "current"] : ["flat", "path-segment"],
                                hint: "\(segment.path)\nClick to open this folder.") { [weak self] in self?.visit(segment.path) }
            append(segments, widget)
        }
        // Long paths stay scrolled to the end so the current folder is visible.
        idle { [weak self] in
            guard let self else { return }
            let adjustment = gtk_scrolled_window_get_hadjustment(c(self.segmentScroll))
            gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
        }
        let hidden = showHidden
        if (gtk_toggle_button_get_active(c(hiddenToggle)) != 0) != hidden { gtk_toggle_button_set_active(c(hiddenToggle), hidden ? 1 : 0) }
        accessiblePressed(hiddenToggle, hidden)
        hint(hiddenToggle, hidden ? "Hide Hidden Files (Ctrl+H)\nStop showing items whose names start with a dot."
                                  : "Show Hidden Files (Ctrl+H)\nAlso list items whose names start with a dot.")
        let marked = bookmarks.contains(current)
        if (gtk_toggle_button_get_active(c(bookmark)) != 0) != marked { gtk_toggle_button_set_active(c(bookmark), marked ? 1 : 0) }
        gtk_button_set_icon_name(c(bookmark), marked ? "starred-symbolic" : "non-starred-symbolic")
        accessiblePressed(bookmark, marked)
        hint(bookmark, marked ? "Remove Bookmark (Ctrl+D)\nTake this folder out of the side pane's Bookmarks."
                              : "Bookmark This Folder (Ctrl+D)\nAdd it to the side pane's Bookmarks.")
        renderPlaces(current)
        renderWorking()
    }

    private func renderPlaces(_ current: String) {
        gtk_list_box_remove_all(c(places))
        placeTargets = []
        placeRemovable = []
        let sections: [PlacesSection]
        if let model = remoteModel {
            sections = [
                PlacesSection(title: model.endpoint.label, places: [Place(name: "Home", icon: "user-home-symbolic", path: homePath),
                                                                    Place(name: "File System", icon: "drive-harddisk-symbolic", path: "/")]),
                PlacesSection(title: "Bookmarks", places: bookmarks.paths.map {
                    Place(name: ($0 as NSString).lastPathComponent.isEmpty ? "/" : ($0 as NSString).lastPathComponent, icon: "folder-symbolic", path: $0)
                }, removable: true),
            ]
        } else {
            sections = [
                PlacesSection(title: "Places", places: LocalPlaces.standard()),
                PlacesSection(title: "Devices", places: LocalPlaces.devices()),
                PlacesSection(title: "Bookmarks", places: bookmarks.paths.map { Place(name: ($0 as NSString).lastPathComponent, icon: "folder-symbolic", path: $0) },
                              removable: true),
            ]
        }
        for section in sections where !section.places.isEmpty {
            let heading = label(section.title, classes: ["section"])
            gtk_list_box_append(c(places), heading)
            if let row = gtk_list_box_get_row_at_index(c(places), Int32(placeTargets.count)) {
                gtk_list_box_row_set_activatable(row, 0)
                gtk_list_box_row_set_selectable(row, 0)
            }
            placeTargets.append(nil)
            placeRemovable.append(false)
            for place in section.places {
                let row = box(.horizontal, spacing: 8, [image(place.icon), label(place.name, ellipsize: PANGO_ELLIPSIZE_MIDDLE)])
                hint(row, "\(place.name)\nOpen \(place.path)")
                gtk_list_box_append(c(places), row)
                let index = Int32(placeTargets.count)
                placeTargets.append(place.path)
                placeRemovable.append(section.removable)
                if place.path == current, let listRow = gtk_list_box_get_row_at_index(c(places), index) { gtk_list_box_select_row(c(places), listRow) }
            }
        }
    }

    /// Below 560 pixels the explorer drops its side pane rather than clipping its content; below 700 it is narrower.
    private func adaptSidebar() {
        let width = gtk_widget_get_width(view)
        guard width > 0 else { return }
        setVisible(sidebar, width >= 560)
        gtk_widget_set_size_request(sidebarScroll, width < 700 ? 140 : 170, -1)
    }

    private func renderWorking() {
        setVisible(working, workingTitle != nil)
        setLabel(workingLabel, workingTitle ?? "")
    }

    // MARK: Filter

    private func buildFilter() {
        let close = iconButton("window-close-symbolic", label: "Close Find", hint: "Close Find\nShow every item in this folder again (Esc).") { [weak self] in
            self?.closeFilter()
        }
        append(filterBar, filterEntry, close)
        hint(filterEntry, "Find\nShow only items whose name contains this text.")
        on(filterEntry, "search-changed") { [weak self] _ in
            guard let self else { return }
            self.filterText = text(of: self.filterEntry)
            self.renderList()
        }
        on(filterEntry, "stop-search") { [weak self] _ in self?.closeFilter() }
    }

    func showFilter() {
        setVisible(filterBar, true)
        gtk_widget_grab_focus(filterEntry)
    }

    private func closeFilter() {
        guard gtk_widget_get_visible(filterBar) != 0 || !filterText.isEmpty else { return }
        filterText = ""
        setText(filterEntry, "")
        setVisible(filterBar, false)
        renderList()
    }

    // MARK: The file list

    private func configureList() {
        on(list, "row-activated") { [weak self] args in
            guard let self, let row = args.pointer(1) else { return }
            let index = Int(gtk_list_box_row_get_index(c(row)))
            if self.visible.indices.contains(index) { self.open(self.visible[index]) }
        }
        on(list, "selected-rows-changed") { [weak self] _ in self?.updateActionStates() }
        onClick(list, button: 3) { [weak self] _, x, y in
            guard let self else { return }
            if let row = gtk_list_box_get_row_at_y(c(self.list), Int32(y)) {
                if gtk_list_box_row_is_selected(row) == 0 {
                    gtk_list_box_unselect_all(c(self.list))
                    gtk_list_box_select_row(c(self.list), row)
                }
            } else {
                gtk_list_box_unselect_all(c(self.list))
            }
            self.showContextMenu(x: x, y: y)
        }
        // Dropping files from a file manager copies them here (uploads them on a host).
        gtk_widget_add_controller(listScroll, filesDropTarget { [weak self] paths in self?.pasteFiles(paths, cut: false) })
    }

    private func showContextMenu(x: Double, y: Double) {
        let names = selectedNames
        let menu = MenuBuilder()
        if names.isEmpty {
            menu.item("New Folder…", "explorer.new-folder")
            menu.item("New File…", "explorer.new-file")
            menu.item("Paste", "explorer.paste")
        } else if let first = entry(names[0]) {
            if remoteModel == nil {
                menu.item("Open", "explorer.open")
                if !first.isFolder {
                    menu.item("Open in Text Editor", "explorer.edit")
                    menu.item("Open with Default App", "explorer.open-default")
                }
                if names.count == 1 { menu.item("Rename…", "explorer.rename") }
                if first.isFolder {
                    menu.item(bookmarks.contains(full(first.name)) ? "Remove Bookmark" : "Add Bookmark", "explorer.bookmark-selected")
                }
                menu.item("Get Info…", "explorer.info")
                menu.item("Show in Files", "explorer.reveal")
                menu.divider()
                menu.item("Cut", "explorer.cut")
                menu.item("Copy", "explorer.copy")
                menu.item("Paste", "explorer.paste")
                menu.item("Move to Trash", "explorer.delete")
            } else {
                if names.count == 1 { menu.item("Rename…", "explorer.rename") }
                if first.isFolder { menu.item("Open", "explorer.open") } else { menu.item("Open in Text Editor", "explorer.edit") }
                menu.item("Get Info…", "explorer.info")
                menu.item("Download…", "explorer.download")
                menu.divider()
                menu.item("Cut", "explorer.cut")
                menu.item("Copy", "explorer.copy")
                menu.item("Paste", "explorer.paste")
                menu.item("Delete…", "explorer.delete")
            }
        }
        popUp(menu.finish(), on: list, x: x, y: y)
    }

    private func open(_ entry: Entry) {
        if entry.isFolder { visit(full(entry.name)); return }
        switch kind {
        case .local:
            let url = localURL(entry.name)
            if TextCodec.isLocalText(url) { Workspace.openEditor(.local(url)) } else { herb_launch_file(rootWindow(view), url.path, 0) }
        case .remote(let model):
            // Text opens in the editor; for files of an unknown type the editor checks the content itself.
            if TextCodec.isText(name: entry.name, sniff: { Data() }) { Workspace.openEditor(model.textSource(for: full(entry.name))) }
        }
    }

    // MARK: Actions

    private func installActions() {
        func add(_ name: String, _ action: @escaping @MainActor (ExplorerView) -> Void) {
            actions[name] = addAction(group, name) { [weak self] in if let self { action(self) } }
        }
        add("open") { view in view.selectedNames.compactMap(view.entry).first.map(view.open) }
        add("edit") { view in
            for name in view.selectedNames {
                guard let entry = view.entry(name), !entry.isFolder else { continue }
                switch view.kind {
                case .local: Workspace.openEditor(.local(view.localURL(name)))
                case .remote(let model): Workspace.openEditor(model.textSource(for: view.full(name)))
                }
            }
        }
        add("open-default") { view in view.selectedNames.forEach { herb_launch_file(rootWindow(view.view), view.localURL($0).path, 0) } }
        add("reveal") { view in view.selectedNames.first.map { herb_launch_file(rootWindow(view.view), view.localURL($0).path, 1) } }
        add("rename") { $0.rename() }
        add("info") { $0.getInfo() }
        add("download") { $0.download() }
        add("upload") { $0.upload() }
        add("cut") { $0.clip(cut: true) }
        add("copy") { $0.clip(cut: false) }
        add("paste") { $0.paste() }
        add("delete") { $0.delete() }
        add("select-all") { gtk_list_box_select_all(c($0.list)) }
        add("find") { $0.showFilter() }
        add("undo") { $0.undo() }
        add("redo") { $0.redo() }
        add("new-folder") { $0.create(folder: true) }
        add("new-file") { $0.create(folder: false) }
        add("bookmark-selected") { view in view.selectedNames.first.map { view.toggleBookmark(view.full($0)) } }
        addParameterAction(group, "remove-bookmark") { [weak self] target in self?.toggleBookmark(target) }
        updateActionStates()
    }

    private func installShortcuts() {
        let keys = LocalShortcuts(view)
        keys.add("<Control>c") { [weak self] in self?.clip(cut: false) }
        keys.add("<Control>x") { [weak self] in self?.clip(cut: true) }
        keys.add("<Control>v") { [weak self] in self?.paste() }
        keys.add("<Control>a") { [weak self] in self.map { gtk_list_box_select_all(c($0.list)) } }
        keys.add("<Control>z") { [weak self] in self?.undo() }
        keys.add("<Control><Shift>z|<Control>y") { [weak self] in self?.redo() }
        keys.add("Delete|KP_Delete") { [weak self] in self?.delete() }
        // Thunar's BackSpace goes back.
        keys.add("BackSpace|<Alt>Left") { [weak self] in self?.goBack() }
        keys.add("<Alt>Right") { [weak self] in self?.goForward() }
        keys.add("<Alt>Up") { [weak self] in self.map { $0.visit(parentPath($0.history.current)) } }
        keys.add("<Alt>Home") { [weak self] in self.map { $0.visit($0.homePath) } }
        keys.add("<Control>l") { [weak self] in self?.startEditing() }
        keys.add("<Control>r|F5") { [weak self] in self?.reload() }
        keys.add("<Control>h") { [weak self] in self.map { $0.setShowHidden(!$0.showHidden) } }
        keys.add("<Control>d") { [weak self] in self.map { $0.toggleBookmark($0.history.current) } }
        keys.add("<Control>f") { [weak self] in self?.showFilter() }
        keys.add("F2") { [weak self] in self?.rename() }
        keys.add("<Alt>Return") { [weak self] in self?.getInfo() }
    }

    private func updateActionStates() {
        let hasSelection = !selectedNames.isEmpty
        for name in ["open", "edit", "open-default", "reveal", "rename", "info", "cut", "copy", "delete", "bookmark-selected"] {
            setActionEnabled(actions[name], hasSelection)
        }
        let undoTitle: String, redoTitle: String
        switch kind {
        case .local:
            let log = state?.localLog
            setActionEnabled(actions["undo"], log?.canUndo ?? false)
            setActionEnabled(actions["redo"], log?.canRedo ?? false)
            undoTitle = log?.undoTitle ?? "Undo"
            redoTitle = log?.redoTitle ?? "Redo"
            setActionEnabled(actions["upload"], false)
            setActionEnabled(actions["download"], false)
        case .remote(let model):
            setActionEnabled(actions["undo"], !model.undoMoves.isEmpty)
            setActionEnabled(actions["redo"], !model.redoMoves.isEmpty)
            undoTitle = model.undoMoves.isEmpty ? "Undo" : "Undo Move"
            redoTitle = model.redoMoves.isEmpty ? "Redo" : "Redo Move"
            setActionEnabled(actions["upload"], true)
            setActionEnabled(actions["download"], hasSelection)
        }
        let menu = MenuBuilder()
        menu.item("Upload File/Folder…", "explorer.upload")
        menu.item("Download File/Folder…", "explorer.download")
        menu.divider()
        menu.item(undoTitle, "explorer.undo", accel: "<Control>z")
        menu.item(redoTitle, "explorer.redo", accel: "<Control><Shift>z")
        menu.divider()
        menu.item("Cut", "explorer.cut", accel: "<Control>x")
        menu.item("Copy", "explorer.copy", accel: "<Control>c")
        menu.item("Paste", "explorer.paste", accel: "<Control>v")
        menu.item(remoteModel == nil ? "Move to Trash" : "Delete…", "explorer.delete", accel: "Delete")
        menu.item("Select All", "explorer.select-all", accel: "<Control>a")
        menu.divider()
        menu.item("Find", "explorer.find", accel: "<Control>f")
        gtk_menu_button_set_menu_model(c(actionsButton), c(menu.finish()))
        nameMenuItems(actionsButton)
    }

    private var parentWindow: Widget? { workspace?.window ?? view }

    private func create(folder: Bool) {
        Task {
            switch kind {
            case .local:
                guard let name = await Dialogs.name(parentWindow, title: folder ? "New Folder" : "New File",
                                                    message: "Name for the new \(folder ? "folder" : "file") in \((path as NSString).lastPathComponent):",
                                                    initial: folder ? "untitled folder" : "untitled") else { return }
                await perform {
                    let change = try LocalFiles.create(folder: folder, named: name, in: URL(fileURLWithPath: Host.sandboxPath(self.path)))
                    self.state?.localLog.record(change, as: folder ? "New Folder" : "New File")
                    if case .created(let urls) = change, !folder, let url = urls.first { Workspace.openEditor(.local(url)) }
                }
            case .remote(let model):
                guard let name = await Dialogs.name(parentWindow, title: folder ? "New Folder" : "New File",
                                                    message: "Name for the new \(folder ? "folder" : "file") on \(model.endpoint.label):",
                                                    initial: folder ? "untitled folder" : "untitled.txt") else { return }
                if folder { await model.newFolder(named: name, in: path) }
                else if let created = await model.newFile(named: name, in: path) { Workspace.openEditor(model.textSource(for: created)) }
            }
        }
    }

    private func rename() {
        guard let name = selectedNames.first else { return }
        Task {
            guard let newName = await Dialogs.name(parentWindow, title: "Rename", message: "New name for “\(name)”:", initial: name),
                  newName != name else { return }
            switch kind {
            case .local:
                await perform {
                    let change = try LocalFiles.rename(self.localURL(name), to: newName)
                    self.state?.localLog.record(change, as: "Rename")
                }
            case .remote(let model):
                await model.rename(name, to: newName, in: path)
            }
        }
    }

    private func getInfo() {
        let names = selectedNames
        guard !names.isEmpty else { return }
        switch kind {
        case .local: FileInfoWindow.show(.local(names.map(localURL)), parent: parentWindow)
        case .remote(let model): FileInfoWindow.show(model.infoSource(for: names, in: path), parent: parentWindow)
        }
    }

    private func clip(cut: Bool) {
        let names = selectedNames
        guard !names.isEmpty else { return }
        switch kind {
        case .local: FileClipboard.shared.writeLocal(names.map { localURL($0).path }, cut: cut)
        case .remote(let model): FileClipboard.shared.writeRemote(names.map(full), on: model.endpoint, cut: cut, fetch: model.clipboardFetcher)
        }
    }

    /// Paste: local files are copied or moved here; on a host, its own items move or copy there and this computer's
    /// files upload.
    private func paste() {
        if case .remote(let model) = kind, let clip = FileClipboard.shared.readRemote(for: model.endpoint) {
            if clip.cut { FileClipboard.shared.finishCut() }
            let folder = path
            Task { await model.paste(clip.paths, cut: clip.cut, into: folder) }
            return
        }
        FileClipboard.shared.readLocal { [weak self] paths, cut in
            guard let self else { return }
            guard !paths.isEmpty else { gtk_widget_error_bell(self.list); return }
            self.pasteFiles(paths, cut: cut)
        }
    }

    private func pasteFiles(_ paths: [String], cut: Bool) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        switch kind {
        case .local:
            let folder = URL(fileURLWithPath: Host.sandboxPath(path))
            inBackground(cut ? "Moving…" : "Copying…", { cut ? try LocalFiles.move(urls, into: folder) : try LocalFiles.copy(urls, into: folder) }) { [weak self] change in
                self?.state?.localLog.record(change)
                if cut { FileClipboard.shared.finishCut() }
            }
        case .remote(let model):
            let folder = path
            Task { await model.upload(urls, into: folder) }
        }
    }

    private func delete() {
        let names = selectedNames
        guard !names.isEmpty else { return }
        switch kind {
        case .local:
            let urls = names.map(localURL)
            inBackground("Moving to Trash…", { try LocalFiles.trash(urls) }) { [weak self] change in self?.state?.localLog.record(change) }
        case .remote(let model):
            let folder = path
            Task {
                let answer = await Dialogs.ask(parentWindow, names.count == 1 ? "Delete “\(names[0])” from \(model.endpoint.label)?"
                                                                              : "Delete \(names.count) items from \(model.endpoint.label)?",
                                               "Remote items are deleted permanently, folders with everything inside. This can't be undone.",
                                               choices: [.init("cancel", "Cancel"), .init("delete", "Delete", .destructive)], cancel: "cancel")
                guard answer == "delete" else { return }
                await model.delete(names, in: folder)
            }
        }
    }

    private func undo() {
        switch kind {
        case .local: Task { await perform { try self.state?.localLog.undo() } }
        case .remote(let model): Task { await model.undo() }
        }
    }

    private func redo() {
        switch kind {
        case .local: Task { await perform { try self.state?.localLog.redo() } }
        case .remote(let model): Task { await model.redo() }
        }
    }

    private func upload() {
        guard case .remote(let model) = kind else { return }
        let folder = path
        Task {
            let paths = await Dialogs.openFiles(parentWindow, title: "Upload to \(model.endpoint.label)", accept: "Upload",
                                                folder: state?.directory.path, multiple: true)
            guard !paths.isEmpty else { return }
            await model.upload(paths.map { URL(fileURLWithPath: $0) }, into: folder)
        }
    }

    private func download() {
        guard case .remote(let model) = kind else { return }
        let names = selectedNames, folder = path
        guard !names.isEmpty else { return }
        Task {
            let downloads = LocalPlaces.userDirs()["DOWNLOAD"] ?? LocalPlaces.home + "/Downloads"
            guard let target = await Dialogs.openFiles(parentWindow, title: "Download from \(model.endpoint.label)", accept: "Download Here",
                                                       folder: downloads, folders: true).first else { return }
            await model.download(names, from: folder, to: URL(fileURLWithPath: target, isDirectory: true))
        }
    }

    func toggleAdministrator() {
        guard let host else { return }
        if isAdministrator { AdministratorMode.leave(host) } else { Task { await AdministratorMode.enter(host, parent: parentWindow) } }
    }

    /// Copy, move and trash can take a long time, so they run off the main thread: the window and every terminal
    /// keep working, and the folder reloads when they finish.
    private func inBackground(_ title: String, _ work: @escaping @Sendable () throws -> FileChange, then record: @escaping (FileChange) -> Void) {
        workingTitle = title
        renderWorking()
        Task {
            do { record(try await Task.detached(operation: work).value) }
            catch { await Dialogs.show(parentWindow, error, heading: "File action failed") }
            workingTitle = nil
            renderWorking()
            reload()
        }
    }

    /// Runs a file change, reloads the folder and reports any failure.
    private func perform(_ change: () throws -> Void) async {
        do { try change() } catch { await Dialogs.show(parentWindow, error, heading: "File action failed") }
        reload()
    }

    // MARK: Transfers

    private var transfersPending = false

    private func scheduleTransfers() {
        guard !transfersPending else { return }
        transfersPending = true
        after(milliseconds: 100) { [weak self] in
            self?.transfersPending = false
            self?.renderTransfers()
        }
    }

    /// Upload and download progress, shown under the file list while there are items.
    private func renderTransfers() {
        guard let model = remoteModel else { return }
        let queue = model.queue
        removeChildren(transfers)
        setVisible(transfers, !queue.items.isEmpty)
        guard !queue.items.isEmpty else { return }
        let heading = label("Transfers")
        setAttributes(heading, weight: 600)
        let clear = button("Clear Finished", classes: ["flat"], hint: "Clear Finished\nRemove completed, failed and cancelled transfers from this list.") {
            queue.clearFinished()
        }
        append(transfers, box(.horizontal, [heading, spacer(), clear]))
        for item in queue.items.suffix(4) {
            let row = box(.horizontal, spacing: 6)
            let icon = image(item.isUpload ? "go-up-symbolic" : "go-down-symbolic")
            hint(icon, item.isUpload ? "Upload from this computer to the remote host." : "Download from the remote host to this computer.")
            let name = label(item.name, ellipsize: PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_set_size_request(name, 140, -1)
            hint(name, item.route)
            append(row, icon, name)
            switch item.state {
            case .failed(let message):
                let text = label(message, classes: ["error-text"], ellipsize: PANGO_ELLIPSIZE_END)
                gtk_widget_set_hexpand(text, 1)
                hint(text, message)
                append(row, text)
                if model.canRetry(item.id) { append(row, retryButton(item.id, model)) }
            case .completed:
                append(row, label("Done", classes: ["dim-label"]))
            case .cancelled:
                append(row, label("Cancelled", classes: ["dim-label"]))
                if model.canRetry(item.id) { append(row, retryButton(item.id, model)) }
            default:
                let bar = gtk_progress_bar_new()!
                gtk_progress_bar_set_fraction(c(bar), item.progressFraction)
                gtk_widget_set_hexpand(bar, 1)
                gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
                hint(bar, formatBytes(item.totalBytes))
                append(row, bar, iconButton("process-stop-symbolic", label: "Cancel",
                                            hint: "Cancel\nStop this transfer and discard the partial copy.") { model.cancelTransfer(item.id) })
            }
            append(transfers, row)
        }
    }

    private func retryButton(_ id: UUID, _ model: RemoteExplorerModel) -> Widget {
        button("Retry", classes: ["flat"], hint: "Retry\nRun this transfer again from the start.") { Task { await model.retryTransfer(id) } }
    }
}

/// Turns Administrator mode on and off for a tab's explorer.
@MainActor
enum AdministratorMode {
    static func enter(_ host: ExplorerHost, parent: Widget?) async {
        guard let state = host.tabState else { return }
        let target: PrivilegedAccess.Target
        let start: String
        if case .remote(let endpoint) = state.endpoint {
            target = .remote(endpoint)
            start = state.remoteDirectory
        } else {
            target = .local
            start = state.directory.path
        }
        let needs = await Task.detached { PrivilegedAccess.needsPassword(target) }.value
        var password: String?
        if needs {
            let message = target == .local
                ? "Enter your password. While Administrator mode is on, the explorer works as root: it can open and change any file."
                : "Enter the sudo password for your account on \(target.label). While Administrator mode is on, the explorer works as root there."
            guard let values = await Dialogs.prompt(parent, "Administrator Mode on \(target.label)", message,
                                                    fields: [Dialogs.Field(label: "Password", secure: true)], ok: "Enter Administrator Mode") else { return }
            let entered = values[0]
            guard await Task.detached(operation: { PrivilegedAccess.check(target, password: entered) }).value else {
                await Dialogs.tell(parent, "Administrator mode isn't available", "That password didn't work, or this account can't use sudo on \(target.label).")
                return
            }
            password = entered
        }
        let typed = password
        do {
            let client = try await Task.detached { try PrivilegedAccess.openSession(target, password: typed) }.value
            let label: String
            switch target {
            case .local: label = "this computer"
            case .remote(let endpoint): label = endpoint.host
            }
            state.adminModel = RemoteExplorerModel(administrator: client, endpoint: RemoteEndpoint(host: label, username: "root"), target: target)
            state.adminTarget = target
            state.adminPath = start
            state.adminHistory = NavigationHistory(start)
            host.rebuild()
        } catch {
            await Dialogs.tell(parent, "Administrator mode isn't available", error.localizedDescription)
        }
    }

    /// Ends the root session; the explorer goes back to the user's own access.
    static func leave(_ host: ExplorerHost) {
        guard let state = host.tabState else { return }
        if state.adminTarget == .local, FileManager.default.isReadableFile(atPath: Host.sandboxPath(state.adminPath)) {
            state.directory = URL(fileURLWithPath: state.adminPath, isDirectory: true)
        } else if case .remote = state.adminTarget {
            state.remoteDirectory = state.adminPath
        }
        state.adminModel = nil
        state.adminTarget = nil
        host.rebuild()
    }
}

// MARK: Feature tests (TestBridge)

extension ExplorerHost {
    var bridgeState: [String: Any] { current?.bridgeState ?? ["shown": false] }
    func bridgeGo(_ path: String) -> Bool { current?.bridgeGo(path) ?? false }
    func bridgeSelect(_ names: [String]) -> [String] { current?.bridgeSelect(names) ?? [] }
    func bridgeDo(_ action: String) -> String { current?.bridgeDo(action) ?? "missing" }
    func bridgeProbe(_ action: String) -> String { current?.bridgeProbe(action) ?? "missing" }
}

extension ExplorerView {
    var bridgeState: [String: Any] {
        ["shown": gtk_widget_get_mapped(view) != 0, "path": path, "items": visible.map { $0.isFolder ? $0.name + "/" : $0.name },
         "selected": selectedNames, "hidden": showHidden, "administrator": isAdministrator, "remote": remoteModel != nil,
         "bookmarked": bookmarks.contains(path),
         "canUndo": actions["undo"] != nil && g_action_group_get_action_enabled(group, "undo") != 0,
         "canRedo": actions["redo"] != nil && g_action_group_get_action_enabled(group, "redo") != 0]
    }
    func bridgeGo(_ target: String) -> Bool { visit(target); return true }
    func bridgeSelect(_ names: [String]) -> [String] { select(Set(names)); return selectedNames }
    func bridgeProbe(_ action: String) -> String {
        if action == "administrator" { return "enabled" }
        guard g_action_group_has_action(group, action) != 0 else { return "missing" }
        return g_action_group_get_action_enabled(group, action) != 0 ? "enabled" : "disabled"
    }
    func bridgeDo(_ action: String) -> String {
        // The lock button: Administrator mode on or off.
        if action == "administrator" { toggleAdministrator(); return "ran" }
        guard g_action_group_has_action(group, action) != 0 else { return "missing" }
        guard g_action_group_get_action_enabled(group, action) != 0 else { return "disabled" }
        g_action_group_activate_action(group, action, nil)
        return "ran"
    }
}
