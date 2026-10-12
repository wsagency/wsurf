// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How a website field turns an editing action into text. Only a typed comma or Space after a complete, valid
/// address becomes a newline. Every other text path inserts exactly what it receives, and nothing is normalized:
/// `CredentialDraft` sanitizes the text when the account is saved. Offsets are UTF-16, like `NSRange`.
nonisolated enum WebsiteFieldEditing {
    /// `.websites` takes login addresses (any HTTPS path). `.extraOrigins` takes origins only.
    enum Kind: Sendable {
        case websites, extraOrigins
    }

    enum Modifier: Hashable, Sendable {
        case shift, option
    }

    struct State: Equatable, Sendable {
        var text: String
        var caret: Int
        var selectionLength: Int
        var hasMarkedText: Bool
    }

    enum Input: Equatable, Sendable {
        case typed(String, modified: Bool)
        case returnKey(modifiers: Set<Modifier>)
        case keypadEnter
        case paste(String)
        case drop(String)
        case dictation(String)
        case replacement(String)
        case imeCommit(String)
    }

    static func apply(_ input: Input, to state: State, kind: Kind) -> State {
        guard let inserted = insertion(for: input, in: state, kind: kind) else { return state }
        let text = state.text as NSString
        let location = min(max(state.caret, 0), text.length)
        let selection = NSRange(location: location, length: min(max(state.selectionLength, 0), text.length - location))
        var result = state
        result.text = text.replacingCharacters(in: selection, with: inserted)
        result.caret = location + (inserted as NSString).length
        result.selectionLength = 0
        return result
    }

    /// The text that replaces the selection, or `nil` when the input system keeps the key (Return while it composes).
    static func insertion(for input: Input, in state: State, kind: Kind) -> String? {
        switch input {
        case .typed(let character, let modified):
            let isDelimiter = character == "," || character == " "
            guard isDelimiter, !modified, !state.hasMarkedText, state.selectionLength == 0,
                  currentLineIsComplete(in: state, kind: kind) else { return character }
            return "\n"
        case .returnKey, .keypadEnter:
            return state.hasMarkedText ? nil : "\n"
        case .paste(let text), .drop(let text), .dictation(let text), .replacement(let text), .imeCommit(let text):
            return text
        }
    }

    /// The address `line` holds, judged as saving judges it (`CredentialDraft.account()`), or `nil`.
    static func url(for line: String, kind: Kind) -> URL? {
        guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch kind {
        case .websites:
            guard let sanitized = try? CredentialAccount.sanitizedLoginURL(url),
                  CredentialAccount.origin(for: sanitized) != nil else { return nil }
        case .extraOrigins:
            guard CredentialAccount.origin(for: url) != nil else { return nil }
        }
        return url
    }

    /// The caret ends its line and the line, up to the caret, is a valid address.
    private static func currentLineIsComplete(in state: State, kind: Kind) -> Bool {
        let text = state.text as NSString
        let caret = min(max(state.caret, 0), text.length)
        if caret < text.length {
            guard Unicode.Scalar(text.character(at: caret)).map(CharacterSet.newlines.contains) == true else { return false }
        }
        let previous = text.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: caret))
        let start = previous.location == NSNotFound ? 0 : NSMaxRange(previous)
        return url(for: text.substring(with: NSRange(location: start, length: caret - start)), kind: kind) != nil
    }
}
