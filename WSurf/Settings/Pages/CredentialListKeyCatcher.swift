// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// An invisible first responder behind the credential list or the Trash. It receives the keys the list handles (arrows, Space, Return,
/// Escape, X, Command-Delete) and the Edit menu's Select All and Undo, and it never takes Tab, so the buttons of every row stay
/// reachable by keyboard. It is first responder only while the selection says the list owns the keyboard; the search field and every
/// other control keep their own keys, and Undo and Select All in a text field act on its text.
struct CredentialListKeyCatcher: NSViewRepresentable {
    let selection: CredentialSelection
    let inTrash: Bool
    let perform: (CredentialListKeys.Command) -> Void
    let undo: () -> Void
    /// The Edit menu's title for Undo, or `nil` when nothing can be taken back.
    let undoTitle: () -> String?

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.inTrash = inTrash
        nsView.hasSelection = !selection.isEmpty
        nsView.perform = perform
        nsView.onUndo = undo
        nsView.undoTitle = undoTitle
        nsView.onSelectAll = { selection.selectAll() }
        nsView.onResign = { selection.releaseKeyboard() }
        let owns = selection.ownsKeyboard
        let request = selection.keyboardRequestID
        defer {
            nsView.wasActive = owns
            nsView.lastRequestID = request
        }
        guard let window = nsView.window else { return }
        if owns && (!nsView.wasActive || nsView.lastRequestID != request) {
            window.makeFirstResponder(nsView)
        } else if !owns && window.firstResponder === nsView {
            window.makeFirstResponder(nil)
        }
    }

    final class CatcherView: NSView, NSMenuItemValidation {
        var inTrash = false
        var hasSelection = false
        var perform: ((CredentialListKeys.Command) -> Void)?
        var onUndo: (() -> Void)?
        var undoTitle: (() -> String?)?
        var onSelectAll: (() -> Void)?
        var onResign: (() -> Void)?
        var wasActive = false
        var lastRequestID: Int?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func isAccessibilityElement() -> Bool {
            false
        }

        /// Another control took the keyboard. The selection is told after the current update, never from inside it.
        override func resignFirstResponder() -> Bool {
            let report = onResign
            Task { @MainActor in report?() }
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard let input = CredentialKeyInput(event) else {
                super.keyDown(with: event)
                return
            }
            // Holding a key down repeats only the arrows; Space, Return and X act once per press.
            if event.isARepeat && input.key != .up && input.key != .down {
                return
            }
            let command = CredentialListKeys.command(for: input, in: .init(inTrash: inTrash, hasSelection: hasSelection))
            guard command != .none else {
                // A letter or digit means nothing here, and there is no type-to-select: it is dropped, without the error beep.
                if case .character(let letter) = input.key, letter.first?.isLetter == true || letter.first?.isNumber == true {
                    return
                }
                super.keyDown(with: event)
                return
            }
            perform?(command)
        }

        override func selectAll(_ sender: Any?) {
            onSelectAll?()
        }

        @objc func undo(_ sender: Any?) {
            onUndo?()
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard item.action == #selector(undo(_:)) else { return true }
            guard let title = undoTitle?() else {
                item.title = String(localized: "Undo")
                return false
            }
            item.title = title
            return true
        }
    }
}

extension CredentialKeyInput {
    /// The keys the list reads, by key code for the named keys (so the arrow keys' function flags are not mistaken for modifiers) and by
    /// character for letters. `nil` for every other key.
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 126:
            key = .up
        case 125:
            key = .down
        case 49:
            key = .space
        case 36, 76:
            key = .return
        case 53:
            key = .escape
        case 51:
            key = .delete
        default:
            guard let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1 else { return nil }
            key = .character(letter)
        }
        let flags = event.modifierFlags
        shift = flags.contains(.shift)
        command = flags.contains(.command)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }
}
