# Feature list: what the Mac version does

The reference for checking the Linux and Windows versions feature by feature. It is taken from the Mac code and
`SPECIFICATION.md` (sections 2–10). Each feature has an id, so results can point at it. Platform shortcuts differ
(⌘ on the Mac, Ctrl/Alt on Linux and Windows, see SPECIFICATION.md §11); the feature is what has to match.

When the Mac gains a feature, add it here with the next free id in its group.

## W: Window and toolbar

- **W1** New Tab button.
- **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account, host, port, route, remote home, time connected) with Disconnect and New Connection.
- **W3** Title in the middle: `user@host ~`, following the shell's title, current folder and foreground program; home shown as `~`.
- **W4** Secrets in a command line (`user:pass@`, `--password=`, `*_TOKEN=`) hidden in the title.
- **W5** Double-click the title: default window size and text zoom. Right-click: make the current size and text size the defaults.
- **W6** Export Session button and shortcut: whole scrollback to `<tab> <date time>.txt`.
- **W7** Take Screenshot button and shortcut: picture of the window to the clipboard.
- **W8** Show File Explorer / Show Terminal button.
- **W9** MultiExec button (toggle).
- **W10** Tailcat Peers button.
- **W11** Search button: searches files in the explorer, the scrollback otherwise.
- **W12** Main Menu: New Tab, New Window, Connect via SSH…, Open Tabs list.
- **W13** Main Menu: Find in Terminal….
- **W14** Main Menu ▸ Zoom: Bigger, Smaller, Default.
- **W15** Main Menu ▸ Appearance: System / Light / Dark, color preset list, Import iTerm2 Color Preset…, Restore Defaults.
- **W16** Main Menu: Toggle Full Screen, Settings…, About (author and GitHub link).
- **W17** Hover hints on every control after about half a second, also in the background; screen readers get the same text.
- **W18** New Window.
- **W19** Every menu in the window: on the Mac the system menu bar holds only the app menu, the Main Menu has Edit, Shell and Window submenus, Hide and Quit, and every shortcut still works. On Linux and Windows the Main Menu holds Edit, Shell and Window in the Mac's order.

## T: Tabs

- **T1** Each tab keeps its own shell, scrollback, explorer location and connection; switching keeps sessions running.
- **T2** Tabs numbered "Terminal N", lowest free number.
- **T3** Rename a tab: double-click, right-click menu, Rename Tab shortcut.
- **T4** Reorder: drag, Move Tab Left / Right.
- **T5** Show Tab 1–8 and Last Tab shortcuts; keyboard focus follows.
- **T6** Previous / Next Tab shortcuts.
- **T7** Close Tab shortcut; on the last tab it closes the window.
- **T8** Typing `exit` closes pane, then tab, then window; in the last window it quits; in SSH it returns to the local shell.
- **T9** Ask before closing a tab, window or the app while a program or SSH session runs.
- **T10** New tabs open in the current tab's folder or home (Settings), or the profile's start folder.
- **T11** Session restore: tabs with folder, panes, explorer folder and name reopen at launch (on by default; remote tabs come back local; no scrollback).

## P: Split panes

- **P1** Split Vertically (side by side) and Split Horizontally (stacked); panes split again and share space equally.
- **P2** A new pane uses the current pane's profile and folder.
- **P3** Close Pane shortcut; `exit` closes a pane.
- **P4** Select Next / Previous Pane.
- **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it.
- **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it closes.

## B: Terminal behavior

- **B1** Right-click menu: Copy, Paste, Paste Escaped Text, Select All, Find.
- **B2** Right-click menu: Clear to Start, Clear Scrollback, Reset.
- **B3** Right-click menu: Split Vertically, Split Horizontally, Close Pane, New Tab, Show File Explorer.
- **B4** Right-click menu: Connect via SSH / Disconnect; Bigger, Smaller, Settings.
- **B5** Dropping files types their paths, quoted for the shell.
- **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion.
- **B7** Size badge (columns × rows) while resizing.
- **B8** Find in Terminal (scrollback search).
- **B9** Copy and paste; Paste Escaped Text.
- **B10** Clear to Start, Clear Scrollback.
- **B11** Reset and Hard Reset.
- **B12** Zoom: Bigger, Smaller, Default; zoom saved in the profile, Default clears it.
- **B13** Secure Keyboard Entry (Mac only; Linux and Windows are exempt).
- **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs.
- **B15** Typing with an input method (Chinese, Japanese, Korean): composition at the cursor, in the terminal's font.

## M: Menus

