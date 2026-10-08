// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct MentionChip: Equatable, Identifiable {
    let id: UUID
    let title: String
    var host: String?
}

enum MentionText {
    static let marker = "\u{FFFC}"
    static let markerCharacter: Character = "\u{FFFC}"

    static func count(in text: String) -> Int {
        text.reduce(0) { $1 == markerCharacter ? $0 + 1 : $0 }
    }

    static func contains(in text: String) -> Bool {
        text.contains(markerCharacter)
    }

    static func appending(to text: String) -> String {
        let head = AskSurfaceInteraction.removingMentionFragment(from: text)
        return head + marker + " "
    }

    static func resolved(_ text: String, chips: [MentionChip]) -> String {
        var index = 0
        var result = ""
        for character in text {
            guard character == markerCharacter else {
                result.append(character)
                continue
            }
            if chips.indices.contains(index) {
                result += "@" + chips[index].title
            }
            index += 1
        }
        return result
    }

    static func removingMarker(at index: Int, from text: String) -> String {
        var seen = 0
        var result = ""
        for character in text {
            if character == markerCharacter {
                defer { seen += 1 }
                if seen == index {
                    continue
                }
            }
            result.append(character)
        }
        return result
    }

    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: marker, with: "")
    }
}

extension NSAttributedString.Key {
    static let mentionID = NSAttributedString.Key("wsurfMentionID")
}

/// ⌘↩ never reaches a field editor: AppKit offers it round as a key
/// equivalent and beeps when nothing claims it.
final class MentionTextField: NSTextField {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "\r",
           let editor = currentEditor(),
           window?.firstResponder === editor,
           let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        allowsWritingTools = false
        allowsWritingToolsAffordance = false
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
        }
        return accepted
    }
}

