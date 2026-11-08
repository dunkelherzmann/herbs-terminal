# Enhancements

Every enhancement requested for Herb's Terminal, oldest first. New requests are added at the end and nothing is removed.
A box is ticked once the change has shipped. A request that covers several platforms has a box for each, and its main box is ticked when they're all done.

- [ ] **Take Screenshot button.** A button next to Export Session copies a picture of the whole window to the clipboard, ready to paste. *Requested 2026-11-07.*
  - [x] Mac: camera button and Shift-Cmd-S. Shipped in 1.0.11.
  - [x] Linux: camera button and Ctrl+Alt+S. Shipped in 1.0.25.
  - [ ] Windows: camera button and Ctrl+Alt+S, in #5. Built and tested on Windows 2026-11-07 (the clipboard got a picture of the whole window); not yet merged.
- [x] **Build the Linux version on a real Linux machine.** It's built and tested natively on Aurora (KDE on Wayland), as well as in the Mac's Linux VM. *Requested 2026-11-07.* Shipped in 1.0.25.
- [x] **Get the repository ready to be public.** Personal data was removed from the whole history, the repo was recreated with that clean history, and it was made public. *Requested 2026-11-07.* Done 2026-11-07.
- [x] **Say that the app is provided as is, without support,** in the README and release notes. *Requested 2026-11-07.* Done in the README's Support section and the release notes from 1.0.25.
- [x] **Audit the Linux version against the Mac version** and test it. The findings are in `bugs.md`. *Requested 2026-11-07.* Done 2026-11-07 (#7).
- [x] **Protect the `main` branch** from force pushes and deletion. *Requested 2026-11-07.* Done 2026-11-07 (a "Protect main" ruleset).
- [x] **Typing `exit` in the last terminal quits the app.** With other windows open, it closes just its own window. *Requested 2026-11-07 · Mac, Linux.* Shipped in 1.0.35 (#10). Windows already quit when its last window closed.
- [x] **Keep these trackers:** `enhancements.md` and `bugs.md`, updated as requests come in and as they're done. *Requested 2026-11-07.* Set up in #11.
- [ ] **Lock button in the Tailcat Peers window.** At the bottom, opposite Done: it shows Lock or Unlock, and its hover bubble explains that it locks or unlocks the safe storage of Tailcat addresses. Clicking it opens a window that asks for the Administrator Password, offers to lock or unlock, and offers to change the Administrator Password. *Requested 2026-11-07 · Mac, Linux, Windows.*
  - [x] Mac: shipped in 1.0.73 (#13).
  - [x] Linux: shipped in 1.0.73 (#13).
  - [ ] Windows: no Tailcat in the Windows version yet.
- [ ] **Explain a Tailcat share that no one can log in to.** Start Sharing checks that this computer answers SSH on port 22 and, if not, says to turn on Remote Login (Mac) or the SSH service (Linux). When the peer is reached but nothing answers SSH there, the connecting side says so and how to fix it, instead of "Connection closed by UNKNOWN port 65535". *Requested 2026-11-07 · Mac, Linux, Windows.*
  - [x] Mac: shipped in 1.0.73 (#13).
  - [x] Linux: shipped in 1.0.73 (#13).
  - [ ] Windows: no Tailcat in the Windows version yet.
- [ ] **Dropping a file or folder on the terminal types its path.** *Requested 2026-11-07 · Mac, Linux, Windows.*
  - [x] Mac: already did, quoted for the shell.
  - [x] Linux: it was meant to and didn't; fixed in 1.0.73 (#14).
  - [ ] Windows: in #15 (stacked on #5). Files dropped from File Explorer are typed as paths quoted for the tab's shell (PowerShell, cmd, WSL, Git Bash or SSH); built and tested on Windows, not yet merged.
- [ ] **Check that the Linux and Windows versions match the Mac version 1:1** in features, controls, behaviour and looks, whatever code each uses, with Craft Anything evidence. Method: the `app-parity` skill (draft, awaiting approval) and `parity/check.sh`. *Requested 2026-11-07 · Mac, Linux, Windows.*
  - [ ] Mac: toolbar identifiers and the `main` scene in a parity copy; built and tested 2026-11-07, not yet merged.
  - [ ] Linux: toolbar identifiers, the `main` scene in a headless KWin session and the AT-SPI reader; first check run 2026-11-07 (four differences, in `bugs.md`); not yet merged.
  - [ ] Windows: waiting for a Remote Control session on the PC.
