import CHerbUIA
import Foundation
import WinSDK

/// One drawn control as UI Automation shows it (the toolbar, the tab strip, the window buttons, the explorer's
/// bar and places): screen readers read its name, hover text, shortcut and state, and can press it.
struct AccessibleItem {
    var identifier: String, name: String, help: String?, accelerator: String?
    var rect: RECT, controlType: Int32, enabled = true, popup = false, invokable = true, tag: Int
    /// A toggle button's on/off state and a tab's or place's selected state, which screen readers announce.
    var toggle: Int32 = -1, selected: Int32 = -1

    static let button = Int32(HERB_UIA_BUTTON), tabItem = Int32(HERB_UIA_TAB_ITEM), text = Int32(HERB_UIA_TEXT)
    static let listItem: Int32 = 50007  // UIA_ListItemControlTypeId

    /// Replaces the drawn controls `owner` shows to UI Automation. Cheap: it runs on every layout or paint.
    static func publish(_ entries: [AccessibleItem], owner: HWND) {
        // Every string stays alive until herb_uia_set_items has copied it.
        var storage: [[UInt16]] = []
        func keep(_ text: String?) -> Int? {
            guard let text else { return nil }
            storage.append(Array(text.utf16) + [0])
            return storage.count - 1
        }
        let slots = entries.map { (keep($0.identifier), keep($0.name), keep($0.help), keep($0.accelerator)) }
        let pointers: [UnsafeMutablePointer<UInt16>] = storage.map { text in
            let pointer = UnsafeMutablePointer<UInt16>.allocate(capacity: text.count)
            pointer.initialize(from: text, count: text.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        func pointer(_ slot: Int?) -> UnsafePointer<UInt16>? { slot.map { UnsafePointer(pointers[$0]) } }
        let items = zip(entries, slots).map { entry, slot in
            HerbUIAItem(automationId: pointer(slot.0), name: pointer(slot.1), help: pointer(slot.2), accelerator: pointer(slot.3),
                        left: entry.rect.left, top: entry.rect.top, right: entry.rect.right, bottom: entry.rect.bottom,
                        controlType: entry.controlType, enabled: entry.enabled ? 1 : 0, hasPopup: entry.popup ? 1 : 0,
                        invokable: entry.invokable ? 1 : 0, tag: Int32(entry.tag), toggle: entry.toggle, selected: entry.selected)
        }
        items.withUnsafeBufferPointer { herb_uia_set_items(UnsafeMutableRawPointer(owner), $0.baseAddress, Int32($0.count)) }
    }
}
