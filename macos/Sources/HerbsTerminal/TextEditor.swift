import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where an edited file lives: this Mac, or a host the explorer reaches over SFTP (as root in Administrator
/// mode). `version` is checked before each save so changes made elsewhere aren't overwritten silently.
struct TextFileSource {
    struct Version: Equatable, Sendable {
        let size: UInt64?
        let modified: Double?
    }

    let name: String
    /// Shown as the window's subtitle and used to find an already open window: a path, or user@host:path.
    let location: String
    let read: () async throws -> Data
    let version: () async throws -> Version?
    let write: (Data) async throws -> Void

    static func local(_ url: URL) -> TextFileSource {
        // Edit the file a link points at; an atomic save would otherwise replace the link with a copy.
        let url = url.resolvingSymlinksInPath()
        return TextFileSource(
            name: url.lastPathComponent, location: url.path,
            read: { try await Task.detached { try Data(contentsOf: url) }.value },
            version: {
                // Read fresh each time; URL resource values are cached on the URL.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
                return Version(size: (attributes[.size] as? NSNumber)?.uint64Value,
                               modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
            },
            write: { data in
                try await Task.detached {
                    let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    try data.write(to: url, options: .atomic)
                    if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                }.value
            })
    }
}

/// Text encodings the editor reads and writes back unchanged.
enum TextCodec {
    static let sizeLimit = 20 * 1024 * 1024

    /// The text and its encoding, or nil for a file that looks binary (NUL bytes without a UTF-16 mark).
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return (text, .utf16) }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        // Every byte sequence is valid Latin-1, so older 8-bit files still open and save byte for byte.
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1) }
    }

    static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .isoLatin1: "Latin-1"
        default: String.localizedName(of: encoding)
        }
    }

    /// Whether a file opens in the editor rather than its Mac app: text types by extension, and files
    /// without a known type whose first bytes look like text.
    static func isText(name: String, sniff: () -> Data?) -> Bool {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
            if [.text, .sourceCode, .script, .json, .xml, .yaml, .propertyList, .commaSeparatedText, .log].contains(where: type.conforms(to:)) {
                return true
            }
            // A known type that isn't text (an image, a PDF, an archive) opens elsewhere.
            if type.conforms(to: .data) && type != .data { return false }
        }
        guard let head = sniff() else { return false }
        return decode(head) != nil
    }

    static func isLocalText(_ url: URL) -> Bool {
        isText(name: url.lastPathComponent) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8192)
        }
    }
}

