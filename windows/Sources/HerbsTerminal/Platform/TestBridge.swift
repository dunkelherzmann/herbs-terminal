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
            // Written with a handle no child process can inherit (Foundation's would be, by any process started
            // meanwhile, and the answer would stay locked in the temporary file).
            let file = withWide(temporary) {
                CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard let file, file != INVALID_HANDLE_VALUE else { return }
            var written: DWORD = 0
            out.withUnsafeBytes { _ = WriteFile(file, $0.baseAddress, DWORD($0.count), &written, nil) }
            CloseHandle(file)
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
            if let editor = workspace.activeEditor { editor.type(text) } else { workspace.focusedPane?.type(text) }
            return true
        case "explorer-go":
            guard let explorer = try workspace.activePane?.explorer else { throw Failure(description: "no explorer") }
            explorer.navigate(to: request["path"] as? String ?? "")
            return true
        case "explorer-filter":
            // Types into the explorer's Find field (opening it first).
            guard let explorer = try workspace.activePane?.explorer else { throw Failure(description: "no explorer") }
            _ = explorer.perform(named: "filter=" + (request["text"] as? String ?? ""))
            return explorer.bridgeState["items"] ?? []
        case "info":
            // The Get Info window on top: edits, then Apply / Revert / Close, then what it shows.
            guard let info = GetInfoWindow.current else { return ["open": false] }
            info.bridge(request)
            return info.bridgeState
        case "editor":
            guard let editor = try workspace.activeEditor else { throw Failure(description: "no editor") }
            editor.bridge(request["action"] as? String ?? "", text: request["text"] as? String ?? "")
            return editor.bridgeState
        case "explorer-upload":
            // Upload with the files given instead of picked in the open dialog.
            guard let explorer = try workspace.activePane?.explorer, explorer.isRemote else { throw Failure(description: "no host explorer") }
            return explorer.perform(named: "upload=" + (request["paths"] as? [String] ?? []).joined(separator: "|"))
        case "explorer-download":
            // Download the selection into the folder given instead of picked in the folder dialog.
            guard let explorer = try workspace.activePane?.explorer, explorer.isRemote else { throw Failure(description: "no host explorer") }
            return explorer.perform(named: "download=" + (request["into"] as? String ?? ""))
        case "explorer-rename":
            // Types the new name into the in-place edit box Rename opened, and presses Return.
            guard let explorer = try workspace.activePane?.explorer else { throw Failure(description: "no explorer") }
            guard explorer.perform(named: "rename=" + (request["name"] as? String ?? "")) else { throw Failure(description: "not renaming") }
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
            // The focused terminal's profile, as on the Mac and Linux.
            case "startupCommand": try TerminalProfile.shared.update(workspace.focusedPane?.profileID) { $0.startupCommand = value }
            case "startDirectory": try TerminalProfile.shared.update(workspace.focusedPane?.profileID) { $0.startDirectory = value }
            case "bell":
                guard let bell = TerminalBell(rawValue: value) else { throw Failure(description: "unknown bell") }
                try TerminalProfile.shared.update(workspace.focusedPane?.profileID) { $0.bell = bell }
            default: throw Failure(description: "unknown profile key")
            }
            return true
        case "tailcat-state":
            guard let window = TailcatPeersWindow.open else { throw Failure(description: "the Tailcat Peers window isn't open") }
            return window.bridgeState
        case "tailcat-share":
            TailcatShare.shared.start(persistent: request["persistent"] as? Bool ?? false)
            return true
        case "tailcat-stop":
            TailcatShare.shared.stop()
            return true
        case "tailcat-add":
            guard let window = TailcatPeersWindow.open else { throw Failure(description: "the Tailcat Peers window isn't open") }
            return window.addPeer(name: request["name"] as? String ?? "", username: request["username"] as? String ?? "",
                                  address: request["address"] as? String ?? "", persistent: request["persistent"] as? Bool ?? false)
        case "tailcat-ping", "tailcat-connect", "tailcat-remove":
            guard let peer = TailcatPeerStore.shared.peers.first(where: { $0.name == request["name"] as? String }) else { throw Failure(description: "no such peer") }
            switch request["op"] as? String {
            case "tailcat-ping": TailcatPeerStore.shared.ping(peer)
            case "tailcat-connect": try workspace.connect(TailcatPeerStore.shared.endpoint(for: peer), password: nil)
            default: try TailcatPeerStore.shared.remove(peer)
            }
            return true
        case "session-snapshot":
            // Every window as session restore would save it (the parity copy never writes it).
            let data = try JSONEncoder().encode(App.allWorkspaces.map(\.savedWindow))
            return try JSONSerialization.jsonObject(with: data)
        case "session-open":
            // Reopens windows from a snapshot, as the next launch would.
            let data = try JSONSerialization.data(withJSONObject: request["windows"] ?? [])
            for window in try JSONDecoder().decode([SavedWindow].self, from: data) { App.newWindow(restoring: window) }
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
            guard let id = (request["profile"] as? String).flatMap(Foundation.UUID.init(uuidString:)) else { throw Failure(description: "no profile id") }
            try workspace.newTab(profile: id)
            return true
        case "find":
            guard let pane = try workspace.focusedPane else { throw Failure(description: "no terminal") }
            pane.bridgeFind(request["text"] as? String ?? "")
            return true
        case "find-step":
            guard let pane = try workspace.focusedPane else { throw Failure(description: "no terminal") }
            pane.bridgeFindStep(up: request["up"] as? Bool ?? true)
            return true
        case "menus":
            // No system menu bar here; the Main Menu holds every menu, nested.
            return ["bar": [String](), "main": MainMenu.outline(for: try workspace)] as [String: Any]
        case "context-menu":
            // The focused terminal's right-click menu, as it would open now.
            guard let pane = try workspace.focusedPane else { throw Failure(description: "no terminal") }
            return try workspace.contextMenuEntries(for: pane).compactMap { $0 }.map {
                ["title": String($0.title.split(separator: "\t").first ?? ""), "enabled": $0.enabled] as [String: Any]
            }
        case "context-choose":
            guard let pane = try workspace.focusedPane else { throw Failure(description: "no terminal") }
            let wanted = request["title"] as? String
            guard let entry = try workspace.contextMenuEntries(for: pane).compactMap({ $0 })
                .first(where: { String($0.title.split(separator: "\t").first ?? "") == wanted }) else { return "missing" }
            guard entry.enabled else { return "disabled" }
            // After this answer, as a click on the item would, since some items open dialogs.
            pending.append("menu:\(entry.command.rawValue)")
            return "ran"
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
        case "hosts-run":
            // Run Command on Hosts, as ticking hosts, typing the command and pressing Run would.
            guard let window = RunOnHostsWindow.open else { throw Failure(description: "the Run Command on Hosts window isn't open") }
            window.bridgeRun(hosts: request["hosts"] as? [String] ?? [], command: request["command"] as? String ?? "")
            return true
        case "hosts-state":
            guard let window = RunOnHostsWindow.open else { throw Failure(description: "the Run Command on Hosts window isn't open") }
            return window.bridgeState
        case "include":
            try workspace.setIncluded(number: request["pane"] as? Int ?? 0, request["on"] as? Bool ?? true)
            return true
        case "mouse":
            // Real mouse messages to the focused terminal, at the middle of a cell (column and row from 0).
            guard let pane = try workspace.focusedPane, let hwnd = pane.hwnd else { throw Failure(description: "no terminal") }
            let point = pane.cellCenter(column: request["column"] as? Int ?? 0, row: request["row"] as? Int ?? 0)
            var keys = [UInt8](repeating: 0, count: 256), saved = [UInt8](repeating: 0, count: 256)
            GetKeyboardState(&saved)
            keys = saved
            if request["shift"] as? Bool == true { keys[Int(VK_SHIFT)] = 0x80 }
            SetKeyboardState(&keys)
            defer { SetKeyboardState(&saved) }
            let position = LPARAM(Int(UInt16(bitPattern: Int16(clamping: point.x))) | Int(UInt16(bitPattern: Int16(clamping: point.y))) << 16)
            switch request["kind"] as? String ?? "" {
            case "down": SendMessageW(hwnd, UINT(WM_LBUTTONDOWN), WPARAM(MK_LBUTTON), position)
            case "up": SendMessageW(hwnd, UINT(WM_LBUTTONUP), 0, position)
            case "move": SendMessageW(hwnd, UINT(WM_MOUSEMOVE), request["held"] as? Bool == true ? WPARAM(MK_LBUTTON) : 0, position)
            case "wheel":
                var screen = point
                ClientToScreen(hwnd, &screen)
                let delta = (request["delta"] as? Int ?? 120) & 0xFFFF
                let screenPosition = LPARAM(Int(UInt16(bitPattern: Int16(clamping: screen.x))) | Int(UInt16(bitPattern: Int16(clamping: screen.y))) << 16)
                SendMessageW(hwnd, UINT(WM_MOUSEWHEEL), WPARAM(delta << 16), screenPosition)
            default: throw Failure(description: "unknown mouse kind")
            }
            return ["reports": pane.reportsMouse, "selection": pane.bridgeSelection]
        case "ime":
            // What an input method does: start composing (the app places its window), then type the result.
            guard let pane = try workspace.focusedPane, let hwnd = pane.hwnd else { throw Failure(description: "no terminal") }
            SendMessageW(hwnd, UINT(WM_IME_STARTCOMPOSITION), 0, 0)
            let place = pane.inputMethodPlace()
            SendMessageW(hwnd, UINT(WM_IME_ENDCOMPOSITION), 0, 0)
            for unit in (request["text"] as? String ?? "").utf16 { SendMessageW(hwnd, UINT(WM_IME_CHAR), WPARAM(unit), 1) }
            guard let place else { return ["window": NSNull()] }
            return ["window": [place.window.x, place.window.y], "cursor": [place.cursor.x, place.cursor.y]]
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
    private static let greyedOut: Set<MenuCommand> = []
    private static let explorerCommands: [String: String] = [
        "cut": "cut", "copy": "copy", "paste": "paste", "delete": "delete", "new-folder": "newFolder", "new-file": "newFile",
        "select-all": "selectAll", "open": "open", "edit": "edit", "info": "info", "reveal": "reveal", "open-default": "openWith",
        "administrator": "toggleAdmin", "undo": "undo", "redo": "redo", "bookmark-selected": "bookmarkSelected", "find": "find", "rename": "rename", "upload": "upload", "download": "download",
    ]

    private static func command(_ name: String, run: Bool) throws -> String {
        let workspace = try workspace
        if name.hasPrefix("explorer.") {
            guard let explorer = workspace.activePane?.explorer else { return "missing" }
            guard let named = explorerCommands[String(name.dropFirst("explorer.".count))] else { return "missing" }
            if ["upload", "download"].contains(named), !explorer.isRemote { return "disabled" }
            if run { _ = explorer.perform(named: named) }
            return run ? "ran" : "enabled"
        }
        if name.hasPrefix("menu:"), let id = UINT(name.dropFirst(5)) {
            if run { workspace.perform(id) }
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
        case "tailcat":
            // The toolbar's Tailcat Peers.
            if run { TailcatPeersWindow.show(owner: workspace.hwnd, workspace: workspace) }
            return run ? "ran" : "enabled"
        case "find":
            // The toolbar's Search: Find in the explorer while it shows, the terminal's find bar otherwise.
            if run { workspace.perform(MenuCommand.findInTerminal.rawValue) }
            return run ? "ran" : "enabled"
        case "close-all":
            // MultiExec ▸ Close All (it asks first).
            if run { workspace.closeAllTerminals() }
            return run ? "ran" : "enabled"
        case "toggle-explorer", "show-explorer":
            if run { workspace.toggleExplorer() }
            return run ? "ran" : "enabled"
        case "new-tab-profile", "use-profile":
            // Submenus of profiles; the feature tests choose one with profile-new-tab.
            if run && name == "new-tab-profile" { workspace.newTab() }
            return run ? "ran" : "enabled"
        case "copy", "paste", "select-all", "paste-escaped":
            let command: MenuCommand = name == "copy" ? .copy : name == "paste" ? .paste : name == "select-all" ? .selectAll : .pasteEscaped
            if run { workspace.perform(command.rawValue) }
            return run ? "ran" : "enabled"
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
                                    "fontSize": TerminalProfile.shared.settings(for: shell.profileID).effectiveSize,
                                    "profile": TerminalProfile.shared.name(of: shell.profileID), "selection": shell.bridgeSelection,
                                    "badge": shell.showingBadge ? shell.badgeText : NSNull(),
                                    "find": ["shown": shell.isFinding, "text": shell.findText, "matches": shell.findMatchCount],
                                    "bellFlashes": shell.bellFlashes, "announcement": shell.lastAnnouncement ?? NSNull()]
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
                        entry["editor"] = editor.bridgeState
                    }
                    return entry
                }
                let active = workspace.focusedPane
                return ["title": active?.title ?? "", "subtitle": active?.subtitle ?? "", "multiExec": workspace.multiExec,
                        "excluded": workspace.excludedNumbers, "tabs": tabs]
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
