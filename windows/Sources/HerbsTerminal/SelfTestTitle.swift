import Foundation
import WinSDK

extension SelfTest {
    /// The title's folder and program (ShellLocation), and the shells' prompt integration.
    static func titleChecks() {
        check("OSC 9;9 gives the folder", ShellLocation.folder(osc9: "9;\"C:\\Users\\me\"") == "C:\\Users\\me")
        check("Other OSC 9 uses are ignored", ShellLocation.folder(osc9: "4;1;50") == nil)
        check("OSC 7 gives a Windows folder", ShellLocation.folder(osc7: "file://pc/C:/Users/me") == "C:\\Users\\me")
        check("OSC 7 gives a POSIX folder", ShellLocation.folder(osc7: "file://pc/home/me") == "/home/me")
        check("The home folder shows as ~", ShellLocation.display("C:\\Users\\Me", home: "C:\\Users\\me") == "~")
        check("Inside home starts with ~", ShellLocation.display("C:\\Users\\me\\src", home: "C:\\Users\\me") == "~\\src")
        check("Elsewhere stays as it is", ShellLocation.display("C:\\", home: "C:\\Users\\me") == "C:\\")
        check("The program shows without folder or .exe",
              ShellLocation.titleText(commandLine: "\"C:\\Windows\\system32\\PING.EXE\" -n 5 host") == "PING -n 5 host")
        check("Passwords and tokens are hidden",
              ShellLocation.titleText(commandLine: "cmd /d /c \"ping & rem --password=hunter2 API_TOKEN=s3cr3t\"")
                  == "cmd /d /c \"ping & rem --password=••• API_TOKEN=•••")
        check("A user:password@ destination is hidden", ShellLocation.titleText(commandLine: "curl https://me:pw@host") == "curl https://me:•••@host")
        check("Command Prompt reports its folder", ShellLocation.integrate(commandLine: "cmd.exe", environment: [:]).environment["PROMPT"]?.hasPrefix(ShellLocation.cmdPromptPrefix) == true)
        check("A one-off cmd /c is left alone", ShellLocation.integrate(commandLine: "cmd.exe /c dir", environment: [:]).environment["PROMPT"] == nil)
        check("PowerShell gets the prompt wrapper", ShellLocation.integrate(commandLine: "\"C:\\pwsh\\pwsh.exe\" -NoLogo", environment: [:]).commandLine.contains("-NoExit -EncodedCommand "))
        check("PowerShell running a script is left alone", ShellLocation.shellKind("pwsh.exe -File x.ps1") == .other)
        // The app's own process: its command line can be read, and it has no shell children.
        let own = GetCurrentProcessId()
        check("A process's command line can be read", ShellLocation.commandLine(of: own)?.lowercased().contains("herbsterminal") == true)
    }
}
