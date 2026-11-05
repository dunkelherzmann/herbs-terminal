import Foundation

/// Lets an `ssh` typed in a tab be followed like a GUI connection. Each tab's shell loads the user's own
/// startup files first, then defines an `ssh` function that resolves the destination with `ssh -G`,
/// announces it to the app (a file named after the shell's PID in the private socket folder), and runs the
/// real ssh as the master of a shared connection the explorer can use. Shells other than zsh and bash run
/// unchanged.
enum ShellIntegration {
    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HerbsTerminal/shell-integration", isDirectory: true)

    /// Where a tab's shell announces a typed ssh; the app reads and removes it.
    static func announcement(for shellPid: pid_t) -> URL {
        SSHControl.directory.appendingPathComponent("announce-\(shellPid)")
    }

    /// How to start `shell` with the integration: extra environment, arguments and the argv[0] name.
    static func launch(shell: String, environment: [String: String]) -> (environment: [String: String], arguments: [String], execName: String)? {
        guard (try? install()) != nil else { return nil }
        var environment = environment
        environment["HERBS_ANNOUNCE_DIR"] = SSHControl.directory.path
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh":
            // zsh reads its startup files from ZDOTDIR; ours load the user's, then add the ssh function.
            environment["HERBS_USER_ZDOTDIR"] = environment["ZDOTDIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            environment["ZDOTDIR"] = folder.path
            return (environment, [], "-zsh")
        case "bash":
            // A login bash ignores --rcfile, so start it interactive and load the login files from ours.
            return (environment, ["--rcfile", folder.appendingPathComponent("bashrc").path], "bash")
        default:
            return nil
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Parses an announcement: user, resolved host name and port, one per line, as printed by `ssh -G`.
    static func endpoint(fromAnnouncement text: String) -> RemoteEndpoint? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, !lines[1].isEmpty, let port = Int(lines[2]) else { return nil }
        return RemoteEndpoint(host: lines[1], port: port, username: lines[0].isEmpty ? NSUserName() : lines[0])
    }

    /// Each of our zsh startup files loads the user's file of the same name with the user's ZDOTDIR in
    /// place, then switches back so zsh keeps reading ours, until .zlogin hands ZDOTDIR back for good.
    private static func zshWrapper(_ file: String, last: Bool = false) -> String {
        var lines = [
            "# Herb's Terminal shell integration: load your own \(file), then continue with ours.",
            "HERBS_INTEGRATION_ZDOTDIR=$ZDOTDIR",
            "ZDOTDIR=${HERBS_USER_ZDOTDIR:-$HOME}",
            "[[ -r \"$ZDOTDIR/\(file)\" ]] && source \"$ZDOTDIR/\(file)\"",
            "HERBS_USER_ZDOTDIR=$ZDOTDIR",
        ]
        if file == ".zshrc" { lines.append("source \"$HERBS_INTEGRATION_ZDOTDIR/herbs-ssh.sh\"") }
        lines.append(last ? "unset HERBS_INTEGRATION_ZDOTDIR" : "ZDOTDIR=$HERBS_INTEGRATION_ZDOTDIR")
        return lines.joined(separator: "\n") + "\n"
    }

    static let sshFunction = #"""
    # Herb's Terminal: follow a typed ssh in the file explorer. The real ssh runs unchanged apart from
    # sharing its connection (ControlMaster), which the explorer and transfers then reuse.
    ssh() {
      case " $* " in
        *" -G "*|*" -O "*|*" -V "*|*" -Q "*) command ssh "$@"; return ;;
      esac
      if [ -n "$HERBS_ANNOUNCE_DIR" ] && [ -d "$HERBS_ANNOUNCE_DIR" ] && [ -O "$HERBS_ANNOUNCE_DIR" ]; then
        command ssh -G "$@" 2>/dev/null | awk '$1=="user"{u=$2} $1=="hostname"{h=$2} $1=="port"{p=$2} END{if (h != "") printf "%s\n%s\n%s\n", u, h, p}' \
          > "$HERBS_ANNOUNCE_DIR/announce-$$.tmp" && mv -f "$HERBS_ANNOUNCE_DIR/announce-$$.tmp" "$HERBS_ANNOUNCE_DIR/announce-$$"
        command ssh -o ControlMaster=auto -o "ControlPath=$HERBS_ANNOUNCE_DIR/cm-%C" -o ControlPersist=10 "$@"
      else
        command ssh "$@"
      fi
    }
    """#

    static var files: [String: String] {
        [
            ".zshenv": zshWrapper(".zshenv"),
            ".zprofile": zshWrapper(".zprofile"),
            ".zshrc": zshWrapper(".zshrc"),
            ".zlogin": zshWrapper(".zlogin", last: true),
            "herbs-ssh.sh": sshFunction + "\n",
            "bashrc": """
            # Herb's Terminal shell integration: what a login bash would load, then the ssh function.
            [ -r /etc/profile ] && . /etc/profile
            for herbs_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
              if [ -r "$herbs_file" ]; then . "$herbs_file"; break; fi
            done
            unset herbs_file
            . "\(folder.path)/herbs-ssh.sh"

            """,
        ]
    }
}