- **M1** Shell menu: New Tab, Export Session, Take Screenshot, New Tab with Profile, Use Profile.
- **M2** Shell menu: Split Vertically / Horizontally, Close Pane, Next / Previous Pane.
- **M3** Shell menu: MultiExec, Run Command on Hosts….
- **M4** Shell menu: New Remote Connection, Disconnect.
- **M5** Shell menu: Previous / Next Tab, Rename Tab, Move Tab Left / Right.
- **M6** Shell menu: Reset, Hard Reset.
- **M7** Edit: Clear to Start, Clear Scrollback.
- **M8** View: Bigger, Smaller, Default.
- **M9** Window: Show Tab 1–8, Show Last Tab.

## R: Profiles, appearance and Settings

- **R1** Named profiles; each tab uses one; new tabs keep the current tab's profile.
- **R2** A profile holds font, size, zoom, cursor shape and blink, color preset, background opacity and blur, Option as Meta, scrollback, bell, startup command and start folder.
- **R3** Default look: Basic profile, 13 pt, Terminal's light and dark colors and ANSI palette.
- **R4** Color presets: Basic, Solarized Dark/Light, Tango Dark/Light, Gruvbox Dark, Nord.
- **R5** iTerm2 `.itermcolors` import (all colors); damaged files rejected; imported presets removable.
- **R6** Restore Defaults asks first, then resets font, size, zoom, cursor, colors, transparency and color scheme.
- **R7** Settings ▸ Profiles: add, duplicate, rename, delete, choose the default; startup command and start folder.
- **R8** Settings ▸ Text: any installed monospaced font, 6–72 pt, cursor shape and blink, opacity 20–100 %, blur, live preview.
- **R9** Settings ▸ Terminal: Option as Meta, scrollback 100–1,000,000, bell, where new tabs open, restore at launch, ask before closing.
- **R10** Settings ▸ Window: columns × rows for new windows (default 100 × 30), size badge toggle, Apply to Open Windows, Use Front Window's Size, Reset.
- **R11** Settings ▸ Colors: color scheme, presets, import and removal.
- **R12** Light and dark follow the system, for the whole app (dialogs and Settings included).

## S: SSH

- **S1** Connect via SSH dialog: host, port (22), username, password or saved login; save or use once.
- **S2** Once logged in, the explorer moves to the same host and account.
- **S3** Typing `ssh user@host` or `ssh alias` in a local shell is followed like Connect via SSH (resolved through `ssh -G`).
- **S4** Exit or Disconnect returns the tab, title and explorer to this computer.
- **S5** Failed login or dropped link: a banner with the real state; title back to local.
- **S6** Shared connection (ControlMaster) so the explorer and transfers reuse the shell's login; keepalive ends a dead session in about 15 s.
- **S7** No command line, password or token on screen or in history; saved password through SSH_ASKPASS with a one-time token.
- **S8** Host-key questions, one-time codes and retries asked in the terminal.
- **S9** Your own `~/.ssh/config`, agent, keys and jump hosts are used.
- **S10** Connection details popover (account, host, port, route, remote home, time) with Disconnect and New Connection.

## E: File explorer

- **E1** Places: Home, the user folders, Computer, Trash, mounted devices; on a host Home and File System.
- **E2** Bookmarks (shortcut), kept per host; Remove Bookmark.
- **E3** Back, Forward, Up, Home, Reload, show hidden files; Delete/BackSpace goes back.
- **E4** Clickable path segments and an editable location (accepts `~` and relative paths).
- **E5** Double-click or Return opens; links to folders open as folders.
- **E6** File Actions menu: Upload, Download, Undo, Redo, Cut, Copy, Paste, Delete, Select All, Find.
- **E7** Local: copy, move, move to Trash with "name copy" names; never overwrites.
- **E8** Local: Undo and Redo, named after the action.
- **E9** System file clipboard works both ways (Finder / file managers / File Explorer).
- **E10** Host: move (undoable), copy on the host, delete after asking (whole folders).
- **E11** Pasting local files into a host uploads them; host items pasted locally download.
- **E12** A folder can't be moved or copied into itself.
- **E13** New Folder, New File (free "untitled" name), Rename; undoable locally, rename undoable on a host.
- **E14** Search files (Find).
- **E15** Open in Text Editor, Open with Default App, Reveal in Finder / Show in Files.
- **E16** Open with Administrator Mode… on an item.

## X: Transfers

- **X1** Upload and download single files and folder trees.
- **X2** Progress strip with Cancel and Retry; Clear Finished.
- **X3** Up to 16 requests in flight.
- **X4** A server silent for 30 s ends the request with an error; Reload works again.
- **X5** Local copy, move and Trash run in the background with a "Copying…" note.
- **X6** Staged uploads (temporary name, exclusive, renamed into place).
- **X7** Name clashes get new names; links to folders inside trees are skipped.

