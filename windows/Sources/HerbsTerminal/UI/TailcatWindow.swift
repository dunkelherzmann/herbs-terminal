import CHerbUIA
import Foundation
import WinSDK

/// Tailcat Peers (the toolbar's peers button), laid out as on the Mac and Linux: adding a peer (name, username,
/// secret address, One-time or Persistent), the saved peers with Ping, Connect and Remove, sharing this PC, and
/// Unlock… / Lock… opposite Done. The form starts empty each time the window opens.
@MainActor
final class TailcatPeersWindow: WindowObject {
    static let className = "HerbsTerminalTailcat"
    private static var current: TailcatPeersWindow?

    private(set) var hwnd: HWND?
    private weak var workspace: Workspace?
    private var font: HFONT?, bold: HFONT?
    private var controls: [ID: HWND] = [:]
    private var labels: [HWND] = []
    private let hints = HoverHints()
    private var observers: [ObservationToken] = []
    private var shown: [TailcatPeer] = []

    private enum ID: Int32 {
        case heading = 5000, about, name, username, address, oneTime, persistent, add, list, ping, connect, remove,
             shareHeading, shareNote, shareAddress, copy, stopShare, shareOneTime, sharePersistent, startShare, error, lock, done
    }

    static func show(owner: HWND?, workspace: Workspace) {
        if let window = current?.hwnd {
            ShowWindow(window, SW_RESTORE)
            SetForegroundWindow(window)
            return
        }
        current = TailcatPeersWindow(owner: owner, workspace: workspace)
    }

    static var open: TailcatPeersWindow? { current?.hwnd == nil ? nil : current }

