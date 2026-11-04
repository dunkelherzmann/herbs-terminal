# Herb's Terminal product specification

**Scope reviewed 4 November 2026, against the build after commit `8ad61d4`.** Herb's Terminal (formerly HerbsTerminal) is a native, terminal-first workspace for an administrator using an Apple Silicon Mac to manage local files and remote Windows, Linux, and macOS machines. Its defining behavior is that the explorer follows the host and account of the active terminal. An administrator who connects once can use the shell, transfer files, and, where available, open the remote desktop from that tab.

At minimum Herb's Terminal must match the everyday functionality of the stock macOS Terminal and Ptyxis, plus the features below. The feature-by-feature comparison with Terminal, Ptyxis and iTerm2 is in [docs/2026-11-04-terminal-parity-audit.md](docs/2026-11-04-terminal-parity-audit.md).

A **requirement** describes the intended product. **Status** says what the current build delivers: **Delivered** (built and verified in the app or by tests), **Partial** (built, but a stated part is missing or unverified), or **Open** (not built). A visible button alone does not count as delivery.

## 1. Platform, packaging and delivery status

The operator application targets **macOS 15 and later on Apple Silicon**. Windows and Linux are remote targets. The app uses SwiftUI, AppKit, SwiftTerm 1.20.0 and a local PTY, and builds with Swift Package Manager.

- **Self-contained.** The app must not depend on anything installed separately, even when other copies exist on the system. It runs only its own bundled helpers and components that ship with macOS (`/usr/bin/ssh`, `/bin/sh`, Screen Sharing). *Delivered:* `tailcat` 0.7.0 (BSD-3, pinned in `Vendor/tailcat`) is bundled in `Contents/Helpers`; copies on PATH or from Homebrew are never used; the SSH password helper and the Tailcat proxy are modes of the app's own executable. RDP viewing still needs Microsoft's Windows App (see §8).
- **Bundle identity.** `script/build_and_run.sh` builds `dist/Herb's Terminal.app` (executable `HerbsTerminal`) and signs the helper and the bundle ad-hoc under `org.herbsterminal.app` and declares `NSLocalNetworkUsageDescription`, so macOS Local Network privacy can identify the app and LAN SSH works. *Delivered.* `--bundle` assembles and signs without quitting a running copy.

| Area | Status | Summary |
|---|---|---|
| Terminal and workspace | Partial | Named profiles, tabs (rename, reorder, ⌘1–9), layouts, session restore, transparency, saved zoom, close/quit confirmation, right-click menu, Terminal shortcuts; no split panes |
| Local explorer | Delivered | Thunar-style navigation, file actions, new folder/file, rename |
| Appearance | Delivered | Terminal Basic default, six built-in themes, iTerm2 import, light/dark |
| SSH and remote files | Partial | GUI and typed `ssh` both attach the explorer after a verified login; new folder, rename, transfer retry; no remote editing in the UI, no reconnect |
| Saved logins | Delivered | Herb's Terminal-owned vault with an Administrator Password or confirmed plain text; Manage Logins import/export |
| MultiExec and multi-host commands | Delivered | MobaXterm-style MultiExec grid with broadcast typing; non-interactive Run Command on Hosts; PowerShell untested |
| Tailcat peers | Partial | Add, ping, connect, remove, share; not yet exercised against a live peer |
| Remote desktop | Partial | VNC/RDP over SSH forwarding into the system viewers; no embedded viewer or view-only mode |

## 2. Terminal window and appearance

