import Foundation
import WinSDK

/// The feature tests' view of Settings (R7–R11): reads the Settings window's controls as it shows them (a tab
/// control's pages, if it has one, else the whole window) and changes one through the messages a person's input
/// produces, so the window's own handlers run. A control's label is its own text (buttons, check boxes) or the label
/// just before it.
@MainActor
enum SettingsBridge {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private struct Control {
        let hwnd: HWND, kind: String, label: String, className: String, style: UInt32
    }

    static func page(_ name: String) throws -> [String: Any] {
        guard let window = SettingsWindow.openWindow else { throw Failure(description: "Settings isn't open") }
        let shown = try show(name, in: window)
        return ["page": shown, "pages": pageTitles(window), "controls": controls(in: window).map(report)]
    }

    static func set(page: String, label: String, value: Any?) throws -> Any {
        guard let window = SettingsWindow.openWindow else { throw Failure(description: "Settings isn't open") }
        _ = try show(page, in: window)
        let all = controls(in: window)
        guard let control = all.first(where: { $0.label == label }) else {
            throw Failure(description: "no \(label) in Settings (there are: \(all.map(\.label)))")
        }
        guard IsWindowEnabled(control.hwnd) else { throw Failure(description: "\(label) is greyed out") }
        let parent = GetParent(control.hwnd)
        let id = WPARAM(UInt32(bitPattern: GetDlgCtrlID(control.hwnd)) & 0xFFFF)
        let handle = LPARAM(Int(bitPattern: UnsafeRawPointer(control.hwnd)))
        func notify(_ code: Int32) { SendMessageW(parent, UINT(WM_COMMAND), (WPARAM(UInt32(code)) << 16) | id, handle) }
        switch control.kind {
        case "button":
            // Posted: a button may open a modal dialog, which the bridge answers on a later request.
            PostMessageW(control.hwnd, UINT(BM_CLICK), 0, 0)
        case "toggle":
            let on = SendMessageW(control.hwnd, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
            if (value as? Bool).map({ $0 != on }) ?? true { PostMessageW(control.hwnd, UINT(BM_CLICK), 0, 0) }
        case "text", "number" where control.className == "EDIT":
            setText(control.hwnd, value.map { "\($0)" } ?? "")
            notify(EN_KILLFOCUS)
        case "choice", "number":
            let text = value.map { "\($0)" } ?? ""
            let items = comboItems(control.hwnd)
            if let index = items.firstIndex(of: text) ?? items.firstIndex(of: text.replacingOccurrences(of: ".0", with: "")) {
                SendMessageW(control.hwnd, UINT(CB_SETCURSEL), WPARAM(index), 0)
                notify(CBN_SELCHANGE)
            } else if isEditableCombo(control) {
                setText(control.hwnd, text)
                notify(CBN_KILLFOCUS)
            } else {
                throw Failure(description: "\(label) has no item \(text) (there are: \(items))")
            }
        default:
            throw Failure(description: "\(label) is a \(control.kind), which the bridge can't change")
        }
        return "ok"
    }

    // MARK: Pages

    private static func tabControl(_ window: HWND) -> HWND? {
        children(of: window).first { className($0) == "SysTabControl32" }
    }

    private static func pageTitles(_ window: HWND) -> [String] {
        guard let tabs = tabControl(window) else { return [] }
        let count = Int(SendMessageW(tabs, UINT(TCM_GETITEMCOUNT), 0, 0))
        return (0..<count).map { index in
            var buffer = [WCHAR](repeating: 0, count: 128)
            return buffer.withUnsafeMutableBufferPointer { pointer -> String in
                var item = TCITEMW()
                item.mask = UINT(TCIF_TEXT)
                item.pszText = pointer.baseAddress
                item.cchTextMax = Int32(pointer.count)
                _ = withUnsafeMutablePointer(to: &item) {
                    SendMessageW(tabs, UINT(TCM_GETITEMW), WPARAM(index), LPARAM(Int(bitPattern: UnsafeRawPointer($0))))
                }
                return String(decoding: pointer.prefix { $0 != 0 }, as: UTF16.self)
            }
        }
    }

    /// Switches to the page `name` when the window has pages; returns what's shown.
    private static func show(_ name: String, in window: HWND) throws -> String {
        guard let tabs = tabControl(window) else { return "Settings" }
        guard let index = pageTitles(window).firstIndex(of: name) else { throw Failure(description: "Settings has no \(name) page") }
        SendMessageW(tabs, UINT(TCM_SETCURSEL), WPARAM(index), 0)
        var header = NMHDR()
        header.hwndFrom = tabs
        header.idFrom = UINT_PTR(UInt32(bitPattern: GetDlgCtrlID(tabs)))
        header.code = UINT(truncatingIfNeeded: TCN_SELCHANGE)
        _ = withUnsafeMutablePointer(to: &header) {
            SendMessageW(GetParent(tabs), UINT(WM_NOTIFY), header.idFrom, LPARAM(Int(bitPattern: UnsafeRawPointer($0))))
        }
        return name
    }

    // MARK: Controls

    private static func children(of window: HWND) -> [HWND] {
        var result: [HWND] = []
        var child = GetWindow(window, UINT(GW_CHILD))
        while let current = child {
            result.append(current)
            // A page can be a child window holding its own controls.
            if className(current) == "#32770" || className(current).hasPrefix("HerbsTerminal") { result += children(of: current) }
            child = GetWindow(current, UINT(GW_HWNDNEXT))
        }
        return result
    }

    private static func controls(in window: HWND) -> [Control] {
        var found: [Control] = []
        var lastLabel = ""
        for hwnd in children(of: window) where IsWindowVisible(hwnd) {
            let cls = className(hwnd), style = UInt32(bitPattern: GetWindowLongW(hwnd, GWL_STYLE)), title = text(hwnd)
            switch cls {
            case "Static":
                if !title.isEmpty { lastLabel = title.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) }
            case "Button":
                let type = style & 0xF
                let kind: String
                switch Int32(type) {
                case BS_CHECKBOX, BS_AUTOCHECKBOX, BS_3STATE, BS_AUTO3STATE: kind = "toggle"
                case BS_GROUPBOX: lastLabel = title; continue
                default: kind = "button"
                }
                found.append(Control(hwnd: hwnd, kind: kind, label: title.replacingOccurrences(of: "&", with: ""), className: cls, style: style))
            case "Edit":
                found.append(Control(hwnd: hwnd, kind: style & UInt32(ES_NUMBER) != 0 ? "number" : "text", label: lastLabel, className: "EDIT", style: style))
            case "ComboBox":
                let items = comboItems(hwnd)
                let numeric = style & 0x3 == UInt32(CBS_DROPDOWN) && !items.isEmpty && items.allSatisfy { Double($0) != nil }
                found.append(Control(hwnd: hwnd, kind: numeric ? "number" : "choice", label: lastLabel, className: cls, style: style))
            case "msctls_trackbar32":
                found.append(Control(hwnd: hwnd, kind: "slider", label: lastLabel, className: cls, style: style))
            default:
                break
            }
        }
        return found
    }

