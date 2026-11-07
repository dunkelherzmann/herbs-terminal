import CGtk
import CHerb
import Foundation

/// Tailcat Peers: pair with machines that can't reach each other by IP, ping them, connect to them, and share this
/// computer's SSH service. Nothing typed but not added is kept: the window starts empty each time it opens.
@MainActor
final class TailcatWindow {
    private let window: ToolWindow
    private weak var workspace: Workspace?
    private let store = TailcatPeerStore.shared
    private let share = TailcatShare.shared
    private let peers = box(.vertical, spacing: 8)
    private let error = label("", classes: ["caption", "error-text"], wrap: true)
    private let shareBox = box(.vertical, spacing: 6)
    private let name = entry(placeholder: "Name")
    private let username = entry(placeholder: "Username")
    private let address = entry(placeholder: "Tailcat address", password: true)
    private var persistent = false
    private var sharePersistent = false
    private var tokens: [ObservationToken] = []
    private let lockButton: Widget

    static func show(_ workspace: Workspace) {
        let peers = TailcatWindow(workspace)
        peers.window.owner = peers
        peers.window.present()
    }

    private init(_ workspace: Workspace) {
        self.workspace = workspace
        window = ToolWindow(title: "Tailcat Peers", width: 620, parent: workspace.window)
        let content = box(.vertical, spacing: 12)
        margins(content, 20)
        append(content, label("Tailcat Peers", classes: ["heading-text"]))
        if Tailcat.executable == nil {
            append(content, label("This build is missing its bundled tailcat helper; rebuild Herb's Terminal with script/build_flatpak.sh.", classes: ["error-text"], wrap: true))
        }
        append(content, label("Reach machines that can't see each other by IP. Each peer runs `tailcat serve 22`; paste the address it prints. Addresses are secrets; they are encrypted with your Administrator Password when one is set.",
                              classes: ["caption", "dim-label"], wrap: true))
        append(content, peers, error)

        hint(name, "Name\nHow this peer appears in Herb's Terminal.")
        hint(username, "Username\nThe SSH account to sign in as on the peer.")
        hint(address, "Tailcat address\nThe secret address the peer's `tailcat serve` printed.")
        accessibleLabel(name, "Name")
        accessibleLabel(username, "Username")
        accessibleLabel(address, "Tailcat address")
        gtk_editable_set_width_chars(c(name), 14)
        gtk_editable_set_width_chars(c(username), 12)
        gtk_widget_set_hexpand(address, 1)
        let kind = segmented(["One-time", "Persistent"], selected: 0) { [weak self] index in self?.persistent = index == 1 }
        hint(kind, "Pairing type\nOne-time: the address dies when its server stops. Persistent: the peer keeps a saved server key.")
        let add = button("Add Peer", hint: "Add Peer\nSave this peer so you can ping and connect to it.") { [weak self] in self?.addPeer() }
        let accept = box(.vertical, spacing: 8, [box(.horizontal, spacing: 8, [name, username, address]), box(.horizontal, spacing: 8, [kind, spacer(), add])])
        append(content, group("Accept a pairing", accept), group("Share this computer", shareBox))
        let done = button("Done", hint: "Done (Esc)\nClose this panel. Sharing keeps running until you stop it or quit Herb's Terminal.") { [weak self] in self?.window.close() }
        // Bottom left, opposite Done: locks or unlocks the safe storage of Tailcat addresses (and saved logins).
        lockButton = gtk_button_new()!
        on(lockButton, "clicked") { [weak self] _ in
            guard let self, let store = CredentialStore.shared else { return }
            Task { await LoginVaultPrompts.manage(store, parent: self.window.window) }
        }
        append(content, box(.horizontal, spacing: 8, [lockButton, spacer(), done]))
        append(window.content, content)
        tokens.append(store.objectWillChange.observe { [weak self] in self?.refresh() })
        tokens.append(share.objectWillChange.observe { [weak self] in self?.refresh() })
        if let vault = CredentialStore.shared { tokens.append(vault.objectWillChange.observe { [weak self] in self?.updateLock() }) }
        updateLock()
        refresh()
    }

