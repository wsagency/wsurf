// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// MARK: - Reducer

private nonisolated let websiteKinds: [WebsiteFieldEditing.Kind] = [.websites, .extraOrigins]

private nonisolated let returnInputs: [WebsiteFieldEditing.Input] = [
    .returnKey(modifiers: []),
    .returnKey(modifiers: [.shift]),
    .returnKey(modifiers: [.option]),
    .returnKey(modifiers: [.shift, .option]),
    .keypadEnter,
]

private nonisolated let verbatimInputs: [WebsiteFieldEditing.Input] = [
    .paste("a, b c"),
    .drop("a, b c"),
    .dictation("a, b c"),
    .replacement("a, b c"),
    .imeCommit("a, b c"),
]

@MainActor
struct WebsiteFieldEditingTests {
    typealias Editing = WebsiteFieldEditing

    /// Offsets are UTF-16, like `NSRange`; the caret defaults to the end of the text.
    private func state(
        _ text: String,
        caret: Int? = nil,
        selection: Int = 0,
        marked: Bool = false
    ) -> Editing.State {
        Editing.State(text: text, caret: caret ?? text.utf16.count, selectionLength: selection, hasMarkedText: marked)
    }

    private func typed(
        _ character: String,
        in start: Editing.State,
        modified: Bool = false,
        kind: Editing.Kind
    ) -> Editing.State {
        Editing.apply(.typed(character, modified: modified), to: start, kind: kind)
    }

    // MARK: Typed delimiters

    @Test(arguments: websiteKinds, [",", " "])
    func typedCommaOrSpaceAtLineEndAfterAValidAddressBecomesANewline(kind: Editing.Kind, delimiter: String) {
        let result = typed(delimiter, in: state("https://a.example"), kind: kind)
        #expect(result == state("https://a.example\n"))
    }

    @Test(arguments: websiteKinds)
    func theSplitJudgesOnlyTheCurrentLine(kind: Editing.Kind) {
        let afterInvalidLine = typed(",", in: state("not an address\nhttps://a.example"), kind: kind)
        #expect(afterInvalidLine == state("not an address\nhttps://a.example\n"))

        // Caret at the end of a valid first line, more text after it.
        let before = state("https://a.example\nsecond", caret: 17)
        #expect(typed(" ", in: before, kind: kind) == state("https://a.example\n\nsecond", caret: 18))

        let afterBadLine = typed(",", in: state("https://a.example\nnot an address"), kind: kind)
        #expect(afterBadLine == state("https://a.example\nnot an address,"))
    }

    @Test(arguments: websiteKinds, [",", " "])
    func delimiterIsLiteralWhenInvalidSelectedMarkedModifiedOrNotAtLineEnd(kind: Editing.Kind, delimiter: String) {
        struct Case {
            let label: String
            let start: Editing.State
            var modified = false
            let expected: Editing.State
        }
        let cases = [
            Case(label: "invalid line", start: state("not an address"), expected: state("not an address" + delimiter)),
            Case(label: "http is not https", start: state("http://a.example"), expected: state("http://a.example" + delimiter)),
            Case(label: "empty line", start: state(""), expected: state(delimiter)),
            Case(label: "empty line after a newline", start: state("https://a.example\n"), expected: state("https://a.example\n" + delimiter)),
            // The selection is replaced by the typed character.
            Case(label: "selection", start: state("https://a.example", caret: 8, selection: 9), expected: state("https://" + delimiter, caret: 9)),
            Case(label: "marked text", start: state("https://a.example", marked: true), expected: state("https://a.example" + delimiter, marked: true)),
            Case(label: "modified", start: state("https://a.example"), modified: true, expected: state("https://a.example" + delimiter)),
            Case(label: "mid-line", start: state("https://a.example", caret: 5), expected: state("https" + delimiter + "://a.example", caret: 6)),
        ]
        for item in cases {
            #expect(typed(delimiter, in: item.start, modified: item.modified, kind: kind) == item.expected, "\(item.label)")
        }
    }

    @Test(arguments: websiteKinds)
    func aSecondDelimiterOnTheNewEmptyLineStaysLiteral(kind: Editing.Kind) {
        let afterSplit = typed(",", in: state("https://a.example"), kind: kind)
        #expect(typed(",", in: afterSplit, kind: kind) == state("https://a.example\n,"))
        #expect(typed(" ", in: afterSplit, kind: kind) == state("https://a.example\n "))
    }

