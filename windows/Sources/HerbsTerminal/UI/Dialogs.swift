import Foundation
import WinSDK

/// A small modal form: a message, optional text fields (plain or secure), an optional checkbox, and buttons.
/// `run` returns once a button is chosen, or nil when the dialog is cancelled.
@MainActor
final class FormDialog: WindowObject {
    static let className = "HerbsTerminalForm"

    struct Field {
        var label: String
        var text = ""
        var secure = false
        var number = false
        /// A drop-down instead of a text field; its value is the chosen index.
        var options: [String]? = nil
    }

    struct Button {
        var title: String
        var isDefault = false
    }

    struct Result {
        var button: Int
        var values: [String]
        var checked: Bool
    }

    private var hwnd: HWND?
    private var owner: HWND?
    private var edits: [HWND?] = []
    private var checkbox: HWND?
    private var errorLabel: HWND?
    private var buttons: [Button] = []
    private var cancelIndex: Int?
    private var result: Result?
    private var done = false
    private var fonts: [HFONT?] = []
    /// Checks the values before the dialog closes; a returned message is shown and the dialog stays open.
    private var validate: ((Int, [String], Bool) -> String?)?
    /// Called when a drop-down field changes: field index, chosen option, and the form (to fill other fields).
    private var onChoice: ((Int, Int, FormDialog) -> Void)?
    private var choiceFields: Set<Int> = []

    /// Shows the form and waits. `cancelIndex` is the button that Escape and the close box choose.
    static func run(owner: HWND?, title: String, message: String, fields: [Field] = [], checkbox: (String, Bool)? = nil,
                    buttons: [Button], cancelIndex: Int? = 0, error: String? = nil,
                    validate: ((Int, [String], Bool) -> String?)? = nil,
                    onChoice: ((Int, Int, FormDialog) -> Void)? = nil) -> Result? {
        let dialog = FormDialog()
        dialog.owner = owner
        dialog.buttons = buttons
        dialog.cancelIndex = cancelIndex
        dialog.validate = validate
        dialog.onChoice = onChoice
        return dialog.show(title: title, message: message, fields: fields, checkbox: checkbox, error: error)
    }

    /// A message with buttons; returns the chosen button, or nil when cancelled.
    static func ask(owner: HWND?, title: String, message: String, buttons: [Button], cancelIndex: Int? = 0) -> Int? {
        guard let result = run(owner: owner, title: title, message: message, buttons: buttons, cancelIndex: cancelIndex) else { return nil }
        return result.button == cancelIndex ? nil : result.button
    }

    static func tell(owner: HWND?, title: String, message: String) {
        _ = run(owner: owner, title: title, message: message, buttons: [Button(title: "OK", isDefault: true)], cancelIndex: 0)
    }

    private func show(title: String, message: String, fields: [Field], checkbox checkboxSpec: (String, Bool)?, error: String?) -> Result? {
        let dpi = owner.map { GetDpiForWindow($0) } ?? GetDpiForSystem()
        func s(_ v: Double) -> Int32 { scaled(v, dpi: dpi) }
        let width = s(440), margin = s(18), inner = width - 2 * margin
        let font = makeFont(dpi: dpi, weight: FW_NORMAL)
        let bold = makeFont(dpi: dpi, weight: FW_SEMIBOLD, size: 14)

        // Measure the message so the form grows with it.
        func measure(_ text: String, _ font: HFONT?) -> Int32 {
            guard !text.isEmpty else { return 0 }
            let dc = GetDC(nil)
            let old = SelectObject(dc, font)
            var rect = RECT(left: 0, top: 0, right: inner, bottom: 0)
            var units = Array(text.utf16)
            DrawTextW(dc, &units, Int32(units.count), &rect, UINT(DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX))
            SelectObject(dc, old)
            ReleaseDC(nil, dc)
            return rect.bottom
        }
        let titleHeight = measure(title, bold)
        let messageHeight = measure(message, font)
        var height = margin + titleHeight + s(8) + messageHeight + s(10)
        height += Int32(fields.count) * s(52) + (checkboxSpec != nil ? s(30) : 0) + s(40) + s(44) + margin

        var frame = RECT(left: 0, top: 0, right: width, bottom: height)
        let style = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
        AdjustWindowRectExForDpi(&frame, style, false, DWORD(WS_EX_DLGMODALFRAME), dpi)
        var x = CW_USEDEFAULT, y = CW_USEDEFAULT
        if let owner {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - (frame.right - frame.left)) / 2
            y = ownerRect.top + max(s(40), ((ownerRect.bottom - ownerRect.top) - (frame.bottom - frame.top)) / 3)
        }
        hwnd = createWindow(self, className: Self.className, title: title, style: style,
                            exStyle: DWORD(WS_EX_DLGMODALFRAME) | DWORD(WS_EX_CONTROLPARENT),
                            x: x, y: y, width: frame.right - frame.left, height: frame.bottom - frame.top, parent: owner)
        guard let hwnd else { return nil }