- Launch into a local terminal. Each tab owns its shell, scrollback, explorer location, and connection. Changing layout or switching tabs preserves the session; closing a tab releases its resources. *Delivered.* Closing a tab, a window, or quitting while a shell runs another program or an SSH session asks first (Settings ▸ Terminal). *Delivered.*
- New tabs open in the current tab's folder (read from the shell process) or in home, per Settings. Tabs can be renamed (double-click, right-click, or Shell ▸ Rename Tab ⇧⌘I), dragged to reorder or moved left and right, and picked with ⌘1–⌘9. *Delivered.*
- **Session restore.** At quit, each window's tabs are saved with their folder, layout, name and explorer folder, and reopen at the next launch (Settings ▸ Terminal, on by default). Remote sessions reopen as local shells; logins are never replayed. Scrollback is not restored. *Delivered.*
- Keep the native traffic lights on the left, followed by **New Tab** and **Connect via SSH**. Center the active tab's title and location, for example `user@host ~`. The legend follows shell-reported titles, current files or directories, foreground commands and exit state, abbreviates home as `~`, truncates while staying centered, and treats shell metadata as display text only. Credentials in command lines (`user:pass@host`, `--password=`, `*_TOKEN=`) are redacted before display. *Delivered.*
- On the right, order the buttons **File Explorer → Split View → Multi-Host Commands → Tailcat Peers → Remote Control**, then **Search → Main Menu**, as compact monochrome Ptyxis-style icons aligned with the window controls (4 pt within groups, 38 pt before Search). The toolbar draws with one or many tabs. *Delivered.*
- While a tab is connected, the SSH button is highlighted and opens connection details (account, host, port, route, remote home, connected time) with **Disconnect** and **New Connection** (which opens a new tab). *Delivered.*
- Every control shows a hover bubble saying what it is and what it does, after about half a second, including in the titlebar and while Herb's Terminal is in the background. Menu items carry native tooltips. *Delivered.*
- Search (⌘F) finds files when the explorer fills the window and searches the scrollback otherwise; Find in Terminal always searches the scrollback. *Delivered.*
- **Menus and shortcuts follow macOS Terminal.** *Delivered:*
  - Shell: New Tab ⌘T, New Remote Connection ⇧⌘K, Disconnect, Show Previous/Next Tab ⇧⌘[ / ⇧⌘], Rename Tab ⇧⌘I, Move Tab Left/Right, Reset ⌥⌘R, Hard Reset ⌃⌥⌘R, Secure Keyboard Entry.
  - Window: Show Tab 1–9 ⌘1–⌘9.
  - Edit: Clear to Start ⌘K, Clear Scrollback ⌥⌘K.
  - View: Bigger ⌘+, Smaller ⌘−, Default Font Size ⌘0. The zoom is saved in the tab's profile, so text keeps its size across sessions; ⌘0 clears it.
  - macOS window tabbing is disabled because Herb's Terminal has its own tab strip.
- **Terminal right-click menu:** Copy, Paste, Paste Escaped Text, Select All, Find, Clear to Start, Clear Scrollback, Reset, New Tab, Split View, Show File Explorer, Connect/Disconnect, Bigger, Smaller, Settings. *Delivered.*
- Dropping files or folders on the terminal types their shell-quoted paths. *Delivered.*
- **Named profiles**, as in Terminal and Ptyxis. Each tab uses one; new tabs keep the current tab's profile. A profile holds font, size, zoom, cursor, color theme, background opacity and blur, Option as Meta, scrollback, bell, a startup command and a start folder. Shell ▸ New Tab with Profile and Use Profile; Settings ▸ Profiles adds, duplicates, renames, deletes and sets the default. Settings from before profiles became the "Basic" profile. *Delivered.*
- **Main Menu ▸ Terminal Theme** sets the current tab's profile theme, imports an iTerm2 preset into it, and **Restore Defaults** (with a confirmation) returns that profile's font, size, zoom, cursor, colors and transparency, and the app appearance, to stock Terminal Basic. *Delivered.*
- **Split View widens the window** by up to 520 points so the terminal keeps its width, staying on screen, and gives the width back when Split View closes. *Delivered.*
- **Settings (⌘,)**: Profiles, then Text, Terminal and Colors for the profile being edited, and Window. *Delivered:*
  - Text: any installed monospaced font, size 6–72 pt, background opacity (20–100%) and blur, cursor block/underline/bar, blink, live preview.
  - Terminal: Option as Meta key (off by default, as in Terminal), scrollback 100–1,000,000 lines, bell (audible, visual, both, off), where new tabs open, restore windows and tabs, ask before closing.
  - Window: default width and height for new windows, apply to open windows, copy the front window's size.
  - Colors: appearance (System/Light/Dark), macOS Terminal Basic plus six built-in palettes (Solarized Dark/Light, Tango Dark/Light, Gruvbox Dark, Nord), `.itermcolors` import and removal.