    private init(owner: HWND?, workspace: Workspace) {
        self.workspace = workspace
        var common = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_LISTVIEW_CLASSES))
        InitCommonControlsEx(&common)
        let dpi = owner.map { GetDpiForWindow($0) } ?? 96
        var rect = RECT(left: 0, top: 0, right: scaled(620, dpi: dpi), bottom: scaled(640, dpi: dpi))
        let style = DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_MINIMIZEBOX)
        AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (rect.right - rect.left)) / 2
            y = ownerRect.top + scaled(40, dpi: dpi)
        }
        hwnd = createWindow(self, className: Self.className, title: "Tailcat Peers", style: style, exStyle: DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: owner)
        guard let hwnd else { return }
        func makeFont(_ size: Double, _ weight: Int32) -> HFONT? {
            withWide("Segoe UI") { CreateFontW(-scaled(size, dpi: dpi), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0) }
        }
        font = makeFont(12, Int32(FW_NORMAL))
        bold = makeFont(15, Int32(FW_SEMIBOLD))
        build(dpi: dpi)
        observers.append(TailcatPeerStore.shared.objectWillChange.observe { [weak self] in MainThread.async { self?.refresh() } })
        observers.append(TailcatShare.shared.objectWillChange.observe { [weak self] in MainThread.async { self?.refresh() } })
        if let store = CredentialStore.shared { observers.append(store.objectWillChange.observe { [weak self] in MainThread.async { self?.refresh() } }) }
        refresh()
        DialogTheme.apply(to: hwnd)
        ShowWindow(hwnd, TestScript.active || ParityScene.isActive ? SW_SHOWNOACTIVATE : SW_SHOW)
        TestDesktop.place(hwnd)
    }

    // MARK: Layout

    private func build(dpi: UINT) {
        guard let hwnd else { return }
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        let margin = s(20), width = s(620) - 2 * margin
        var y = margin
        func make(_ cls: String, _ text: String, _ style: DWORD, _ id: ID?, x: Int32, w: Int32, h: Int32, chosenFont: HFONT? = nil) -> HWND? {
            let control = withWide(cls) { c in
                withWide(text) { t in
                    CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style, x, y, w, h, hwnd,
                                    HMENU(bitPattern: Int(id?.rawValue ?? 0)), GetModuleHandleW(nil), nil)
                }
            }
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(chosenFont ?? font)))), 1)
            if let id, let control { controls[id] = control } else if let control { labels.append(control) }
            return control
        }
        func field(_ label: String, _ id: ID, password: Bool = false, hint: String) {
            _ = make("STATIC", label, DWORD(SS_LEFT), nil, x: margin, w: s(110), h: s(20))
            y -= s(3)
            let control = make("EDIT", "", DWORD(ES_AUTOHSCROLL) | DWORD(WS_BORDER) | DWORD(WS_TABSTOP) | (password ? DWORD(ES_PASSWORD) : 0), id,
                               x: margin + s(116), w: width - s(116), h: s(24))
            hints.set(control, hint, owner: hwnd)
            y += s(32)
        }
        _ = make("STATIC", "Tailcat Peers", DWORD(SS_LEFT), .heading, x: margin, w: width, h: s(24), chosenFont: bold)
        y += s(30)
        _ = make("STATIC", "Reach machines that can't see each other by IP. Each peer runs `tailcat serve 22`; paste the address it prints. "
                 + "Addresses are secrets; they are encrypted with your Administrator Password when one is set.",
                 DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), .about, x: margin, w: width, h: s(36))
        y += s(44)
        field("Name", .name, hint: "Name\nHow this peer appears in Herb's Terminal.")
        field("Username", .username, hint: "Username\nThe SSH account to sign in as on the peer.")
        field("Address", .address, password: true, hint: "Tailcat address\nThe secret address the peer's `tailcat serve` printed.")
        let oneTime = make("BUTTON", "One-time", DWORD(BS_AUTORADIOBUTTON) | DWORD(WS_GROUP) | DWORD(WS_TABSTOP), .oneTime, x: margin + s(116), w: s(100), h: s(22))
        let persistent = make("BUTTON", "Persistent", DWORD(BS_AUTORADIOBUTTON), .persistent, x: margin + s(220), w: s(110), h: s(22))
        for radio in [oneTime, persistent] {
            hints.set(radio, "Pairing type\nOne-time: the address dies when its server stops. Persistent: the peer keeps a saved server key.", owner: hwnd)
        }
        SendMessageW(oneTime, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
        let add = make("BUTTON", "Add Peer", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), .add, x: margin + width - s(100), w: s(100), h: s(28))
        hints.set(add, "Add Peer\nSave this peer so you can ping and connect to it.", owner: hwnd)
        y += s(40)

        let list = make(WC_LISTVIEWW_NAME, "", DWORD(LVS_REPORT) | DWORD(LVS_SINGLESEL) | DWORD(LVS_SHOWSELALWAYS) | DWORD(WS_BORDER) | DWORD(WS_TABSTOP),
                        .list, x: margin, w: width, h: s(120))
        SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE), 0, LPARAM(LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER))
        for (index, column) in [("Peer", 200.0), ("Pairing", 90.0), ("Route", 280.0)].enumerated() {
            var item = LVCOLUMNW()
            item.mask = UINT(LVCF_TEXT | LVCF_WIDTH)
            item.cx = s(column.1)
            var title = column.0.wide
            title.withUnsafeMutableBufferPointer { pointer in
                item.pszText = pointer.baseAddress
                _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: $0))) }
            }
        }
        y += s(128)
        var x = margin
        for (id, title, hint) in [(ID.ping, "Ping", "Ping\nCheck the peer is reachable and whether the route is Direct or Relayed."),
                                  (.connect, "Connect", "Connect\nOpen an SSH shell to this peer; the explorer follows it."),
                                  (.remove, "Remove", "Remove\nForget this peer and its address here. Stop or re-key the peer's server to revoke it there too.")] {
            let button = make("BUTTON", title, DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), id, x: x, w: s(90), h: s(28))
            hints.set(button, hint, owner: hwnd)
            x += s(96)
        }
        y += s(44)

        _ = make("STATIC", "Share this PC", DWORD(SS_LEFT), .shareHeading, x: margin, w: width, h: s(20), chosenFont: bold)
        y += s(26)
        _ = make("STATIC", "", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), .shareNote, x: margin, w: width, h: s(20))
        y += s(26)
        let address = make("EDIT", "", DWORD(ES_AUTOHSCROLL) | DWORD(ES_READONLY) | DWORD(WS_BORDER) | DWORD(WS_TABSTOP), .shareAddress,
                           x: margin, w: width - s(230), h: s(24))
        hints.set(address, "Address\nGive this secret address only to the peer, over a private channel.", owner: hwnd)
        let copy = make("BUTTON", "Copy", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), .copy, x: margin + width - s(222), w: s(80), h: s(28))
        hints.set(copy, "Copy\nCopy the address to send to your peer over a private channel.", owner: hwnd)
        let stop = make("BUTTON", "Stop Sharing", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), .stopShare, x: margin + width - s(136), w: s(136), h: s(28))
        hints.set(stop, "Stop Sharing\nShut down this PC's tailcat server; peers can no longer connect.", owner: hwnd)
        let shareOneTime = make("BUTTON", "One-time", DWORD(BS_AUTORADIOBUTTON) | DWORD(WS_GROUP) | DWORD(WS_TABSTOP), .shareOneTime, x: margin, w: s(100), h: s(22))
        let sharePersistent = make("BUTTON", "Persistent", DWORD(BS_AUTORADIOBUTTON), .sharePersistent, x: margin + s(104), w: s(110), h: s(22))
        for radio in [shareOneTime, sharePersistent] {
            hints.set(radio, "Sharing type\nOne-time uses a fresh key; persistent keeps the same address across restarts.", owner: hwnd)
        }
        SendMessageW(shareOneTime, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
        let start = make("BUTTON", "Start Sharing", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), .startShare, x: margin + width - s(136), w: s(136), h: s(28))
        hints.set(start, "Start Sharing\nRun a tailcat server for this PC's port 22. Needs the OpenSSH SSH Server running.", owner: hwnd)
        y += s(36)
        _ = make("STATIC", "", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), .error, x: margin, w: width, h: s(40))

        y = s(640) - margin - s(30)
        _ = make("BUTTON", "Unlock…", DWORD(BS_PUSHBUTTON) | DWORD(WS_TABSTOP), .lock, x: margin, w: s(110), h: s(30))
        _ = make("BUTTON", "Done", DWORD(BS_DEFPUSHBUTTON) | DWORD(WS_TABSTOP), .done, x: margin + width - s(90), w: s(90), h: s(30))
        hints.set(controls[.done], "Done (Esc)\nClose this panel. Sharing keeps running until you stop it or quit Herb's Terminal.", owner: hwnd)
        // The share address row and the start row sit in the same place; refresh shows one of them.
    }

    // MARK: State

    private func refresh() {
        guard let hwnd else { return }
        let store = TailcatPeerStore.shared
        shown = store.peers
        let list = controls[.list]
        let selected = Int(SendMessageW(list, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED)))
        SendMessageW(list, UINT(LVM_DELETEALLITEMS), 0, 0)
        for (row, peer) in shown.enumerated() {
            let cells = ["\(peer.username)@\(peer.name)", peer.persistent ? "Persistent" : "One-time", (store.routes[peer.id] ?? .unknown).text]
            for (column, text) in cells.enumerated() {
                var item = LVITEMW()
                item.mask = UINT(LVIF_TEXT)
                item.iItem = Int32(row)
                item.iSubItem = Int32(column)
                var units = text.wide
                units.withUnsafeMutableBufferPointer { pointer in
                    item.pszText = pointer.baseAddress
                    _ = withUnsafeMutablePointer(to: &item) { SendMessageW(list, UINT(column == 0 ? LVM_INSERTITEMW : LVM_SETITEMW), 0, LPARAM(Int(bitPattern: $0))) }
                }
            }
        }
        if shown.indices.contains(selected) { select(row: selected) } else if !shown.isEmpty { select(row: 0) }
        for id in [ID.ping, .connect, .remove] { EnableWindow(controls[id], !shown.isEmpty) }

        let share = TailcatShare.shared
        let sharing = share.isSharing && share.address != nil
        for id in [ID.shareAddress, .copy, .stopShare] { ShowWindow(controls[id], sharing ? SW_SHOW : SW_HIDE) }
        for id in [ID.shareOneTime, .sharePersistent, .startShare] { ShowWindow(controls[id], sharing ? SW_HIDE : SW_SHOW) }
        EnableWindow(controls[.startShare], !share.starting && Tailcat.executable != nil)
        let note = sharing ? "Sharing SSH \(share.persistent ? "persistently" : "one-time"). Give this secret address only to the peer:"
            : share.starting ? "Starting tailcat…" : "Let a peer reach this PC's SSH server through Tailcat."
        withWide(note) { _ = SetWindowTextW(controls[.shareNote], $0) }
        withWide(share.address ?? "") { _ = SetWindowTextW(controls[.shareAddress], $0) }
        let problem = Tailcat.executable == nil ? Tailcat.missing : (share.error ?? "")
        withWide(problem) { _ = SetWindowTextW(controls[.error], $0) }

        // Unlock… or Lock…, with what it does in the hover hint and the name screen readers read.
        let vault = CredentialStore.shared
        let locked = vault?.isLocked ?? false
        let lock = controls[.lock]
        withWide(locked ? "Unlock…" : "Lock…") { _ = SetWindowTextW(lock, $0) }
        if let lock { _ = withWide(locked ? "Unlock Saved Logins" : "Lock Saved Logins") { herb_set_accessible_name(UnsafeMutableRawPointer(lock), $0) } }
        EnableWindow(lock, vault != nil && CredentialStore.unavailableReason == nil)
        hints.set(lock, vault?.protection == .adminPassword
                  ? (locked ? "Unlock\nUnlock the safe storage of Tailcat addresses and saved logins with the Administrator Password, or change the password."
                            : "Lock\nLock the safe storage of Tailcat addresses and saved logins until the Administrator Password is entered again, or change the password.")
                  : "Lock\nTailcat addresses and saved logins are stored as plain text. Create an Administrator Password to lock them.", owner: hwnd)
    }

    private func select(row: Int) {
        var item = LVITEMW()
        item.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        item.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
        _ = withUnsafeMutablePointer(to: &item) { SendMessageW(controls[.list], UINT(LVM_SETITEMSTATE), WPARAM(row), LPARAM(Int(bitPattern: $0))) }
    }

    private var selectedPeer: TailcatPeer? {
        let row = Int(SendMessageW(controls[.list], UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED)))
        return shown.indices.contains(row) ? shown[row] : nil
    }

    private func text(_ id: ID) -> String { controls[id].map { String(windowText: $0) } ?? "" }
    private func isChecked(_ id: ID) -> Bool { SendMessageW(controls[id], UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }

    private func showError(_ message: String) { withWide(message) { _ = SetWindowTextW(controls[.error], $0) } }

    // MARK: Actions

    /// Adds a peer from the form, as the Add Peer button does (also the feature tests' way in).
    func addPeer(name: String, username: String, address: String, persistent: Bool) -> Bool {
        do {
            if let vault = CredentialStore.shared, vault.isLocked, !LoginVaultPrompts.unlock(vault, owner: hwnd) { return false }
            try TailcatPeerStore.shared.add(name: name, username: username, address: address, persistent: persistent)
            for id in [ID.name, .username, .address] { withWide("") { _ = SetWindowTextW(controls[id], $0) } }
            showError("")
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    func connect(_ peer: TailcatPeer) {
        workspace?.connect(TailcatPeerStore.shared.endpoint(for: peer), password: nil)
    }

    private func perform(_ id: ID) {
        switch id {
        case .add: _ = addPeer(name: text(.name), username: text(.username), address: text(.address), persistent: isChecked(.persistent))
        case .ping: if let peer = selectedPeer { TailcatPeerStore.shared.ping(peer) }
        case .connect: if let peer = selectedPeer { connect(peer) }
        case .remove:
            guard let peer = selectedPeer,
                  FormDialog.ask(owner: hwnd, title: "Remove the peer “\(peer.name)”?",
                                 message: "Its saved address is removed from Herb's Terminal. Stop or re-key the peer's server to revoke it there too.",
                                 buttons: [.init(title: "Cancel", isDefault: true), .init(title: "Remove")]) == 1 else { return }
            do { try TailcatPeerStore.shared.remove(peer) } catch { showError(error.localizedDescription) }
        case .copy: if let address = TailcatShare.shared.address, let hwnd { setClipboardText(address, owner: hwnd) }
        case .stopShare: TailcatShare.shared.stop()
        case .startShare: TailcatShare.shared.start(persistent: isChecked(.sharePersistent))
        case .lock:
            guard let vault = CredentialStore.shared else { return }
            if vault.protection != .adminPassword {
                _ = LoginVaultPrompts.createOrModify(vault, owner: hwnd)
            } else if vault.isLocked {
                _ = LoginVaultPrompts.unlock(vault, owner: hwnd)
            } else {
                let answer = FormDialog.ask(owner: hwnd, title: "Lock saved logins?",
                                            message: "Tailcat addresses and saved logins stay locked until the Administrator Password is entered again.",
                                            buttons: [.init(title: "Cancel"), .init(title: "Change Administrator Password…"), .init(title: "Lock", isDefault: true)])
                if answer == 2 { vault.lock() } else if answer == 1 { _ = LoginVaultPrompts.createOrModify(vault, owner: hwnd) }
            }
        case .done: if let hwnd { DestroyWindow(hwnd) }
        default: break
        }
        refresh()
    }

    /// For the feature tests' bridge.
    var bridgeState: [String: Any] {
        ["peers": TailcatPeerStore.shared.peers.map { peer -> [String: Any] in
            ["name": peer.name, "username": peer.username, "persistent": peer.persistent,
             "route": (TailcatPeerStore.shared.routes[peer.id] ?? .unknown).text]
         },
         "sharing": TailcatShare.shared.isSharing, "shareAddress": TailcatShare.shared.address ?? NSNull(),
         "error": TailcatShare.shared.error ?? NSNull(), "locked": CredentialStore.shared?.isLocked ?? false]
    }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if let themed = DialogTheme.handle(hwnd, message, wParam) { return themed }
        switch Int32(message) {
        case WM_COMMAND:
            let id = Int32(wParam & 0xFFFF)
            if id == IDCANCEL { DestroyWindow(hwnd); return 0 }
            if Int32((wParam >> 16) & 0xFFFF) == BN_CLICKED, let action = ID(rawValue: id) { perform(action) }
            return 0
        case WM_DESTROY:
            observers = []
            hints.release()
            for item in [font, bold] where item != nil { DeleteObject(item) }
            if Self.current === self { Self.current = nil }
            return 0
        default:
            return nil
        }
    }

    /// Esc closes; Tab moves between controls.
    func dialogMessage(_ message: inout MSG) -> Bool {
        guard let hwnd else { return false }
        return IsDialogMessageW(hwnd, &message)
    }
}