    private func group(_ title: String, _ child: Widget) -> Widget {
        let frame = gtk_frame_new(title)!
        margins(child, 8)
        gtk_frame_set_child(c(frame), child)
        return frame
    }

    private func segmented(_ titles: [String], selected: Int, _ changed: @escaping @MainActor (Int) -> Void) -> Widget {
        let row = box(.horizontal, classes: ["linked"])
        var first: Widget?
        for (index, title) in titles.enumerated() {
            let toggle = gtk_toggle_button_new_with_label(title)!
            if let first { gtk_toggle_button_set_group(c(toggle), c(first)) } else { first = toggle }
            if index == selected { gtk_toggle_button_set_active(c(toggle), 1) }
            on(toggle, "toggled") { _ in if gtk_toggle_button_get_active(c(toggle)) != 0 { changed(index) } }
            append(row, toggle)
        }
        return row
    }

    private func addPeer() {
        do {
            try store.add(name: text(of: name), username: text(of: username), address: text(of: address), persistent: persistent)
            [name, username, address].forEach { setText($0, "") }
            store.error = nil
        } catch { store.error = error.localizedDescription }
    }

    private func refresh() {
        removeChildren(peers)
        if store.peers.isEmpty { append(peers, label("No peers yet.", classes: ["dim-label"])) }
        for peer in store.peers {
            let title = label("\(peer.username)@\(peer.name)")
            setAttributes(title, weight: 600)
            let detail = label((peer.persistent ? "Persistent" : "One-time") + " · " + routeText(store.routes[peer.id] ?? .unknown), classes: ["caption", "dim-label"])
            let text = box(.vertical, [title, detail])
            gtk_widget_set_hexpand(text, 1)
            let ping = button("Ping", hint: "Ping\nCheck the peer is reachable and whether the route is Direct or Relayed.") { [weak self] in
                Task { await self?.store.ping(peer) }
            }
            let connect = button("Connect", hint: "Connect\nOpen an SSH shell to this peer in the current tab; the explorer follows it.") { [weak self] in
                guard let self else { return }
                do {
                    self.workspace?.connect(try self.store.endpoint(for: peer), password: nil)
                    self.window.close()
                } catch { self.store.error = error.localizedDescription }
            }
            let remove = button("Remove", classes: ["destructive-action"],
                                hint: "Remove\nForget this peer and its address here. Stop or re-key the peer's server to revoke it there too.") { [weak self] in
                do { try self?.store.remove(peer) } catch { self?.store.error = error.localizedDescription }
            }
            append(peers, box(.horizontal, spacing: 8, [image("ht-peers-symbolic"), text, ping, connect, remove]))
        }
        setLabel(error, store.error ?? "")

        removeChildren(shareBox)
        if let shared = share.address {
            append(shareBox, label("Sharing SSH \(share.persistent ? "persistently" : "one-time"). Give this secret address only to the peer:", classes: ["caption", "dim-label"], wrap: true))
            let value = label(shared, classes: ["monospace-text", "caption"], selectable: true, ellipsize: PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_set_hexpand(value, 1)
            append(shareBox, box(.horizontal, spacing: 8, [
                value,
                button("Copy", hint: "Copy\nCopy the address to send to your peer over a private channel.") { setClipboardText(shared) },
                button("Stop Sharing", hint: "Stop Sharing\nShut down this computer's tailcat server; peers can no longer connect.") { [weak self] in self?.share.stop() },
            ]))
        } else {
            let kind = segmented(["One-time", "Persistent"], selected: sharePersistent ? 1 : 0) { [weak self] index in self?.sharePersistent = index == 1 }
            hint(kind, "Sharing type\nOne-time uses a fresh key; persistent keeps the same address across restarts.")
            let start = button("Start Sharing", hint: "Start Sharing\nRun a tailcat server for this computer's port 22. Needs the SSH server (sshd) running.") { [weak self] in
                guard let self else { return }
                Task { await self.share.start(persistent: self.sharePersistent) }
            }
            enable(start, Tailcat.executable != nil && !share.starting)
            let row = box(.horizontal, spacing: 8, [kind, spacer()])
            if share.starting { let spinner = gtk_spinner_new()!; gtk_spinner_start(c(spinner)); append(row, spinner) }
            append(row, start)
            append(shareBox, row)
        }
        if let problem = share.error { append(shareBox, label(problem, classes: ["caption", "error-text"], wrap: true)) }
    }

    /// Unlock… or Lock…, as a click would do, with a matching padlock.
    private func updateLock() {
        let store = CredentialStore.shared
        let locked = store?.isLocked ?? false
        gtk_button_set_child(c(lockButton), box(.horizontal, spacing: 6, [image(locked ? "changes-prevent-symbolic" : "changes-allow-symbolic"),
                                                                       label(locked ? "Unlock…" : "Lock…")]))
        accessibleLabel(lockButton, locked ? "Unlock Saved Logins" : "Lock Saved Logins")
        enable(lockButton, store != nil && CredentialStore.unavailableReason == nil)
        hint(lockButton, store?.protection == .adminPassword
             ? (locked ? "Unlock\nUnlock the safe storage of Tailcat addresses and saved logins with the Administrator Password, or change the password."
                       : "Lock\nLock the safe storage of Tailcat addresses and saved logins until the Administrator Password is entered again, or change the password.")
             : "Lock\nTailcat addresses and saved logins are stored as plain text. Create an Administrator Password to lock them.")
    }

    private func routeText(_ route: TailcatRoute) -> String {
        switch route {
        case .unknown: "Route not checked"
        case .checking: "Checking route…"
        case .direct(let detail): "Direct · \(detail)"
        case .relayed(let detail): "Relayed · \(detail)"
        case .unreachable(let reason): "Unreachable · \(reason)"
        }
    }
}

/// Run Command on Hosts: one command on several machines at once, without typing into any session.
@MainActor
final class MultiHostWindow {
    private let window: ToolWindow
    private let model: MultiHostModel
    private let targets: [HostTarget]
    private let command: Widget
    private let summary = label("", classes: ["caption", "dim-label"], wrap: true)
    private let results = box(.vertical, spacing: 10)
    private let resultsScroll: Widget
    private let spinner = gtk_spinner_new()!
    private let stop: Widget
    private let run: Widget
    private var token: ObservationToken?

