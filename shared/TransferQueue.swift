import Foundation

enum TransferDirection: Equatable, Sendable {
    case upload(localURL: URL, remotePath: String)
    case download(remotePath: String, localURL: URL)
}

enum TransferState: Equatable, Sendable {
    case pending
    case inProgress(bytesTransferred: Int64, totalBytes: Int64)
    case completed
    case failed(message: String)
    case cancelled
}

struct TransferItem: Identifiable, Sendable {
    let id: UUID
    let direction: TransferDirection
    var state: TransferState
    var totalBytes: Int64
    var name: String

    var progressFraction: Double {
        switch state {
        case .pending:
            return 0.0
        case .inProgress(let transferred, let total):
            return total > 0 ? Double(transferred) / Double(total) : 0.0
        case .completed:
            return 1.0
        case .failed, .cancelled:
            return 0.0
        }
    }
}

@MainActor
final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    @Published var items: [TransferItem] = []

    func enqueueUpload(localURL: URL, remotePath: String, totalBytes: Int64) -> UUID {
        let id = UUID()
        let item = TransferItem(id: id,
                                direction: .upload(localURL: localURL, remotePath: remotePath),
                                state: .pending,
                                totalBytes: totalBytes,
                                name: localURL.lastPathComponent)
        items.append(item)
        return id
    }

    func enqueueDownload(remotePath: String, localURL: URL, totalBytes: Int64) -> UUID {
        let id = UUID()
        let item = TransferItem(id: id,
                                direction: .download(remotePath: remotePath, localURL: localURL),
                                state: .pending,
                                totalBytes: totalBytes,
                                name: (remotePath as NSString).lastPathComponent)
        items.append(item)
        return id
    }

    func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .cancelled
    }

    func updateProgress(id: UUID, bytesTransferred: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // A late report from a background transfer must not revive a finished item.
        switch items[index].state {
        case .pending, .inProgress: break
        default: return
        }
        let total = items[index].totalBytes
        items[index].state = .inProgress(bytesTransferred: bytesTransferred, totalBytes: total)
    }

    func markCompleted(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed
    }

    func markFailed(id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed(message: message)
    }
}