        func add(_ cls: String, _ text: String, _ style: DWORD, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32, id: Int32 = 0, font f: HFONT? = nil) -> HWND? {
            let control = withWide(cls) { c in
                withWide(text) { t in
                    CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style, x, y, w, h, hwnd,
                                    HMENU(bitPattern: Int(id)), GetModuleHandleW(nil), nil)
                }
            }
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(f ?? font)))), 1)
            return control
        }

        var top = margin
        _ = add("STATIC", title, DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), margin, top, inner, titleHeight, font: bold)
        top += titleHeight + s(8)
        if messageHeight > 0 {
            _ = add("STATIC", message, DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), margin, top, inner, messageHeight)
            top += messageHeight + s(10)
        }
        for (index, field) in fields.enumerated() {
            _ = add("STATIC", field.label, DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), margin, top, inner, s(20))
            if let options = field.options {
                let combo = add("COMBOBOX", "", DWORD(CBS_DROPDOWNLIST) | DWORD(WS_VSCROLL) | DWORD(WS_TABSTOP),
                                margin, top + s(21), inner, s(300), id: 2000 + Int32(index))
                for option in options { withWide(option) { _ = SendMessageW(combo, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0))) } }
                SendMessageW(combo, UINT(CB_SETCURSEL), WPARAM(Int(field.text) ?? 0), 0)
                edits.append(combo)
                choiceFields.insert(index)
                top += s(52)
                continue
            }
            var style = DWORD(WS_TABSTOP) | DWORD(WS_BORDER) | DWORD(ES_AUTOHSCROLL)
            if field.secure { style |= DWORD(ES_PASSWORD) }
            if field.number { style |= DWORD(ES_NUMBER) }
            let edit = add("EDIT", field.text, style, margin, top + s(21), inner, s(25))
            edits.append(edit)
            top += s(52)
        }
        if let (label, checked) = checkboxSpec {
            checkbox = add("BUTTON", label, DWORD(BS_AUTOCHECKBOX) | DWORD(WS_TABSTOP), margin, top + s(2), inner, s(22))
            SendMessageW(checkbox, UINT(BM_SETCHECK), WPARAM(checked ? BST_CHECKED : BST_UNCHECKED), 0)
            top += s(30)
        }
        errorLabel = add("STATIC", error ?? "", DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), margin, top, inner, s(36))
        top += s(40)

        // Buttons right-aligned, in the order given.
        let buttonWidths = buttons.map { max(s(84), measureButton($0.title, font) + s(28)) }
        var bx = width - margin - buttonWidths.reduce(0, +) - s(8) * Int32(max(0, buttons.count - 1))
        for (index, button) in buttons.enumerated() {
            let style = DWORD(WS_TABSTOP) | DWORD(button.isDefault ? BS_DEFPUSHBUTTON : BS_PUSHBUTTON)
            _ = add("BUTTON", button.title, style, bx, top, buttonWidths[index], s(30), id: 1000 + Int32(index))
            bx += buttonWidths[index] + s(8)
        }
        fonts = [font, bold]

        // Modal: the owner is disabled until the form closes.
        if let owner { EnableWindow(owner, false) }
        DialogTheme.apply(to: hwnd)
        ShowWindow(hwnd, TestScript.active ? SW_SHOWNOACTIVATE : SW_SHOW)
        if let first = edits.indices.first(where: { !choiceFields.contains($0) }).flatMap({ edits[$0] }) ?? edits.first ?? nil { SetFocus(first) }
        var message = MSG()
        while !done {
            let status = GetMessageW(&message, nil, 0, 0)
            if !status {
                PostQuitMessage(Int32(message.wParam))
                break
            }
            if IsDialogMessageW(hwnd, &message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        if let owner {
            EnableWindow(owner, true)
            SetActiveWindow(owner)
        }
        DestroyWindow(hwnd)
        for font in fonts { DeleteObject(font) }
        Self.open.removeAll { $0 === self }
        return result
    }

    private func makeFont(dpi: UINT, weight: Int32, size: Double = 12) -> HFONT? {
        withWide("Segoe UI") {
            CreateFontW(-scaled(size, dpi: dpi), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, $0)
        }
    }

    private func measureButton(_ text: String, _ font: HFONT?) -> Int32 {
        let dc = GetDC(nil)
        let old = SelectObject(dc, font)
        var size = SIZE()
        var units = Array(text.utf16)
        GetTextExtentPoint32W(dc, &units, Int32(units.count), &size)
        SelectObject(dc, old)
        ReleaseDC(nil, dc)
        return size.cx
    }

    private func text(of edit: HWND?) -> String {
        guard let edit else { return "" }
        let length = GetWindowTextLengthW(edit)
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(edit, &buffer, length + 1)
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private func value(_ index: Int) -> String {
        if choiceFields.contains(index) { return String(SendMessageW(edits[index], UINT(CB_GETCURSEL), 0, 0)) }
        return text(of: edits[index])
    }

    /// Replaces a text field's contents (for example when a saved login is picked).
    func setText(_ index: Int, _ value: String) {
        guard edits.indices.contains(index), !choiceFields.contains(index), let edit = edits[index] else { return }
        withWide(value) { _ = SetWindowTextW(edit, $0) }
    }

    func setChecked(_ on: Bool) {
        SendMessageW(checkbox, UINT(BM_SETCHECK), WPARAM(on ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    private func choose(_ index: Int) {
        let values = edits.indices.map(value)
        let checked = checkbox.map { SendMessageW($0, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) } ?? false
        if index != cancelIndex, let validate, let problem = validate(index, values, checked) {
            if let errorLabel { withWide(problem) { _ = SetWindowTextW(errorLabel, $0) } }
            if let first = edits.first ?? nil { SetFocus(first); SendMessageW(first, UINT(EM_SETSEL), 0, -1) }
            return
        }
        result = Result(button: index, values: values, checked: checked)
        done = true
    }

    /// For scripted runs: fills the fields and presses a button.
    func scripted(values: [String], button: Int) {
        var values = values
        // A last value of "+check" ticks the checkbox.
        if values.last == "+check" {
            values.removeLast()
            setChecked(true)
        }
        for (index, value) in values.enumerated() where edits.indices.contains(index) {
            if choiceFields.contains(index) {
                SendMessageW(edits[index], UINT(CB_SETCURSEL), WPARAM(Int(value) ?? 0), 0)
                onChoice?(index, Int(value) ?? 0, self)
            } else if !value.isEmpty || values.count > 1 {
                setText(index, value)
            }
        }
        choose(button)
    }

    var window: HWND? { hwnd }
    /// For the feature tests' bridge: the buttons' titles and how many fields there are.
    var buttonTitles: [String] { buttons.map(\.title) }
    var fieldCount: Int { edits.count }

    func handle(_ hwnd: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if Int32(message) != WM_CTLCOLORSTATIC, let themed = DialogTheme.handle(hwnd, message, wParam) { return themed }
        switch Int32(message) {
        case WM_COMMAND:
            let id = Int32(wParam & 0xFFFF)
            if id >= 2000, Int32(hiWord(wParam)) == CBN_SELCHANGE {
                let field = Int(id - 2000)
                onChoice?(field, Int(SendMessageW(edits[field], UINT(CB_GETCURSEL), 0, 0)), self)
                return 0
            }
            if id == IDOK {
                choose(buttons.firstIndex(where: \.isDefault) ?? buttons.count - 1)
            } else if id == IDCANCEL {
                if let cancelIndex { choose(cancelIndex) } else { done = true }
            } else if id >= 1000, Int(id - 1000) < buttons.count {
                choose(Int(id - 1000))
            }
            return 0
        case WM_CLOSE:
            if let cancelIndex { choose(cancelIndex) } else { done = true }
            return 0
        case WM_CTLCOLORSTATIC:
            let brush = DialogTheme.colors(message, wParam)
            if let errorLabel, HWND(bitPattern: UInt(lParam)) == errorLabel { SetTextColor(HDC(bitPattern: UInt(wParam)), DialogTheme.errorText) }
            return brush
        default:
            return nil
        }
    }

    /// The form on top, for scripted runs.
    static var current: FormDialog? { open.last }
    private static var open: [FormDialog] = []
    private init() { Self.open.append(self) }
}
