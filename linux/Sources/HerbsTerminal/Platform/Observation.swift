import Foundation

// SwiftUI's ObservableObject and @Published, for the shared model classes. There's no Combine on Linux; a change
// to a @Published property calls the object's observers, which the GTK views use to refresh.

/// Change notifications for one object.
final class ObjectChange {
    private var observers: [Int: () -> Void] = [:]
    private var next = 0

    /// Calls every observer. Observers may add or remove observers while they run.
    func send() {
        for observer in Array(observers.values) { observer() }
    }

    /// Observes changes until the returned token is released.
    func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        next += 1
        let id = next
        observers[id] = handler
        return ObservationToken { [weak self] in self?.observers[id] = nil }
    }
}

final class ObservationToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

protocol ObservableObject: AnyObject {}

private nonisolated(unsafe) var changeRegistry: [ObjectIdentifier: (object: Weak, change: ObjectChange)] = [:]

private struct Weak {
    weak var value: AnyObject?
}

extension ObservableObject {
    var objectWillChange: ObjectChange {
        let key = ObjectIdentifier(self)
        if let entry = changeRegistry[key], entry.object.value === self { return entry.change }
        if changeRegistry.count > 256 { changeRegistry = changeRegistry.filter { $0.value.object.value != nil } }
        let change = ObjectChange()
        changeRegistry[key] = (Weak(value: self), change)
        return change
    }
}

@propertyWrapper
struct Published<Value> {
    private var value: Value

    init(wrappedValue: Value) { value = wrappedValue }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript<Object: ObservableObject>(
        _enclosingInstance object: Object,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Object, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Object, Published<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].value }
        set {
            object[keyPath: storageKeyPath].value = newValue
            object.objectWillChange.send()
        }
    }
}