    @Test(arguments: websiteKinds)
    func otherTypedCharactersAreInsertedAtTheCaretReplacingTheSelection(kind: Editing.Kind) {
        #expect(typed("x", in: state("https://a.example"), kind: kind) == state("https://a.examplex"))
        #expect(typed("é", in: state("ab", caret: 1), kind: kind) == state("aéb", caret: 2))
        #expect(typed("x", in: state("abc", caret: 1, selection: 2), kind: kind) == state("ax", caret: 2))
    }

    // MARK: Return

    @Test(arguments: websiteKinds, returnInputs)
    func returnVariantsInsertPlainNewlineAndNeverSave(kind: Editing.Kind, input: Editing.Input) {
        let valid = Editing.apply(input, to: state("https://a.example"), kind: kind)
        #expect(valid == state("https://a.example\n"))

        let invalidMid = Editing.apply(input, to: state("ab cd", caret: 2), kind: kind)
        #expect(invalidMid == state("ab\n cd", caret: 3))

        let replacing = Editing.apply(input, to: state("abc", caret: 1, selection: 1), kind: kind)
        #expect(replacing == state("a\nc", caret: 2))

        for result in [valid, invalidMid, replacing] {
            #expect(!result.text.contains("\u{2028}"))
        }
    }

    // MARK: Verbatim inserts

    @Test(arguments: websiteKinds, verbatimInputs)
    func pasteDropDictationReplacementAndIMECommitInsertVerbatim(kind: Editing.Kind, input: Editing.Input) {
        let inserted = Editing.apply(input, to: state("https://a.example\n"), kind: kind)
        #expect(inserted == state("https://a.example\na, b c"))

        let middle = Editing.apply(input, to: state("xy", caret: 1), kind: kind)
        #expect(middle == state("xa, b cy", caret: 7))

        let replacing = Editing.apply(input, to: state("abcd", caret: 1, selection: 2), kind: kind)
        #expect(replacing == state("aa, b cd", caret: 7))
    }

    @Test(arguments: websiteKinds)
    func verbatimInsertsAreNeverSplitConvertedOrNormalized(kind: Editing.Kind) {
        let payloads = [
            "https://b.example,",
            "https://b.example ",
            "https://b.example\u{2028}https://c.example",
            "https://b.example\r\nhttps://c.example",
            "  \t https://b.example  ",
            "HTTPS://B.EXAMPLE:443/",
            "e\u{301}",
        ]
        for payload in payloads {
            let start = state("https://a.example")
            for input in [Editing.Input.paste(payload), .drop(payload), .dictation(payload), .replacement(payload), .imeCommit(payload)] {
                let result = Editing.apply(input, to: start, kind: kind)
                #expect(result.text == "https://a.example" + payload)
                #expect(result.caret == result.text.utf16.count)
                #expect(result.selectionLength == 0)
            }
        }
    }

    @Test(arguments: websiteKinds)
    func markedTextGoesToTheIMEUntouched(kind: Editing.Kind) {
        let composing = state("https://a.example", marked: true)
        // The IME owns Return while it composes: the reducer changes nothing.
        #expect(Editing.apply(.returnKey(modifiers: []), to: composing, kind: kind) == composing)
        #expect(Editing.apply(.keypadEnter, to: composing, kind: kind) == composing)
        // A typed delimiter is never turned into a newline under composition.
        #expect(typed(",", in: composing, kind: kind).text == "https://a.example,")
    }

    // MARK: Save-time sanitization is the existing code

    /// Accepts exactly what `CredentialDraft.account()` accepts for one line of the given field.
    private func draftAccepts(_ line: String, kind: Editing.Kind) -> Bool {
        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.username = "user"
        switch kind {
        case .websites:
            draft.websites = line
        case .extraOrigins:
            draft.extraOrigins = line
        }
        return (try? draft.account()) != nil
    }

    @Test(arguments: websiteKinds)
    func aLineIsValidExactlyWhenSavingWouldAcceptIt(kind: Editing.Kind) {
        let lines = [
            "https://a.example", "https://a.example/login", "https://a.example:8443/x?y=1#z", "HTTPS://A.EXAMPLE:443",
            "  https://a.example  ", "https://user:pw@a.example", "https://a.example/a b",
            "http://a.example", "a.example", "https://", "https:///x", "ftp://a.example", "javascript:alert(1)",
            "https://a.example, https://b.example", "not an address", "https://exa mple.test",
        ]
        for line in lines {
            let result = typed(",", in: state(line), kind: kind)
            let split = result.text == line + "\n"
            #expect(split == draftAccepts(line, kind: kind), "\(line.debugDescription)")
        }
    }

