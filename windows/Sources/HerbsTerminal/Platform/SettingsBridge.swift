import Foundation
import WinSDK

/// The feature tests' view of Settings (R7–R11): reads a page's controls as the window shows them and changes one
/// through the messages a person's input produces, so the window's own handlers run. A control's label is its own
/// text (buttons, check boxes, lists), or the label just before it; a row of linked option buttons is one choice.
@MainActor
enum SettingsBridge {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private struct Control {
        let kind: String, label: String, className: String
        var hwnds: [HWND]
        var hwnd: HWND { hwnds[0] }
    }

    static func page(_ name: String) throws -> [String: Any] {
        guard let window = SettingsWindow.openWindow else { throw Failure(description: "Settings isn't open") }
        guard SettingsWindow.showPage(name) else { throw Failure(description: "Settings has no \(name) page") }
        return ["page": name, "pages": SettingsWindow.pageTitles, "controls": controls(in: window).map(report)]
    }

    static func set(page: String, label: String, value: Any?) throws -> Any {
        guard let window = SettingsWindow.openWindow else { throw Failure(description: "Settings isn't open") }
        guard SettingsWindow.showPage(page) else { throw Failure(description: "Settings has no \(page) page") }
        let all = controls(in: window)
        guard let control = all.first(where: { $0.label == label }) else {
            throw Failure(description: "no \(label) in Settings ▸ \(page) (there are: \(all.map(\.label)))")
        }
        guard IsWindowEnabled(control.hwnd) else { throw Failure(description: "\(label) is greyed out") }
        let parent = GetParent(control.hwnd)
        func notify(_ code: Int32, _ hwnd: HWND) {
            let id = WPARAM(UInt32(bitPattern: GetDlgCtrlID(hwnd)) & 0xFFFF)
            SendMessageW(parent, UINT(WM_COMMAND), (WPARAM(UInt32(bitPattern: code)) << 16) | id, LPARAM(Int(bitPattern: UnsafeRawPointer(hwnd))))
        }
        let text = value.map { "\($0)" } ?? ""
        switch (control.kind, control.className) {
        case ("button", _):
            // Posted: a button may open a modal dialog, which the bridge answers on a later request.
            PostMessageW(control.hwnd, UINT(BM_CLICK), 0, 0)
        case ("toggle", _):
            if (value as? Bool).map({ $0 != isChecked(control.hwnd) }) ?? true { PostMessageW(control.hwnd, UINT(BM_CLICK), 0, 0) }
        case ("choice", "Button"):
            guard let button = control.hwnds.first(where: { self.text(of: $0) == text }) else {
                throw missing(label, text, control.hwnds.map { self.text(of: $0) })
            }
            SendMessageW(button, UINT(BM_CLICK), 0, 0)
        case ("choice", "ListBox"):
            guard let index = listItems(control.hwnd).firstIndex(of: text) else { throw missing(label, text, listItems(control.hwnd)) }
            SendMessageW(control.hwnd, UINT(LB_SETCURSEL), WPARAM(index), 0)
            notify(LBN_SELCHANGE, control.hwnd)
        case ("choice", _):
            let items = comboItems(control.hwnd)
            if let index = items.firstIndex(of: text) {
                SendMessageW(control.hwnd, UINT(CB_SETCURSEL), WPARAM(index), 0)
                notify(CBN_SELCHANGE, control.hwnd)
            } else if UInt32(bitPattern: GetWindowLongW(control.hwnd, GWL_STYLE)) & 0x3 == UInt32(CBS_DROPDOWN) {
                setText(control.hwnd, text)
                notify(CBN_KILLFOCUS, control.hwnd)
            } else {
                throw missing(label, text, items)
            }
        case ("slider", _):
            // Settings' sliders are percentages; the bridge speaks in fractions, as the Mac's do.
            guard let fraction = (value as? NSNumber)?.doubleValue else { throw Failure(description: "\(label) needs a number") }
            SendMessageW(control.hwnd, UINT(TBM_SETPOS), 1, LPARAM(Int((fraction * 100).rounded())))
            SendMessageW(parent, UINT(WM_HSCROLL), WPARAM(SB_THUMBPOSITION), LPARAM(Int(bitPattern: UnsafeRawPointer(control.hwnd))))
        case ("text", _), ("number", _):
            // Typed (the field reports each change), then left, as when a person tabs away.
            var typed = text
            if let number = value as? NSNumber, number.doubleValue == number.doubleValue.rounded() { typed = String(Int(number.doubleValue)) }
            setText(control.hwnd, typed)
            notify(EN_KILLFOCUS, control.hwnd)
        default:
            throw Failure(description: "\(label) is a \(control.kind), which the bridge can't change")
        }
        return "ok"
    }

