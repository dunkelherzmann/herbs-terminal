import Foundation
import WinSDK

/// The feature tests' way into the app (`parity/tests`), the same requests as the Mac and Linux versions take.
/// It runs only in a parity scene started with `--test-bridge`. The runner writes `request.json` in
/// `%TEMP%\herbs-parity-app\bridge`; the app answers in `response.json`. A thread timer polls it, so it keeps
/// answering while a dialog's own message loop runs.
@MainActor
enum TestBridge {
    static let isActive = ParityScene.isActive && CommandLine.arguments.contains("--test-bridge")
    static var folder: String { ParityScene.appFiles.appendingPathComponent("bridge").path }
    private static var lastID = -1

    static func start() {
        guard isActive else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: folder + "/request.json")
        SetTimer(nil, 0, 50, { _, _, _, _ in MainActor.assumeIsolated { TestBridge.poll() } })
    }

    private static var busy = false
    private static var pending: [String] = []

    private static func poll() {
        // Windows the app didn't make itself (message boxes, system dialogs) go to the test desktop too.
        if TestDesktop.isActive { for window in threadWindows() where IsWindowVisible(window) && GetParent(window) == nil { TestDesktop.place(window) } }
        if !busy, !pending.isEmpty {
            // Not marked busy: a dialog this opens runs its own message loop, and requests answer it from there.
            let name = pending.removeFirst()
            _ = try? command(name, run: true)
            return
        }
        guard !busy, let data = FileManager.default.contents(atPath: folder + "/request.json"),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = request["id"] as? Int, id != lastID else { return }
        lastID = id
        busy = true
        var response: [String: Any] = ["id": id]
        do {
            response["result"] = try handle(request)
            response["ok"] = true
        } catch {
            response["ok"] = false
            response["error"] = "\(error)"
        }
        busy = false
        if let out = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
            let temporary = folder + "/response.tmp", final = folder + "/response.json"
            _ = FileManager.default.createFile(atPath: temporary, contents: out)
            // The runner reads response.json every 50 ms, and Windows refuses to replace a file someone has open:
            // try again for up to two seconds, or the answer is lost and the runner thinks the app quit.
            for _ in 0..<100 {
                if withWide(temporary, { from in withWide(final) { to in MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING)) } }) { break }
                Sleep(20)
            }
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private static var workspace: Workspace {
        get throws { guard let workspace = App.allWorkspaces.last else { throw Failure(description: "no window") }; return workspace }
    }

    private static func handle(_ request: [String: Any]) throws -> Any {
        switch request["op"] as? String ?? "" {
        case "state": return state()
        case "command":
            // Run after this request is answered: a dialog's modal loop would otherwise hold the answer back.
            let name = request["name"] as? String ?? ""
            let result = try command(name, run: false)
            if result == "enabled" { pending.append(name) }
            return result == "enabled" ? "ran" : result
        case "probe": return try command(request["name"] as? String ?? "", run: false)
        case "type":
            let workspace = try workspace
            let text = (request["text"] as? String ?? "")
            if let editor = workspace.activeEditor { editor.type(text) } else { workspace.focusedPane?.send(text) }
            return true
        case "explorer-go":
            guard let explorer = try workspace.activePane?.explorer else { throw Failure(description: "no explorer") }
            explorer.navigate(to: request["path"] as? String ?? "")
            return true
        case "explorer-select":
            guard let explorer = try workspace.activePane?.explorer else { throw Failure(description: "no explorer") }
            explorer.select(names: request["names"] as? [String] ?? [])
            return explorer.bridgeState["selected"] ?? []
        case "connect":
            // A login typed into the Connect via SSH dialog, without the dialog.
            let login = SSHLogin(host: request["host"] as? String ?? "", port: request["port"] as? Int ?? 22,
                                 username: request["user"] as? String ?? "", password: request["password"] as? String ?? "")
            try workspace.connectSSH(login)
            return true
        case "answer": return try answer(request)
        case "profile-set":
            let value = request["value"] as? String ?? ""
            switch request["key"] as? String ?? "" {
            case "startupCommand": TerminalProfile.shared.update(nil) { $0.startupCommand = value }
            case "startDirectory": TerminalProfile.shared.update(nil) { $0.startDirectory = value }
            default: throw Failure(description: "unknown profile key")
            }
            return true
        // The terminal has no right-click menu yet: right-click copies or pastes, as in Windows Terminal.
        case "context-menu", "context-choose": return "missing"
        case "drop":
            // The same WM_DROPFILES message a drop from File Explorer sends the focused terminal.
            guard let pane = try workspace.focusedPane?.hwnd else { throw Failure(description: "no terminal") }
            TestScript.drop(request["paths"] as? [String] ?? [], on: pane)
            return true
        case "clipboard": return TestClipboard.contents
        case "clipboard-set":
            // Text, or files as File Explorer's Copy puts them there.
            TestClipboard.clear()
            if let files = request["files"] as? [String] { TestClipboard.files = (files, false) } else { TestClipboard.text = request["text"] as? String ?? "" }
            return true
        case "include": throw Failure(description: "MultiExec isn't in the Windows version")
        case "quit": PostQuitMessage(0); return true
        default: throw Failure(description: "unknown op")
        }
    }

    // MARK: Commands

    /// The Mac and Linux command names, mapped onto this version's menu commands. Commands this version greys
    /// out report "disabled"; ones it doesn't have at all report "missing".
    private static let menuCommands: [String: MenuCommand] = [
        "new-tab": .newTab, "new-window": .newWindow, "connect": .connect, "find-in-terminal": .findInTerminal,
        "zoom-in": .zoomIn, "zoom-out": .zoomOut, "zoom-reset": .zoomReset, "color-scheme": .schemeSystem,
        "color-preset": .presetBasic, "import-preset": .importPreset, "restore-theming": .restoreTheming,
        "export-session": .exportSession, "split-vertical": .splitVertical, "split-horizontal": .splitHorizontal,
        "close-pane": .closePane, "next-pane": .nextPane, "previous-pane": .previousPane, "multiexec": .multiExec,
        "run-on-hosts": .runOnHosts, "disconnect": .disconnect, "previous-tab": .previousTab, "next-tab": .nextTab,
        "rename-tab": .renameTab, "move-tab-left": .moveTabLeft, "move-tab-right": .moveTabRight,
        "clear-to-start": .clearToStart, "clear-scrollback": .clearScrollback, "reset": .reset, "hard-reset": .hardReset,
        "fullscreen": .fullScreen, "settings": .settings, "about": .about, "restore-size": .restoreDefaultSize,
        "default-size": .makeSizeDefault, "close-tab": .closeTab, "take-screenshot": .takeScreenshot,
    ]
    private static let greyedOut: Set<MenuCommand> = [.findInTerminal, .multiExec, .runOnHosts]
    private static let explorerCommands: [String: String] = [
        "cut": "cut", "copy": "copy", "paste": "paste", "delete": "delete", "new-folder": "newFolder", "new-file": "newFile",
        "select-all": "selectAll", "open": "open", "edit": "edit", "info": "info", "reveal": "reveal", "open-default": "openWith",
        "administrator": "toggleAdmin", "undo": "undo", "redo": "redo", "bookmark-selected": "bookmarkSelected",
    ]

    private static func command(_ name: String, run: Bool) throws -> String {
        let workspace = try workspace
        if name.hasPrefix("explorer.") {
            guard let explorer = workspace.activePane?.explorer else { return "missing" }
            guard let named = explorerCommands[String(name.dropFirst("explorer.".count))] else { return "missing" }
            if run { _ = explorer.perform(named: named) }
            return run ? "ran" : "enabled"
        }
        if name.hasPrefix("tab-"), let number = Int(name.dropFirst(4)), (1...9).contains(number) {
            let count = workspace.tabNames.count
            if run { workspace.perform(MenuCommand.firstTab + UINT(number == 9 ? count - 1 : min(number - 1, count - 1))) }
            return run ? "ran" : "enabled"
        }
        switch name {
        case "connect-button":
            // The toolbar's SSH button: connection details while connected, Connect via SSH otherwise.
            if run { workspace.connectButton() }
            return run ? "ran" : "enabled"
        case "toggle-explorer", "show-explorer":
            if run { workspace.toggleExplorer() }
            return run ? "ran" : "enabled"
        case "new-tab-profile", "use-profile": return "disabled"
        case "copy", "paste", "select-all":
            if run {
                if name == "paste" { workspace.focusedPane?.paste() } else if name == "copy" { workspace.focusedPane?.copySelection() }
            }
            return name == "select-all" ? "missing" : (run ? "ran" : "enabled")
        default: break
        }
        guard let command = menuCommands[name] else { return "missing" }
        if greyedOut.contains(command) { return "disabled" }
        if run { workspace.perform(command.rawValue) }
        return run ? "ran" : "enabled"
    }

    // MARK: Dialogs

    /// The app's own forms and the system message boxes on screen.
    private static func openDialogs() -> [(hwnd: HWND, heading: String, buttons: [String], fields: Int, form: FormDialog?)] {
        var found: [(HWND, String, [String], Int, FormDialog?)] = []
        for window in threadWindows() where IsWindowVisible(window) {
            let className = windowClass(window)
            if let form = FormDialog.current, form.window == window {
                found.append((window, windowText(window), form.buttonTitles, form.fieldCount, form))
            } else if className == "#32770" {
                let buttons = children(of: window).filter { windowClass($0) == "Button" }.map { windowText($0).replacingOccurrences(of: "&", with: "") }
                found.append((window, windowText(window), buttons, 0, nil))
            }
        }
        return found
    }

    private static func answer(_ request: [String: Any]) throws -> Bool {
        let wanted = request["heading"] as? String
        guard let dialog = openDialogs().last(where: { wanted == nil || $0.heading == wanted }) else { throw Failure(description: "no dialog") }
        let response = request["response"] as? String ?? ""
        guard let index = dialog.buttons.firstIndex(where: { $0.caseInsensitiveCompare(response) == .orderedSame }) else {
            throw Failure(description: "no button \(response)")
        }
        if let form = dialog.form {
            form.scripted(values: request["fields"] as? [String] ?? [], button: index)
        } else if let button = children(of: dialog.hwnd).filter({ windowClass($0) == "Button" })[safe: index] {
            PostMessageW(button, UINT(BM_CLICK), 0, 0)
        }
        return true
    }

    private static func threadWindows() -> [HWND] {
        var list: [HWND] = []
        withUnsafeMutablePointer(to: &list) { pointer in
            _ = EnumThreadWindows(GetCurrentThreadId(), { window, parameter in
                UnsafeMutablePointer<[HWND]>(bitPattern: Int(parameter))?.pointee.append(window!)
                return true
            }, LPARAM(Int(bitPattern: pointer)))
        }
        return list
    }

    private static func children(of window: HWND) -> [HWND] {
        var list: [HWND] = []
        withUnsafeMutablePointer(to: &list) { pointer in
            _ = EnumChildWindows(window, { child, parameter in
                UnsafeMutablePointer<[HWND]>(bitPattern: Int(parameter))?.pointee.append(child!)
                return true
            }, LPARAM(Int(bitPattern: pointer)))
        }
        return list
    }

    private static func windowText(_ window: HWND) -> String {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let count = GetWindowTextW(window, &buffer, 512)
        return String(decoding: buffer[0..<Int(count)], as: UTF16.self)
    }

    private static func windowClass(_ window: HWND) -> String {
        var buffer = [WCHAR](repeating: 0, count: 256)
        let count = GetClassNameW(window, &buffer, 256)
        return String(decoding: buffer[0..<Int(count)], as: UTF16.self)
    }

    // MARK: State

    private static func state() -> [String: Any] {
        let profile = TerminalProfile.shared
        let settings = profile.settings(for: nil)
        return [
            "platform": "windows",
            "testDesktop": ["active": TestDesktop.isActive, "moved": TestDesktop.moved, "failed": TestDesktop.failed],
            "windows": App.allWorkspaces.map { workspace -> [String: Any] in
                var number = 0
                let tabs = workspace.allTabs.enumerated().map { index, tab -> [String: Any] in
                    var entry: [String: Any] = ["name": tab.tabName, "selected": index == workspace.activeIndex]
                    if let pane = tab as? TerminalPane {
                        entry["kind"] = "terminal"
                        entry["layout"] = pane.showingExplorer ? "explorer" : "terminal"
                        // Every pane of the tab, numbered across the window as on the Mac and Linux.
                        let focused = pane.group?.focused ?? pane
                        entry["panes"] = (pane.group?.panes ?? [pane]).map { shell -> [String: Any] in
                            number += 1
                            return ["number": number, "focused": shell === focused, "columns": shell.terminal.cols, "rows": shell.terminal.rows,
                                    "title": shell.title, "subtitle": shell.subtitle, "exited": !shell.isRunning, "text": shell.exportText(),
                                    "fontSize": settings.effectiveSize]
                        }
                        // A tab's connection, as the Mac and Linux report it.
                        if let remote = pane.remote {
                            entry["connection"] = pane.isConnected ? ["state": "connected", "account": remote.label]
                                : pane.isRunning ? ["state": "connecting", "account": remote.label] : ["state": "failed", "account": remote.label]
                        } else {
                            entry["connection"] = ["state": "local"]
                        }
                        if let explorer = pane.explorer { entry["explorer"] = explorer.bridgeState }
                    } else if let editor = tab as? TextEditorPane {
                        entry["kind"] = "editor"
                        entry["layout"] = "editor"
                        entry["panes"] = [[String: Any]]()
                        entry["editor"] = ["name": tab.tabName, "edited": tab.title.hasPrefix("•"), "text": editor.bridgeText]
                    }
                    return entry
                }
                let active = workspace.focusedPane
                return ["title": active?.title ?? "", "subtitle": active?.subtitle ?? "", "multiExec": false, "excluded": [Int](), "tabs": tabs]
            },
            "dialogs": openDialogs().map { ["heading": $0.heading, "responses": $0.buttons, "fields": $0.fields] as [String: Any] },
            "toplevels": threadWindows().filter { IsWindowVisible($0) }.map(windowText),
            "profiles": profile.profiles.map(\.name),
            "presets": ThemeLibrary.shared.allNames,
            "settings": ["windowColumns": profile.windowColumns, "windowRows": profile.windowRows,
                         "appearance": profile.appearance, "askBeforeClosing": profile.askBeforeClosing],
        ]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
