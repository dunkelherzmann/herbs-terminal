import SwiftUI
import HerbsTerminalUI

/// One destination for a multi-host command: a saved login, or the tab's live connection.
struct HostTarget: Identifiable, Hashable {
    let endpoint: RemoteEndpoint
    let password: String?
    let source: String
    var id: String { "\(endpoint.username)@\(endpoint.host):\(endpoint.port)" }

    static func == (a: HostTarget, b: HostTarget) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HostResult: Identifiable {
    enum Outcome: Equatable { case running, succeeded, failed(Int32), notReached(String), cancelled }
    let target: HostTarget
    var outcome: Outcome = .running
    var output = ""
    var seconds: Double = 0
    var id: String { target.id }
}

/// Runs the same command on several hosts at once, each over its own non-interactive ssh channel. It never
/// types into interactive sessions, never retries, and reports every host on its own.
@MainActor
final class MultiHostModel: ObservableObject {
    @Published var command = ""
    @Published var selected = Set<String>()
    @Published private(set) var results: [HostResult] = []
    @Published private(set) var running = false
    private var processes: [String: Process] = [:]

    nonisolated static let outputLimit = 64 * 1024

    func run(_ targets: [HostTarget]) async {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !targets.isEmpty else { return }
        running = true
        results = targets.map { HostResult(target: $0) }
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                let process = Self.makeProcess(target, command: command)
                processes[target.id] = process
                group.addTask { [weak self] in
                    let result = await Self.execute(process, target: target)
                    await self?.finish(result)
                }
            }
        }
        processes = [:]
        running = false
    }

    func cancel() {
        for (id, process) in processes where process.isRunning {
            process.terminate()
            if let index = results.firstIndex(where: { $0.id == id }) { results[index].outcome = .cancelled }
        }
    }

    private func finish(_ result: HostResult) {
        guard let index = results.firstIndex(where: { $0.id == result.id }) else { return }
        if results[index].outcome == .cancelled { results[index].output = result.output; return }
        results[index] = result
    }

    nonisolated static func makeProcess(_ target: HostTarget, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -T: no terminal, so nothing waits at a prompt. Unknown host keys are refused, not accepted.
        process.arguments = target.endpoint.sshArguments([
            "-T", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1",
        ]) + [command]
        var environment = ProcessInfo.processInfo.environment
        if let password = target.password, !password.isEmpty, let broker = AskpassBroker.shared {
            environment.merge(broker.environment(token: broker.issue(password, for: SSHControl.passwordLogins(target.endpoint)))) { $1 }
        } else {
            environment["SSH_ASKPASS_REQUIRE"] = "never"
            environment["SSH_ASKPASS"] = nil
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    nonisolated static func execute(_ process: Process, target: HostTarget) async -> HostResult {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started = Date()
        var result = HostResult(target: target)
        do { try process.run() } catch {
            result.outcome = .notReached(error.localizedDescription)
            return result
        }
        // Only the first `outputLimit` bytes are kept; the rest is read and dropped, so a command that
        // prints gigabytes can't fill memory.
        let (data, truncated) = await Task.detached { () -> (Data, Bool) in
            var kept = Data(), dropped = false
            let handle = pipe.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                let room = outputLimit - kept.count
                if room > 0 { kept.append(chunk.prefix(room)) }
                if chunk.count > room { dropped = true }
            }
            return (kept, dropped)
        }.value
        // Waiting for the exit off the cooperative thread pool.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); done.resume() }
        }
        result.seconds = Date().timeIntervalSince(started)
        result.output = String(decoding: data, as: UTF8.self)
        if truncated { result.output += "\n… output truncated" }
        let status = process.terminationStatus
        if process.terminationReason == .uncaughtSignal {
            result.outcome = .cancelled
        } else if status == 0 {
            result.outcome = .succeeded
        } else if status == 255 {
            // ssh's own failure: the command never ran there.
            let reason = result.output.split(separator: "\n").last.map(String.init) ?? "ssh could not connect."
            result.outcome = .notReached(reason)
        } else {
            result.outcome = .failed(status)
        }
        return result
    }
}

struct MultiHostView: View {
    @ObservedObject var model: MultiHostModel
    let targets: [HostTarget]
    let dismiss: () -> Void

    private var chosen: [HostTarget] { targets.filter { model.selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Multi-Host Commands").font(.headline)
            if let store = CredentialStore.shared, store.isLocked {
                HStack {
                    Text("Saved logins are locked with your Administrator Password.").font(.caption).foregroundStyle(.secondary)
                    Button("Unlock…") { if LoginVaultPrompts.unlock(store) { dismiss() } }
                        .hint("Unlock\nEnter the Administrator Password, then reopen Multi-Host Commands to pick saved hosts.")
                }
            }
            if targets.isEmpty {
                Text("No hosts yet. Save a login in Connect via SSH, or connect this tab, and it appears here.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Hosts").font(.caption.weight(.semibold))
                List(targets) { target in
                    Toggle(isOn: Binding(get: { model.selected.contains(target.id) },
                                         set: { if $0 { model.selected.insert(target.id) } else { model.selected.remove(target.id) } })) {
                        HStack {
                            Text(target.endpoint.label + (target.endpoint.port == 22 ? "" : ":\(target.endpoint.port)"))
                            Text(target.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .hint("\(target.endpoint.label)\nInclude this host when the command runs.")
                }
                .frame(height: 140)
                TextField("Command to run on each host", text: $model.command, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(.body, design: .monospaced))
                    .hint("Command\nRuns once per host in that account's login shell, without a terminal. Nothing is retried.")
                Text(chosen.isEmpty ? "Select at least one host."
                     : "Will run on \(chosen.map(\.endpoint.label).joined(separator: ", ")) — each account's login shell, non-interactive (no TTY).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.results.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.results) { result in resultRow(result) }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancel() }
                        .hint("Stop\nEnd the command on hosts that are still running it.")
                }
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                    .hint("Close (Esc)\nClose this panel.")
                Button("Run") { Task { await model.run(chosen) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.running || chosen.isEmpty || model.command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .hint("Run (Return)\nSend the command to every selected host at once.")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func resultRow(_ result: HostResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                switch result.outcome {
                case .running: ProgressView().controlSize(.mini)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .notReached: Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
                case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                }
                Text(result.target.endpoint.label).font(.callout.weight(.semibold))
                Text(summary(result)).font(.caption).foregroundStyle(.secondary)
            }
            if !result.output.isEmpty {
                Text(result.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func summary(_ result: HostResult) -> String {
        let time = String(format: "%.1fs", result.seconds)
        switch result.outcome {
        case .running: return "running…"
        case .succeeded: return "exit 0 · \(time)"
        case .failed(let code): return "exit \(code) · \(time)"
        case .notReached(let reason): return "not reached: \(reason)"
        case .cancelled: return "stopped"
        }
    }
}
