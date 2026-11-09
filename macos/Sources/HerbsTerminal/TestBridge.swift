import AppKit
import SwiftTerm

/// The feature tests' way into the app (`parity/tests`), the same requests as the Linux and Windows versions
/// take. It runs only in the parity copy (see `ParityScene`) started with `--test-bridge`. The runner writes
/// `request.json` in `<temporary folder>/herbs-parity-app/bridge`; the app answers in `response.json`. The timer
/// runs in the common run-loop modes, so it keeps answering while an alert is up.
@MainActor
enum TestBridge {
    static let isActive = ParityScene.isActive && CommandLine.arguments.contains("--test-bridge")
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herbs-parity-app/bridge").path
    private static var lastID = -1
    private static var busy = false
    /// Set by the window's view: SwiftUI opens new windows only from inside a view.
    static var openWindow: (() -> Void)?

    static func start() {
        guard isActive else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: folder + "/request.json")
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { poll() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func poll() {
        guard !busy, let data = FileManager.default.contents(atPath: folder + "/request.json"),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, id != lastID else { return }
        lastID = id
        busy = true
        defer { busy = false }
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
            FileManager.default.createFile(atPath: temporary, contents: out)
            _ = rename(temporary, folder + "/response.json")
        }
        // Exit here, once answered: a block queued on the main queue can wait for input while an alert is up.
        if quitting { exit(0) }
    }

    private static var quitting = false

    struct Failure: Error, CustomStringConvertible { let description: String }

    private static var workspace: Workspace {
        get throws { guard let workspace = Workspace.all.last else { throw Failure(description: "no window") }; return workspace }
    }

