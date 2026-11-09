# Linux: what isn't production-ready yet

What the Linux version still needs before it can ship with as few bugs as possible: everything a feature test found broken or missing, and every feature no automatic test covers yet. Fix broken items first, one pull request each, and tick an item with its PR number once it is fixed and its test passes. `bugs.md` and `enhancements.md` stay the record of requests and releases.

<!-- feature-tests:start -->
## Feature test results (2026-11-09 03:01)

Written by `parity/tests/report.py`; rerun the tests and the report rather than editing this part.

### Not checked automatically (83)

Try these by hand before a release, or extend the test bridge so a test can check them.

- [ ] **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account,… (§2): checked as S10
- [ ] **W6** Export Session button and shortcut: whole scrollback to `<tab> <date time>.txt`. (§2): the command is there; saving goes through the system's save dialog, which the bridge can't fill
- [ ] **W11** Search button: searches files in the explorer, the scrollback otherwise. (§2): the command is there; whether the search field opens isn't reported by the bridge yet
- [ ] **W13** Main Menu: Find in Terminal…. (§2): the command is there; the search bar isn't reported by the bridge yet
- [ ] **W17** Hover hints on every control after about half a second, also in the background; screen readers get… (§2): covered by parity/check.sh (hover texts through the accessibility tree)
- [ ] **T11** Session restore: tabs with folder, panes, explorer folder and name reopen at launch (on by… (§2): the test scene never saves or restores a session
- [ ] **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it. (§2): visual: shown in the window's picture, not reported by the bridge
- [ ] **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it… (§2): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **B1** Right-click menu: Copy, Paste, Paste Escaped Text, Select All, Find. (§2): the items are there and Select All and Find… run; Copy and Paste aren't chosen, since they'd use the system clipboard, and the bridge doesn't report a selection or the find bar
- [ ] **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion. (§2): sound and flash can't be observed by the bridge
- [ ] **B7** Size badge (columns × rows) while resizing. (§2): needs a window resize by the pointer
- [ ] **B8** Find in Terminal (scrollback search). (§2): the command is there; the search bar and its matches aren't reported by the bridge yet
- [ ] **B9** Copy and paste; Paste Escaped Text. (§2): the commands are there; not run, since they'd use the system clipboard
- [ ] **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs. (§2): visual: needs the window's picture compared with the Mac's
- [ ] **R5** iTerm2 `.itermcolors` import (all colors); damaged files rejected; imported presets removable. (§3): needs the system's open dialog
- [ ] **R7** Settings ▸ Profiles: add, duplicate, rename, delete, choose the default; startup command and start… (§3): Settings opens; its Profiles page isn't read by the bridge yet
- [ ] **R8** Settings ▸ Text: any installed monospaced font, 6–72 pt, cursor shape and blink, opacity 20–100 %,… (§3): Settings opens; its Text page isn't read by the bridge yet
- [ ] **R9** Settings ▸ Terminal: Option as Meta, scrollback 100–1,000,000, bell, where new tabs open, restore… (§3): Settings opens; its Terminal page isn't read by the bridge yet
- [ ] **R10** Settings ▸ Window: columns × rows for new windows (default 100 × 30), size badge toggle, Apply to… (§3): Settings opens; its Window page isn't read by the bridge yet
- [ ] **R11** Settings ▸ Colors: color scheme, presets, import and removal. (§3): Settings opens; its Colors page isn't read by the bridge yet
- [ ] **R12** Light and dark follow the system, for the whole app (dialogs and Settings included). (§3): visual: needs pictures in light and dark mode
- [ ] **S3** Typing `ssh user@host` or `ssh alias` in a local shell is followed like Connect via SSH (resolved… (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S6** Shared connection (ControlMaster) so the explorer and transfers reuse the shell's login; keepalive… (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S8** Host-key questions, one-time codes and retries asked in the terminal. (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S9** Your own `~/.ssh/config`, agent, keys and jump hosts are used. (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **E1** Places: Home, the user folders, Computer, Trash, mounted devices; on a host Home and File System. (§5): checked in the accessibility tree by parity/check.sh; the bridge doesn't report places
- [ ] **E2** Bookmarks (shortcut), kept per host; Remove Bookmark. (§5): needs pointer or keyboard input the test bridge doesn't reach yet
- [ ] **E3** Back, Forward, Up, Home, Reload, show hidden files; Delete/BackSpace goes back. (§5): going into a folder works; Back, Forward, Up and Home are buttons the bridge doesn't press yet
- [ ] **E4** Clickable path segments and an editable location (accepts `~` and relative paths). (§5): needs pointer or keyboard input the test bridge doesn't reach yet
- [ ] **E9** System file clipboard works both ways (Finder / file managers / File Explorer). (§5): would use the system clipboard
- [ ] **E11** Pasting local files into a host uploads them; host items pasted locally download. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **E14** Search files (Find). (§5): the command is there; the filter field isn't driven by the bridge yet
- [ ] **E16** Open with Administrator Mode… on an item. (§5): needs a sudo password (not automated)
- [ ] **X1** Upload and download single files and folder trees. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **X2** Progress strip with Cancel and Retry; Clear Finished. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **X3** Up to 16 requests in flight. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **X4** A server silent for 30 s ends the request with an error; Reload works again. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **X5** Local copy, move and Trash run in the background with a "Copying…" note. (§5): needs a large folder and timing; not automated yet
- [ ] **X6** Staged uploads (temporary name, exclusive, renamed into place). (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **X7** Name clashes get new names; links to folders inside trees are skipped. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
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
- [ ] **A4** Safe root delete rules. (§5): deleting system folders as root isn't something to try on a real machine
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
- [ ] **U7** Results per host: outcome, exit code, duration, output (64 KB cap, marked truncated). (§7): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **C1** Add a peer: name, username, secret address, One-time or Persistent; addresses protected like logins. (§8): the window opens; adding a peer needs its form, which the bridge doesn't fill yet
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

## Bugs to fix

Hand-written from `bugs.md`; fix these before the features above, one pull request each, and tick each with its PR number.

- [x] **The self-test crashes when `HERBS_TEST_SSH` is set but empty or malformed.** (#40) It should report a failed check instead of stopping with "Index out of range". (§11 Build and packaging, Checks)
- [x] **The debug build has 31 compiler warnings, three of them errors in the Swift 6 language mode.** (#39) Main-actor statics used from nonisolated code (`TransferQueue.shared` as a default argument in `RemoteExplorerModel.swift`, `defaultIterations` in the shared `CredentialStore.swift`), plus deprecated `utf8String` and VTE calls. (§11 Build and packaging)
- [x] **The Flatpak build fails when GitHub's release downloads are down.** (#43) Give the manifest a mirror URL for the tailcat archive, or vendor it. (§11 Build and packaging)