struct MentionField: NSViewRepresentable {
    @Binding var text: String
    var chips: [MentionChip] = []
    let placeholder: String
    let fontSize: CGFloat
    let isFocused: Bool
    var selectAllToken: Int = 0
    var accessibilityLabel: String = ""
    var textColor: NSColor?
    /// An `NSTextField` that wraps cannot scroll, so it must grow to fit.
    var wraps = false
    var onFocusChange: (Bool) -> Void = { _ in }
    var onChipsChange: ([UUID]) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCommandSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMove: (Int, Bool) -> Void = { _, _ in }
    var onTab: () -> Bool = { false }
    var onDeleteBackward: () -> Bool = { false }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.profileFavicons) private var profileFavicons

    func makeNSView(context: Context) -> MentionTextField {
        let field = MentionTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.allowsEditingTextAttributes = true
        field.importsGraphics = false
        field.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        field.cell?.wraps = wraps
        field.cell?.isScrollable = !wraps
        field.usesSingleLineMode = !wraps
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return field
    }

    func updateNSView(_ field: MentionTextField, context: Context) {
        let coordinator = context.coordinator
        field.onCommandReturn = onCommandSubmit
        coordinator.text = $text
        coordinator.onFocusChange = onFocusChange
        coordinator.onChipsChange = onChipsChange
        coordinator.onSubmit = onSubmit
        coordinator.onCommandSubmit = onCommandSubmit
        coordinator.onCancel = onCancel
        coordinator.onMove = onMove
        coordinator.onTab = onTab
        coordinator.onDeleteBackward = onDeleteBackward

        coordinator.favicons = profileFavicons
        let isDark = colorScheme == .dark
        let appearance: NSAppearance.Name = isDark ? .darkAqua : .aqua
        if field.appearance?.name != appearance {
            field.appearance = NSAppearance(named: appearance)
        }
        if field.font?.pointSize != fontSize {
            field.font = .systemFont(ofSize: fontSize)
        }
        field.setAccessibilityLabel(accessibilityLabel.isEmpty ? nil : accessibilityLabel)
        field.textColor = textColor ?? .labelColor
        coordinator.apply(text: text, chips: chips, isDark: isDark, to: field)
        coordinator.applyPlaceholder(placeholder, fontSize: fontSize, to: field)
        coordinator.syncFocus(isFocused, in: field)
        coordinator.selectAll(token: selectAllToken, in: field)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MentionTextField,
        context: Context
    ) -> CGSize? {
        guard wraps, let width = proposal.width, width > 0 else { return nil }
        nsView.preferredMaxLayoutWidth = width
        let line = (nsView.font?.pointSize ?? fontSize) + 5
        let fitted = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(fitted, line))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onFocusChange: (Bool) -> Void = { _ in }
        var onChipsChange: ([UUID]) -> Void = { _ in }
        var onSubmit: () -> Void = {}
        var onCommandSubmit: () -> Void = {}
        var onCancel: () -> Void = {}
        var onMove: (Int, Bool) -> Void = { _, _ in }
        var onTab: () -> Bool = { false }
        var onDeleteBackward: () -> Bool = { false }

        private var renderedText: String?
        private var renderedChips: [UUID] = []
        private var lastChips: [MentionChip] = []
        private var renderedDark: Bool?
        private var renderedColor: NSColor?
        private var renderedPlaceholder: String?
        private var isSyncingFocus = false
        private var isReportingFocus = false
        private var selectionToken = 0
        var favicons: FaviconLoader?
        private var requestedFaviconsID: ObjectIdentifier?
        private var renderedFaviconsID: ObjectIdentifier?
        private var requestedHosts: Set<String> = []
        private var needsRefresh = false

        init(text: Binding<String>) {
            self.text = text
        }

        func applyPlaceholder(_ placeholder: String, fontSize: CGFloat, to field: NSTextField) {
            guard renderedPlaceholder != placeholder else { return }
            renderedPlaceholder = placeholder
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }

        func apply(text value: String, chips: [MentionChip], isDark: Bool, to field: NSTextField) {
            loadMissingIcons(for: chips, in: field)
            let ids = chips.map(\.id)
            let faviconsID = favicons.map { ObjectIdentifier($0) }
            let holdsContent = renderedText == value && renderedChips == ids
            guard !(holdsContent
                && renderedDark == isDark
                && renderedColor == field.textColor
                && renderedFaviconsID == faviconsID) || needsRefresh else { return }
            let editor = field.currentEditor() as? NSTextView
            guard editor?.hasMarkedText() != true else { return }

            needsRefresh = false

            let selection = editor?.selectedRange()
            let attributed = MentionFieldRendering.attributed(
                text: value,
                chips: chips,
                fontSize: field.font?.pointSize ?? 13,
                isDark: isDark,
                textColor: field.textColor ?? .labelColor,
                favicons: favicons
            )
            renderedText = value
            renderedChips = ids
            renderedDark = isDark
            renderedColor = field.textColor
            renderedFaviconsID = faviconsID
            lastChips = chips
            field.attributedStringValue = attributed

            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.typingAttributes = MentionFieldRendering.baseAttributes(
                fontSize: field.font?.pointSize ?? 13, textColor: field.textColor ?? .labelColor
            )
            let caret = holdsContent ? (selection?.location ?? attributed.length) : attributed.length
            let location = min(caret, attributed.length)
            let length = holdsContent ? min(selection?.length ?? 0, attributed.length - location) : 0
            editor.selectedRange = NSRange(location: location, length: length)
        }

        private func loadMissingIcons(for chips: [MentionChip], in field: NSTextField) {
            let faviconsID = favicons.map { ObjectIdentifier($0) }
            if requestedFaviconsID != faviconsID {
                requestedFaviconsID = faviconsID
                requestedHosts.removeAll()
            }
            guard let favicons else { return }
            let hosts = chips.compactMap(\.host).filter {
                favicons.cached(for: $0) == nil && !requestedHosts.contains($0)
            }
            guard !hosts.isEmpty else { return }
            requestedHosts.formUnion(hosts)
            Task { [weak self, weak field] in
                for host in hosts {
                    _ = await favicons.load(forHost: host)
                }
                guard let self,
                      let field,
                      self.favicons === favicons else { return }
                needsRefresh = true
                if let text = renderedText, let dark = renderedDark {
                    apply(text: text, chips: lastChips, isDark: dark, to: field)
                }
            }
        }

        func syncFocus(_ isFocused: Bool, in field: NSTextField) {
            guard holdsFocus(field) != isFocused, !isSyncingFocus else { return }
            isSyncingFocus = true
            DispatchQueue.main.async { [weak field] in
                defer { self.isSyncingFocus = false }
                guard let field, let window = field.window else { return }
                if isFocused {
                    window.makeFirstResponder(field)
                } else if window.firstResponder === field.currentEditor() {
                    window.makeFirstResponder(nil)
                }
            }
        }

        func selectAll(token: Int, in field: NSTextField) {
            guard token != selectionToken else { return }
            selectionToken = token
            guard !selectAllNow(in: field) else { return }
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                _ = self.selectAllNow(in: field)
            }
        }

        @discardableResult
        private func selectAllNow(in field: NSTextField) -> Bool {
            guard let editor = field.currentEditor() as? NSTextView else { return false }
            editor.selectedRange = NSRange(location: 0, length: editor.attributedString().length)
            return true
        }

        private func holdsFocus(_ field: NSTextField) -> Bool {
            guard let window = field.window else { return false }
            return window.firstResponder === field.currentEditor()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView
            else { return }
            let fontSize = field.font?.pointSize ?? 13
            MentionFieldRendering.stripPastedStyles(in: editor, fontSize: fontSize, textColor: field.textColor ?? .labelColor)
            let attributed = editor.attributedString()
            editor.typingAttributes = MentionFieldRendering.baseAttributes(fontSize: fontSize, textColor: field.textColor ?? .labelColor)
            renderedText = attributed.string
            renderedChips = MentionFieldRendering.mentionIDs(in: attributed)
            text.wrappedValue = attributed.string
            onChipsChange(renderedChips)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            reportFocus(in: field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            reportFocus(in: field)
        }

        /// Content and placeholder updates can end editing without moving focus.
        /// Check the actual responder after AppKit finishes the update.
        private func reportFocus(in field: NSTextField) {
            guard !isReportingFocus else { return }
            isReportingFocus = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                isReportingFocus = false
                guard let field else { return }
                onFocusChange(holdsFocus(field))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                return !textView.hasMarkedText() && onTab()
            case #selector(NSResponder.deleteBackward(_:)):
                return !textView.hasMarkedText() && textView.string.isEmpty && onDeleteBackward()
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onCommandSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            case #selector(NSResponder.moveUp(_:)):
                onMove(-1, false)
            case #selector(NSResponder.moveDown(_:)):
                onMove(1, false)
            case #selector(NSResponder.moveToBeginningOfDocument(_:)):
                onMove(-1, true)
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                onMove(1, true)
            default:
                return false
            }
            return true
        }
    }
}