    static func show(_ workspace: Workspace) {
        let hosts = MultiHostWindow(workspace)
        hosts.window.owner = hosts
        hosts.window.present()
    }

    private init(_ workspace: Workspace) {
        model = workspace.multiHost
        targets = workspace.hostTargets
        window = ToolWindow(title: "Run Command on Hosts", width: 580, parent: workspace.window)
        command = gtk_text_view_new()!
        gtk_text_view_set_monospace(c(command), 1)
        gtk_text_view_set_wrap_mode(c(command), GTK_WRAP_WORD_CHAR)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(c(command)), model.command, -1)
        resultsScroll = scrolled(results)
        gtk_widget_set_size_request(resultsScroll, -1, 220)
        stop = button("Stop", hint: "Stop\nEnd the command on hosts that are still running it.") { [weak workspace] in workspace?.multiHost.cancel() }
        run = button("Run", classes: ["suggested-action"], hint: "Run (Return)\nSend the command to every selected host at once.") { _ = () }
        build(workspace)
        token = model.objectWillChange.observe { [weak self] in self?.refresh() }
        refresh()
    }

    private var chosen: [HostTarget] { targets.filter { model.selected.contains($0.id) } }

    private func build(_ workspace: Workspace) {
        let content = box(.vertical, spacing: 12)
        margins(content, 20)
        append(content, label("Multi-Host Commands", classes: ["heading-text"]))
        if let store = CredentialStore.shared, store.isLocked {
            let unlock = button("Unlock…", hint: "Unlock\nEnter the Administrator Password, then reopen Run Command on Hosts to pick saved hosts.") { [weak self] in
                guard let self else { return }
                Task { if await LoginVaultPrompts.unlock(store, parent: self.window.window) { self.window.close() } }
            }
            append(content, box(.horizontal, spacing: 8, [label("Saved logins are locked with your Administrator Password.", classes: ["caption", "dim-label"]), unlock]))
        }
        if targets.isEmpty {
            append(content, label("No hosts yet. Save a login in Connect via SSH, or connect this tab, and it appears here.", classes: ["dim-label"], wrap: true))
        } else {
            let heading = label("Hosts")
            setAttributes(heading, weight: 600)
            let list = box(.vertical, spacing: 4)
            for target in targets {
                let title = target.endpoint.label + (target.endpoint.port == 22 ? "" : ":\(target.endpoint.port)")
                let toggle = check(title, active: model.selected.contains(target.id), hint: "\(target.endpoint.label)\nInclude this host when the command runs.") { [weak self] on in
                    guard let self else { return }
                    if on { self.model.selected.insert(target.id) } else { self.model.selected.remove(target.id) }
                }
                append(list, box(.horizontal, spacing: 8, [toggle, label(target.source, classes: ["caption", "dim-label"])]))
            }
            let listScroll = scrolled(list)
            gtk_widget_set_size_request(listScroll, -1, 140)
            gtk_widget_set_vexpand(listScroll, 0)
            let frame = gtk_frame_new(nil)!
            gtk_frame_set_child(c(frame), command)
            gtk_widget_set_size_request(frame, -1, 60)
            hint(command, "Command\nRuns once per host in that account's login shell, without a terminal. Nothing is retried.")
            accessibleLabel(command, "Command to run on each host")
            append(content, heading, listScroll, frame, summary)
            on(gtk_text_view_get_buffer(c(command)), "changed") { [weak self] _ in
                guard let self else { return }
                self.model.command = self.commandText
            }
        }
        append(content, resultsScroll)
        let close = button("Close", hint: "Close (Esc)\nClose this panel.") { [weak self] in self?.window.close() }
        on(run, "clicked") { [weak self] _ in
            guard let self else { return }
            let chosen = self.chosen
            Task { await self.model.run(chosen) }
        }
        append(content, box(.horizontal, spacing: 8, [spinner, stop, spacer(), close, run]))
        append(window.content, content)
    }