    private static func missing(_ label: String, _ item: String, _ items: [String]) -> Failure {
        Failure(description: "\(label) has no item \(item) (there are: \(items))")
    }

    // MARK: Reading the window

    private static var rangeOf: [HWND: (Int, Int)] = [:]

    private static func controls(in window: HWND) -> [Control] {
        var all: [HWND] = []
        var child = GetWindow(window, UINT(GW_CHILD))
        while let current = child {
            all.append(current)
            child = GetWindow(current, UINT(GW_HWNDNEXT))
        }
        // A number field's range is its arrows'.
        rangeOf = [:]
        for arrows in all where className(arrows) == "msctls_updown32" {
            guard let field = buddy(of: arrows) else { continue }
            var low: Int32 = 0, high: Int32 = 0
            withUnsafeMutablePointer(to: &low) { lowPointer in
                withUnsafeMutablePointer(to: &high) { highPointer in
                    _ = SendMessageW(arrows, UINT(UDM_GETRANGE32), WPARAM(UInt(bitPattern: Int(bitPattern: lowPointer))),
                                     LPARAM(Int(bitPattern: highPointer)))
                }
            }
            rangeOf[field] = (Int(low), Int(high))
        }
        var found: [Control] = []
        var lastLabel = ""
        for hwnd in all where IsWindowVisible(hwnd) && !SettingsWindow.isPageButton(hwnd) {
            let cls = className(hwnd), style = UInt32(bitPattern: GetWindowLongW(hwnd, GWL_STYLE)), title = text(of: hwnd)
            switch cls {
            case "Static":
                if style & 0x1F == UInt32(SS_OWNERDRAW) {
                    // A drawn part, such as the preview: its text names it and says what it shows.
                    found.append(Control(kind: "display", label: title.components(separatedBy: ": ")[0], className: cls, hwnds: [hwnd]))
                } else if !title.isEmpty {
                    lastLabel = title.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                }
            case "Button":
                switch Int32(style & 0xF) {
                case BS_CHECKBOX, BS_AUTOCHECKBOX, BS_3STATE, BS_AUTO3STATE:
                    found.append(Control(kind: "toggle", label: title, className: cls, hwnds: [hwnd]))
                case BS_RADIOBUTTON, BS_AUTORADIOBUTTON:
                    if style & UInt32(WS_GROUP) == 0, let last = found.indices.last, found[last].kind == "choice", found[last].className == "Button" {
                        found[last].hwnds.append(hwnd)
                    } else {
                        found.append(Control(kind: "choice", label: lastLabel, className: cls, hwnds: [hwnd]))
                    }
                case BS_GROUPBOX:
                    lastLabel = title
                default:
                    found.append(Control(kind: "button", label: title.replacingOccurrences(of: "&", with: ""), className: cls, hwnds: [hwnd]))
                }
            case "Edit":
                let numeric = style & UInt32(ES_NUMBER) != 0 || rangeOf[hwnd] != nil
                found.append(Control(kind: numeric ? "number" : "text", label: lastLabel, className: cls, hwnds: [hwnd]))
            case "ComboBox":
                found.append(Control(kind: "choice", label: lastLabel, className: cls, hwnds: [hwnd]))
            case "ListBox":
                found.append(Control(kind: "choice", label: title.isEmpty ? lastLabel : title, className: cls, hwnds: [hwnd]))
            case "msctls_trackbar32":
                found.append(Control(kind: "slider", label: lastLabel, className: cls, hwnds: [hwnd]))
            default:
                break
            }
        }
        return found
    }