    @Test func saveTimeSanitizationIsUnchanged() throws {
        // Typing the way the editor now allows, then saving, is today's save of the same text.
        var text = state("")
        for character in "https://a.example/login" {
            text = typed(String(character), in: text, kind: .websites)
        }
        text = typed(",", in: text, kind: .websites)
        for character in "https://b.example" {
            text = typed(String(character), in: text, kind: .websites)
        }
        text = typed(" ", in: text, kind: .websites)
        #expect(text.text == "https://a.example/login\nhttps://b.example\n")

        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.username = "user"
        draft.websites = text.text
        draft.extraOrigins = "https://c.example\n"
        let account = try draft.account()
        #expect(account.loginURLs.map(\.absoluteString) == ["https://a.example/login", "https://b.example"])
        #expect(account.origins == ["https://a.example", "https://b.example", "https://c.example"])

        // Verbatim text that the editor does not split is still refused by the save, exactly as before.
        var pasted = CredentialDraft(editing: nil, revision: 0)
        pasted.username = "user"
        pasted.websites = Editing.apply(.paste("https://a.example, https://b.example"), to: state(""), kind: .websites).text
        #expect(throws: CredentialVaultError.self) { try pasted.account() }
    }
}

// MARK: - The AppKit view

/// Drives a real `WebsiteTextView` in an offscreen window through real `NSEvent`s. Nothing is shown or focused
/// on screen, and no link is ever opened.
@MainActor
struct WebsiteTextViewTests {
    /// A window whose next events come from the test. Click tracking asks the window for the mouse-up, so the
    /// test can hand it one at the exact point instead of posting through the system queue.
    private final class ScriptedWindow: NSWindow {
        var scripted: [NSEvent] = []

        override func nextEvent(
            matching mask: NSEvent.EventTypeMask, until date: Date?, inMode mode: RunLoop.Mode, dequeue: Bool
        ) -> NSEvent? {
            scripted.isEmpty
                ? super.nextEvent(matching: mask, until: date, inMode: mode, dequeue: dequeue)
                : scripted.removeFirst()
        }
    }

    private struct Field {
        let window: ScriptedWindow
        let view: WebsiteTextView

        var text: String {
            view.string
        }

        var caret: Int {
            view.selectedRange().location
        }
    }

    private func makeField(
        _ kind: WebsiteFieldEditing.Kind = .websites,
        text: String = "",
        caret: Int? = nil,
        selection: Int = 0
    ) -> Field {
        let window = ScriptedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = WebsiteTextView(kind: kind)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = view
        window.makeFirstResponder(view)
        view.string = text
        view.refreshStyling()
        view.setSelectedRange(NSRange(location: caret ?? text.utf16.count, length: selection))
        return Field(window: window, view: view)
    }

    private func key(
        _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 2, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    private func press(_ characters: String, flags: NSEvent.ModifierFlags = [], in field: Field) throws {
        let code: UInt16 = characters == "," ? 43 : 49
        field.view.keyDown(with: try key(characters, code: code, flags: flags, in: field.window))
    }

    /// A valid address is underlined in the link color. The text never carries a `.link` attribute, so AppKit has
    /// no link to open.
    private func isStyled(_ field: Field, at index: Int) -> Bool {
        guard let storage = field.view.textStorage else { return false }
        let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        return storage.attribute(.underlineStyle, at: index, effectiveRange: nil) != nil && color == .linkColor
    }

    private func hasLinkAttribute(_ field: Field) -> Bool {
        guard let storage = field.view.textStorage else { return false }
        var found = false
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            found = found || value != nil
        }
        return found
    }

    // MARK: Typed delimiters on the real key path

    @Test(arguments: [WebsiteFieldEditing.Kind.websites, .extraOrigins], [",", " "])
    func aTypedDelimiterAfterAValidAddressBecomesANewlineAndTheLineIsALink(
        kind: WebsiteFieldEditing.Kind, delimiter: String
    ) throws {
        let field = makeField(kind, text: "https://a.example")
        try press(delimiter, in: field)
        #expect(field.text == "https://a.example\n")
        #expect(field.caret == 18)
        #expect(field.view.selectedRange().length == 0)
        #expect(isStyled(field, at: 0))
        #expect(!hasLinkAttribute(field))
    }

