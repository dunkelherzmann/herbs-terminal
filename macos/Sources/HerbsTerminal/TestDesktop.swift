import AppKit

/// The feature tests' own desktop on the Mac: the last desktop (Space) of the main display. A parity copy started
/// with `--test-desktop` moves every window it shows there, so tests run in the foreground on that desktop and
/// never on the one in use; switching to it shows the run. macOS has no public API for desktops, so this uses
/// SkyLight's, which may move only the app's own windows. With a single desktop, windows stay where they open.
@MainActor
enum TestDesktop {
    static let isActive = ParityScene.isActive && CommandLine.arguments.contains("--test-desktop")

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func function<T>(_ name: String, _ type: T.Type) -> T? { dlsym(skyLight, name).map { unsafeBitCast($0, to: type) } }

    private static var placed = Set<Int>()
    private static var observer: NSObjectProtocol?

    static func start() {
        guard isActive, observer == nil else { return }
        // After every pass of the event loop, before the window server shows a new window on screen.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { placeNewWindows() }
        }
    }

    private static func placeNewWindows() {
        let windows = NSApp.windows.map(\.windowNumber).filter { $0 > 0 && !placed.contains($0) }
        guard !windows.isEmpty, let space = testSpace(), let connection = function("SLSMainConnectionID", MainConnection.self)?(),
              let move = function("SLSMoveWindowsToManagedSpace", MoveWindows.self) else { return }
        move(connection, windows as CFArray, space)
        placed.formUnion(windows)
    }

    /// The last ordinary desktop (not a full-screen app) of the main display, if it has more than one.
    private static func testSpace() -> UInt64? {
        guard let connection = function("SLSMainConnectionID", MainConnection.self)?(),
              let displays = function("SLSCopyManagedDisplaySpaces", CopySpaces.self)?(connection)?.takeRetainedValue() as? [[String: Any]],
              let main = displays.first else { return nil }
        let desktops = (main["Spaces"] as? [[String: Any]] ?? []).filter { $0["type"] as? Int == 0 }
        guard desktops.count > 1, let id = desktops.last?["ManagedSpaceID"] as? Int else { return nil }
        return UInt64(id)
    }
}
