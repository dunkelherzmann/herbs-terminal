import Foundation
import WinSDK

/// Runs work on the window thread from a background thread. The app's message loop doesn't run Swift's main
/// dispatch queue, so this posts a message to a hidden message-only window instead.
@MainActor
final class MainThread: WindowObject {
    static let className = "HerbsTerminalMainThread"
    private static var shared: MainThread?
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var queue: [@Sendable @MainActor () -> Void] = []
    private nonisolated(unsafe) static var window: HWND?
    private var hwnd: HWND?

    /// Call once on the window thread, after the window classes are registered.
    static func start() {
        let object = MainThread()
        shared = object
        object.hwnd = withWide(className) { cls in
            CreateWindowExW(0, cls, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3) /* HWND_MESSAGE */, nil, GetModuleHandleW(nil),
                            Unmanaged.passUnretained(object as AnyObject).toOpaque())
        }
        lock.withLock { window = object.hwnd }
    }

    /// Schedules `work` on the window thread; safe from any thread.
    nonisolated static func async(_ work: @escaping @Sendable @MainActor () -> Void) {
        let target: HWND? = lock.withLock {
            queue.append(work)
            return window
        }
        PostMessageW(target, UINT(WM_APP_MAIN), 0, 0)
    }

    /// Runs `work` on the window thread after `seconds`; safe from any thread. (DispatchQueue.main never runs here.)
    nonisolated static func after(_ seconds: Double, _ work: @escaping @Sendable @MainActor () -> Void) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: seconds)
            async(work)
        }
    }

    /// Runs `body` on a background thread and hands its result to `done` on the window thread.
    nonisolated static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T,
                                                    done: @escaping @Sendable @MainActor (Result<T, Error>) -> Void) {
        Thread.detachNewThread {
            let result = Result { try body() }
            async { done(result) }
        }
    }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard Int32(message) == WM_APP_MAIN else { return nil }
        let work = Self.lock.withLock { () -> [@Sendable @MainActor () -> Void] in
            let items = Self.queue
            Self.queue.removeAll()
            return items
        }
        for item in work { item() }
        return 0
    }
}

let WM_APP_MAIN = Int32(WM_APP) + 4
