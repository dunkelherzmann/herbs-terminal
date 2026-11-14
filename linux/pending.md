# Linux: what isn't production-ready yet

What the Linux version still needs before it can ship with as few bugs as possible: everything a feature test found broken or missing, and every feature no automatic test covers yet. Fix broken items first, one pull request each, and tick an item with its PR number once it is fixed and its test passes. `bugs.md` and `enhancements.md` stay the record of requests and releases.

## Next (top priority)

- [x] **Main Menu matches the Mac's in-window menus** (#70). It holds the same menus, submenus, order and shortcuts (Edit, Shell and Window included), and no command is reachable only somewhere else; W19 checks it. (§2, §14, enhancements.md) *Asked 2026-11-09.*

<!-- feature-tests:start -->
## Feature test results (2026-11-14 05:52)

Written by `parity/tests/report.py`; rerun the tests and the report rather than editing this part.

### Not checked automatically (41)

Try these by hand before a release, or extend the test bridge so a test can check them.

- [ ] **W2** Connect via SSH button; highlighted while connected, then shows the connection details (account,… (§2): checked as S10
- [ ] **W17** Hover hints on every control after about half a second, also in the background; screen readers get… (§2): covered by parity/check.sh (hover texts through the accessibility tree)
- [ ] **W20** A closed window leaves the session: after New Window and closing that window with its close… (§2): this platform's test bridge can't close a window or read the session yet
- [ ] **P5** Focused pane outlined; Zoom, Clear, Reset and Find act on it. (§2): visual: shown in the window's picture, not reported by the bridge
- [ ] **P6** The tab's SSH connection and explorer belong to its first pane; the next pane takes over when it… (§2): needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)
- [ ] **B6** Bell: sound, flash, both or none; flash at most twice a second, gentle with Reduce Motion. (§2): sound and flash can't be observed by the bridge
- [ ] **B8** Find in Terminal (scrollback search). (§2): the find bar opens with the text; this platform's terminal (VTE) highlights matches but doesn't count them
- [ ] **B14** Full color, bold/italic/underline, wide characters, mouse reporting for full-screen programs. (§2): this platform's test bridge can't send mouse events yet; visual: needs the window's picture compared with the Mac's
- [ ] **B15** Typing with an input method (Chinese, Japanese, Korean): composition at the cursor, in the… (§2): this platform's test bridge can't drive an input method yet
- [ ] **R12** Light and dark follow the system, for the whole app (dialogs and Settings included). (§3): visual: needs pictures in light and dark mode
- [ ] **S3** Typing `ssh user@host` or `ssh alias` in a local shell is followed like Connect via SSH (resolved… (§4): the test scene's /bin/sh runs ssh unchanged by design; zsh and bash tabs follow it
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
- [ ] **Y1** Every control has a screen-reader name and hover hint (hint without repeating the name). (§9): this platform's accessibility tree is checked by parity/check.sh, not the feature tests
- [ ] **Y2** Selected tab announced (and bold); toggles announce on/off; MultiExec checkboxes named. (§9): this platform's accessibility tree is checked by parity/check.sh, not the feature tests
- [ ] **Y3** Password fields have visible labels. (§9): covered by the accessibility tree; not automated here
- [ ] **Y4** Resizing follows Reduce Motion; visual bell limited to twice a second. (§9): this platform's test bridge doesn't report the visual bell yet; window resizing isn't animated on Windows; the slower fade with animations off is visual
- [ ] **Y5** Shared accessibility identifiers on the toolbar. (§9): covered by parity/check.sh
- [ ] **Z1** Settings, profiles or peers that can't be read are set aside, not overwritten. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z2** Login database that can't be opened: in-memory store, Manage Logins off. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z3** Export files readable only by you. (§10): needs damaged files or a dropped connection (fault injection, not automated yet)
- [ ] **Z5** Self-contained: nothing extra to install. (§10): checked by each platform's packaging script

<!-- feature-tests:end -->

## Bugs to fix

Hand-written from `bugs.md`; fix these before the features above, one pull request each, and tick each with its PR number.

- [x] **The self-test crashes when `HERBS_TEST_SSH` is set but empty or malformed.** (#40) It should report a failed check instead of stopping with "Index out of range". (§11 Build and packaging, Checks)
- [x] **The debug build has 31 compiler warnings, three of them errors in the Swift 6 language mode.** (#39) Main-actor statics used from nonisolated code (`TransferQueue.shared` as a default argument in `RemoteExplorerModel.swift`, `defaultIterations` in the shared `CredentialStore.swift`), plus deprecated `utf8String` and VTE calls. (§11 Build and packaging)
- [x] **The Flatpak build fails when GitHub's release downloads are down.** (#43) Give the manifest a mirror URL for the tailcat archive, or vendor it. (§11 Build and packaging)
