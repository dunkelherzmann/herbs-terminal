import Foundation

extension SelfTest {
    /// The password hand-off and the pieces of an ssh command line.
    static func sshChecks() {
        // Host paths for the explorer: never through Windows path rules.
        check("Host paths resolve . and ..", RemotePath.normalize("/srv/./www/../logs//") == "/srv/logs")
        check("Host location field: ~ and relative paths",
              RemotePath.resolve("~/site", from: "/tmp", home: "/home/herb") == "/home/herb/site"
                  && RemotePath.resolve("../etc", from: "/home/herb", home: "/home/herb") == "/home/etc")
        check("Host parent and name", RemotePath.parent("/home/herb") == "/home" && RemotePath.parent("/") == "/"
                  && RemotePath.name("/home/herb/") == "herb" && RemotePath.name("/") == "/")
        // Dropped paths, quoted for each kind of shell a tab can run.
        let spaced = "C:\\Users\\Herb\\My Files\\it's.txt"
        check("Dropped path for PowerShell", DropQuoting.powerShell.typed([spaced, "C:\\a.txt"]) == "'C:\\Users\\Herb\\My Files\\it''s.txt' C:\\a.txt ")
        check("Dropped path for Command Prompt", DropQuoting.commandPrompt.quote("C:\\My Files") == "\"C:\\My Files\"")
        check("Dropped path for WSL", DropQuoting.wsl.quote("C:\\My Files\\x") == "'/mnt/c/My Files/x'")
        check("Dropped path for ssh and Git Bash", DropQuoting.posix.quote("it's") == "'it'\\''s'")
        check("Shell picked from the command line",
              DropQuoting(commandLine: "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo") == .powerShell
                  && DropQuoting(commandLine: "\"C:\\WINDOWS\\system32\\cmd.exe\"") == .commandPrompt
                  && DropQuoting(commandLine: "\"C:\\WINDOWS\\system32\\wsl.exe\"") == .wsl
                  && DropQuoting(commandLine: "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login -i") == .posix)

        // Arguments survive the trip through CreateProcess's single command line.
        check("Plain arguments stay unquoted", quoteArgument("herb@server") == "herb@server")
        check("Spaces are quoted", quoteArgument("C:\\Program Files\\x") == "\"C:\\Program Files\\x\"")
        check("Quotes and trailing backslashes are escaped", quoteArgument("a\"b\\") == "\"a\\\"b\\\\\"")
        check("Empty arguments are kept", quoteArgument("") == "\"\"")
        check("ssh ends soon after the host goes away",
              SSH.keepAliveOptions == ["-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]
                  && (SSH.commandLine(RemoteEndpoint(host: "server", port: 22, username: "herb"))?.contains("ServerAliveInterval=5") ?? true))

        // Both ways ssh asks for a password are recognized; other prompts and other hosts aren't.
        check("Password prompt is recognized", AskpassBroker.isPasswordPrompt("herb@server's password: ", for: "herb@server"))
        check("Keyboard-interactive prompt is recognized", AskpassBroker.isPasswordPrompt("(herb@server) Password: ", for: "herb@server"))
        check("Another host's prompt is not", !AskpassBroker.isPasswordPrompt("(root@jump) Password: ", for: "herb@server"))
        check("A host-key question is not", !AskpassBroker.isPasswordPrompt("Are you sure you want to continue connecting (yes/no)? ", for: "herb@server"))

        // The broker over its named pipe: the right prompt gets the secret once; the wrong host gets nothing.
        guard let broker = AskpassBroker.shared else {
            check("Password helper pipe starts", false)
            return
        }
        let token = broker.issue("s3cret pass", for: ["herb@server"])
        check("Wrong host's prompt gets nothing", AskpassBroker.redeem(token: token, pipe: broker.pipeName, prompt: "(root@jump) Password:") == nil)
        check("Password reaches the right prompt", AskpassBroker.redeem(token: token, pipe: broker.pipeName, prompt: "(herb@server) Password:") == "s3cret pass")
        check("A token works only once", AskpassBroker.redeem(token: token, pipe: broker.pipeName, prompt: "(herb@server) Password:") == nil)
        check("Unknown tokens get nothing", AskpassBroker.redeem(token: "nope", pipe: broker.pipeName, prompt: "herb@server's password:") == nil)
        check("ssh environment asks the helper", broker.environment(token: "t")["SSH_ASKPASS_REQUIRE"] == "force")
    }
}
