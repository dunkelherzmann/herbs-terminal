# HerbsTerminal product specification

**Scope reviewed 4 November 2026.** HerbsTerminal is a native, terminal-first workspace for an administrator using an Apple Silicon Mac to manage local files and remote Windows, Linux, and macOS machines. Its defining behavior is that the explorer follows the host and account of the active terminal. An administrator who connects once can use the shell, transfer files, and, where available, open the remote desktop from that tab.

## 1. Platform and delivery status

The operator application targets **macOS 15 and later on Apple Silicon**. Windows and Linux are remote targets. Peer connectivity on those platforms calls for a compatible helper. The existing application uses SwiftUI, AppKit, SwiftTerm, and a local PTY. The project builds a macOS app bundle through its Codex Run action.

| Area | Present in the project | Work required for the requested product |
|---|---|---|
| Terminal and workspace | Local login shell, independent tabs and windows, search, zoom, layout switching, session legend | Associate verified remote connection state with a tab |
| Local explorer | Browse non-hidden entries, navigate home or up, refresh, create a file, open it with its Mac app | Complete file and folder operations, including hidden-file visibility |
| Appearance | Stock Terminal Basic font and colors, light/dark appearance, persisted iTerm2 color imports | Preserve these settings across future session types |
| SSH and remote files | The local shell can invoke the installed SSH client | GUI connect, typed SSH integration, host mirroring, SFTP operations and transfers |
| Saved logins | No credential store or exchange workflow | Encrypted SQLite records, account picker, CSV import/export |
| Multi-host, Tailcat, remote control | Toolbar entry points display development notices | Implement and verify each service end to end |

A **requirement** below describes the intended product. A **proposed implementation** or **open decision** identifies a choice that still needs validation. A visible button alone does not count as delivery of its feature.

## 2. Terminal window and appearance

- Launch into a local terminal. Each new tab owns its shell, scrollback, explorer location, and current connection. Opening a tool, changing layout, or switching tabs preserves that session. Closing one tab releases its resources.
- Keep the native traffic lights and New Tab button on the left. Center the active tab's title and location side by side, for example `user@host ~`. The legend follows shell-reported titles, current files or directories, foreground commands, and exit state. Abbreviate the local home directory as `~`. Truncate long titles and paths while keeping the legend centered and its full text discoverable. Treat shell-reported metadata as display text only.
- On the right, order the buttons **File Explorer → Split View → Multi-Host Commands → Tailcat Peers → Remote Control**, then **Search → Main Menu**. Keep the compact, monochrome Ptyxis-style icons aligned with the native window controls. Use 4 pt within groups and 38 pt between Remote Control and Search, including the requested extra button width.
- File Explorer switches between terminal-only and explorer-only views. Split View opens or closes the side-by-side layout. Search targets the active terminal's scrollback and brings the terminal back when the explorer fills the window. The menu provides tab and window actions, search, zoom/reset, terminal theme, appearance, full screen, and About. Buttons need accessible names, tooltips, and keyboard access.
- Match the installed macOS Terminal **Basic** profile by default. The currently inspected profile uses SF Mono Terminal at 11 pt. Preserve stock light/dark colors and the ANSI palette. Inset the terminal 8 pt from the leading edge and 6 pt from the top using its own background color.
- Import `.itermcolors` presets from the Terminal Theme menu. Apply foreground, background, cursor, cursor text, selection, selected text, and the 16 ANSI colors wherever provided. Fill missing supported fields from the default theme and reject malformed imports without losing the current selection. Apply the selection across tabs and windows, persist it across launches, and offer a reset to Basic. Font settings remain independent of the color preset.

## 3. Connect once and follow the active host

| User action | Required terminal and explorer behavior |
|---|---|
| Open a tab on the Mac | Start the local login shell. Opening the explorer shows local files. |
| Type ordinary interactive `ssh user@host` or `ssh alias` | Resolve the destination using SSH configuration. Attach the explorer after successful authentication. If a bare host has multiple saved logins, offer a choice. Respect an explicitly supplied username. |
| Choose **Connect via SSH** | Accept host/address, port (default 22), username, and password or a saved login. Allow one-time use and optional saving. Open the remote shell and attach the explorer to the same host/account. |
| Change layout or select another tab | Show that tab's session and location. Preserve transfers' original endpoints even if another tab becomes active. |
| Exit SSH normally | Restore the preceding verified session and its explorer location. For a single hop from the Mac, this returns to local files. |
| Authentication fails, the link drops, or a hop cannot be verified | Show the actual connection state. Distinguish disconnected remote files from local files. Disable stale remote writes and offer reconnect or explicit reattachment. |

Honor SSH aliases, custom ports, identity files, agent authentication, interactive MFA, host-key verification, and jump hosts. Prefer shared authenticated transport for shell and SFTP where supported. Keep a working shell usable if the server denies the SFTP subsystem.

