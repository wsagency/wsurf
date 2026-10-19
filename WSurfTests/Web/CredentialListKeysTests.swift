// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import WSurf

// What each key does while the credential list or the Trash has the keyboard. The rules are a pure function of the key, its modifiers
// and two facts about the list, so no NSEvent is needed. The Edit menu's Select All and Undo do not come through here.

struct CredentialListKeysTests {
    private let active = CredentialListKeys.Context(inTrash: false, hasSelection: false)
    private let trash = CredentialListKeys.Context(inTrash: true, hasSelection: false)

    private func command(
        _ key: CredentialKeyInput.Key, shift: Bool = false, command: Bool = false, option: Bool = false, control: Bool = false,
        in context: CredentialListKeys.Context
    ) -> CredentialListKeys.Command {
        let input = CredentialKeyInput(key: key, shift: shift, command: command, option: option, control: control)
        return CredentialListKeys.command(for: input, in: context)
    }

    @Test(arguments: [false, true])
    func arrowsMoveTheCursor(inTrash: Bool) {
        let context = CredentialListKeys.Context(inTrash: inTrash)
        #expect(command(.up, in: context) == .move(-1, extending: false))
        #expect(command(.down, in: context) == .move(1, extending: false))
    }

    @Test func shiftArrowsExtend() {
        #expect(command(.up, shift: true, in: active) == .move(-1, extending: true))
        #expect(command(.down, shift: true, in: trash) == .move(1, extending: true))
        #expect(command(.down, command: true, in: active) == .none, "command and option arrows belong to the system")
        #expect(command(.up, option: true, in: active) == .none)
    }

    @Test func spaceToggles() {
        #expect(command(.space, in: active) == .toggle)
        #expect(command(.space, in: trash) == .toggle)
        #expect(command(.space, shift: true, in: active) == .none)
        #expect(command(.space, command: true, in: active) == .none, "command-space is Spotlight")
    }

    @Test func returnOpensInActiveAndDoesNothingInTrash() {
        #expect(command(.return, in: active) == .open)
        #expect(command(.return, in: trash) == .none, "the Trash has no editor")
        #expect(command(.return, command: true, in: active) == .none)
    }

    @Test(arguments: [false, true])
    func xAndCommandDeleteRemove(inTrash: Bool) {
        let context = CredentialListKeys.Context(inTrash: inTrash)
        #expect(command(.character("x"), in: context) == .remove)
        #expect(command(.delete, command: true, in: context) == .remove)
        #expect(command(.delete, in: context) == .none, "a bare Delete is not a decision")
    }

    @Test func xWithModifiersDoesNothing() {
        #expect(command(.character("x"), shift: true, in: active) == .none)
        #expect(command(.character("x"), command: true, in: active) == .none, "command-X is Cut")
        #expect(command(.character("x"), option: true, in: active) == .none)
        #expect(command(.character("x"), control: true, in: active) == .none)
        #expect(command(.delete, shift: true, command: true, in: active) == .none)
    }

    @Test func lettersOtherThanXDoNothing() {
        for letter in "abcdefghijklmnopqrstuvwyz0123456789" {
            #expect(command(.character(String(letter)), in: active) == .none, "no type-to-select: \(letter)")
        }
    }

    @Test func escapeClearsTheSelectionFirst() {
        let selected = CredentialListKeys.Context(inTrash: false, hasSelection: true)
        #expect(command(.escape, in: selected) == .clear)
        #expect(command(.escape, in: active) == .none, "with nothing selected, Escape is left to the window")
        #expect(command(.escape, command: true, in: selected) == .none)
    }
}
