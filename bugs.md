# Bugs

Every bug reported for Herb's Terminal, oldest first. New reports are added at the end and nothing is removed.
A box is ticked once the fix has shipped. A bug that affects several platforms has a box for each, and its main box is ticked when they're all done.
Items marked *found in testing* were found while testing other work, not reported by a user.

- [ ] **SSH stays connected after the remote host restarts or is switched off.** The session should end soon after the host goes away. *Reported 2026-11-07.*
  - [x] Mac: ends within about 15 seconds (keepalive every 5 s, gives up after 2 misses). Fixed in 1.0.11.
  - [x] Linux: same shared code. Fixed in 1.0.25.
  - [ ] Windows: same options for `ssh.exe`, in #5. Not yet built or tested.
- [x] **Linux: the app closed right after it opened.** Newer Flatpak already hands the shell its terminal, and taking it a second time failed, so the shell ended at once. *Found in testing, 2026-11-07.* Fixed in 1.0.25.
- [x] **Linux: the app called itself version 1.0.0.** The Flatpak build can't see git history, so the version was never worked out. *Found in testing, 2026-11-07.* Fixed in 1.0.25.
- [x] **Linux: building the Flatpak failed in a fresh VM.** *Found in testing, 2026-11-07.* Fixed in 1.0.25.
- [x] **Linux: Take Screenshot came back empty.** Snapshotting the window directly gave no picture on some calls. *Found in testing, 2026-11-07.* Fixed in 1.0.25.
- [x] **Linux: programs couldn't name their terminal.** `tty` failed and `GPG_TTY` broke, because terminals were created inside the sandbox. *Found in testing, 2026-11-07.* Fixed in 1.0.35 (#7).
- [x] **Linux: login scripts ran twice in every tab on Fedora-based systems**, so welcome messages showed twice. *Found in testing, 2026-11-07.* Fixed in 1.0.35 (#7).
- [x] **Linux: Take Screenshot drew see-through bars wrong.** The explorer's location bar and the MultiExec bar came out blank or unreadable. *Found in testing, 2026-11-07.* Fixed in 1.0.35 (#7).
- [x] **Linux: MultiExec and the Administrator mode lock didn't tell screen readers whether they were on.** They're now real toggle buttons. *Found in testing, 2026-11-07.* Fixed in 1.0.35 (#7). Not yet confirmed with a screen reader.
- [x] **Linux: two icons were missing** (the Settings Text tab, and the success mark in Run Command on Hosts). *Found in testing, 2026-11-07.* Fixed in 1.0.35 (#7).
- [x] **Mac: two layout tests failed on a busy machine.** They allowed a new tab's shell only 250 ms to start. *Found in testing, 2026-11-07.* Fixed in #7.
- [x] **The title kept the remote `user@host` after the remote host ended the SSH connection.** It should show this computer's `user@host` again. *Reported 2026-11-07 · Mac, Linux.* Fixed in 1.0.35 (#8). On Windows a dropped SSH tab stays that host's tab, so its title is already right.
- [ ] **The gap between Search and Tailcat Peers was wider than between the other toolbar buttons.** *Reported 2026-11-07.*
  - [x] Linux: fixed in 1.0.35 (#9).
  - [ ] Windows: in #5. Not yet built.
  - [x] Mac: already even; no change needed.
- [ ] **Linux: Connect via SSH doesn't work.** Saved logins can't be managed or saved, and connecting to a host fails. Works on the Mac. *Reported 2026-11-07 · Linux.* Fixes in #12: the dialog's buttons, a crash when opening Manage Logins, ssh hanging at a new host's fingerprint question, and a crash when unlocking saved logins. Confirmed working on Aurora (1.0.40); ticked once released.
- [ ] **Mac tests: one test can hang the test run.** `hostCommandOutputIsCappedWhileItRuns` pipes `yes` into `head`; when broken pipes are being ignored, macOS's `yes` never stops. *Found in testing, 2026-11-07.*
- [ ] **Linux: after typing `exit` in an SSH session, the app still shows the tab as connected.** *Reported 2026-11-07 · Linux.* Fix in #12 (the connection monitor waited forever on a finished ssh); confirmed on Aurora (1.0.40), ticked once released.
- [ ] **Linux: other short commands may wait out their time limit.** `Host.run`, the sudo checks and similar commands wait with Foundation's `Process`, which in the Linux app can miss that a command has finished; they would fail after their timeout (up to 20 s) instead of hanging. *Found in testing, 2026-11-07.*
- [ ] **Tailcat: the app crashes and closes the moment Start Sharing is clicked.** *Reported 2026-11-07 · Linux.* Fix in #13 (a removed widget kept the keyboard focus); not yet retested.
- [ ] **Tailcat: accepting a pairing asks to unlock saved logins with the Administrator Password, but the Tailcat Peers window offers no way to do that.** Unlocking in Connect via SSH and coming back works, but isn't practical. *Reported 2026-11-07.* Fixed by the new Lock / Unlock button (#13); not yet retested.
- [ ] **Linux: connecting through Tailcat fails** with "Connection closed by UNKNOWN port 65535" (Mac to Linux pairing). *Reported 2026-11-07 · Linux.* The Mac had the same bug. Fix in #13 (the proxy command began with variable assignments, which `exec` can't run); still failing on 1.0.45 (ping worked). Found 2026-11-07: the Linux side now works end to end (tested on Aurora against a Tailcat share); the Mac it connected to was sharing with Remote Login turned off, so nothing answered on port 22 and Tailcat closed the connection.