**Host following and directory following are separate.** Host following is automatic. A directory-follow option may track shell navigation while still allowing independent browsing. An SSH command executed *inside* a remote shell may need remote integration before HerbsTerminal can identify the next hop. Track verified hops as a stack and restore the previous one on exit. A prompt, window title, or printed hostname is insufficient evidence to redirect file operations.

## 4. Explorer, editing, and transfers

| Capability | Expected behavior |
|---|---|
| Browse and manage | Show host, authenticated user, and current path. Support directory listing, path entry, hidden files, create file/folder, rename, and delete. Handle Windows drive paths, spaces, Unicode, case differences, and symbolic links according to the endpoint. |
| Transfer | Upload from Mac to remote and download from remote to Mac through explicit actions or drag-and-drop. Support files and directory trees. Show source, destination, size, progress, errors, cancel, and retry in a queue that remains accessible while using the shell. |
| Replace and resume | Resolve name conflicts before overwrite. Stage an upload under a temporary name where supported. After interruption, verify that the source and partial destination still match before resuming. Expose any server limitation on safe replacement. |
| Edit remotely | Open a working copy in the chosen Mac editor and send changes back to the original endpoint. Detect concurrent remote edits before overwriting. Preserve a recoverable draft after disconnect. Preserve file bytes, line endings, and permissions where supported. |
| Permissions | Use the authenticated file account. If shell privileges change through `sudo`, continue to identify the explorer's actual account. Make a privileged edit an explicit, separately authorized operation. |

## 5. Saved logins and CSV exchange

- Store host, port, username, and encrypted password in a **HerbsTerminal-owned SQLite `.db` file**. Keep the encryption key in macOS Keychain. Provide create, select, update, and delete operations. Allow several username/password pairs for one host. Passwords must stay out of process arguments, terminal history, and diagnostic logs.
- Provide GUI **Import CSV** and **Export CSV** using the header `host,port,username,password`. Support UTF-8, quoted commas, quotes, and embedded line breaks. Validate addresses and ports, preview conflicts, and make the duplicate policy explicit before committing an import. Apply accepted records transactionally.
- Export readable passwords only after explicit confirmation. Keep SSH private keys, Keychain material, and Tailcat pairing secrets outside the CSV. Report unavailable encryption keys without overwriting existing credentials. A machine migration must include a viable credential recovery path.
- **Acceptance example.** Save two accounts for one host, relaunch, select either account, export, import into a fresh store, and reconnect. A password containing a comma and a quote must round-trip exactly. A rejected import must preserve the previous store.

## 6. Multi-host commands

The Multi-Host Commands button opens a composer with selectable hosts/accounts. Display the destination list and shell type before execution. Submit the same command text concurrently to each selected target through independent execution channels. Do not inject keystrokes into interactive sessions that may be waiting at a password prompt or running an editor.

Keep stdout, stderr, exit status, duration, and execution state attributable to each host. Preserve literal quoting and line breaks. The operator chooses commands suitable for the selected shells, including PowerShell and POSIX shells. If contact is lost after dispatch, mark the outcome unknown. Retrying an uncertain command is an explicit per-host action. One host's failure must leave other results visible.

## 7. Tailcat pairing and connectivity

Use Tailcat as an alternate route when peers cannot reach each other by direct IP. The full GUI runs on the Mac. A compatible peer/helper must be running on the other machine. Its service configuration determines which local SSH or desktop endpoint can be reached.

- The Tailcat Peers toolbar action supports creating or accepting a pairing, naming the peer, reconnecting, and revoking access. Distinguish a one-time pairing from persistent unattended access.
- Show peer identity, connection state, and **Direct** or **Relayed** when known. Protect bearer addresses and persistent peer keys as secrets. Keep SSH host verification and endpoint authentication active over the tunnel.
- Use normal SSH/SFTP for terminal and files over the selected route. A route change must preserve endpoint identity. Recover from a disconnect without replaying commands or committing partial files.
- **Proposed implementation.** Pin and test compatible native Tailcat versions for macOS, Windows, and Linux. Verify NAT traversal and relay fallback independently. Public relay throughput and availability must be measured before making desktop or transfer performance commitments.

## 8. Remote desktop control

The Remote Control button opens a desktop for the active host. Provide a terminal invocation with the same destination semantics (proposed command `herbsterminal desktop`). Keep the shell and transfer queue alive while viewing the desktop. Offer view-only and interactive control where the endpoint supports them. Distinguish sharing the current user's screen from creating a separate graphical login.

| Target | Proposed desktop endpoint | Prerequisite |
|---|---|---|
| Windows | RDP, or a compatible VNC server | RDP hosting must be enabled on a supported Windows edition, or another desktop service must be installed |
| macOS | VNC-compatible Screen Sharing | Screen Sharing, compatible authentication, and permission for the intended account |
| Linux | Available RDP or VNC service | A configured graphical session or remote-login service; headless SSH-only hosts retain shell and file access |