- Match the macOS Terminal **Basic** profile by default (SF Mono Terminal 11 pt, stock light/dark colors and ANSI palette), inset 8 pt leading and 6 pt top in the terminal's own background color. *Delivered.*
- `.itermcolors` import applies foreground, background, cursor, cursor text, selection, selected text and the 16 ANSI colors; malformed files are rejected without losing the current selection; the choice persists and applies across tabs and windows. *Delivered.*
- **Open:** split panes within a tab, moving a tab to another window, a tab overview, marks and bookmarks, an inspector, editable key bindings, and cmd-click opening of URLs and files (SwiftTerm's default link handling is in place but unverified). See the audit for priorities.

## 3. Connect once and follow the active host

| User action | Required behavior | Status |
|---|---|---|
| Open a tab on the Mac | Start the local login shell; the explorer shows local files. | Delivered |
| Choose **Connect via SSH** (⇧⌘K) | Accept host, port (default 22), username, and password or a saved login; allow one-time use and optional saving; open the remote shell and attach the explorer to the same host and account. | Delivered |
| Type ordinary `ssh user@host` or `ssh alias` | Resolve through SSH configuration and attach the explorer after authentication; offer a choice when a bare host has several saved logins. | Delivered for zsh and bash (shell integration); saved-login choice for typed ssh is Open |
| Change layout or select another tab | Show that tab's session and location; transfers keep their original endpoints. | Delivered |
| Exit SSH normally, or Disconnect | Return to the preceding session and its explorer location; for one hop, local files. | Delivered |
| Authentication fails or the link drops | Show the real connection state, distinguish remote from local files, never redirect writes. | Partial: "Connecting…" and failure banners exist; reconnect is not offered |

**Typed ssh.** Each tab's zsh or bash starts with a small integration (zsh through `ZDOTDIR`, bash through `--rcfile`) that first loads the user's own startup files, then defines an `ssh` function. It resolves the destination with `ssh -G` (aliases, HostName, User, Port), announces it to the app in the private socket folder, and runs the real ssh as the master of a shared connection; the tab then follows it exactly like a GUI login. `ssh -G/-O/-V/-Q` pass straight through; other shells run unchanged. A password typed into the user name is never shown.

**How a GUI connection works.** Herb's Terminal types only the path of a private, self-deleting launcher (mode 0700). The launcher erases that echoed line, prints "Connecting to user@host…" and execs `/usr/bin/ssh` as the master of an OpenSSH shared connection (`ControlMaster=auto`, `ControlPersist=no`, socket in a short private folder, `/tmp/herbs-<uid>`, which must be a real directory owned by the user with mode 0700, because Unix socket paths must stay under 104 bytes). No command line, token or option appears on screen or in shell history. A saved password reaches ssh through `SSH_ASKPASS`, which is the Herb's Terminal executable in helper mode, trading a one-time token over a private Unix socket. Host-key questions, one-time codes and retries are asked on the terminal. Each tab polls the shared socket: it attaches the explorer at the remote home folder once the login succeeds, and detaches when ssh exits or the link drops.

Honor SSH aliases, custom ports, identity files, agent authentication, interactive MFA, host-key verification and jump hosts; prefer shared transport for shell and SFTP; keep the shell usable if SFTP is denied. *Delivered through the system ssh client and the user's ssh configuration; jump hosts and MFA are untested.*

**Host following and directory following are separate.** Host following is automatic for GUI connections. Directory following, nested hops inside a remote shell, and a stack of verified hops remain **Open**. A prompt, window title or printed hostname is never evidence for redirecting file operations.

## 4. Explorer, editing and transfers

The explorer follows Thunar's model, locally and remotely: a Places side pane, back and forward history, up, home, clickable path segments, an editable location (⌘L), hidden files (⇧⌘.), reload, double-click or Return to open, and Delete for Back. Shortcuts are Mac adaptations of Thunar's.

| Capability | Requirement | Status |
|---|---|---|
| Navigate | Places (local: Home, Desktop, Documents, Downloads, Movies, Music, Pictures, Computer, Trash, mounted Devices; remote: Home, File System), bookmarks (⌘D; per host when remote), history, path bar, location entry with `~` and relative paths, hidden files, symbolic links to folders opened as folders. | Delivered |
| File Actions menu | Upload File/Folder, Download File/Folder, Undo ⌘Z, Redo ⇧⌘Z, Cut ⌘X, Copy ⌘C, Paste ⌘V, Delete ⌘⌫, Select All ⌘A, Find ⌘F. Shortcuts are shown in the menu and reach the focused file list through the Edit menu, so ⌘C/⌘V still copy and paste terminal text. | Delivered |
| Local file changes | Copy, move and Trash with Finder-style "name copy" names, never overwriting; Undo/Redo by original action name; Finder clipboard interoperability. | Delivered |
| Remote file changes | Move within the host (undoable), copy on the host, confirmed recursive delete, paste of Mac files uploads them. | Delivered |
| Create and rename | New Folder and New File (right-click an empty area), Rename (right-click an item); free "untitled" names; undoable locally ("Undo New Folder", "Undo Rename"), rename undoable remotely. | Delivered |
| Transfer | Upload and download files and folder trees with a progress strip, cancel and Retry (failed or cancelled items rerun from the start); uploads land under a temporary name and are renamed into place; name clashes get new names. | Partial: no drag-and-drop, no resume after interruption |
| Edit remotely | Open a working copy in the chosen Mac editor and send changes back; detect concurrent remote edits; keep a recoverable draft; preserve bytes, line endings and permissions. | **Open:** staging and conflict checks exist in code but aren't reachable from the UI |
| Permissions | Use the authenticated file account; a privileged edit is a separate, explicitly authorized action. | Partial: no privileged workflow |
| Windows targets | Windows drive paths, case rules, PowerShell hosts. | Untested |

## 5. Saved logins

- Logins (host, port, username, password; several per host) live in an **app-owned SQLite file** (`~/Library/Application Support/HerbsTerminal/logins.sqlite3`, mode 0600). **The app does not use the macOS Keychain at all.** *Delivered.*
- **Administrator Password.** When one is set, each password is AES-GCM encrypted with a key derived from it (PBKDF2-SHA256, 600,000 rounds, random 16-byte salt). Only the salt, iteration count and an encrypted check value are stored; the password itself never is. The app starts locked and asks once per session; a wrong password changes nothing. Changing the password re-encrypts every login in one transaction. Tailcat peer addresses are protected the same way. *Delivered.*
- **Plain text.** Without an Administrator Password, logins are stored as plain text inside Herb's Terminal. This needs an explicit choice and a second confirmation. *Delivered.*
- **First use.** The first time Connect via SSH or Manage Logins is used, an alert explains that an Administrator Password is needed to encrypt saved logins, and that otherwise they are stored as plain text, which is a security risk. It offers Create Administrator Password, Store as Plain Text, or Not Now. Nothing is saved until a choice is made. *Delivered.*
- **Manage Logins** offers Create/Modify Admin Password, Import Login Data and Export Login Data (CSV with header `host,port,username,password`; UTF-8, quoted commas, quotes and embedded line breaks; transactional; a rejected import preserves the store). Export writes readable passwords, so it requires the Administrator Password, or a confirmation in plain-text mode. *Delivered; conflict preview before import is Open.*
- **Earlier builds.** Logins saved by builds that used a Keychain key can't be read and are only listed, with **Discard** (behind a confirmation whose default is Cancel). *Delivered.*
- Passwords stay out of process arguments, terminal output, shell history and logs. SSH private keys and Tailcat server keys never enter the CSV. *Delivered.*
- **Recovery.** A forgotten Administrator Password cannot be recovered; the logins must be deleted and re-entered. Machine migration is by Export and Import.
- **Acceptance example.** Set an Administrator Password, save two accounts for one host, relaunch (locked), unlock, select either account, export, import into a fresh store, and reconnect. A password containing a comma and a quote must round-trip exactly, and the database must contain neither password nor the Administrator Password. *Covered by tests except the reconnect.*

## 6. MultiExec and multi-host commands

**MultiExec** (the toolbar's Multi-Host button, Shell ▸ MultiExec ⇧⌘M) follows MobaXterm's MultiExec. The window shows every tab as a live terminal in a grid, each with a caption bar giving its number, title (or remote `user@host`) and an include checkbox. What the user types or pastes into an included terminal is sent to every included terminal. An unchecked terminal takes only its own typing. The focused terminal is outlined; a bar shows how many terminals receive input, with New Tab, Connect via SSH, Include All and Exit MultiExec (Esc). Only user input is broadcast: the emulator's replies to programs (cursor reports and the like) and text the app types itself (the ssh launcher, startup commands, Clear's redraw) stay in their own tab. *Delivered.*

Because MultiExec types into live sessions, it reaches whatever each session is running, including a password prompt or an editor. Leaving a terminal out with its checkbox is the guard.

**Run Command on Hosts** (Shell menu) keeps the non-interactive composer: it runs one command concurrently on selected saved logins and the tab's live connection, each over its own ssh channel (`-T`, `StrictHostKeyChecking=yes`), never typing into interactive sessions and never retrying, and reports each host's outcome, exit code, duration and output. *Delivered.* Saved host groups, per-host retry, separate stdout/stderr and PowerShell targets are **Open**.

## 7. Tailcat pairing and connectivity

Tailcat is the alternate route when machines can't reach each other by IP. The app runs its bundled `tailcat`; the other machine runs `tailcat serve`.

- **Accept a pairing:** name, username, and the peer's secret address, marked **Persistent** (the peer keeps a saved server key) or **One-time** (the address dies with its server). Addresses are stored under the login protection of §5. *Delivered.*
- **Peer actions:** Ping reports **Direct** or **Relayed** with latency. Connect opens the shell and explorer through Tailcat: ssh's ProxyCommand is the app's helper, which redeems a one-time token for the address and becomes the bundled tailcat, so the address never appears in ssh's arguments or history. Remove forgets the peer here; revoking it server-side means stopping or re-keying that server. *Delivered, not yet exercised against a live peer.*
- **Share this Mac:** run `tailcat serve` for port 22, one-time (fresh key) or persistent (saved `default` key), and show the address with Copy and Stop. Requires Remote Login. Sharing stops when the app quits. *Delivered, not exercised live.*
- SSH host verification and authentication stay active over the tunnel. Route-change recovery, NAT-traversal measurements and Windows/Linux helper packaging are **Open**.

## 8. Remote desktop control

The Remote Control button opens the active host's desktop through the tab's SSH connection, so the desktop service is never exposed on the network. The app adds a local forward (`ssh -O forward`) to a free loopback port, then opens:

| Target | Service | Viewer |
|---|---|---|
| macOS, Linux | VNC / Screen Sharing (5900) | macOS Screen Sharing (`vnc://`) |
| Windows | RDP (3389) | Microsoft Windows App (`rdp://`), which must be installed |

The shell and transfers keep running; forwards are listed and closable, and end with the SSH session. Missing viewers, refused forwards and absent services are reported without disturbing the shell. *Delivered.* View-only mode, an embedded viewer (the earlier Guacamole proposal), the `herbsterminal desktop` command, desktops over Tailcat, and distinguishing a shared screen from a separate login are **Open**.

## 9. Release acceptance matrix

Run `script/test.sh` (72 tests, including real SFTP transfers through `/usr/libexec/sftp-server`, the password helper, the login vault and Tailcat parsing) and `script/build_and_run.sh --verify`. Remote milestones need live endpoints.

| Gate | Scenario and pass condition | Status |
|---|---|---|
| Local workspace | All three layouts keep the shell PID; new tabs have independent shells; toolbar visible with one tab; title centered at any width. | Passing |
| Appearance | Import a preset, switch tabs, relaunch, reset to Basic; check text, cursor, selection, ANSI and insets in light and dark. | Passing (manual for relaunch) |
| Single-host administration | On each remote OS: GUI and typed SSH, browse, create, edit, upload, download, exit to local files; compare bytes; denied permissions; unavailable SFTP. | Partial: GUI connect, browse and disconnect verified on Linux (ZimaOS); typed SSH, editing and Windows/macOS hosts outstanding |
| Session identity | Two accounts on one host, alias, jump host, changed host key, unverified nested hop; no write reaches the wrong account. | Not run |
| Transfer recovery | Interrupt a replacement upload, reconnect, resume or restart safely; verify bytes. | Partial: cancel leaves no partial file and Retry restarts safely (tested); resume Open |
| Credentials | §5 acceptance example; database and logs free of plaintext; locked and plain-text behavior. | Passing in tests |
| Multi-host | One command on three hosts with a failure and an unreachable host; independent results, no replay. | Passing in tests; live run outstanding |
| Tailcat | Pair across networks, direct and relayed routes, reconnect, revoke. | Not run live |
| Desktop | RDP and VNC over SSH, input, recovery; SSH-only host gets an actionable error. | Not run live |

## 10. Delivery sequence and open decisions

1. **Close the SSH gaps:** reconnect after a drop, remote editing in the UI, drag-and-drop transfers and resume, saved-login choice for typed ssh.
2. **Terminal parity:** the remaining gaps in the audit (split panes, moving tabs between windows, tab overview, marks and inspector, verifying cmd-click links, regex find and inline images, key bindings).
3. **Live validation:** Tailcat across two networks, remote desktop on each OS, multi-host against Windows.
4. **Embedded desktop viewer**, if the system viewers prove insufficient.

Open decisions: nested SSH coverage; the privileged-edit workflow; stable code signing (ad-hoc rebuilds change identity, which matters for Local Network privacy prompts); Tailcat helper packaging and relay ownership for Windows and Linux peers; supported desktop authentication and session combinations. Record interoperability by host OS, service version and transport before declaring a combination supported.

## Design and protocol references

| Reference | Relevance |
|---|---|
| [TMOG](https://tmog.org/) and [Ptyxis](https://devsuite.app/ptyxis/) | Native status presentation and compact terminal-first controls |
| [macOS Terminal User Guide](https://support.apple.com/guide/terminal/welcome/mac) and [iTerm2 documentation](https://iterm2.com/documentation.html) | Parity baselines |
| [MobaXterm](https://mobaxterm.mobatek.net/features.html) | SSH-linked explorer and multi-host execution |
| [FilesRemote](https://github.com/allanrbo/filesremote) and [WinSCP transfer resume](https://winscp.net/eng/docs/resume) | Local-editor workflow, transfer staging and recovery |
| [Xfce Thunar](https://docs.xfce.org/xfce/thunar/the-file-manager-window) | File manager navigation and layout |
| [OpenSSH ssh_config](https://man.openbsd.org/ssh_config) and [Tailcat](https://github.com/tailscale/tailcat) | Connection sharing, askpass, host routing, peer identity and relays |
| [Guacamole architecture](https://guacamole.apache.org/doc/gug/guacamole-architecture.html) | Candidate embedded desktop viewer |
| [iTerm2 color presets](https://iterm2.com/documentation-preferences-profiles-colors.html) | Terminal theme interchange |
