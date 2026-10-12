// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// A plain-text, multi-line list of website addresses. Valid lines are link-styled, but a link here is editable
/// text: a click places the caret and nothing is ever opened.
struct WebsiteListField: NSViewRepresentable {
    let kind: WebsiteFieldEditing.Kind
    let label: LocalizedStringResource
    let lineLimit: ClosedRange<Int>
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = WebsiteTextView(kind: kind)
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.setAccessibilityLabel(String(localized: label))
        textView.string = text
        textView.refreshStyling()

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        // The view owns the text while the user edits, and an input method owns it while it composes.
        guard let textView = scrollView.documentView as? WebsiteTextView,
              !textView.hasMarkedText(), textView.string != text else { return }
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.refreshStyling()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let font = (nsView.documentView as? NSTextView)?.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let lines = min(max(text.components(separatedBy: .newlines).count, lineLimit.lowerBound), lineLimit.upperBound)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let width = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 200, height: 0)).width
        return CGSize(width: width, height: CGFloat(lines) * lineHeight + 12)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

final class WebsiteTextView: NSTextView {
    private let kind: WebsiteFieldEditing.Kind
    private let storage = NSTextStorage()

    init(kind: WebsiteFieldEditing.Kind) {
        self.kind = kind
        // An explicit TextKit 1 stack, so layout and click positions behave the same on every system.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20), textContainer: container)
        isRichText = false
        allowsUndo = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
        textContainerInset = NSSize(width: 4, height: 4)
        textContainer?.widthTracksTextView = true
        // Addresses must reach the text exactly as typed or pasted.
        isAutomaticLinkDetectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Styles the lines that save would accept like links. Only attributes change, so the undo stack is untouched.
    /// The text carries no `.link` attribute: a click edits, and AppKit never has a link to open.
    func refreshStyling() {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let notSpace = CharacterSet.whitespaces.inverted
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        storage.removeAttribute(.underlineStyle, range: whole)
        (storage.string as NSString).enumerateSubstrings(in: whole, options: .byLines) { line, range, _, _ in
            guard let line, WebsiteFieldEditing.url(for: line, kind: self.kind) != nil else { return }
            let text = line as NSString
            let first = text.rangeOfCharacter(from: notSpace)
            let last = text.rangeOfCharacter(from: notSpace, options: .backwards)
            let address = NSRange(location: range.location + first.location, length: NSMaxRange(last) - first.location)
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: address)
        }
        storage.endEditing()
    }

    override func didChangeText() {
        super.didChangeText()
        // Styling a marked range would disturb the input method's composition; the commit refreshes it.
        if !hasMarkedText() {
            refreshStyling()
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let selection = selectedRange()
        let state = WebsiteFieldEditing.State(
            text: string, caret: selection.location, selectionLength: selection.length, hasMarkedText: hasMarkedText()
        )
        // Anything but a newline stays with the input system, so composition, dead keys and literals are untouched.
        guard let input = Self.input(for: event),
              WebsiteFieldEditing.insertion(for: input, in: state, kind: kind) == "\n" else {
            super.keyDown(with: event)
            return
        }
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Return and Enter belong to the field while it has focus, so a sheet's default button never sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode else {
            return super.performKeyEquivalent(with: event)
        }
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    private static func input(for event: NSEvent) -> WebsiteFieldEditing.Input? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case keypadEnterKeyCode:
            return .keypadEnter
        case returnKeyCode:
            var modifiers: Set<WebsiteFieldEditing.Modifier> = []
            if flags.contains(.shift) {
                modifiers.insert(.shift)
            }
            if flags.contains(.option) {
                modifiers.insert(.option)
            }
            return .returnKey(modifiers: modifiers)
        default:
            guard let characters = event.characters, characters == "," || characters == " " else { return nil }
            return .typed(characters, modified: !flags.isDisjoint(with: [.shift, .control, .option, .command]))
        }
    }
}