    private var commandText: String {
        var start = GtkTextIter(), end = GtkTextIter()
        let buffer = gtk_text_view_get_buffer(c(command))
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        return takeString(gtk_text_buffer_get_text(buffer, &start, &end, 1)) ?? ""
    }

    private func refresh() {
        let chosen = chosen
        setLabel(summary, chosen.isEmpty ? "Select at least one host."
                 : "Will run on \(chosen.map(\.endpoint.label).joined(separator: ", ")) — each account's login shell, non-interactive (no TTY).")
        enable(run, !model.running && !chosen.isEmpty && !model.command.trimmingCharacters(in: .whitespaces).isEmpty)
        setVisible(stop, model.running)
        setVisible(spinner, model.running)
        if model.running { gtk_spinner_start(c(spinner)) } else { gtk_spinner_stop(c(spinner)) }
        removeChildren(results)
        setVisible(resultsScroll, !model.results.isEmpty)
        for result in model.results {
            let icon: Widget
            switch result.outcome {
            case .running: icon = gtk_spinner_new()!; gtk_spinner_start(c(icon))
            case .succeeded: icon = image("object-select-symbolic", classes: ["success"])
            case .failed: icon = image("dialog-error-symbolic", classes: ["error"])
            case .notReached: icon = image("network-error-symbolic", classes: ["warning"])
            case .cancelled: icon = image("process-stop-symbolic", classes: ["dim-label"])
            }
            let name = label(result.target.endpoint.label)
            setAttributes(name, weight: 600)
            let block = box(.vertical, spacing: 4, [box(.horizontal, spacing: 8, [icon, name, label(summaryText(result), classes: ["caption", "dim-label"])])])
            if !result.output.isEmpty { append(block, label(result.output, classes: ["result-output"], wrap: true, selectable: true)) }
            append(results, block)
        }
    }

    private func summaryText(_ result: HostResult) -> String {
        let time = String(format: "%.1fs", result.seconds)
        switch result.outcome {
        case .running: return "running…"
        case .succeeded: return "exit 0 · \(time)"
        case .failed(let code): return "exit \(code) · \(time)"
        case .notReached(let reason): return "not reached: \(reason)"
        case .cancelled: return "stopped"
        }
    }
}