    @Test(arguments: [WebsiteFieldEditing.Kind.websites, .extraOrigins])
    func aTypedDelimiterIsLiteralWhereTheContractSaysSo(kind: WebsiteFieldEditing.Kind) throws {
        let invalid = makeField(kind, text: "not an address")
        try press(",", in: invalid)
        #expect(invalid.text == "not an address,")

        let midLine = makeField(kind, text: "https://a.example", caret: 5)
        try press(" ", in: midLine)
        #expect(midLine.text == "https ://a.example")

        let selected = makeField(kind, text: "https://a.example", caret: 8, selection: 9)
        try press(",", in: selected)
        #expect(selected.text == "https://,")

        let modified = makeField(kind, text: "https://a.example")
        try press(",", flags: .control, in: modified)
        #expect(!modified.text.contains("\n"))

        let repeated = makeField(kind, text: "https://a.example")
        try press(",", in: repeated)
        try press(",", in: repeated)
        #expect(repeated.text == "https://a.example\n,")
    }

    @Test func markedTextGoesToTheInputSystemExactlyAsAPlainTextViewDoes() throws {
        func outcome(_ view: NSTextView, window: NSWindow, key event: NSEvent) -> (String, Bool) {
            window.contentView = view
            window.makeFirstResponder(view)
            view.unmarkText()
            view.string = "https://a.example"
            view.setSelectedRange(NSRange(location: 17, length: 0))
            view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.keyDown(with: event)
            return (view.string, view.hasMarkedText())
        }
        let field = makeField()
        let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        plain.isRichText = false
        for (characters, code) in [(",", UInt16(43)), (" ", 49), ("\r", 36)] {
            let event = try key(characters, code: code, in: field.window)
            let mine = outcome(field.view, window: field.window, key: event)
            let baseline = outcome(plain, window: field.window, key: event)
            #expect(mine.0 == baseline.0, "\(characters.debugDescription) text")
            #expect(mine.1 == baseline.1, "\(characters.debugDescription) marked")
        }
    }

    @Test func textInsertedWithoutAKeyPressIsNeverSplit() {
        // Paste, dictation, text replacement and IME commit all arrive as insertText, not as a key event.
        let field = makeField(text: "https://a.example")
        field.view.insertText(",", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.text == "https://a.example,")
        field.view.insertText("a, b c", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.text == "https://a.example,a, b c")
    }

    // MARK: Return

    @Test(arguments: [
        ("\r", UInt16(36), NSEvent.ModifierFlags([])),
        ("\r", 36, .shift),
        ("\r", 36, .option),
        ("\u{3}", 76, .numericPad),
    ])
    func returnVariantsInsertAPlainNewline(characters: String, code: UInt16, flags: NSEvent.ModifierFlags) throws {
        let field = makeField(text: "https://a.example")
        field.view.keyDown(with: try key(characters, code: code, flags: flags, in: field.window))
        #expect(field.text == "https://a.example\n")
        #expect(!field.text.contains("\u{2028}"))
        #expect(field.caret == 18)
    }

    @Test func theFirstResponderClaimsReturnSoASheetsDefaultButtonDoesNotSave() throws {
        let field = makeField(text: "https://a.example")
        let event = try key("\r", code: 36, in: field.window)
        #expect(field.view.performKeyEquivalent(with: event))
        #expect(field.text == "https://a.example\n")

        field.window.makeFirstResponder(nil)
        #expect(!field.view.performKeyEquivalent(with: event))
        #expect(field.text == "https://a.example\n")
    }

    // MARK: Tab and Escape

    @Test func tabAndShiftTabMoveFocusInsteadOfInsertingText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let field = WebsiteTextView(kind: .websites)
        field.frame = NSRect(x: 0, y: 100, width: 400, height: 100)
        let last = NSTextField(frame: NSRect(x: 0, y: 250, width: 400, height: 30))
        for view in [first, field, last] {
            content.addSubview(view)
        }
        window.contentView = content
        first.nextKeyView = field
        field.nextKeyView = last
        last.nextKeyView = first
        field.string = "abc"

        window.makeFirstResponder(field)
        field.keyDown(with: try key("\t", code: 48, in: window))
        #expect(window.firstResponder === last.currentEditor())
        #expect(field.string == "abc")

