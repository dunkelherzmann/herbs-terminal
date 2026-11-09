# Mac: what isn't production-ready yet

What the Mac version still needs before it can ship with as few bugs as possible: everything a feature test found broken or missing, and every feature no automatic test covers yet. Fix broken items first, one pull request each, and tick an item with its PR number once it is fixed and its test passes. `bugs.md` and `enhancements.md` stay the record of requests and releases.

## Next (top priority)

- [x] **Every menu in the window, none in the macOS menu bar.** (#67) All menus and submenus (Shell, Edit, View, Window, Help and the rest) move into the Main Menu in the window, as on Linux and Windows, so nothing needs a trip to the top of a wide screen. The macOS menu bar keeps only the app menu macOS always shows. Every shortcut keeps working, Undo, Cut, Copy, Paste and Select All in text fields included, and every item keeps its hover text and VoiceOver label. Describe the new menu in `SPECIFICATION.md` in the same PR. (§2, enhancements.md) *Asked 2026-11-09.*

<!-- feature-tests:start -->
## Feature test results (2026-11-09 15:02)

Written by `parity/tests/report.py`; rerun the tests and the report rather than editing this part.

### Not checked automatically (111)

Try these by hand before a release, or extend the test bridge so a test can check them.

- [ ] **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account,… (§2): checked as S10
- [ ] **W6** Export Session button and shortcut: whole scrollback to `<tab> <date time>.txt`. (§2): the command is there; saving goes through the system's save dialog, which the bridge can't fill
- [ ] **W11** Search button: searches files in the explorer, the scrollback otherwise. (§2): the command runs; whether the search field opens isn't reported by this platform's bridge yet
- [ ] **W13** Main Menu: Find in Terminal…. (§2): the command runs; whether the search field opens isn't reported by this platform's bridge yet
- [ ] **W17** Hover hints on every control after about half a second, also in the background; screen readers get… (§2): covered by parity/check.sh (hover texts through the accessibility tree)
- [ ] **T11** Session restore: tabs with folder, panes, explorer folder and name reopen at launch (on by… (§2): this platform's test bridge can't read or reopen a session yet
- [ ] **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it. (§2): visual: shown in the window's picture, not reported by the bridge
- [ ] **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it… (§2): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **B1** Right-click menu: Copy, Paste, Paste Escaped Text, Select All, Find. (§2): Copy, Paste, Paste Escaped Text and Select All work; Find… runs, but this platform's bridge doesn't report the find bar yet
- [ ] **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion. (§2): sound and flash can't be observed by the bridge
- [ ] **B7** Size badge (columns × rows) while resizing. (§2): this platform's test bridge can't resize the window yet
- [ ] **B8** Find in Terminal (scrollback search). (§2): the command is there; this platform's bridge doesn't report the find bar and its matches yet
- [ ] **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs. (§2): this platform's test bridge can't send mouse events yet; visual: needs the window's picture compared with the Mac's
- [ ] **B15** Typing with an input method (Chinese, Japanese, Korean): composition at the cursor, in the… (§2): this platform's test bridge can't drive an input method yet
- [ ] **R1** Named profiles; each tab uses one; new tabs keep the current tab's profile. (§3): this platform's test bridge can't make or choose profiles yet
- [ ] **R5** iTerm2 `.itermcolors` import (all colors); damaged files rejected; imported presets removable. (§3): needs the system's open dialog
- [ ] **R7** Settings ▸ Profiles: add, duplicate, rename, delete, choose the default; startup command and start… (§3): Settings opens; its Profiles page isn't read by the bridge yet
- [ ] **R8** Settings ▸ Text: any installed monospaced font, 6–72 pt, cursor shape and blink, opacity 20–100 %,… (§3): no test yet
- [ ] **R9** Settings ▸ Terminal: Option as Meta, scrollback 100–1,000,000, bell, where new tabs open, restore… (§3): no test yet
- [ ] **R10** Settings ▸ Window: columns × rows for new windows (default 100 × 30), size badge toggle, Apply to… (§3): no test yet
- [ ] **R11** Settings ▸ Colors: color scheme, presets, import and removal. (§3): no test yet
- [ ] **R12** Light and dark follow the system, for the whole app (dialogs and Settings included). (§3): no test yet
- [ ] **S1** Connect via SSH dialog: host, port (22), username, password or saved login; save or use once. (§4): no test yet
- [ ] **S2** Once logged in, the explorer moves to the same host and account. (§4): no test yet
- [ ] **S3** Typing `ssh user@host` or `ssh alias` in a local shell is followed like Connect via SSH (resolved… (§4): no test yet
- [ ] **S4** Exit or Disconnect returns the tab, title and explorer to this computer. (§4): no test yet
- [ ] **S5** Failed login or dropped link: a banner with the real state; title back to local. (§4): no test yet
- [ ] **S6** Shared connection (ControlMaster) so the explorer and transfers reuse the shell's login; keepalive… (§4): no test yet
- [ ] **S7** No command line, password or token on screen or in history; saved password through SSH_ASKPASS… (§4): no test yet
- [ ] **S8** Host-key questions, one-time codes and retries asked in the terminal. (§4): no test yet
- [ ] **S9** Your own `~/.ssh/config`, agent, keys and jump hosts are used. (§4): no test yet
- [ ] **S10** Connection details popover (account, host, port, route, remote home, time) with Disconnect and New… (§4): no test yet
- [ ] **E1** Places: Home, the user folders, Computer, Trash, mounted devices; on a host Home and File System. (§5): no test yet
- [ ] **E2** Bookmarks (shortcut), kept per host; Remove Bookmark. (§5): no test yet
- [ ] **E3** Back, Forward, Up, Home, Reload, show hidden files; Delete/BackSpace goes back. (§5): no test yet
- [ ] **E4** Clickable path segments and an editable location (accepts `~` and relative paths). (§5): no test yet
- [ ] **E5** Double-click or Return opens; links to folders open as folders. (§5): no test yet
- [ ] **E6** File Actions menu: Upload, Download, Undo, Redo, Cut, Copy, Paste, Delete, Select All, Find. (§5): no test yet
- [ ] **E7** Local: copy, move, move to Trash with "name copy" names; never overwrites. (§5): no test yet
- [ ] **E8** Local: Undo and Redo, named after the action. (§5): no test yet
- [ ] **E9** System file clipboard works both ways (Finder / file managers / File Explorer). (§5): no test yet
- [ ] **E10** Host: move (undoable), copy on the host, delete after asking (whole folders). (§5): no test yet
- [ ] **E11** Pasting local files into a host uploads them; host items pasted locally download. (§5): no test yet
- [ ] **E12** A folder can't be moved or copied into itself. (§5): no test yet
- [ ] **E13** New Folder, New File (free "untitled" name), Rename; undoable locally, rename undoable on a host. (§5): no test yet
- [ ] **E14** Search files (Find). (§5): no test yet
- [ ] **E15** Open in Text Editor, Open with Default App, Reveal in Finder / Show in Files. (§5): no test yet
- [ ] **E16** Open with Administrator Mode… on an item. (§5): no test yet
- [ ] **X1** Upload and download single files and folder trees. (§5): no test yet
- [ ] **X2** Progress strip with Cancel and Retry; Clear Finished. (§5): no test yet
- [ ] **X3** Up to 16 requests in flight. (§5): no test yet
- [ ] **X4** A server silent for 30 s ends the request with an error; Reload works again. (§5): no test yet
- [ ] **X5** Local copy, move and Trash run in the background with a "Copying…" note. (§5): no test yet
- [ ] **X6** Staged uploads (temporary name, exclusive, renamed into place). (§5): no test yet
- [ ] **X7** Name clashes get new names; links to folders inside trees are skipped. (§5): no test yet
- [ ] **D1** Text files open as a tab in the window (double-click, Open in Text Editor); text detection by type… (§5): no test yet
- [ ] **D2** New File… opens straight in the editor (locally and on hosts). (§5): no test yet
- [ ] **D3** Monospaced font, undo, Find. (§5): no test yet
- [ ] **D4** Wrap Lines. (§5): no test yet
- [ ] **D5** Status line: line, column, line count, encoding, line endings. (§5): no test yet
- [ ] **D6** Save shortcut and button; • on the tab while unsaved. (§5): no test yet
- [ ] **D7** Closing the tab, window or app asks before discarding. (§5): no test yet
- [ ] **D8** Changed elsewhere since opened: asks before replacing. (§5): no test yet
- [ ] **D9** Keeps encoding (UTF-8, UTF-16, Latin-1), line endings and permissions; links edited at their… (§5): no test yet
- [ ] **D10** Refuses files over 20 MB and binary files, with a message. (§5): no test yet
- [ ] **G1** Get Info… on one or more items: name, location, kind, size, modified, `ls -l` permissions with… (§5): no test yet
- [ ] **G2** Read / write / execute for owner, group, others; set-UID, set-GID, sticky; octal field in step. (§5): no test yet
- [ ] **G3** Owner and group by name or number (looked up on the host). (§5): no test yet
- [ ] **G4** Hidden and Locked (Mac only). (§5): no test yet
- [ ] **G5** Apply to enclosed items; Apply changes only what was edited; Revert. (§5): no test yet
- [ ] **G6** Works on this computer and on hosts. (§5): no test yet
- [ ] **A1** Lock button starts Administrator mode for the tab, locally and on the connected host. (§5): no test yet
- [ ] **A2** Every explorer action runs as root (sftp-server under sudo). (§5): no test yet
- [ ] **A3** sudo password checked first, never stored; password-free sudo not asked. (§5): no test yet
- [ ] **A4** Safe root delete rules. (§5): no test yet
- [ ] **A5** Red bar until you leave; ends with the SSH session. (§5): no test yet
- [ ] **L1** Login database (host, port, username, password), several logins per host, host names ignore case. (§6): no test yet
- [ ] **L2** Administrator Password: AES-GCM with PBKDF2 600,000 rounds; locked at start, unlock once per… (§6): no test yet
- [ ] **L3** Change the Administrator Password re-encrypts everything; removing it asks. (§6): no test yet
- [ ] **L4** Plain text needs an explicit choice and a second confirmation. (§6): no test yet
- [ ] **L5** First use: explanation with Create Administrator Password, Store as Plain Text, Not Now. (§6): no test yet
- [ ] **L6** Manage Logins window: list with host, port, username, hidden password, encrypted or plain. (§6): no test yet
- [ ] **L7** Opening asks for the Administrator Password; Skip shows plain-text logins with an unlock bar. (§6): no test yet
- [ ] **L8** New and Edit form with Show password. (§6): no test yet
- [ ] **L9** Import (CSV, all-or-nothing). (§6): no test yet
- [ ] **L10** Export ticked logins (checkbox column with select-all heading), file readable only by you,… (§6): no test yet
- [ ] **L11** Double-click edits; Delete key or right-click removes after a confirmation defaulting to Cancel. (§6): no test yet
- [ ] **U1** MultiExec grid of every terminal in the window, each with number, title and include checkbox. (§7): no test yet
- [ ] **U2** Typing or pasting into an included terminal goes to all included ones. (§7): no test yet
- [ ] **U3** Pick terminal by number, close only the active one, Esc leaves. (§7): no test yet
- [ ] **U4** Bar: count of receivers, New Tab, Connect via SSH, Include All, Close All (asks), Exit MultiExec. (§7): no test yet
- [ ] **U5** Only your own input is broadcast. (§7): no test yet
- [ ] **U6** Run Command on Hosts: targets are selected saved logins and the live connection, own ssh channel… (§7): no test yet
- [ ] **U7** Results per host: outcome, exit code, duration, output (64 KB cap, marked truncated). (§7): no test yet
- [ ] **C1** Add a peer: name, username, secret address, One-time or Persistent; addresses protected like logins. (§8): no test yet
- [ ] **C2** Ping: Direct or Relayed with latency. (§8): no test yet
- [ ] **C3** Connect: shell and explorer through Tailcat, address never in arguments or history. (§8): no test yet
- [ ] **C4** Clear message when nothing answers SSH on the peer. (§8): no test yet
- [ ] **C5** Remove a peer. (§8): no test yet
- [ ] **C6** Share this computer: `tailcat serve`, one-time or persistent, address with Copy and Stop; checks… (§8): no test yet
- [ ] **C7** Unlock… / Lock… button with the vault states. (§8): no test yet
- [ ] **Y1** Every control has a screen-reader name and hover hint (hint without repeating the name). (§9): no test yet
- [ ] **Y2** Selected tab announced (and bold); toggles announce on/off; MultiExec checkboxes named. (§9): no test yet
- [ ] **Y3** Password fields have visible labels. (§9): no test yet
- [ ] **Y4** Resizing follows Reduce Motion; visual bell limited to twice a second. (§9): no test yet
- [ ] **Y5** Shared accessibility identifiers on the toolbar. (§9): no test yet
- [ ] **Z1** Settings, profiles or peers that can't be read are set aside, not overwritten. (§10): no test yet
- [ ] **Z2** Login database that can't be opened: in-memory store, Manage Logins off. (§10): no test yet
- [ ] **Z3** Export files readable only by you. (§10): no test yet
- [ ] **Z4** A dropped connection is an error, never a crash. (§10): no test yet
- [ ] **Z5** Self-contained: nothing extra to install. (§10): no test yet

<!-- feature-tests:end -->