/// A plain-text editor shown as a tab in the terminal window: monospaced, with undo, Find (⌘F), line wrapping
/// and a status line. ⌘S saves; closing the tab with unsaved changes asks first.
@MainActor
final class TextEditorModel: NSObject, ObservableObject, NSTextViewDelegate {
    let source: TextFileSource
    /// Unsaved changes; the tab shows a dot while this is set.
    @Published private(set) var isEdited = false
    let contentView: NSView
    private let textView: EditorTextView
    private let scrollView: NSScrollView
    private let status = NSTextField(labelWithString: "Loading…")
    private let wrapButton = NSButton(checkboxWithTitle: "Wrap Lines", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var encoding: String.Encoding = .utf8
    private var loadedVersion: TextFileSource.Version?
    private var loaded = false
    /// Called when the file can't be opened; the tab closes itself.
    var onFailure: (() -> Void)?

    init(source: TextFileSource) {
        self.source = source
        textView = EditorTextView()
        scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        contentView = NSView()
        super.init()
        textView.onSave = { [weak self] in self?.save() }
        configureText()
        layout()
    }

    private func configureText() {
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isEditable = false
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        let settings = TerminalProfile.shared.defaultProfile.settings
        textView.font = NSFontManager.shared.convert(settings.font, toSize: max(12, settings.font.pointSize))
        textView.textContainerInset = NSSize(width: 6, height: 6)
        wrapButton.target = self
        wrapButton.action = #selector(toggleWrap)
        wrapButton.state = UserDefaults.standard.object(forKey: "editorWrapsLines") as? Bool ?? true ? .on : .off
        wrapButton.toolTip = "Wrap long lines at the edge instead of scrolling sideways."
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.toolTip = "Save (⌘S)"
        saveButton.isEnabled = false
        applyWrap()
    }

    private func layout() {
        let bar = NSStackView(views: [status, NSView(), wrapButton, saveButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in [wrapButton, saveButton] as [NSControl] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let divider = NSBox()
        divider.boxType = .separator
        for view in [scrollView, divider, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func load() async {
        do {
            let data = try await source.read()
            guard data.count <= TextCodec.sizeLimit else {
                throw FileIssue("“\(source.name)” is larger than \(TextCodec.sizeLimit / 1_048_576) MB, too big to edit here.")
            }
            guard let decoded = TextCodec.decode(data) else {
                throw FileIssue("“\(source.name)” doesn't look like a text file, so it wasn't opened for editing.")
            }
            loadedVersion = try? await source.version()
            encoding = decoded.encoding
            textView.string = decoded.text
            textView.isEditable = true
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            loaded = true
            setEdited(false)
            focus()
            updateStatus()
        } catch {
            status.stringValue = error.localizedDescription
            NSAlert(error: error).runModal()
            onFailure?()
        }
    }

    func focus() {
        DispatchQueue.main.async { [textView] in textView.window?.makeFirstResponder(textView) }
    }

    func find() {
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        textView.performTextFinderAction(item)
    }

    /// Saves, after checking that nobody changed the file since it was opened or last saved.
    @discardableResult
    func save() -> Task<Bool, Never> {
        Task { await saveNow() }
    }

    @objc private func saveClicked() { save() }

    func saveNow() async -> Bool {
        guard loaded else { return false }
        guard let data = textView.string.data(using: encoding) else {
            NSAlert(error: FileIssue("Some characters can't be saved in \(TextCodec.name(of: encoding)). Remove them, or save a copy in UTF-8.")).runModal()
            return false
        }
        if let current = try? await source.version(), let loadedVersion, current != loadedVersion {
            let alert = NSAlert()
            alert.messageText = "“\(source.name)” changed since you opened it."
            alert.informativeText = "Saving replaces those changes with yours."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            try await source.write(data)
            loadedVersion = try? await source.version()
            setEdited(false)
            updateStatus()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Before the tab closes: true when it may close (saved, nothing to save, or changes discarded).
    func confirmClose() async -> Bool {
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(source.name)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return await saveNow()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func setEdited(_ edited: Bool) {
        if isEdited != edited { isEdited = edited }
        saveButton.isEnabled = edited
    }

    @objc private func toggleWrap() {
        UserDefaults.standard.set(wrapButton.state == .on, forKey: "editorWrapsLines")
        applyWrap()
    }

    func applyWrap() {
        let wraps = wrapButton.state == .on
        let container = textView.textContainer
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container?.widthTracksTextView = wraps
        container?.containerSize = NSSize(width: wraps ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                          height: CGFloat.greatestFiniteMagnitude)
        if wraps { textView.frame.size.width = scrollView.contentSize.width }
    }

    private func updateStatus() {
        let text = textView.string as NSString
        let caret = min(textView.selectedRange().location, text.length)
        let before = text.substring(to: caret)
        let line = before.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let column = (before as NSString).length - ((before as NSString).range(of: "\n", options: .backwards).upperBound)
        let lines = textView.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let endings = textView.string.contains("\r\n") ? "CRLF" : "LF"
        status.stringValue = "Line \(line), Column \(column + 1) · \(lines) line\(lines == 1 ? "" : "s") · \(TextCodec.name(of: encoding)) · \(endings)"
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        setEdited(true)
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if loaded { updateStatus() }
    }
}

/// The editor's text view: ⌘S saves while it has focus.
final class EditorTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "s", window?.firstResponder === self {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Puts an editor tab's view in the window.
struct EditorPane: NSViewRepresentable {
    let model: TextEditorModel

    func makeNSView(context: Context) -> NSView {
        model.focus()
        return model.contentView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { model.applyWrap() }
    }
}

extension TextEditorModel {
    /// Feature tests: the text being edited.
    var bridgeText: String { textView.string }

    /// Feature tests: what the editor shows, and the selected text.
    var bridgeState: [String: Any] {
        let text = textView.string as NSString
        let range = textView.selectedRange()
        return ["name": source.name, "edited": isEdited, "text": textView.string, "wrap": wrapButton.state == .on,
                "status": status.stringValue, "monospaced": textView.font?.isFixedPitch ?? false,
                "finding": scrollView.isFindBarVisible, "loaded": loaded,
                "selection": NSMaxRange(range) <= text.length ? text.substring(with: range) : ""]
    }

    /// Feature tests: types (as the keyboard does, so it's undoable), undoes, opens Find, saves or toggles Wrap
    /// Lines. Find here is AppKit's own find bar, which the bridge opens but doesn't type into.
    func bridge(_ action: String, text: String) {
        switch action {
        case "type": textView.insertText(text, replacementRange: textView.selectedRange())
        case "undo": textView.undoManager?.undo()
        case "find": find()
        case "save": save()
        case "wrap": wrapButton.performClick(nil)
        case "start": textView.setSelectedRange(NSRange(location: 0, length: 0))
        default: break
        }
    }
}