enum MentionFieldRendering {
    static func baseAttributes(fontSize: CGFloat, textColor: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
        ]
    }

    static let pastedStyleKeys: [NSAttributedString.Key] = [
        .link,
        .underlineStyle,
        .underlineColor,
        .strikethroughStyle,
        .strikethroughColor,
        .backgroundColor,
        .strokeColor,
        .strokeWidth,
        .shadow,
        .obliqueness,
        .expansion,
    ]

    static func stripPastedStyles(in editor: NSTextView, fontSize: CGFloat, textColor: NSColor = .labelColor) {
        guard let storage = editor.textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        var dirty: [NSRange] = []
        storage.enumerateAttributes(in: full) { attributes, range, _ in
            guard attributes[.attachment] == nil else { return }
            let styled = pastedStyleKeys.contains { attributes[$0] != nil }
            let resized = (attributes[.font] as? NSFont)?.pointSize != fontSize
            let tinted = (attributes[.foregroundColor] as? NSColor) != textColor
            guard styled || resized || tinted else { return }
            dirty.append(range)
        }
        guard !dirty.isEmpty else { return }
        let base = baseAttributes(fontSize: fontSize, textColor: textColor)
        storage.beginEditing()
        for range in dirty {
            storage.setAttributes(base, range: range)
        }
        storage.endEditing()
    }

    static func mentionIDs(in attributed: NSAttributedString) -> [UUID] {
        var ids: [UUID] = []
        attributed.enumerateAttribute(
            .mentionID,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let id = value as? UUID {
                ids.append(id)
            }
        }
        return ids
    }

    static func attributed(
        text: String,
        chips: [MentionChip],
        fontSize: CGFloat,
        isDark: Bool,
        textColor: NSColor = .labelColor,
        favicons: FaviconLoader?
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize)
        let result = NSMutableAttributedString()
        var index = 0
        for character in text {
            guard character == MentionText.markerCharacter else {
                result.append(NSAttributedString(
                    string: String(character),
                    attributes: baseAttributes(fontSize: fontSize, textColor: textColor)
                ))
                continue
            }
            defer { index += 1 }
            guard chips.indices.contains(index) else { continue }
            result.append(chip(chips[index], font: font, isDark: isDark, favicons: favicons))
        }
        return result
    }

    private static func chip(
        _ chip: MentionChip,
        font: NSFont,
        isDark: Bool,
        favicons: FaviconLoader?
    ) -> NSAttributedString {
        let image = chipImage(chip, fontSize: font.pointSize, isDark: isDark, favicons: favicons)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: ((font.capHeight - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height
        )
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes(
            [.mentionID: chip.id, .font: font],
            range: NSRange(location: 0, length: piece.length)
        )
        return piece
    }

    private static func chipImage(
        _ chip: MentionChip,
        fontSize: CGFloat,
        isDark: Bool,
        favicons: FaviconLoader?
    ) -> NSImage {
        let icon = chip.host.flatMap { favicons?.cached(for: $0) }
        let loaderID = favicons.map { String(describing: ObjectIdentifier($0)) } ?? ""
        let key = "\(loaderID)|\(chip.title)|\(chip.host ?? "")|\(icon == nil ? 0 : 1)|\(fontSize)|\(isDark)"
        if let cached = cache[key] {
            return cached
        }
        let renderer = ImageRenderer(
            content: AskPageChip(
                title: chip.title,
                icon: icon,
                isRasterised: true,
                fontSize: (fontSize - 1.5).rounded()
            )
                .environment(\.colorScheme, isDark ? .dark : .light)
        )
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: CGSize(width: 1, height: 1))
        image.accessibilityDescription = chip.title
        cache[key] = image
        return image
    }

    private static var cache: [String: NSImage] = [:]
}
