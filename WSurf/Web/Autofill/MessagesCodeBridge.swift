// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

/// What the native code field takes for a code. Pure: text in, code out.
nonisolated enum MessagesCode {
    static let lengths = 3...12

    /// `text` as a code (trimmed, 3 to 12 letters and digits), or nil.
    static func plausible(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAlphanumeric = code.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        return lengths.contains(code.count) && isAlphanumeric ? code : nil
    }

    /// The code an edit brought in, when one edit inserted a whole code at once, as macOS does when the person picks its
    /// suggestion. Typing a character at a time never counts; that goes on with Return.
    static func inserted(from previous: String, to current: String) -> String? {
        current.count - previous.count >= lengths.lowerBound ? plausible(current) : nil
    }
}

/// The native text field macOS offers one-time codes to (`contentType = .oneTimeCode`): from Messages or Mail, as the system lists
/// them under it. Web views do not get that list in WSurf (AppKit stops offering it once CEF is loaded), a native field does.
///
/// A code leaves the field once, through `onCode`, and the field is empty and without undo history before the owner sees it: it
/// is never kept, logged, put on the pasteboard or saved anywhere.
@MainActor
final class MessagesCodeField: NSTextField, NSTextFieldDelegate {
    /// A code was picked from the system's list, or typed and confirmed with Return.
    var onCode: (@MainActor (String) -> Void)?
    /// Escape. Without it, Escape goes on to the window (a sheet's Cancel).
    var onCancel: (@MainActor () -> Void)?
    var onEndEditing: (@MainActor () -> Void)?
    private var before = ""

    init(site: String?) {
        super.init(frame: .zero)
        contentType = .oneTimeCode
        placeholderString = String(localized: "Code from Messages or Mail")
        setAccessibilityLabel(site.map { String(localized: "Verification code for \($0)") } ?? String(localized: "Verification code"))
        font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        usesSingleLineMode = true
        isBezeled = true
        bezelStyle = .roundedBezel
        cell?.allowsUndo = false
        delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.allowsUndo = false
        return accepted
    }

    /// Empties the field and its editor, and forgets what they held.
    func clear() {
        before = ""
        let editor = currentEditor() as? NSTextView
        editor?.string = ""
        stringValue = ""
        editor?.undoManager?.removeAllActions(withTarget: editor as Any)
    }

    /// The code goes out and the field is empty before the owner gets it.
    private func hand(_ code: String) {
        clear()
        onCode?(code)
    }

    func controlTextDidChange(_ notification: Notification) {
        let previous = before
        before = stringValue
        if let code = MessagesCode.inserted(from: previous, to: stringValue) {
            hand(code)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let code = MessagesCode.plausible(stringValue) {
                hand(code)
            } else {
                NSSound.beep()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard let onCancel else { return false }
            onCancel()
            return true
        default:
            return false
        }
    }
}

/// "Code from Messages or Mail…": a small native field, named for the site, placed inside the browser window over the page's code
/// field. It is a subview of the window's content view, never a popover or a panel of its own: macOS shows its code list only for
/// a field in the window that is the key window. The code the person picks goes to `deliver`, which fills the one page field that
/// asked; nothing else leaves the bridge.
///
/// It ends (the field emptied, the view gone) on a delivered code, Escape, a click outside, losing focus, a navigation or load of
/// the page, the page no longer in front (another tab, hidden, parked), the window resigning key, moving or resizing or closing,
/// `isCurrent` turning false, and after `lifetime`. After a fill, Escape or `lifetime` focus goes back to the page's field.
@MainActor
final class MessagesCodeBridge {
    enum Ending: Equatable {
        case filled, refused, cancelled, lostFocus, pageChanged, windowChanged, timedOut, replaced

        /// Whether the page, which held the focus before, gets it back.
        var returnsFocus: Bool {
            switch self {
            case .filled, .refused, .cancelled, .timedOut:
                true
            case .lostFocus, .pageChanged, .windowChanged, .replaced:
                false
            }
        }
    }

    static let lifetime: Duration = .seconds(180)
    static let padding: CGFloat = 8
    static let minimumFieldWidth: CGFloat = 220
    static let fieldHeight: CGFloat = 26
    private static let labelHeight: CGFloat = 14
    private static let gap: CGFloat = 2

    let field: MessagesCodeField
    let box = NSVisualEffectView()
    private(set) var isOpen = true
    private weak var page: BrowserPage?
    private weak var window: NSWindow?
    private let isCurrent: @MainActor () -> Bool
    private let deliver: @MainActor (String) async -> Bool
    private let finished: @MainActor (MessagesCodeBridge, Ending) -> Void
    private var isDelivering = false
    private var observers: [NSObjectProtocol] = []
    private var observations: [NSKeyValueObservation] = []
    private var mouseMonitor: Any?
    private var watch: Task<Void, Never>?

