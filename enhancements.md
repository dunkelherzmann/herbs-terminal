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
  - [ ] Mac: toolbar identifiers and the `main` scene in a parity copy; built and tested 2026-11-07, merged in #23, not yet released.
  - [ ] Linux: toolbar identifiers, the `main` scene in a headless KWin session and the AT-SPI reader; first check run 2026-11-07 (four differences, in `bugs.md`); merged in #23, not yet released.
  - [ ] Windows: UI Automation for the drawn toolbar, tab strip and window buttons, the `main` scene, the UI Automation reader and `parity/windows-scene.ps1` (run over SSH; the scene opens for a few seconds on the PC's desktop). First check run 2026-11-08 (differences in `bugs.md`); not yet merged.
- [ ] **New terminals start at 100 × 30 with 13 pt text** in every version (Mac, Linux, Windows), instead of 120 × 32 and 11 pt. Saved settings keep their own size; Settings ▸ Window ▸ Restore Defaults and new profiles use the new values. *Requested 2026-11-08 · Mac, Linux, Windows.* Merged in #26 (Mac, Linux) and #27 (Windows stack), not yet released.
- [ ] **A full list of the Mac version's features, used to check the Linux and Windows versions.** `parity/features.md` lists 159 features with ids; `parity/feature-check.md` has each one's status on Linux and Windows (works, in code, partial, missing or broken) and how it was found. Bugs found are in `bugs.md`; Windows' missing features follow `windows/pending.md`. *Requested 2026-11-08 · Mac, Linux, Windows. Done 2026-11-08, not yet merged.*
- [ ] **Run the feature tests in the foreground on a dedicated virtual desktop on each computer**, so the app windows open there instead of on the desktop in use, and the run can be watched by switching to that desktop. *Requested 2026-11-08 · Mac, Linux, Windows.*
- [ ] **A setup script for an Ubuntu 24.04 development machine** (`linux/dev/setup-ubuntu.sh`): build tools, Flatpak SDK, test tools and agent-desktop, SSH both ways with the Mac, git identity from the Mac, GitHub and Claude Code sign-ins in the new machine's browser (no tokens copied), skills and projects, and Remote Control as a service. *Requested 2026-11-08 · Linux.*
- [ ] **Commits show which computer made them**: each machine commits as `claude-mac`, `claude-linux` or `claude-windows` (git's committer name), with Herbert Cisneros as the author. Set on the Mac and the Windows PC; the Linux setup script sets it. *Requested 2026-11-08 · Mac, Linux, Windows.*
- [ ] **Build the Linux version on the Linux machine itself, without the Mac.** `script/build_flatpak.sh` and the development scripts in `linux/dev` run on Linux with flatpak-builder from Flathub and the same manifest, instead of in a Linux VM on the Mac; `--install` installs the build there, and the Mac starts a build over SSH. *Requested 2026-11-08 · Linux.* In #29, not yet merged. Tested on the Linux machine 2026-11-08: `script/build_flatpak.sh --install` built and installed 1.0.88 (x86_64), and `linux/dev/check.sh` passed every check (live SSH skipped, no test account); `run.sh` and `restart.sh` not yet tried, because they open a window on the desktop. The aarch64 bundle needs an aarch64 Linux machine; there isn't one yet.
- [ ] **Windows: one portable `.exe`, nothing installed.** Herb's Terminal for Windows ships as a single self-contained `HerbsTerminal.exe` that needs no installer, no runtime and nothing added to the system (today it is an exe with 18 DLLs beside it). Every new Windows build is copied to the Windows PC's desktop so it's easy to find. *Requested 2026-11-08 · Windows.*
  - [x] A copy of each new build on the desktop (for now a shortcut to the self-contained folder, until the single exe exists)
  - [ ] A single portable `.exe`