    private static func handle(_ request: [String: Any]) throws -> Any {
        switch request["op"] as? String ?? "" {
        case "state": return state()
        case "command": return try command(request["name"] as? String ?? "", run: true)
        case "probe": return try command(request["name"] as? String ?? "", run: false)
        case "type":
            // As the keyboard does: through the view, so MultiExec forwards it like real typing.
            try workspace.selected.focusedShell.view.send(txt: request["text"] as? String ?? "")
            return true
        case "explorer-go", "explorer-select": return "unsupported"
        case "include":
            let workspace = try workspace
            let shells = workspace.tabs.flatMap(\.shells)
            let number = request["pane"] as? Int ?? 0
            guard shells.indices.contains(number - 1) else { throw Failure(description: "no pane \(number)") }
            workspace.setIncluded(shells[number - 1], request["on"] as? Bool ?? true)
            return true
        case "connect":
            // A login typed into the Connect via SSH dialog, without the dialog.
            let login = SSHLogin(host: request["host"] as? String ?? "", port: request["port"] as? Int ?? 22,
                                 username: request["user"] as? String ?? "", password: request["password"] as? String ?? "")
            try workspace.connectSSH(login)
            return true
        case "answer": return try answer(request)
        case "profile-set":
            let value = request["value"] as? String ?? ""
            let id = try workspace.selected.focusedShell.profileID
            switch request["key"] as? String ?? "" {
            case "startupCommand": TerminalProfile.shared.update(id) { $0.startupCommand = value }
            case "startDirectory": TerminalProfile.shared.update(id) { $0.startDirectory = value }
            default: throw Failure(description: "unknown profile key")
            }
            return true
        case "context-menu":
            // The focused terminal's right-click menu, as it would open now.
            let menu = try workspace.selected.focusedShell.view.contextMenu()
            menu.update()
            return menu.items.filter { !$0.isSeparatorItem }.map { ["title": $0.title, "enabled": $0.isEnabled] as [String: Any] }
        case "context-choose":
            let menu = try workspace.selected.focusedShell.view.contextMenu()
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title == request["title"] as? String }) else { return "missing" }
            guard menu.items[index].isEnabled else { return "disabled" }
            menu.performActionForItem(at: index)
            return "ran"
        case "drop":
            // Files dropped on the focused terminal, through the same code a drop from Finder runs.
            try workspace.selected.focusedShell.view.drop(paths: request["paths"] as? [String] ?? [])
            return true
        case "clipboard": return PrivatePasteboard.contents
        case "clipboard-set":
            // Text, or files as Finder puts them there.
            PrivatePasteboard.board.clearContents()
            if let files = request["files"] as? [String] {
                PrivatePasteboard.board.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
            } else {
                PrivatePasteboard.board.setString(request["text"] as? String ?? "", forType: .string)
            }
            return true
        case "quit":
            quitting = true
            return true
        case "menus": return InWindowMenu.report
        case "shortcut":
            // A key with ⌘ (and any of shift, option, control), sent the way AppKit sends one: through the in-window
            // menus, since the macOS menu bar holds only the app menu.
            let key = request["key"] as? String ?? ""
            let codes: [String: UInt16] = ["t": 17, "k": 40, "d": 2, "s": 1, "n": 45, "0": 29]
            var flags: NSEvent.ModifierFlags = [.command]
            for name in request["modifiers"] as? [String] ?? [] {
                switch name {
                case "shift": flags.insert(.shift)
                case "option": flags.insert(.option)
                case "control": flags.insert(.control)
                default: break
                }
            }
            guard let code = codes[key], let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { throw Failure(description: "unknown key") }
            return InWindowMenu.route(event)
        default: throw Failure(description: "unknown op")
        }
    }

    // MARK: Commands

    /// The shared command names, mapped onto what this version's menu items and buttons run.
    private static func command(_ name: String, run: Bool) throws -> String {
        let workspace = try workspace
        let shell = workspace.selected.focusedShell
        let terminal = workspace.selected.editor == nil
        var actions: [String: () -> Void] = [
            "new-tab": { workspace.add() },
            "new-window": { openWindow?() },
            "connect": { workspace.showingSSHConnect = true },
            // The toolbar's SSH button: connection details while connected, Connect via SSH otherwise.
            "connect-button": { workspace.connectButton() },
            "disconnect": { workspace.disconnect() },
            "export-session": { workspace.exportSession() },
            "take-screenshot": { workspace.takeScreenshot() },
            "split-vertical": { workspace.split(.horizontal) },
            "split-horizontal": { workspace.split(.vertical) },
            "close-pane": { workspace.closePane() },
            "next-pane": { workspace.focusPane(offset: 1) },
            "previous-pane": { workspace.focusPane(offset: -1) },
            "multiexec": { workspace.multiExec.toggle() },
            "run-on-hosts": { workspace.panel = .multiHost },
            "tailcat": { workspace.panel = .tailcat },
            "previous-tab": { workspace.selectTab(offset: -1) },
            "next-tab": { workspace.selectTab(offset: 1) },
            "rename-tab": { workspace.rename(workspace.selected) },
            "move-tab-left": { workspace.moveSelected(by: -1) },
            "move-tab-right": { workspace.moveSelected(by: 1) },
            "close-tab": { workspace.close(workspace.selected) },
            "zoom-in": { workspace.zoom(1) },
            "zoom-out": { workspace.zoom(-1) },
            "zoom-reset": { workspace.resetZoom() },
            "restore-size": { workspace.restoreDefaultSize() },
            "default-size": { workspace.makeCurrentSizeDefault() },
            "fullscreen": { workspace.window?.toggleFullScreen(nil) },
            "settings": { SettingsOpener.open() },
            "about": { AboutPanel.show() },
            "toggle-explorer": { workspace.selected.state.layout = workspace.selected.state.layout == .explorer ? .terminal : .explorer },
            "show-explorer": { workspace.selected.state.layout = .explorer },
            "find": { workspace.selected.state.layout == .explorer ? (workspace.selected.state.explorerFindRequest += 1) : (workspace.selected.state.findRequest += 1) },
            "find-in-terminal": { workspace.selected.state.findRequest += 1 },
            "close-all": { workspace.closeAllTerminals() },
            "restore-theming": { ThemeMenu.restoreDefaults(shell.profileID) },
            "import-preset": { _ = ThemeMenu.importPreset() },
            "secure-keyboard-entry": { SecureInput.shared.enabled.toggle() },
        ]
        if terminal {
            actions["clear-to-start"] = { shell.view.clearToStart() }
            actions["clear-scrollback"] = { shell.view.clearHistory() }
            actions["reset"] = { shell.view.reset(hard: false) }
            actions["hard-reset"] = { shell.view.reset(hard: true) }
            actions["paste-escaped"] = { shell.view.pasteEscaped() }
            actions["copy"] = { shell.view.copy(self) }
            actions["paste"] = { shell.view.paste(self) }
            actions["select-all"] = { shell.view.selectAll(self) }
        }
        for number in 1...9 { actions["tab-\(number)"] = { workspace.selectTab(number: number - 1) } }
        // Menus that pick from a list: present when the list is.
        for name in ["new-tab-profile", "use-profile", "color-scheme", "color-preset"] { actions[name] = {} }
        // The explorer's lock button: Administrator mode on or off.
        actions["explorer.administrator"] = {
            let state = workspace.selected.state
            if state.adminViewModel != nil { AdministratorMode.leave(state) } else { Task { await AdministratorMode.enter(state) } }
        }
        if name.hasPrefix("explorer."), name != "explorer.administrator" { return "unsupported" }
        guard let action = actions[name] else { return "missing" }
        if name == "disconnect", workspace.selected.state.connection == .local { return "disabled" }
        // Run after this request is answered: an alert's modal loop would otherwise hold the answer back.
        if run { DispatchQueue.main.async { action() } }
        return run ? "ran" : "enabled"
    }

    // MARK: Alerts

    private static func openAlerts() -> [(window: NSWindow, heading: String, buttons: [NSButton], fields: [NSTextField])] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Alert") }.map { window in
            let views = allSubviews(window.contentView)
            let labels = views.compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.stringValue.isEmpty }
            // In the order they were added: NSAlert puts the first button rightmost (or on top when stacked).
            let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty && $0.bezelStyle == .push }
                .sorted { a, b in
                    let pa = a.convert(NSPoint.zero, to: nil), pb = b.convert(NSPoint.zero, to: nil)
                    return pa.y != pb.y ? pa.y > pb.y : pa.x > pb.x
                }
            let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
            return (window, labels.first?.stringValue ?? "", buttons, fields)
        }
    }

    private static func allSubviews(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(allSubviews)
    }

    private static func answer(_ request: [String: Any]) throws -> Bool {
        let wanted = request["heading"] as? String
        guard let alert = openAlerts().last(where: { wanted == nil || $0.heading == wanted }) else { throw Failure(description: "no dialog") }
        for (field, value) in zip(alert.fields, request["fields"] as? [String] ?? []) { field.stringValue = value }
        let response = request["response"] as? String ?? ""
        guard let index = alert.buttons.firstIndex(where: { $0.title.caseInsensitiveCompare(response) == .orderedSame }) else {
            throw Failure(description: "no button \(response)")
        }
        // The alert runs modally and this runs inside its loop: end it as that button would.
        if NSApp.modalWindow === alert.window {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        } else {
            alert.buttons[index].performClick(nil)
        }
        return true
    }

    // MARK: State

    private static func state() -> [String: Any] {
        let profile = TerminalProfile.shared
        var toplevels = NSApp.windows.filter(\.isVisible).map(\.title)
        for workspace in Workspace.all {
            if workspace.showingSSHConnect { toplevels.append("Connect via SSH") }
            switch workspace.panel {
            case .tailcat: toplevels.append("Tailcat Peers")
            case .multiHost: toplevels.append("Run Command on Hosts")
            case .connection: toplevels.append("Connection")
            case nil: break
            }
        }
        return [
            "platform": "mac",
            "windows": Workspace.all.map { workspace -> [String: Any] in
                let shells = workspace.tabs.flatMap(\.shells)
                let legend = workspace.selected.focusedShell.legend
                return [
                    "title": legend.title, "subtitle": legend.subtitle, "multiExec": workspace.multiExec,
                    "visible": workspace.window?.isVisible ?? false, "onActiveSpace": workspace.window?.isOnActiveSpace ?? false,
                    
                    "excluded": shells.enumerated().filter { workspace.excludedFromMultiExec.contains($0.element.id) }.map { $0.offset + 1 },
                    "tabs": workspace.tabs.map { tab -> [String: Any] in
                        var entry: [String: Any] = [
                            "name": tab.title, "selected": tab === workspace.selected,
                            "kind": tab.editor == nil ? "terminal" : "editor",
                            "layout": tab.state.layout == .explorer ? "explorer" : "terminal",
                            "panes": tab.shells.map { shell -> [String: Any] in
                                let terminal = shell.view.getTerminal()
                                return ["number": (shells.firstIndex { $0 === shell } ?? -1) + 1, "focused": shell === tab.focusedShell,
                                        "columns": terminal.cols, "rows": terminal.rows, "title": shell.legend.title,
                                        "subtitle": shell.legend.subtitle, "exited": false, "text": Workspace.sessionText(shell),
                                        "fontSize": shell.settings.effectiveSize]
                            },
                        ]
                        entry["connection"] = bridgeConnection(tab.state.connection)
                        let remote: Bool = { if case .remote = tab.state.endpoint { return true }; return false }()
                        entry["explorer"] = ["shown": tab.state.layout == .explorer, "remote": remote,
                                             "administrator": tab.state.adminViewModel != nil,
                                             "path": remote ? tab.state.remoteDirectory : tab.state.directory.path,
                                             "items": [String](), "selected": [String]()] as [String: Any]
                        if let editor = tab.editor { entry["editor"] = ["name": editor.source.name, "edited": editor.isEdited, "text": editor.bridgeText] }
                        return entry
                    },
                ]
            },
            "dialogs": openAlerts().map { ["heading": $0.heading, "responses": $0.buttons.map(\.title), "fields": $0.fields.count] as [String: Any] },
            "toplevels": toplevels,
            "profiles": profile.profiles.map(\.name),
            "presets": ThemeLibrary.shared.allNames,
            "settings": ["windowColumns": profile.windowColumns, "windowRows": profile.windowRows,
                         "askBeforeClosing": profile.askBeforeClosing],
        ]
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
