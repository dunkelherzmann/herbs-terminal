# Windows: closing the gap with the Mac and Linux versions

What the Windows version still needs so it works 1:1 like the Mac and Linux versions, in the order it's being
built. Each item names the `SPECIFICATION.md` section it follows and lands in its own pull request, stacked on the
one before. An item is ticked when its PR is open, built and tested on Windows, with the PR number; the
project's `enhancements.md` and `bugs.md` stay the record of requests and releases.

## Next (top priority)

- [x] **Settings with the Mac's five pages** (#89) (Profiles, Text, Terminal, Window, Colors), their controls, labels and hover texts, the profile and color theme lists drawn as on the Mac, Bell, the Window page's buttons and preset removal. Option as Meta isn't a setting: Alt always acts as Meta (spec §12). R7, R9, R10 and R11 work. (§3, feature tests) *Found 2026-11-10.*
- [x] **Background opacity and blur** (#90) (Settings ▸ Text, §3): the terminal's background drawn with alpha into 32-bit bitmaps, the window's alpha honored by DWM, and Windows 11's acrylic backdrop for blur; solid while the explorer, an editor, MultiExec or the find bar is shown. R8 checks it. *Found 2026-11-10.*
- [x] **Main Menu matches the Mac's in-window menus** (#70). It holds the same menus, submenus, order and shortcuts (Edit, Shell and Window included), and no command is reachable only somewhere else; W19 checks it. (§2, §14, enhancements.md) *Asked 2026-11-09.*

## To build

- [x] **Feature tests on the packaged exe** (#34) (§12, enhancements.md). `parity/tests` on Windows can run
      `dist\HerbsTerminal.exe`, the single exe that ships, as well as the development build.
- [x] **App icon** (#35) (§12, enhancements.md). The launcher and the app's window show Herb's Terminal's icon.
- [x] ~~**Static Swift runtime in the package**~~ (§12, enhancements.md). Dropped: measured, it makes the package
      larger, not smaller.
- [x] **One portable `HerbsTerminal.exe`** (#33) (§12, enhancements.md). A small static launcher carries the
      packaged folder and runs it from a per-build copy under `%LOCALAPPDATA%`; each build is copied to the
      Windows PC's desktop as `Herb's Terminal.exe`.
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
- [x] **7. Undo and Redo** in the explorer (§5), and bookmarks per host (#54).
- [x] **8. Split panes** (§2) (#55): Split Vertically / Horizontally, Close Pane, Next / Previous Pane, the focused
      pane outline.
- [x] **9. MultiExec** (§7) (#56): every terminal in a grid, typing into all of them, include / leave out.
- [x] **10. Run Command on Hosts** (§7) (#57).
- [x] **11. Find in Terminal** (§2), the terminal's right-click menu, Paste Escaped Text (#58).
- [x] **12. Named profiles** (§3) (#59): New Tab with Profile, Use Profile, editing profiles in Settings.
- [x] **13. Session restore** (§2) and the size badge while resizing (#60).
- [x] **14. Following an `ssh` typed in a local tab** (§4), and the explorer following that host. SSH sessions run inside the local shell, so Disconnect returns the tab to it (feature test S4). (#61)
- [x] **15. Tailcat peers** (§8) (#63): pairing, sharing, connecting through Tailcat, the Lock / Unlock button.
- [x] **16. Accessibility** (§9): UI Automation names, hover texts and states for the toolbar, tabs, window buttons and the explorer's bar and places; the terminal's text through the Text pattern, with new output announced; the visual bell (feature tests Y1, Y2, Y4).
- [x] **17. Dark mode for Settings and dialogs** (done in #43), mouse reporting for full-screen programs, IME composition (feature tests B14, B15).
- [x] **18. App icon** (§12): done in #35. ~~MSIX installer and code signing~~ dropped: Herbert chose on 2026-11-09 to keep the single portable exe, with no installer and no paid certificate.

## Done

- [x] Terminal with tabs, ConPTY, colors, scrollback, selection, copy and paste (#1)
- [x] Settings (#2)
- [x] SSH with saved logins and Manage Logins (#3)
- [x] Toolbar, Main Menu and tab strip laid out as on Linux; self-contained package (#4)
- [x] SSH keepalive, Take Screenshot, toolbar spacing (#5)
- [x] Dropping files on the terminal types their paths (#15)

<!-- feature-tests:start -->
## Feature test results (2026-11-10 15:45)

Written by `parity/tests/report.py`; rerun the tests and the report rather than editing this part.

### Broken (2)

A test ran and the feature didn't do what the Mac version does.

- [ ] **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs. (§2): Mouse reporting: a full-screen program gets clicks, the wheel, and Shift+drag still selects: Shift+drag didn't select while the program tracks the mouse
- [ ] **Y1** Every control has a screen-reader name and hover hint (hint without repeating the name). (§9): Every drawn control has a name, and buttons a hover text: the explorer's explorer.back isn't named for screen readers (saw []); Screen readers read the terminal's text, and hear new output: the terminal isn't in the UI…

### Not checked automatically (34)

Try these by hand before a release, or extend the test bridge so a test can check them.

- [ ] **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account,… (§2): checked as S10
- [ ] **W17** Hover hints on every control after about half a second, also in the background; screen readers get… (§2): covered by parity/check.sh (hover texts through the accessibility tree)
- [ ] **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it. (§2): visual: shown in the window's picture, not reported by the bridge
- [ ] **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it… (§2): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion. (§2): sound and flash can't be observed by the bridge
- [ ] **R12** Light and dark follow the system, for the whole app (dialogs and Settings included). (§3): visual: needs pictures in light and dark mode
- [ ] **S6** Shared connection (ControlMaster) so the explorer and transfers reuse the shell's login; keepalive… (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S8** Host-key questions, one-time codes and retries asked in the terminal. (§4): needs the user's own ssh setup or a dropped link; not automated yet
- [ ] **S9** Your own `~/.ssh/config`, agent, keys and jump hosts are used. (§4): needs the user's own ssh setup or a dropped link; not automated yet
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
- [ ] **C3** Connect: shell and explorer through Tailcat, address never in arguments or history. (§8): needs the test host shared over tailcat (~/.config/herbs-terminal/test-tailcat holds its address)
- [ ] **C4** Clear message when nothing answers SSH on the peer. (§8): needs a peer whose SSH service is off (parity/tests/tailcat-host.sh shares one for a run)
- [ ] **C7** Unlock… / Lock… button with the vault states. (§8): the Tailcat window isn't driven by the bridge yet
- [ ] **Y3** Password fields have visible labels. (§9): covered by the accessibility tree; not automated here
- [ ] **Y4** Resizing follows Reduce Motion; visual bell limited to twice a second. (§9): window resizing isn't animated on Windows; the slower fade with animations off is visual
- [ ] **Y5** Shared accessibility identifiers on the toolbar. (§9): covered by parity/check.sh
- [ ] **Z1** Settings, profiles or peers that can't be read are set aside, not overwritten. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z2** Login database that can't be opened: in-memory store, Manage Logins off. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z3** Export files readable only by you. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z5** Self-contained: nothing extra to install. (§10): checked by each platform's packaging script

<!-- feature-tests:end -->
