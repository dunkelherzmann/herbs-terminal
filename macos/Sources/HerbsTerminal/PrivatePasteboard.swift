import AppKit
import ObjectiveC

/// The parity copy's own clipboard. Feature tests copy, paste and take screenshots, and that must never touch
/// what the user has on the clipboard. In a parity copy every use of `NSPasteboard.general` (this app's, and
/// SwiftTerm's and AppKit's own Copy and Paste) is pointed at a private named pasteboard instead.
enum PrivatePasteboard {
    // NSPasteboard is safe to use from any thread; `general` may be asked for anywhere.
    nonisolated(unsafe) static let board = NSPasteboard(name: NSPasteboard.Name("org.herbsterminal.parity.clipboard"))

    /// Call once, at launch, and only in a parity copy.
    static func install() {
        precondition(ParityScene.isActive, "the private pasteboard is for the parity copy only")
        board.clearContents()
        guard let method = class_getClassMethod(NSPasteboard.self, NSSelectorFromString("generalPasteboard")) else { return }
        let general: @convention(block) (AnyObject) -> NSPasteboard = { _ in PrivatePasteboard.board }
        method_setImplementation(method, imp_implementationWithBlock(general))
    }

    /// What the bridge reports: the text, file paths, and whether a picture is there.
    static var contents: [String: Any] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return ["text": board.string(forType: .string) ?? "", "files": urls.map(\.path),
                "image": board.data(forType: .png) != nil || board.data(forType: .tiff) != nil]
    }
}