## D: Text editor

- **D1** Text files open as a tab in the window (double-click, Open in Text Editor); text detection by type and content.
- **D2** New File… opens straight in the editor (locally and on hosts).
- **D3** Monospaced font, undo, Find.
- **D4** Wrap Lines.
- **D5** Status line: line, column, line count, encoding, line endings.
- **D6** Save shortcut and button; • on the tab while unsaved.
- **D7** Closing the tab, window or app asks before discarding.
- **D8** Changed elsewhere since opened: asks before replacing.
- **D9** Keeps encoding (UTF-8, UTF-16, Latin-1), line endings and permissions; links edited at their target; remote saves atomic.
- **D10** Refuses files over 20 MB and binary files, with a message.

## G: Get Info

- **G1** Get Info… on one or more items: name, location, kind, size, modified, `ls -l` permissions with octal.
- **G2** Read / write / execute for owner, group, others; set-UID, set-GID, sticky; octal field in step.
- **G3** Owner and group by name or number (looked up on the host).
- **G4** Hidden and Locked (Mac only).
- **G5** Apply to enclosed items; Apply changes only what was edited; Revert.
- **G6** Works on this computer and on hosts.

## A: Administrator mode

- **A1** Lock button starts Administrator mode for the tab, locally and on the connected host.
- **A2** Every explorer action runs as root (sftp-server under sudo).
- **A3** sudo password checked first, never stored; password-free sudo not asked.
- **A4** Safe root delete rules.
- **A5** Red bar until you leave; ends with the SSH session.

## L: Saved logins

- **L1** Login database (host, port, username, password), several logins per host, host names ignore case.
- **L2** Administrator Password: AES-GCM with PBKDF2 600,000 rounds; locked at start, unlock once per session.
- **L3** Change the Administrator Password re-encrypts everything; removing it asks.
- **L4** Plain text needs an explicit choice and a second confirmation.
- **L5** First use: explanation with Create Administrator Password, Store as Plain Text, Not Now.
- **L6** Manage Logins window: list with host, port, username, hidden password, encrypted or plain.
- **L7** Opening asks for the Administrator Password; Skip shows plain-text logins with an unlock bar.
- **L8** New and Edit form with Show password.
- **L9** Import (CSV, all-or-nothing).
- **L10** Export ticked logins (checkbox column with select-all heading), file readable only by you, `logins_export.csv`.
- **L11** Double-click edits; Delete key or right-click removes after a confirmation defaulting to Cancel.
- **L12** Saved Passwords: a lock next to Connect via SSH lists saved passwords by name; choosing one types only its password into the terminal, without Return.
- **L13** Manage Passwords: Name, Password and Description; New, Edit and Delete; a vault of its own under the logins' Administrator Password.

## U: MultiExec and Run Command on Hosts

- **U1** MultiExec grid of every terminal in the window, each with number, title and include checkbox.
- **U2** Typing or pasting into an included terminal goes to all included ones.
- **U3** Pick terminal by number, close only the active one, Esc leaves.
- **U4** Bar: count of receivers, New Tab, Connect via SSH, Include All, Close All (asks), Exit MultiExec.
- **U5** Only your own input is broadcast.
- **U6** Run Command on Hosts: targets are selected saved logins and the live connection, own ssh channel each, strict host keys.
- **U7** Results per host: outcome, exit code, duration, output (64 KB cap, marked truncated).

## C: Tailcat peers

- **C1** Add a peer: name, username, secret address, One-time or Persistent; addresses protected like logins.
- **C2** Ping: Direct or Relayed with latency.
- **C3** Connect: shell and explorer through Tailcat, address never in arguments or history.
- **C4** Clear message when nothing answers SSH on the peer.
- **C5** Remove a peer.
- **C6** Share this computer: `tailcat serve`, one-time or persistent, address with Copy and Stop; checks SSH is on first; stops on quit.
- **C7** Unlock… / Lock… button with the vault states.

## Y: Accessibility

- **Y1** Every control has a screen-reader name and hover hint (hint without repeating the name).
- **Y2** Selected tab announced (and bold); toggles announce on/off; MultiExec checkboxes named.
- **Y3** Password fields have visible labels.
- **Y4** Resizing follows Reduce Motion; visual bell limited to twice a second.
- **Y5** Shared accessibility identifiers on the toolbar.

## Z: Safety and storage

- **Z1** Settings, profiles or peers that can't be read are set aside, not overwritten.
- **Z2** Login database that can't be opened: in-memory store, Manage Logins off.
- **Z3** Export files readable only by you.
- **Z4** A dropped connection is an error, never a crash.
- **Z5** Self-contained: nothing extra to install.
