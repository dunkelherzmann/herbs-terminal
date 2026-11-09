import Foundation

// MARK: Tailcat peers (the Mac, Linux and Windows versions keep the same records)

/// A machine reached over Tailcat. Its address is a bearer secret, so it is protected like saved logins and only
/// handed to tailcat on connect.
struct TailcatPeer: Codable, Equatable {
    var id = UUID()
    var name: String
    var username: String
    var port = 22
    /// One-time peers come from an ephemeral `tailcat serve` and stop working when it exits.
    var persistent: Bool
    var secret: Data
}

enum TailcatRoute: Equatable {
    case unknown, checking, direct(String), relayed(String), unreachable(String)
}

extension TailcatRoute {
    /// Reads a ping report such as "pong in 42.1ms via DERP(sfo)" or "pong in 1.2ms via 203.0.113.7:41641".
    init(ping output: String) {
        let pongs = output.split(separator: "\n").filter { $0.hasPrefix("pong") }
        guard let last = pongs.last.map(String.init) else {
            let reason = output.split(separator: "\n").last.map(String.init) ?? "No reply."
            self = .unreachable(reason.isEmpty ? "No reply." : reason)
            return
        }
        let latency = last.components(separatedBy: " ").dropFirst(2).first ?? ""
        if pongs.contains(where: { !$0.contains("DERP") }) {
            let path = pongs.last { !$0.contains("DERP") }.flatMap { $0.components(separatedBy: "via ").last } ?? ""
            self = .direct("\(latency) via \(path)")
            return
        }
        let relay = last.components(separatedBy: "via ").last ?? "DERP"
        self = .relayed("\(latency) via \(relay)")
    }

    /// What the peer list shows for the route.
    var text: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .direct(let detail): "Direct · " + detail
        case .relayed(let detail): "Relayed · " + detail
        case .unreachable(let reason): "Unreachable · " + reason
        }
    }
}
