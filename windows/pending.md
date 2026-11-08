# Windows: closing the gap with the Mac and Linux versions

What the Windows version still needs so it works 1:1 like the Mac and Linux versions, in the order it's being
built. Each item names the `SPECIFICATION.md` section it follows and lands in its own pull request, stacked on the
one before. An item is ticked when its PR is open, built and tested on Windows, with the PR number; the
project's `enhancements.md` and `bugs.md` stay the record of requests and releases.

## To build

- [x] **1. File explorer, this PC's files** (#17) (§5, §12). Places, location bar with back / forward / up / home and
      an editable location, the file list, opening items, Copy / Cut / Paste shared with File Explorer, Recycle
      Bin, rename, New Folder / New File, hidden files, Properties, Open in New Terminal Tab, and the terminal ⇄
      explorer switch (toolbar button, Ctrl+Shift+X).
- [x] **2. File explorer, hosts** (#18) (§4, §5): browse the SSH tab's host over SFTP (Windows OpenSSH has no
      `ControlMaster`, so the explorer opens its own session with the saved password), Home and File System
      places, rename, delete, New Folder / New File, copy and move on the host.
- [x] **3. Transfers** (#19) (§5): upload and download files and folder trees, the progress strip with Cancel and
      Retry, staged uploads, new names instead of overwriting; copy between this PC and a host with the clipboard.
- [x] **4. Text editor** (#20) (§5): open text files as a tab, Find, Wrap Lines, status line, encodings and line endings
      kept, Save locally and to hosts, unsaved-changes prompts.
- [x] **5. Get Info on hosts** (#21) (§5): permissions, owner and group, Apply to enclosed items.
- [x] **6. Administrator mode on hosts** (#22) (§5): SFTP under `sudo` over the tab's connection, the red bar.
- [ ] **7. Undo and Redo** in the explorer (§5), and bookmarks per host.
- [ ] **8. Split panes** (§2): Split Vertically / Horizontally, Close Pane, Next / Previous Pane, the focused
      pane outline.
- [ ] **9. MultiExec** (§7): every terminal in a grid, typing into all of them, include / leave out.
- [ ] **10. Run Command on Hosts** (§7).
- [ ] **11. Find in Terminal** (§2), the terminal's right-click menu, Paste Escaped Text.
- [ ] **12. Named profiles** (§3): New Tab with Profile, Use Profile, editing profiles in Settings.
- [ ] **13. Session restore** (§2) and the size badge while resizing.
- [ ] **14. Following an `ssh` typed in a local tab** (§4), and the explorer following that host.
- [ ] **15. Tailcat peers** (§8): pairing, sharing, connecting through Tailcat, the Lock / Unlock button.
- [ ] **16. Accessibility** (§9): UI Automation names for the toolbar, tabs and terminal.
- [ ] **17. Dark mode for Settings and dialogs**, mouse reporting for full-screen programs, IME composition.
- [ ] **18. App icon, MSIX installer and code signing** (§1).

## Done

- [x] Terminal with tabs, ConPTY, colors, scrollback, selection, copy and paste (#1)
- [x] Settings (#2)
- [x] SSH with saved logins and Manage Logins (#3)
- [x] Toolbar, Main Menu and tab strip laid out as on Linux; self-contained package (#4)
- [x] SSH keepalive, Take Screenshot, toolbar spacing (#5)
- [x] Dropping files on the terminal types their paths (#15)

<!-- feature-tests:start -->
## Feature test results (2026-11-08 07:49)

Written by `parity/tests/report.py`; rerun the tests and the report rather than editing this part.

### Broken (13)

A test ran and the feature didn't do what the Mac version does.

- [ ] **W3** Title in the middle: `user@host ~`, following the shell's title, current folder and foreground… (§2): The title follows the folder and the program: no answer to state in 10 s (did the app quit?)
- [ ] **W4** Secrets in a command line (`user:pass@`, `--password=`, `*_TOKEN=`) hidden in the title. (§2): Secrets in a command line are hidden in the title: the program isn't in the title, so hiding wasn't shown: 'parity@scene '
- [ ] **T2** Tabs numbered "Terminal N", lowest free number. (§2): New tabs take the lowest free number: no answer to state in 10 s (did the app quit?)
- [ ] **T7** Close Tab shortcut; on the last tab it closes the window. (§2): Close Tab: expected one tab left (saw: 1 window(s), tabs ['Terminal 1', 'Terminal 2'], 1 pane(s), title 'parity@scene' '', dialogs ['Close Terminal 2?'], last lines ['$'])
- [ ] **T9** Ask before closing a tab, window or the app while a program or SSH session runs. (§2): Asks before closing a tab with a running program: the app crashed or quit during the test
- [ ] **T10** New tabs open in the current tab's folder or home (Settings), or the profile's start folder. (§2): New tabs open in the current tab's folder: no answer to state in 10 s (did the app quit?)
- [ ] **M3** Shell menu: MultiExec, Run Command on Hosts…. (§2): Menu commands: multiexec, run-on-hosts: the app crashed or quit during the test
- [ ] **R2** A profile holds font, size, zoom, cursor shape and blink, color preset, background opacity and… (§3): A profile's startup command runs when a tab opens: expected the startup command's output in the new tab (saw: 1 window(s), tabs ['Terminal 1', 'Terminal 2'], 1 pane(s), title 'parity@scene' '', dialogs [], last lines…
- [ ] **E7** Local: copy, move, move to Trash with "name copy" names; never overwrites. (§5): Copy and paste here gives a 'copy' name: no answer to state in 10 s (did the app quit?)
- [ ] **E8** Local: Undo and Redo, named after the action. (§5): Undo and Redo a move to Trash: no answer to command in 10 s (did the app quit?)
- [ ] **E13** New Folder, New File (free "untitled" name), Rename; undoable locally, rename undoable on a host. (§5): New Folder and Rename: expected the New Folder dialog (saw: 1 window(s), tabs ['Terminal 1'], 1 pane(s), title 'parity@scene' '', dialogs [], last lines ['$'])
- [ ] **D2** New File… opens straight in the editor (locally and on hosts). (§5): New File opens in the editor: expected the New File dialog (saw: 1 window(s), tabs ['Terminal 1'], 1 pane(s), title 'parity@scene' '', dialogs [], last lines ['$'])
- [ ] **L5** First use: explanation with Create Administrator Password, Store as Plain Text, Not Now. (§6): First use explains the Administrator Password: expected the Administrator Password explanation (saw: 1 window(s), tabs ['Terminal 1'], 1 pane(s), title 'parity@scene' '', dialogs ['Connect via SSH'], last lines ['$'])

### Missing (23)

The command isn't there, or it's greyed out.

- [ ] **W9** MultiExec button (toggle). (§2): MultiExec button: `multiexec` is greyed out
- [ ] **W10** Tailcat Peers button. (§2): Tailcat Peers: no `tailcat` command
- [ ] **W11** Search button: searches files in the explorer, the scrollback otherwise. (§2): Search: `find` is not there
- [ ] **W13** Main Menu: Find in Terminal…. (§2): Find in Terminal: `find-in-terminal` is greyed out
- [ ] **T8** Typing `exit` closes pane, then tab, then window; in the last window it quits; in SSH it returns… (§2): exit closes the pane, then the tab: `split-vertical` is greyed out
- [ ] **P1** Split Vertically (side by side) and Split Horizontally (stacked); panes split again and share… (§2): Split Vertically and Horizontally: `split-vertical` is greyed out
- [ ] **P2** A new pane uses the current pane's profile and folder. (§2): A new pane starts in the current pane's folder: `split-vertical` is greyed out
- [ ] **P3** Close Pane shortcut; `exit` closes a pane. (§2): Close Pane: `split-vertical` is greyed out
- [ ] **P4** Select Next / Previous Pane. (§2): Select Next / Previous Pane: `split-vertical` is greyed out
- [ ] **B8** Find in Terminal (scrollback search). (§2): Find in Terminal: `find-in-terminal` is greyed out
- [ ] **B9** Copy and paste; Paste Escaped Text. (§2): Copy, Paste and Paste Escaped Text: `paste-escaped` is not there
- [ ] **M1** Shell menu: New Tab, Export Session, Take Screenshot, New Tab with Profile, Use Profile. (§2): Menu commands: new-tab, export-session, take-screenshot, new-tab-profile, use-profile: `new-tab-profile` is greyed out
- [ ] **M2** Shell menu: Split Vertically / Horizontally, Close Pane, Next / Previous Pane. (§2): Menu commands: split-vertical, split-horizontal, close-pane, next-pane, previous-pane: `split-vertical` is greyed out
- [ ] **R1** Named profiles; each tab uses one; new tabs keep the current tab's profile. (§3): Named profiles: `new-tab-profile` is greyed out
- [ ] **E6** File Actions menu: Upload, Download, Undo, Redo, Cut, Copy, Paste, Delete, Select All, Find. (§5): File Actions commands: `explorer.undo` is not there
- [ ] **E14** Search files (Find). (§5): Find files: `explorer.find` is not there
- [ ] **U1** MultiExec grid of every terminal in the window, each with number, title and include checkbox. (§7): Every terminal joins the grid, included: `split-vertical` is greyed out
- [ ] **U2** Typing or pasting into an included terminal goes to all included ones. (§7): Typing reaches every included terminal once; an excluded one is left out: `split-vertical` is greyed out
- [ ] **U3** Pick terminal by number, close only the active one, Esc leaves. (§7): Leave MultiExec: `split-vertical` is greyed out
- [ ] **U4** Bar: count of receivers, New Tab, Connect via SSH, Include All, Close All (asks), Exit MultiExec. (§7): Close All: `split-vertical` is greyed out
- [ ] **U5** Only your own input is broadcast. (§7): Text the app types isn't broadcast: `split-vertical` is greyed out; Connecting in a new tab while MultiExec is on types only into that tab: `split-vertical` is greyed out
- [ ] **U6** Run Command on Hosts: targets are selected saved logins and the live connection, own ssh channel… (§7): Run Command on Hosts window: `run-on-hosts` is greyed out
- [ ] **C1** Add a peer: name, username, secret address, One-time or Persistent; addresses protected like logins. (§8): Tailcat Peers: add a peer: no `tailcat` command

### Not checked automatically (91)

Try these by hand before a release, or extend the test bridge so a test can check them.

- [ ] **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account,… (§2): needs an SSH test host (not set up yet)
- [ ] **W6** Export Session button and shortcut: whole scrollback to `<tab> <date time>.txt`. (§2): the command is there; saving goes through the system's save dialog, which the bridge can't fill
- [ ] **W17** Hover hints on every control after about half a second, also in the background; screen readers get… (§2): covered by parity/check.sh (hover texts through the accessibility tree)
- [ ] **T11** Session restore: tabs with folder, panes, explorer folder and name reopen at launch (on by… (§2): the test scene never saves or restores a session
- [ ] **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it. (§2): visual: shown in the window's picture, not reported by the bridge
- [ ] **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it… (§2): needs an SSH test host (not set up yet)
- [ ] **B1** Right-click menu: Copy, Paste, Paste Escaped Text, Select All, Find. (§2): the right-click menu needs a pointer click the bridge doesn't make yet
- [ ] **B2** Right-click menu: Clear to Start, Clear Scrollback, Reset. (§2): the right-click menu needs a pointer click the bridge doesn't make yet
- [ ] **B3** Right-click menu: Split Vertically, Split Horizontally, Close Pane, New Tab, Show File Explorer. (§2): the right-click menu needs a pointer click the bridge doesn't make yet
- [ ] **B4** Right-click menu: Connect via SSH / Disconnect; Bigger, Smaller, Settings. (§2): the right-click menu needs a pointer click the bridge doesn't make yet
- [ ] **B5** Dropping files types their paths, quoted for the shell. (§2): needs pointer or keyboard input the test bridge doesn't reach yet
- [ ] **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion. (§2): sound and flash can't be observed by the bridge
- [ ] **B7** Size badge (columns × rows) while resizing. (§2): needs a window resize by the pointer
- [ ] **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs. (§2): visual: needs the window's picture compared with the Mac's
- [ ] **R5** iTerm2 `.itermcolors` import (all colors); damaged files rejected; imported presets removable. (§3): needs the system's open dialog
- [ ] **R7** Settings ▸ Profiles: add, duplicate, rename, delete, choose the default; startup command and start… (§3): Settings opens; its Profiles page isn't read by the bridge yet
- [ ] **R8** Settings ▸ Text: any installed monospaced font, 6–72 pt, cursor shape and blink, opacity 20–100 %,… (§3): Settings opens; its Text page isn't read by the bridge yet
- [ ] **R9** Settings ▸ Terminal: Option as Meta, scrollback 100–1,000,000, bell, where new tabs open, restore… (§3): Settings opens; its Terminal page isn't read by the bridge yet
- [ ] **R10** Settings ▸ Window: columns × rows for new windows (default 100 × 30), size badge toggle, Apply to… (§3): Settings opens; its Window page isn't read by the bridge yet
- [ ] **R11** Settings ▸ Colors: color scheme, presets, import and removal. (§3): Settings opens; its Colors page isn't read by the bridge yet
- [ ] **R12** Light and dark follow the system, for the whole app (dialogs and Settings included). (§3): visual: needs pictures in light and dark mode
- [ ] **S2** Once logged in, the explorer moves to the same host and account. (§4): needs an SSH test host (not set up yet)
- [ ] **S3** Typing `ssh user@host` or `ssh alias` in a local shell is followed like Connect via SSH (resolved… (§4): needs an SSH test host (not set up yet)
- [ ] **S4** Exit or Disconnect returns the tab, title and explorer to this computer. (§4): needs an SSH test host (not set up yet)
- [ ] **S5** Failed login or dropped link: a banner with the real state; title back to local. (§4): needs an SSH test host (not set up yet)
- [ ] **S6** Shared connection (ControlMaster) so the explorer and transfers reuse the shell's login; keepalive… (§4): needs an SSH test host (not set up yet)
- [ ] **S7** No command line, password or token on screen or in history; saved password through SSH_ASKPASS… (§4): needs an SSH test host (not set up yet)
- [ ] **S8** Host-key questions, one-time codes and retries asked in the terminal. (§4): needs an SSH test host (not set up yet)
- [ ] **S9** Your own `~/.ssh/config`, agent, keys and jump hosts are used. (§4): needs an SSH test host (not set up yet)
- [ ] **S10** Connection details popover (account, host, port, route, remote home, time) with Disconnect and New… (§4): needs an SSH test host (not set up yet)
- [ ] **E1** Places: Home, the user folders, Computer, Trash, mounted devices; on a host Home and File System. (§5): checked in the accessibility tree by parity/check.sh; the bridge doesn't report places
- [ ] **E2** Bookmarks (shortcut), kept per host; Remove Bookmark. (§5): needs pointer or keyboard input the test bridge doesn't reach yet
- [ ] **E3** Back, Forward, Up, Home, Reload, show hidden files; Delete/BackSpace goes back. (§5): going into a folder works; Back, Forward, Up and Home are buttons the bridge doesn't press yet
- [ ] **E4** Clickable path segments and an editable location (accepts `~` and relative paths). (§5): needs pointer or keyboard input the test bridge doesn't reach yet
- [ ] **E9** System file clipboard works both ways (Finder / file managers / File Explorer). (§5): would use the system clipboard
- [ ] **E10** Host: move (undoable), copy on the host, delete after asking (whole folders). (§5): needs an SSH test host (not set up yet)
- [ ] **E11** Pasting local files into a host uploads them; host items pasted locally download. (§5): needs an SSH test host (not set up yet)
- [ ] **E16** Open with Administrator Mode… on an item. (§5): needs a sudo password (not automated)
- [ ] **X1** Upload and download single files and folder trees. (§5): needs an SSH test host (not set up yet)
- [ ] **X2** Progress strip with Cancel and Retry; Clear Finished. (§5): needs an SSH test host (not set up yet)
- [ ] **X3** Up to 16 requests in flight. (§5): needs an SSH test host (not set up yet)
- [ ] **X4** A server silent for 30 s ends the request with an error; Reload works again. (§5): needs an SSH test host (not set up yet)
- [ ] **X5** Local copy, move and Trash run in the background with a "Copying…" note. (§5): needs a large folder and timing; not automated yet
- [ ] **X6** Staged uploads (temporary name, exclusive, renamed into place). (§5): needs an SSH test host (not set up yet)
- [ ] **X7** Name clashes get new names; links to folders inside trees are skipped. (§5): needs an SSH test host (not set up yet)
- [ ] **D3** Monospaced font, undo, Find. (§5): the bridge can't type into the editor or read its status yet
- [ ] **D4** Wrap Lines. (§5): the bridge can't type into the editor or read its status yet
- [ ] **D5** Status line: line, column, line count, encoding, line endings. (§5): the bridge can't type into the editor or read its status yet
- [ ] **D6** Save shortcut and button; • on the tab while unsaved. (§5): the bridge can't type into the editor or read its status yet
- [ ] **D7** Closing the tab, window or app asks before discarding. (§5): the bridge can't type into the editor or read its status yet
- [ ] **D8** Changed elsewhere since opened: asks before replacing. (§5): the bridge can't type into the editor or read its status yet
- [ ] **D9** Keeps encoding (UTF-8, UTF-16, Latin-1), line endings and permissions; links edited at their… (§5): the bridge can't type into the editor or read its status yet
- [ ] **D10** Refuses files over 20 MB and binary files, with a message. (§5): the bridge can't type into the editor or read its status yet
- [ ] **G1** Get Info… on one or more items: name, location, kind, size, modified, `ls -l` permissions with… (§5): the Get Info window isn't driven by the bridge yet
- [ ] **G2** Read / write / execute for owner, group, others; set-UID, set-GID, sticky; octal field in step. (§5): the Get Info window isn't driven by the bridge yet
- [ ] **G3** Owner and group by name or number (looked up on the host). (§5): the Get Info window isn't driven by the bridge yet
- [ ] **G4** Hidden and Locked (Mac only). (§5): Mac only
- [ ] **G5** Apply to enclosed items; Apply changes only what was edited; Revert. (§5): the Get Info window isn't driven by the bridge yet
- [ ] **G6** Works on this computer and on hosts. (§5): the Get Info window isn't driven by the bridge yet
- [ ] **A1** Lock button starts Administrator mode for the tab, locally and on the connected host. (§5): needs a sudo password (not automated)
- [ ] **A2** Every explorer action runs as root (sftp-server under sudo). (§5): needs a sudo password (not automated)
- [ ] **A3** sudo password checked first, never stored; password-free sudo not asked. (§5): needs a sudo password (not automated)
- [ ] **A4** Safe root delete rules. (§5): needs a sudo password (not automated)
- [ ] **A5** Red bar until you leave; ends with the SSH session. (§5): needs a sudo password (not automated)
- [ ] **L1** Login database (host, port, username, password), several logins per host, host names ignore case. (§6): covered by the unit and self tests of the shared vault code
- [ ] **L2** Administrator Password: AES-GCM with PBKDF2 600,000 rounds; locked at start, unlock once per… (§6): covered by the unit and self tests of the shared vault code
- [ ] **L3** Change the Administrator Password re-encrypts everything; removing it asks. (§6): covered by the unit and self tests of the shared vault code
- [ ] **L4** Plain text needs an explicit choice and a second confirmation. (§6): covered by the unit and self tests of the shared vault code
- [ ] **L6** Manage Logins window: list with host, port, username, hidden password, encrypted or plain. (§6): the Manage Logins window isn't driven by the bridge yet
- [ ] **L7** Opening asks for the Administrator Password; Skip shows plain-text logins with an unlock bar. (§6): the Manage Logins window isn't driven by the bridge yet
- [ ] **L8** New and Edit form with Show password. (§6): the Manage Logins window isn't driven by the bridge yet
- [ ] **L9** Import (CSV, all-or-nothing). (§6): the Manage Logins window isn't driven by the bridge yet
- [ ] **L10** Export ticked logins (checkbox column with select-all heading), file readable only by you,… (§6): the Manage Logins window isn't driven by the bridge yet
- [ ] **L11** Double-click edits; Delete key or right-click removes after a confirmation defaulting to Cancel. (§6): the Manage Logins window isn't driven by the bridge yet
- [ ] **U7** Results per host: outcome, exit code, duration, output (64 KB cap, marked truncated). (§7): needs an SSH test host (not set up yet)
- [ ] **C2** Ping: Direct or Relayed with latency. (§8): needs a second machine running tailcat
- [ ] **C3** Connect: shell and explorer through Tailcat, address never in arguments or history. (§8): needs a second machine running tailcat
- [ ] **C4** Clear message when nothing answers SSH on the peer. (§8): needs a second machine running tailcat
- [ ] **C5** Remove a peer. (§8): needs a second machine running tailcat
- [ ] **C6** Share this computer: `tailcat serve`, one-time or persistent, address with Copy and Stop; checks… (§8): needs a second machine running tailcat
- [ ] **C7** Unlock… / Lock… button with the vault states. (§8): the Tailcat window isn't driven by the bridge yet
- [ ] **Y1** Every control has a screen-reader name and hover hint (hint without repeating the name). (§9): covered by parity/check.sh and a screen-reader pass
- [ ] **Y2** Selected tab announced (and bold); toggles announce on/off; MultiExec checkboxes named. (§9): needs a screen reader
- [ ] **Y3** Password fields have visible labels. (§9): covered by the accessibility tree; not automated here
- [ ] **Y4** Resizing follows Reduce Motion; visual bell limited to twice a second. (§9): visual
- [ ] **Y5** Shared accessibility identifiers on the toolbar. (§9): covered by parity/check.sh
- [ ] **Z1** Settings, profiles or peers that can't be read are set aside, not overwritten. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z2** Login database that can't be opened: in-memory store, Manage Logins off. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z3** Export files readable only by you. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z4** A dropped connection is an error, never a crash. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z5** Self-contained: nothing extra to install. (§10): checked by each platform's packaging script

<!-- feature-tests:end -->
