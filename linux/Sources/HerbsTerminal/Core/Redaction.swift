import Foundation

/// Hides secrets a command line may carry before it is shown as the window title: `user:password@host` in a
/// destination or URL, and the values of `-p`/`--password`/`*_TOKEN=`-style arguments.
func redactCredentials(_ commandLine: String) -> String {
    var text = commandLine
    let patterns = [
        #"([A-Za-z][A-Za-z0-9+.-]*://)?([^\s:/@]+):[^\s@/]+@"#: "$1$2:•••@",
        #"(?i)(--?(?:pass(?:word)?|token|secret|api[-_]?key)[= ])\S+"#: "$1•••",
        #"(?i)\b([A-Z0-9_]*(?:PASS(?:WORD)?|TOKEN|SECRET|KEY)=)\S+"#: "$1•••",
    ]
    for (pattern, template) in patterns {
        text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return text
}