    private static func buddy(of arrows: HWND) -> HWND? {
        HWND(bitPattern: Int(SendMessageW(arrows, UINT(UDM_GETBUDDY), 0, 0)))
    }

    private static func report(_ control: Control) -> [String: Any] {
        var result: [String: Any] = ["kind": control.kind, "label": control.label, "enabled": IsWindowEnabled(control.hwnd)]
        switch (control.kind, control.className) {
        case ("toggle", _):
            result["value"] = isChecked(control.hwnd)
        case ("choice", "Button"):
            result["options"] = control.hwnds.map { text(of: $0) }
            result["value"] = control.hwnds.first(where: { isChecked($0) }).map { text(of: $0) } ?? ""
        case ("choice", "ListBox"):
            let items = listItems(control.hwnd)
            let index = Int(SendMessageW(control.hwnd, UINT(LB_GETCURSEL), 0, 0))
            result["options"] = items
            result["value"] = items.indices.contains(index) ? items[index] : ""
        case ("choice", _):
            let items = comboItems(control.hwnd)
            let index = Int(SendMessageW(control.hwnd, UINT(CB_GETCURSEL), 0, 0))
            result["options"] = items
            result["value"] = items.indices.contains(index) ? items[index] : text(of: control.hwnd)
        case ("number", _):
            let value = text(of: control.hwnd)
            result["value"] = Double(value.replacingOccurrences(of: ",", with: ".")) as Any? ?? value
            if let range = rangeOf[control.hwnd] { result["min"] = range.0; result["max"] = range.1 }
        case ("slider", _):
            result["value"] = Double(SendMessageW(control.hwnd, UINT(TBM_GETPOS), 0, 0)) / 100
            result["min"] = Double(SendMessageW(control.hwnd, UINT(TBM_GETRANGEMIN), 0, 0)) / 100
            result["max"] = Double(SendMessageW(control.hwnd, UINT(TBM_GETRANGEMAX), 0, 0)) / 100
        case ("display", _):
            result["value"] = text(of: control.hwnd).components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        case ("text", _):
            result["value"] = text(of: control.hwnd)
        default:
            break
        }
        return result
    }

    private static func isChecked(_ hwnd: HWND) -> Bool { SendMessageW(hwnd, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }

    private static func comboItems(_ combo: HWND) -> [String] {
        items(combo, count: UINT(CB_GETCOUNT), length: UINT(CB_GETLBTEXTLEN), text: UINT(CB_GETLBTEXT))
    }

    private static func listItems(_ list: HWND) -> [String] {
        items(list, count: UINT(LB_GETCOUNT), length: UINT(LB_GETTEXTLEN), text: UINT(LB_GETTEXT))
    }

    private static func items(_ control: HWND, count: UINT, length: UINT, text: UINT) -> [String] {
        let total = Int(SendMessageW(control, count, 0, 0))
        return (0..<max(0, total)).map { index in
            let size = max(0, Int(SendMessageW(control, length, WPARAM(index), 0)))
            var buffer = [WCHAR](repeating: 0, count: size + 1)
            buffer.withUnsafeMutableBufferPointer { _ = SendMessageW(control, text, WPARAM(index), LPARAM(Int(bitPattern: $0.baseAddress!))) }
            return String(decoding: buffer.prefix(size), as: UTF16.self)
        }
    }

    private static func className(_ hwnd: HWND) -> String {
        var buffer = [WCHAR](repeating: 0, count: 128)
        let length = GetClassNameW(hwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func text(of hwnd: HWND) -> String {
        let length = GetWindowTextLengthW(hwnd)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(hwnd, &buffer, length + 1)
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func setText(_ hwnd: HWND, _ value: String) { withWide(value) { _ = SetWindowTextW(hwnd, $0) } }
}
