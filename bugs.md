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
- [ ] **Linux: Connect via SSH doesn't work.** Saved logins can't be managed or saved, and connecting to a host fails. Works on the Mac. *Reported 2026-11-07 · Linux.* Fixes in #12: the dialog's buttons, a crash when opening Manage Logins, and ssh hanging at a new host's fingerprint question. Not yet retested.
- [ ] **Mac tests: one test can hang the test run.** `hostCommandOutputIsCappedWhileItRuns` pipes `yes` into `head`; when broken pipes are being ignored, macOS's `yes` never stops. *Found in testing, 2026-11-07.*