    private static func report(_ control: Control) -> [String: Any] {
        var result: [String: Any] = ["kind": control.kind, "label": control.label, "enabled": IsWindowEnabled(control.hwnd)]
        switch control.className {
        case "Button" where control.kind == "toggle":
            result["value"] = SendMessageW(control.hwnd, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
        case "EDIT":
            let value = text(control.hwnd)
            result["value"] = control.kind == "number" ? (Double(value) as Any? ?? value) : value
        case "ComboBox":
            let items = comboItems(control.hwnd)
            let index = Int(SendMessageW(control.hwnd, UINT(CB_GETCURSEL), 0, 0))
            let value = items.indices.contains(index) ? items[index] : text(control.hwnd)
            result["value"] = control.kind == "number" ? (Double(value) as Any? ?? value) : value
            if control.kind == "choice" { result["options"] = items }
        case "msctls_trackbar32":
            result["value"] = Int(SendMessageW(control.hwnd, UINT(TBM_GETPOS), 0, 0))
            result["min"] = Int(SendMessageW(control.hwnd, UINT(TBM_GETRANGEMIN), 0, 0))
            result["max"] = Int(SendMessageW(control.hwnd, UINT(TBM_GETRANGEMAX), 0, 0))
        default:
            break
        }
        return result
    }

    private static func isEditableCombo(_ control: Control) -> Bool { control.style & 0x3 == UInt32(CBS_DROPDOWN) }

    private static func comboItems(_ combo: HWND) -> [String] {
        let count = Int(SendMessageW(combo, UINT(CB_GETCOUNT), 0, 0))
        return (0..<max(0, count)).map { index in
            let length = Int(SendMessageW(combo, UINT(CB_GETLBTEXTLEN), WPARAM(index), 0))
            var buffer = [WCHAR](repeating: 0, count: max(0, length) + 1)
            buffer.withUnsafeMutableBufferPointer {
                _ = SendMessageW(combo, UINT(CB_GETLBTEXT), WPARAM(index), LPARAM(Int(bitPattern: $0.baseAddress!)))
            }
            return String(decoding: buffer.prefix(max(0, length)), as: UTF16.self)
        }
    }

    private static func className(_ hwnd: HWND) -> String {
        var buffer = [WCHAR](repeating: 0, count: 128)
        let length = GetClassNameW(hwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func text(_ hwnd: HWND) -> String {
        let length = GetWindowTextLengthW(hwnd)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(hwnd, &buffer, length + 1)
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func setText(_ hwnd: HWND, _ value: String) { withWide(value) { _ = SetWindowTextW(hwnd, $0) } }
}
