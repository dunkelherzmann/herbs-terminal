# Mac: what isn't production-ready yet

What the Mac version still needs before it can ship with as few bugs as possible: everything a feature test found broken or missing, and every feature no automatic test covers yet. Fix broken items first, one pull request each, and tick an item with its PR number once it is fixed and its test passes. `bugs.md` and `enhancements.md` stay the record of requests and releases.

## Next (top priority)

- [x] **Every menu in the window, none in the macOS menu bar.** (#67) All menus and submenus (Shell, Edit, View, Window, Help and the rest) move into the Main Menu in the window, as on Linux and Windows, so nothing needs a trip to the top of a wide screen. The macOS menu bar keeps only the app menu macOS always shows. Every shortcut keeps working, Undo, Cut, Copy, Paste and Select All in text fields included, and every item keeps its hover text and VoiceOver label. Describe the new menu in `SPECIFICATION.md` in the same PR. (§2, enhancements.md) *Asked 2026-11-09.*

<!-- feature-tests:start -->
## Feature test results (2026-11-09 16:11)

Written by `parity/tests/report.py`; rerun the tests and the report rather than editing this part.

### Not checked automatically (57)

Try these by hand before a release, or extend the test bridge so a test can check them.

- [ ] **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account,… (§2): checked as S10
- [ ] **W6** Export Session button and shortcut: whole scrollback to `<tab> <date time>.txt`. (§2): the command is there; saving goes through the system's save dialog, which the bridge can't fill
- [ ] **W17** Hover hints on every control after about half a second, also in the background; screen readers get… (§2): covered by parity/check.sh (hover texts through the accessibility tree)
- [ ] **T11** Session restore: tabs with folder, panes, explorer folder and name reopen at launch (on by… (§2): this platform's test bridge can't read or reopen a session yet
- [ ] **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it. (§2): visual: shown in the window's picture, not reported by the bridge
- [ ] **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it… (§2): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion. (§2): sound and flash can't be observed by the bridge
- [ ] **B7** Size badge (columns × rows) while resizing. (§2): this platform's test bridge can't resize the window yet
- [ ] **B8** Find in Terminal (scrollback search). (§2): opening the find bar is checked in W13; typing into it would use the Mac's shared find pasteboard, which the tests leave alone
- [ ] **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs. (§2): this platform's test bridge can't send mouse events yet; visual: needs the window's picture compared with the Mac's
- [ ] **B15** Typing with an input method (Chinese, Japanese, Korean): composition at the cursor, in the… (§2): this platform's test bridge can't drive an input method yet
- [ ] **R1** Named profiles; each tab uses one; new tabs keep the current tab's profile. (§3): this platform's test bridge can't make or choose profiles yet
- [ ] **R5** iTerm2 `.itermcolors` import (all colors); damaged files rejected; imported presets removable. (§3): needs the system's open dialog
- [ ] **R7** Settings ▸ Profiles: add, duplicate, rename, delete, choose the default; startup command and start… (§3): Settings opens; its Profiles page isn't read by the bridge yet
- [ ] **R8** Settings ▸ Text: any installed monospaced font, 6–72 pt, cursor shape and blink, opacity 20–100 %,… (§3): Settings opens; its Text page isn't read by the bridge yet
- [ ] **R9** Settings ▸ Terminal: Option as Meta, scrollback 100–1,000,000, bell, where new tabs open, restore… (§3): Settings opens; its Terminal page isn't read by the bridge yet
- [ ] **R10** Settings ▸ Window: columns × rows for new windows (default 100 × 30), size badge toggle, Apply to… (§3): Settings opens; its Window page isn't read by the bridge yet
- [ ] **R11** Settings ▸ Colors: color scheme, presets, import and removal. (§3): Settings opens; its Colors page isn't read by the bridge yet
- [ ] **R12** Light and dark follow the system, for the whole app (dialogs and Settings included). (§3): visual: needs pictures in light and dark mode
- [ ] **S3** Typing `ssh user@host` or `ssh alias` in a local shell is followed like Connect via SSH (resolved… (§4): the test scene's /bin/sh runs ssh unchanged by design; zsh and bash tabs follow it
- [ ] **S6** Shared connection (ControlMaster) so the explorer and transfers reuse the shell's login; keepalive… (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S8** Host-key questions, one-time codes and retries asked in the terminal. (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S9** Your own `~/.ssh/config`, agent, keys and jump hosts are used. (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **E1** Places: Home, the user folders, Computer, Trash, mounted devices; on a host Home and File System. (§5): checked in the accessibility tree by parity/check.sh; the bridge doesn't report places
- [ ] **E4** Clickable path segments and an editable location (accepts `~` and relative paths). (§5): needs pointer or keyboard input the test bridge doesn't reach yet
- [ ] **E11** Pasting local files into a host uploads them; host items pasted locally download. (§5): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **E16** Open with Administrator Mode… on an item. (§5): needs a sudo password (not automated)
- [ ] **X2** Progress strip with Cancel and Retry; Clear Finished. (§5): needs a transfer slow enough to cancel; not automated yet
- [ ] **X3** Up to 16 requests in flight. (§5): inside the SFTP client, where the bridge can't see its requests; not automated yet
- [ ] **X4** A server silent for 30 s ends the request with an error; Reload works again. (§5): needs a dropped connection (fault injection, not automated yet)
- [ ] **X5** Local copy, move and Trash run in the background with a "Copying…" note. (§5): needs a large folder and timing; not automated yet
- [ ] **X6** Staged uploads (temporary name, exclusive, renamed into place). (§5): inside the SFTP client, where the bridge can't see its requests; not automated yet
- [ ] **G4** Hidden and Locked (Mac only). (§5): Mac only
- [ ] **A4** Safe root delete rules. (§5): deleting system folders as root isn't something to try on a real machine
- [ ] **L1** Login database (host, port, username, password), several logins per host, host names ignore case. (§6): covered by the unit and self tests of the shared vault code
- [ ] **L2** Administrator Password: AES-GCM with PBKDF2 600,000 rounds; locked at start, unlock once per… (§6): covered by the unit and self tests of the shared vault code
- [ ] **L3** Change the Administrator Password re-encrypts everything; removing it asks. (§6): covered by the unit and self tests of the shared vault code
- [ ] **L4** Plain text needs an explicit choice and a second confirmation. (§6): covered by the unit and self tests of the shared vault code
- [ ] **L7** Opening asks for the Administrator Password; Skip shows plain-text logins with an unlock bar. (§6): needs the logins locked at start, which takes a second launch of the same test copy
- [ ] **U7** Results per host: outcome, exit code, duration, output (64 KB cap, marked truncated). (§7): this platform's test bridge can't drive Run Command on Hosts yet
- [ ] **C1** Add a peer: name, username, secret address, One-time or Persistent; addresses protected like logins. (§8): the window opens; this platform's test bridge can't drive it yet
- [ ] **C2** Ping: Direct or Relayed with latency. (§8): the window opens; this platform's test bridge can't drive it yet
- [ ] **C3** Connect: shell and explorer through Tailcat, address never in arguments or history. (§8): needs the test host shared over tailcat (~/.config/herbs-terminal/test-tailcat holds its address)
- [ ] **C4** Clear message when nothing answers SSH on the peer. (§8): needs a peer whose SSH service is off
- [ ] **C5** Remove a peer. (§8): the window opens; this platform's test bridge can't drive it yet
- [ ] **C6** Share this computer: `tailcat serve`, one-time or persistent, address with Copy and Stop; checks… (§8): the window opens; this platform's test bridge can't drive it yet
- [ ] **C7** Unlock… / Lock… button with the vault states. (§8): the Tailcat window isn't driven by the bridge yet
- [ ] **Y1** Every control has a screen-reader name and hover hint (hint without repeating the name). (§9): this platform's accessibility tree is checked by parity/check.sh, not the feature tests
- [ ] **Y2** Selected tab announced (and bold); toggles announce on/off; MultiExec checkboxes named. (§9): this platform's accessibility tree is checked by parity/check.sh, not the feature tests
- [ ] **Y3** Password fields have visible labels. (§9): covered by the accessibility tree; not automated here
- [ ] **Y4** Resizing follows Reduce Motion; visual bell limited to twice a second. (§9): this platform's test bridge doesn't report the visual bell yet; window resizing isn't animated on Windows; the slower fade with animations off is visual
- [ ] **Y5** Shared accessibility identifiers on the toolbar. (§9): covered by parity/check.sh
- [ ] **Z1** Settings, profiles or peers that can't be read are set aside, not overwritten. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z2** Login database that can't be opened: in-memory store, Manage Logins off. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z3** Export files readable only by you. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z4** A dropped connection is an error, never a crash. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z5** Self-contained: nothing extra to install. (§10): checked by each platform's packaging script

<!-- feature-tests:end -->