        window.makeFirstResponder(field)
        field.keyDown(with: try key("\u{19}", code: 48, flags: .shift, in: window))
        #expect(window.firstResponder === first.currentEditor())
        #expect(field.string == "abc")
    }

    private final class CancelRecorder: NSResponder {
        var cancels = 0
        override func cancelOperation(_ sender: Any?) {
            cancels += 1
        }
    }

    @Test func escapeIsNotInterceptedAndReachesTheResponderChain() throws {
        let field = makeField(text: "abc")
        let recorder = CancelRecorder()
        field.view.nextResponder = recorder
        field.view.keyDown(with: try key("\u{1b}", code: 53, in: field.window))
        #expect(recorder.cancels == 1)
        #expect(field.text == "abc")
    }

    // MARK: Styling and clicks

    @Test func validLinesAreStyledLikeLinksAndInvalidLinesAreNot() throws {
        let text = "https://a.example\nnot an address\nhttps://b.example/login\n\nhttp://c.example"
        let field = makeField(text: text)
        let ns = text as NSString
        func styled(_ line: String) -> Bool {
            isStyled(field, at: ns.range(of: line).location)
        }
        #expect(styled("https://a.example"))
        #expect(styled("https://b.example/login"))
        #expect(!styled("not an address"))
        #expect(!styled("http://c.example"))
        #expect(field.text == text)
        #expect(!hasLinkAttribute(field))
    }

    @Test func theOtherOriginsFieldJudgesLinesByTheOriginRule() {
        let field = makeField(.extraOrigins, text: "https://a.example/ignored/path\nnot an address")
        #expect(isStyled(field, at: 0))
        #expect(!isStyled(field, at: 31))
        #expect(!hasLinkAttribute(field))
    }

    @Test func stylingFollowsEditsLineByLine() throws {
        let field = makeField(text: "https://a.example")
        try press(",", in: field)
        field.view.insertText("zz", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.text == "https://a.example\nzz")
        #expect(isStyled(field, at: 0))
        #expect(!isStyled(field, at: 18))
        // "https" becomes "http": the first line is no longer an address.
        field.view.insertText("http", replacementRange: NSRange(location: 0, length: 5))
        #expect(field.text == "http://a.example\nzz")
        #expect(!isStyled(field, at: 0))
        #expect(!hasLinkAttribute(field))
    }

    private final class LinkClickRecorder: NSObject, NSTextViewDelegate {
        var calls = 0
        /// Returning true keeps AppKit from opening anything, so a regression cannot open a URL here either.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            calls += 1
            return true
        }
    }

    @Test func clickingAnAddressPlacesTheCaretAndOpensNothing() throws {
        let text = "https://a.example\nhttps://b.example\n"
        let field = makeField(text: text, caret: text.utf16.count)
        let recorder = LinkClickRecorder()
        field.view.delegate = recorder
        let layout = try #require(field.view.layoutManager)
        let container = try #require(field.view.textContainer)
        layout.ensureLayout(for: container)
        // The middle of the first line's glyph 8.
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 8, length: 1), in: container)
        let origin = field.view.textContainerOrigin
        let point = NSPoint(x: glyph.midX + origin.x, y: glyph.midY + origin.y)
        let expected = field.view.characterIndexForInsertion(at: point)
        #expect((1...16).contains(expected))
        #expect(expected != field.caret)

        let location = field.view.convert(point, to: nil)
        func mouse(_ type: NSEvent.EventType, _ time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: time,
                windowNumber: field.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        // AppKit tracks the click until the mouse-up, which the window hands over from its own queue. A posted
        // event comes back with its location moved on a hosted run, so the test supplies the exact event.
        field.window.scripted.append(try mouse(.leftMouseUp, 1.05))
        field.view.mouseDown(with: try mouse(.leftMouseDown, 1))

        #expect(field.caret == expected)
        #expect(field.view.selectedRange().length == 0)
        #expect(recorder.calls == 0)
        #expect(field.text == text)
    }

    // MARK: Undo

    @Test func undoRevertsASplitAndStillLeavesTheAddressStyled() throws {
        let field = makeField(text: "https://a.example")
        let undo = try #require(field.view.undoManager)
        undo.removeAllActions()
        try press(",", in: field)
        #expect(field.text == "https://a.example\n")
        undo.undo()
        #expect(field.text == "https://a.example")
        #expect(isStyled(field, at: 0))
        #expect(!hasLinkAttribute(field))
    }
}
