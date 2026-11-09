import CGtk
import CHerb
import Foundation

/// The feature tests' way into the app (`parity/tests`). It runs only in a parity scene started with
/// `--test-bridge`, so the user's own app never listens. The test runner writes a request to
/// `<scene files>/bridge/request.json`; the app answers in `response.json`. A request is one of:
///
/// - `{"op": "state"}`: the windows, tabs, panes (their text, size and focus), explorer, MultiExec and profile;
/// - `{"op": "command", "name": "split-vertical"}`: runs a window, app or explorer command, the same one its
///   menu item or button runs ("explorer.new-folder" for the explorer's);
/// - `{"op": "type", "text": "ls\n"}`: types into the focused terminal as the keyboard does;
/// - `{"op": "explorer-go", "path": "/tmp/x"}`, `{"op": "explorer-select", "names": ["a"]}`;
/// - `{"op": "include", "pane": 2, "on": false}`: a MultiExec checkbox.
@MainActor
enum TestBridge {
    static let isActive = ParityScene.isActive && CommandLine.arguments.contains("--test-bridge")
    static let folder = ParityScene.appFiles + "/bridge"
    private static var lastID = -1

    static func start() {
        guard isActive else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: folder + "/request.json")
        _ = every(milliseconds: 50) { poll(); return true }
    }

    private static func poll() {
        guard let data = FileManager.default.contents(atPath: folder + "/request.json"),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, id != lastID else { return }
        lastID = id
        var response: [String: Any] = ["id": id]
        do {
            response["result"] = try handle(request)
            response["ok"] = true
        } catch {
            response["ok"] = false
            response["error"] = "\(error)"
        }
        if let out = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
            let temporary = folder + "/response.tmp"
            _ = FileManager.default.createFile(atPath: temporary, contents: out)
            _ = rename(temporary, folder + "/response.json")
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private static var workspace: Workspace {
        get throws { guard let workspace = Workspace.all.last else { throw Failure(description: "no window") }; return workspace }
    }

    private static func handle(_ request: [String: Any]) throws -> Any {
        switch request["op"] as? String ?? "" {
        case "state": return state()
        case "command": return try command(request["name"] as? String ?? "")
        case "type":
            let pane = try workspace.selected.focused
            pane.typeAsKeyboard(request["text"] as? String ?? "")
            return true
        case "explorer-go":
            guard let explorer = try workspace.selected.explorer else { throw Failure(description: "no explorer") }
            return explorer.bridgeGo(request["path"] as? String ?? "")
        case "info":
            // The newest Get Info window: edits, then Apply / Revert / Close, then what it shows.
            guard let info = FileInfoWindow.newest, info.bridgeState["open"] as? Bool == true else { return ["open": false] }
            info.bridge(request)
            return info.bridgeState
        case "editor":
            guard let editor = try workspace.selected.editor else { throw Failure(description: "no editor") }
            editor.bridge(request["action"] as? String ?? "", text: request["text"] as? String ?? "")
            return editor.bridgeState
        case "find":
            // Types into the focused terminal's find bar, opening it first.
            try workspace.selected.focused.bridgeFind(request["text"] as? String ?? "")
            return true
        case "explorer-filter":
            guard let explorer = try workspace.selected.explorer else { throw Failure(description: "no explorer") }
            return explorer.bridgeFilter(request["text"] as? String ?? "")
        case "explorer-upload":
            guard let explorer = try workspace.selected.explorer else { throw Failure(description: "no explorer") }
            return explorer.bridgeUpload(request["paths"] as? [String] ?? [])
        case "explorer-download":
            guard let explorer = try workspace.selected.explorer else { throw Failure(description: "no explorer") }
            return explorer.bridgeDownload(into: request["into"] as? String ?? "")
        case "explorer-select":
            guard let explorer = try workspace.selected.explorer else { throw Failure(description: "no explorer") }
            return explorer.bridgeSelect(request["names"] as? [String] ?? [])
        case "include":
            let workspace = try workspace
            let number = request["pane"] as? Int ?? 0
            guard number >= 1, number <= workspace.allPanes.count else { throw Failure(description: "no pane \(number)") }
            workspace.setIncluded(workspace.allPanes[number - 1], request["on"] as? Bool ?? true)
            return true
        case "session-snapshot":
            // Every window as session restore would save it (the parity copy never writes it).
            return try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Workspace.sessionSnapshot))
        case "session-open":
            // Reopens windows from a snapshot, as the next launch would.
            let data = try JSONSerialization.data(withJSONObject: request["windows"] ?? [])
            for window in try JSONDecoder().decode([SavedWindow].self, from: data) { Workspace(restoring: window).present() }
            return true
        case "resize-grid":
            // The window resized to show this grid, as dragging its edge would.
            try workspace.resize(columns: request["columns"] as? Int ?? 80, rows: request["rows"] as? Int ?? 24)
            return true
        case "profile-add":
            // A new named profile (a copy of the default), with a startup command when given; returns its id.
            let profile = TerminalProfile.shared
            let id = profile.addProfile(named: request["name"] as? String ?? "Profile")
            if let command = request["startupCommand"] as? String { profile.update(id) { $0.startupCommand = command } }
            return id.uuidString
        case "profile-new-tab":
            // New Tab with Profile.
            guard let id = (request["profile"] as? String).flatMap(UUID.init(uuidString:)) else { throw Failure(description: "no profile id") }
            try workspace.add(profile: id)
            return true
        case "profile-set":
            // The profile the focused terminal uses; only what tests need.
            let value = request["value"] as? String ?? ""
            let id = try workspace.selected.focused.profileID
            switch request["key"] as? String ?? "" {
            case "startupCommand": TerminalProfile.shared.update(id) { $0.startupCommand = value }
            case "startDirectory": TerminalProfile.shared.update(id) { $0.startDirectory = value }
            default: throw Failure(description: "unknown profile key")
            }
            return true
        case "menus":
            // No system menu bar here; the Main Menu holds every menu, nested.
            guard let model = try workspace.mainMenuModel else { throw Failure(description: "no Main Menu") }
            return ["bar": [String](), "main": menuTree(model)] as [String: Any]
        case "context-menu":
            // The focused terminal's right-click menu, as it would open now.
            let workspace = try workspace
            let menu = workspace.selected.focused.contextMenu()
            defer { g_object_unref(raw(menu)) }
            return menuItems(menu).map { ["title": $0.title, "enabled": actionState(workspace, $0.action) == "enabled"] as [String: Any] }
        case "context-choose":
            let workspace = try workspace
            let menu = workspace.selected.focused.contextMenu()
            defer { g_object_unref(raw(menu)) }
            guard let item = menuItems(menu).first(where: { $0.title == request["title"] as? String }) else { return "missing" }
            guard actionState(workspace, item.action) == "enabled" else { return "disabled" }
            // As a menu item does: the action, found from the terminal up through its window and the app.
            gtk_widget_activate_action_variant(workspace.selected.focused.terminal, item.action, nil)
            return "ran"
        case "drop":
            // Files dropped on the focused terminal, through the same code a drop from a file manager runs.
            try workspace.selected.focused.drop(paths: request["paths"] as? [String] ?? [])
            return true
        case "quit":
            idle { exit(0) }
            return true
        case "probe": return try probe(request["name"] as? String ?? "")
        case "connect":
            // A login typed into the Connect via SSH dialog, without the dialog.
            let login = SSHLogin(host: request["host"] as? String ?? "", port: request["port"] as? Int ?? 22,
                                 username: request["user"] as? String ?? "", password: request["password"] as? String ?? "")
            try workspace.connectSSH(login)
            return true
        case "answer":
            let heading = request["heading"] as? String
            guard let dialog = Dialogs.open.values.first(where: { heading == nil || $0.heading == heading }) else {
                throw Failure(description: "no dialog")
            }
            for (field, value) in zip(dialog.fields, request["fields"] as? [String] ?? []) { setText(field, value) }
            let response = request["response"] as? String ?? ""
            guard dialog.responses.contains(response) else { throw Failure(description: "no response \(response)") }
            herb_alert_respond(dialog.alert, response)
            return true
        default: throw Failure(description: "unknown op")
        }
    }

    /// A menu model's items in order, sections flattened: their labels and actions ("win.copy").
    private static func menuItems(_ model: OpaquePointer) -> [(title: String, action: String)] {
        var items: [(title: String, action: String)] = []
        for index in 0..<g_menu_model_get_n_items(c(model)) {
            if let section = g_menu_model_get_item_link(c(model), index, "section") {
                items += menuItems(c(section))
                g_object_unref(raw(section))
                continue
            }
            func attribute(_ name: String) -> String {
                guard let value = g_menu_model_get_item_attribute_value(c(model), index, name, nil) else { return "" }
                defer { g_variant_unref(value) }
                return String(cString: g_variant_get_string(value, nil))
            }
            items.append((attribute("label"), attribute("action")))
        }
        return items
    }

    /// A menu model's titles with their submenus nested, sections flattened.
    private static func menuTree(_ model: OpaquePointer) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for index in 0..<g_menu_model_get_n_items(c(model)) {
            if let section = g_menu_model_get_item_link(c(model), index, "section") {
                items += menuTree(c(section))
                g_object_unref(raw(section))
                continue
            }
            var item: [String: Any] = [:]
            if let value = g_menu_model_get_item_attribute_value(c(model), index, "label", nil) {
                item["title"] = String(cString: g_variant_get_string(value, nil))
                g_variant_unref(value)
            }
            if let submenu = g_menu_model_get_item_link(c(model), index, "submenu") {
                item["items"] = menuTree(c(submenu))
                g_object_unref(raw(submenu))
            }
            items.append(item)
        }
        return items
    }

    /// "enabled", "disabled" or "missing" for an action named as a menu item names it ("win.copy", "app.settings").
    private static func actionState(_ workspace: Workspace, _ action: String) -> String {
        let parts = action.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "missing" }
        let group: OpaquePointer? = parts[0] == "win" ? OpaquePointer(workspace.window) : parts[0] == "app" ? App.shared.application : nil
        guard let group, g_action_group_has_action(group, parts[1]) != 0 else { return "missing" }
        return g_action_group_get_action_enabled(group, parts[1]) != 0 ? "enabled" : "disabled"
    }

    /// Like `command`, without running it.
    private static func probe(_ name: String) throws -> String {
        let workspace = try workspace
        if name == "connect-button" { return "enabled" }
        if name.hasPrefix("explorer.") {
            guard let explorer = workspace.selected.explorer else { return "missing" }
            return explorer.bridgeProbe(String(name.dropFirst("explorer.".count)))
        }
        let groups: [OpaquePointer?] = [OpaquePointer(workspace.window), App.shared.application]
        for case let actions? in groups where g_action_group_has_action(actions, name) != 0 {
            return g_action_group_get_action_enabled(actions, name) != 0 ? "enabled" : "disabled"
        }
        return "missing"
    }

    /// "missing" when the app has no such command, "disabled" when it's greyed out, else "ran".
    private static func command(_ name: String) throws -> String {
        let workspace = try workspace
        // The toolbar's SSH button: connection details while connected, Connect via SSH otherwise.
        if name == "connect-button" { workspace.connectButton(); return "ran" }
        if name.hasPrefix("explorer.") {
            guard let explorer = workspace.selected.explorer else { return "missing" }
            return explorer.bridgeDo(String(name.dropFirst("explorer.".count)))
        }
        let groups: [OpaquePointer?] = [OpaquePointer(workspace.window), App.shared.application]
        for case let actions? in groups {
            guard g_action_group_has_action(actions, name) != 0 else { continue }
            guard g_action_group_get_action_enabled(actions, name) != 0 else { return "disabled" }
            g_action_group_activate_action(actions, name, nil)
            return "ran"
        }
        return "missing"
    }

    private static func state() -> [String: Any] {
        let profile = TerminalProfile.shared
        return [
            "platform": "linux",
            "windows": Workspace.all.map { workspace -> [String: Any] in
                let panes = workspace.allPanes
                return [
                    "title": workspace.selected.focused.title,
                    "subtitle": workspace.selected.focused.subtitle,
                    "multiExec": workspace.multiExec,
                    "excluded": panes.enumerated().filter { workspace.excludedFromMultiExec.contains($0.element.id) }.map { $0.offset + 1 },
                    "tabs": workspace.tabs.map { tab -> [String: Any] in
                        var entry: [String: Any] = [
                            "name": tab.title, "selected": tab === workspace.selected,
                            "kind": tab.editor == nil ? "terminal" : "editor",
                            "layout": tab.state.layout.rawValue,
                            "panes": tab.panes.map { pane -> [String: Any] in
                                ["number": (panes.firstIndex { $0 === pane } ?? -1) + 1, "focused": pane === tab.focused,
                                 "columns": pane.columns, "rows": pane.rows, "title": pane.title, "subtitle": pane.subtitle,
                                 "exited": pane.exited, "text": pane.screenText, "fontSize": pane.settings.effectiveSize, "find": pane.bridgeFind,
                                 "profile": TerminalProfile.shared.name(of: pane.profileID), "badge": pane.bridgeBadge ?? NSNull()]
                            },
                        ]
                        entry["connection"] = bridgeConnection(tab.state.connection)
                        if let explorer = tab.explorer { entry["explorer"] = explorer.bridgeState }
                        if let editor = tab.editor { entry["editor"] = editor.bridgeState }
                        return entry
                    },
                ]
            },
            "dialogs": Dialogs.open.values.map { ["heading": $0.heading, "responses": $0.responses, "fields": $0.fields.count] as [String: Any] },
            "toplevels": toplevelTitles(),
            "profiles": profile.profiles.map(\.name),
            "presets": ThemeLibrary.shared.allNames,
            "settings": ["windowColumns": profile.windowColumns, "windowRows": profile.windowRows,
                         "appearance": profile.appearance, "askBeforeClosing": profile.askBeforeClosing],
        ]
    }

    /// Titles of the app's shown windows (Settings, Tailcat Peers, Manage Logins…), the main windows included.
    private static func toplevelTitles() -> [String] {
        let list = gtk_window_get_toplevels()
        var titles: [String] = []
        for index in 0..<g_list_model_get_n_items(list) {
            guard let item = g_list_model_get_item(list, index) else { continue }
            let window: UnsafeMutablePointer<GtkWindow> = c(item)
            if gtk_widget_get_visible(c(window)) != 0 { titles.append(string(gtk_window_get_title(window)) ?? "") }
            g_object_unref(item)
        }
        return titles
    }
}

/// A tab's connection for the feature tests: "local", "connecting", "connected" or "failed", and the account.
func bridgeConnection(_ state: ConnectionState) -> [String: Any] {
    switch state {
    case .local: ["state": "local"]
    case .connecting(let endpoint): ["state": "connecting", "account": endpoint.label]
    case .connected(let endpoint): ["state": "connected", "account": endpoint.label]
    case .failed(let reason): ["state": "failed", "reason": reason]
    }
}