Carry the desktop service over permitted SSH forwarding or an authenticated Tailcat route. SSH access alone does not supply a graphical desktop. Desktop credentials may differ from the SSH login. Report an unavailable service, denied forwarding, or missing host permission without disturbing the shell.

**Proposed viewer.** Embed Guacamole's JavaScript display and input client in a dedicated desktop pane. Connect it through a private local bridge to `guacd` and its RDP/VNC plugin. The plugin speaks the target protocol. Prototype Apple Silicon packaging, keyboard mapping, pointer coordinates, clipboard controls, resizing, and disconnect/reconnect before committing to the viewer. RustDesk-style attended control is a workflow reference; a custom cross-platform screen-capture agent is a separate scope decision.

## 9. Release acceptance matrix

Run the local suite through `script/test.sh` and the app launch check through `script/build_and_run.sh --verify`. The existing tests exercise local layout/session persistence, header alignment, tab search and metadata, Basic appearance, and theme persistence. Remote milestones need tests against live endpoints.

| Gate | Scenario and pass condition |
|---|---|
| Local workspace | On Apple Silicon, exercise macOS 15 and a later supported release. All three layouts retain the shell PID. New tabs have independent shells. The title remains centered at narrow and wide window sizes. |
| Appearance | Import a preset, switch tabs, relaunch, and reset to Basic. Verify text, cursor, selection, ANSI samples, and pane insets in light and dark appearances. |
| Single-host administration | On each remote OS, connect by typed SSH and GUI, browse, create, edit, upload, download, and exit to the local explorer. Compare transferred bytes. Exercise denied permissions and unavailable SFTP. |
| Session identity | Switch between two accounts on one host, use an alias and a jump host, reject a changed host key, and attempt an unverified nested hop. No file write may reach the wrong account or machine. |
| Transfer recovery | Interrupt a replacement upload, reconnect, and resume or safely restart. Verify final bytes and retained draft after a conflicting edit. |
| Credentials | Pass the CSV round trip and duplicate/error cases above. Inspect the database and logs for plaintext passwords. Verify key-unavailable behavior. |
| Multi-host | Run the same compatible command on three hosts. Include a failure and a disconnected host. Verify independent output and outcomes, with no automatic replay. |
| Tailcat | Pair machines on separate networks without public SSH exposure. Exercise direct and forced-relay routes, reconnect a persistent peer, revoke it, and verify access is denied afterward. |
| Desktop | Test RDP and VNC over the supported routes, keyboard and pointer input, view-only mode, and session recovery. An SSH-only host must give an actionable desktop error while its terminal remains usable. |

## 10. Delivery sequence and decisions to validate

1. **SSH and SFTP.** Deliver GUI and typed connections, verified session identity, transfers, remote editing, credential storage, and CSV exchange. Validate against one host of each target OS.
2. **Multi-host execution.** Deliver target selection, parallel dispatch, and per-host results. Test partial failure before adding saved host groups.
3. **Tailcat peers.** Deliver authenticated pairing, peer lifecycle, and route reporting. Test interrupted transfers over both direct and relayed paths.
4. **Remote desktop.** Validate the viewer and host services, then integrate the toolbar and terminal entry points.

Open decisions include nested SSH integration coverage, the exact privileged-edit workflow, the recovery procedure for a lost Keychain key, peer helper packaging and relay ownership, and the supported desktop authentication/session combinations. Record actual interoperability results by host OS, service version, and transport before declaring a combination supported.

## Design and protocol references

| Reference | Relevance |
|---|---|
| [TMOG](https://tmog.org/) and [Ptyxis](https://devsuite.app/ptyxis/) | Native, readable status presentation and compact terminal-first controls |
| [MobaXterm](https://mobaxterm.mobatek.net/features.html) | SSH-linked explorer and multi-host execution |
| [FilesRemote](https://github.com/allanrbo/filesremote) and [WinSCP transfer resume](https://winscp.net/eng/docs/resume) | Local-editor workflow, transfer staging and recovery |
| [File Browser](https://hub.docker.com/r/filebrowser/filebrowser) and [Xfce Thunar](https://docs.xfce.org/xfce/thunar/the-file-manager-window) | File actions and directory navigation |
| [OpenSSH configuration](https://man.openbsd.org/ssh_config) and [Tailcat](https://github.com/tailscale/tailcat) | Authentication, host routing, peer identity and relay behavior |
| [Guacamole architecture](https://guacamole.apache.org/doc/gug/guacamole-architecture.html) and [JavaScript client](https://guacamole.apache.org/doc/gug/guacamole-common-js.html) | Desktop gateway and embedded viewer responsibilities |
| [iTerm2 color presets](https://iterm2.com/documentation-preferences-profiles-colors.html) | Terminal theme interchange |
