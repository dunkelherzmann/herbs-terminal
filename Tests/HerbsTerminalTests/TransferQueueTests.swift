import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Transfer Queue Tests")
@MainActor
struct TransferQueueTests {

    @Test
    func enqueueUploadAndDownload() throws {
        let queue = TransferQueue()
        let localURL = URL(fileURLWithPath: "/tmp/sample.txt")

        let uploadId = queue.enqueueUpload(localURL: localURL, remotePath: "/home/user/sample.txt", totalBytes: 1024)
        #expect(queue.items.count == 1)

        let uploadItem = try #require(queue.items.first { $0.id == uploadId })
        #expect(uploadItem.state == .pending)
        #expect(uploadItem.totalBytes == 1024)

        let downloadId = queue.enqueueDownload(remotePath: "/var/log/syslog", localURL: URL(fileURLWithPath: "/tmp/syslog"), totalBytes: 2048)
        #expect(queue.items.count == 2)

        let downloadItem = try #require(queue.items.first { $0.id == downloadId })
        #expect(downloadItem.state == .pending)
        #expect(downloadItem.totalBytes == 2048)
    }

    @Test
    func cancelTransferItem() throws {
        let queue = TransferQueue()
        let localURL = URL(fileURLWithPath: "/tmp/data.bin")

        let itemId = queue.enqueueUpload(localURL: localURL, remotePath: "/remote/data.bin", totalBytes: 5000)
        queue.cancel(id: itemId)

        let item = try #require(queue.items.first { $0.id == itemId })
        #expect(item.state == .cancelled)
    }

    @Test
    func updateTransferProgress() throws {
        let queue = TransferQueue()
        let localURL = URL(fileURLWithPath: "/tmp/bigfile.iso")

        let itemId = queue.enqueueUpload(localURL: localURL, remotePath: "/remote/bigfile.iso", totalBytes: 10000)
        queue.updateProgress(id: itemId, bytesTransferred: 5000)

        let item = try #require(queue.items.first { $0.id == itemId })
        #expect(item.state == .inProgress(bytesTransferred: 5000, totalBytes: 10000))

        queue.markCompleted(id: itemId)
        let completed = try #require(queue.items.first { $0.id == itemId })
        #expect(completed.state == .completed)
    }
}
