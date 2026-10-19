// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A key press as the credential list understands it, without AppKit, so the rules below are tested without an `NSEvent`.
nonisolated struct CredentialKeyInput: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case up, down, space, `return`, escape, delete
        /// A letter, lower-cased.
        case character(String)
    }

    var key: Key
    var shift = false
    var command = false
    var option = false
    var control = false

    var hasNoModifiers: Bool {
        !(shift || command || option || control)
    }
}

/// What a key does in the credential list and in the Trash while the list has the keyboard. Select All and Undo come through the Edit
/// menu, not through here. Text fields keep their own keys: the list only sees the keyboard when a row was clicked or the search field
/// handed it over.
nonisolated enum CredentialListKeys {
    enum Command: Equatable, Sendable {
        case move(Int, extending: Bool)
        case toggle
        case open
        case clear
        case remove
        case none
    }

    struct Context: Equatable, Sendable {
        /// The Trash has no editor, so Return does nothing there, and X marks for deletion instead of moving to Trash.
        var inTrash = false
        var hasSelection = false
    }

    static func command(for input: CredentialKeyInput, in context: Context) -> Command {
        switch input.key {
        case .up, .down:
            guard !(input.command || input.option || input.control) else { return .none }
            return .move(input.key == .up ? -1 : 1, extending: input.shift)
        case .space:
            return input.hasNoModifiers ? .toggle : .none
        case .return:
            return input.hasNoModifiers && !context.inTrash ? .open : .none
        case .escape:
            return input.hasNoModifiers && context.hasSelection ? .clear : .none
        case .delete:
            // Command-Delete only: a bare Delete is a typo, not a decision.
            return input.command && !(input.shift || input.option || input.control) ? .remove : .none
        case .character(let letter):
            return letter == "x" && input.hasNoModifiers ? .remove : .none
        }
    }
}
