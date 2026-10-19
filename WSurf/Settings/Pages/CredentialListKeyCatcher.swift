// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Behind the credential list or the Trash. A view of its own, so that a key press that moves the cursor or changes the selection
/// redraws this and not the page around it, which never reads those values. It also brings the cursor row into view.
struct CredentialKeyboardHost: View {
    let selection: CredentialSelection
    let inTrash: Bool
    let perform: (CredentialListKeys.Command) -> Void
    let undo: () -> Void
    let redo: () -> Void
    /// The Edit menu's titles for Undo and Redo, or `nil` when there is nothing to take back or repeat.
    let undoTitle: () -> String?
    let redoTitle: () -> String?
    @Environment(\.settingsScrollProxy) private var scrollProxy

    var body: some View {
        CredentialListKeyCatcher(
            selection: selection, inTrash: inTrash, ownsKeyboard: selection.ownsKeyboard, request: selection.keyboardRequestID,
            hasSelection: !selection.isEmpty, perform: perform, undo: undo, redo: redo, undoTitle: undoTitle, redoTitle: redoTitle
        )
        // A key that moved the cursor brings its row into view; a click never scrolls.
        .onChange(of: selection.scrollRequestID) {
            if let cursor = selection.cursor {
                scrollProxy?.scrollTo(cursor, anchor: nil)
            }
        }
    }
}

/// An invisible first responder behind the credential list or the Trash. It receives the keys the list handles (arrows, Space, Return,
/// Escape, X, Command-Delete) and the Edit menu's Select All, Undo and Redo, and it never takes Tab, so the buttons of every row stay
/// reachable by keyboard. It is first responder only while the selection says the list owns the keyboard; the search field and every
/// other control keep their own keys, and Undo and Select All in a text field act on its text.
struct CredentialListKeyCatcher: NSViewRepresentable {
    /// Used by the closures below; its observed values arrive as the plain values after it, so this view updates when they change.
    let selection: CredentialSelection
    let inTrash: Bool
    let ownsKeyboard: Bool
    let request: Int
    let hasSelection: Bool
    let perform: (CredentialListKeys.Command) -> Void
    let undo: () -> Void
    let redo: () -> Void
    let undoTitle: () -> String?
    let redoTitle: () -> String?

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.inTrash = inTrash
        nsView.hasSelection = hasSelection
        nsView.perform = perform
        nsView.onUndo = undo
        nsView.onRedo = redo
        nsView.undoTitle = undoTitle
        nsView.redoTitle = redoTitle
        nsView.onSelectAll = { selection.selectAll() }
        nsView.onResign = { selection.releaseKeyboard() }
        guard let window = nsView.window else { return }
        if ownsKeyboard && (!nsView.wasActive || nsView.lastRequestID != request) {
            window.makeFirstResponder(nsView)
        } else if !ownsKeyboard && window.firstResponder === nsView {
            window.makeFirstResponder(nil)
        }
        nsView.wasActive = ownsKeyboard
        nsView.lastRequestID = request
    }

    final class CatcherView: NSView, NSMenuItemValidation {
        var inTrash = false
        var hasSelection = false
        var perform: ((CredentialListKeys.Command) -> Void)?
        var onUndo: (() -> Void)?
        var onRedo: (() -> Void)?
        var undoTitle: (() -> String?)?
        var redoTitle: (() -> String?)?
        var onSelectAll: (() -> Void)?
        var onResign: (() -> Void)?
        var wasActive = false
        var lastRequestID: Int?

        override var acceptsFirstResponder: Bool {
            true
        }

        /// Tab must not stop on it.
        override var canBecomeKeyView: Bool {
            false
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
            restoreMenuTitles()
            return true
        }

        /// Undo and Redo keep the title this view gave them until a responder sets another, and most do not: the plain titles go back
        /// when the keyboard leaves the list.
        private func restoreMenuTitles() {
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                for item in menu.items where item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
                    item.title = item.action == #selector(undo(_:)) ? String(localized: "Undo") : String(localized: "Redo")
                }
            }
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

        @objc func redo(_ sender: Any?) {
            onRedo?()
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if item.action == #selector(undo(_:)) {
                return enable(item, title: undoTitle?(), otherwise: String(localized: "Undo"))
            }
            if item.action == #selector(redo(_:)) {
                return enable(item, title: redoTitle?(), otherwise: String(localized: "Redo"))
            }
            return true
        }

        /// Titles the menu item for what it would do, or leaves it plain and off.
        private func enable(_ item: NSMenuItem, title: String?, otherwise: String) -> Bool {
            item.title = title ?? otherwise
            return title != nil
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