    /// Places the field over `rect` (the page field's, in the page's coordinates) and focuses it. nil when the page has no window
    /// or the window will not give up its focus. `isCurrent` is asked on every change and every 250 ms; `deliver` takes the code
    /// and says whether the page took it.
    init?(
        page: BrowserPage, rect: NSRect, site: String, isCurrent: @escaping @MainActor () -> Bool,
        lifetime: Duration = MessagesCodeBridge.lifetime, deliver: @escaping @MainActor (String) async -> Bool,
        finished: @escaping @MainActor (MessagesCodeBridge, Ending) -> Void
    ) {
        guard let window = page.window, let content = window.contentView else { return nil }
        self.page = page
        self.window = window
        self.isCurrent = isCurrent
        self.deliver = deliver
        self.finished = finished
        field = MessagesCodeField(site: site)

        let pad = Self.padding
        let target = page.convert(rect, to: content)
        let width = max(Self.minimumFieldWidth, target.width)
        let size = NSSize(width: width + 2 * pad, height: Self.fieldHeight + Self.gap + Self.labelHeight + 2 * pad)
        // The field sits where the page's field is; the site's name goes above it.
        let top = target.midY - Self.fieldHeight / 2
        var frame = NSRect(
            origin: NSPoint(x: target.minX - pad, y: content.isFlipped ? top - pad - Self.labelHeight - Self.gap : top - pad), size: size
        )
        let room = content.bounds.insetBy(dx: pad, dy: pad)
        if room.width >= frame.width, room.height >= frame.height {
            frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
        }
        box.frame = frame
        box.material = .popover
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        let label = NSTextField(labelWithString: site)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityElement(false)
        label.frame = NSRect(x: pad, y: pad + Self.fieldHeight + Self.gap, width: width, height: Self.labelHeight)
        field.frame = NSRect(x: pad, y: pad, width: width, height: Self.fieldHeight)
        box.addSubview(label)
        box.addSubview(field)
        content.addSubview(box, positioned: .above, relativeTo: nil)
        guard window.makeFirstResponder(field) else {
            box.removeFromSuperview()
            return nil
        }
        field.onCode = { [weak self] code in self?.accept(code) }
        field.onCancel = { [weak self] in self?.end(.cancelled) }
        field.onEndEditing = { [weak self] in
            if self?.isDelivering == false {
                self?.end(.lostFocus)
            }
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(.windowChanged) }
            })
        }
        observations = [
            page.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.end(.pageChanged) } },
            page.observe(\.isLoading) { [weak self] page, _ in MainActor.assumeIsolated { if page.isLoading { self?.end(.pageChanged) } } },
        ]
        // A click that lands elsewhere in the window ends it; a click on the system's own list (another window) does not.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.noteClick(event) }
            return event
        }
        let opened = ContinuousClock.now
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, isOpen else { return }
                if ContinuousClock.now - opened >= lifetime {
                    end(.timedOut)
                } else if !stillShowsItsPage() {
                    end(.pageChanged)
                }
            }
        }
    }

    /// The page is still the one in front in this window, and its owner still allows the bridge.
    private func stillShowsItsPage() -> Bool {
        guard let page, page.window === window, !page.isHiddenOrHasHiddenAncestor, !page.isParked else { return false }
        return isCurrent()
    }

    private func noteClick(_ event: NSEvent) {
        guard isOpen, let window, let content = window.contentView, event.window === window,
              !box.frame.contains(content.convert(event.locationInWindow, from: nil)) else { return }
        end(.lostFocus)
    }

    private func accept(_ code: String) {
        guard isOpen, !isDelivering else { return }
        guard stillShowsItsPage() else {
            end(.pageChanged)
            return
        }
        isDelivering = true
        field.isEditable = false
        let deliver = deliver
        Task { [weak self] in
            let delivered = await deliver(code)
            self?.end(delivered ? .filled : .refused)
        }
    }

    /// Closes the bridge: the field is emptied, the view removed, the page given its focus back when the ending says so.
    func end(_ ending: Ending) {
        guard isOpen else { return }
        isOpen = false
        watch?.cancel()
        watch = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        observations.removeAll()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        field.onCode = nil
        field.onCancel = nil
        field.onEndEditing = nil
        field.clear()
        if let window, let editor = field.currentEditor(), window.firstResponder === editor {
            if ending.returnsFocus, let page, page.window === window, !page.isHiddenOrHasHiddenAncestor, !page.isParked {
                window.makeFirstResponder(page)
            } else {
                window.makeFirstResponder(nil)
            }
        }
        box.removeFromSuperview()
        finished(self, ending)
    }
}
