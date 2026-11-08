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
        case "explorer-select":
            guard let explorer = try workspace.selected.explorer else { throw Failure(description: "no explorer") }
            return explorer.bridgeSelect(request["names"] as? [String] ?? [])
        case "include":
            let workspace = try workspace
            let number = request["pane"] as? Int ?? 0
            guard number >= 1, number <= workspace.allPanes.count else { throw Failure(description: "no pane \(number)") }
            workspace.setIncluded(workspace.allPanes[number - 1], request["on"] as? Bool ?? true)
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

    /// Like `command`, without running it.
    private static func probe(_ name: String) throws -> String {
        let workspace = try workspace
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
                                 "exited": pane.exited, "text": pane.screenText, "fontSize": pane.settings.effectiveSize]
                            },
                        ]
                        if let explorer = tab.explorer { entry["explorer"] = explorer.bridgeState }
                        if let editor = tab.editor { entry["editor"] = ["name": editor.source.name, "edited": editor.isEdited, "text": editor.bridgeText] }
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
