// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox
import Testing

@testable import WSurf

/// The boundary between what a client may type into a page and what only the app may receive.
struct PageKeyChordTests {
    private func chord(_ key: String, _ modifiers: String = "") throws -> PageKeyChord {
        try PageKeyChord.parse(key: key, modifiers: modifiers).get()
    }

    private func refusal(_ key: String, _ modifiers: String) -> PageKeyChord.Refusal? {
        if case .failure(let refusal) = PageKeyChord.parse(key: key, modifiers: modifiers) {
            return refusal
        }
        return nil
    }

    @Test func clipboardAndAppShortcutsAreRefused() {
        for key in ["c", "x", "v", "C", "X", "V"] {
            #expect(refusal(key, "command") == .clipboard, "Command+\(key)")
            #expect(refusal(key, "command+shift") == .clipboard, "Command+Shift+\(key)")
        }
        for key in ["w", "q", "t", "n", "l", "r", "p", "s", "o", "f", "h", "m", ","] {
            #expect(refusal(key, "command") == .appShortcut, "Command+\(key)")
            #expect(refusal(key, "cmd+shift") == .appShortcut, "Command+Shift+\(key)")
        }
        #expect(refusal("a", "command+shift") == .commandNotAllowed)
        #expect(refusal("Tab", "command") == .commandNotAllowed)
        #expect(refusal("Escape", "command") == .commandNotAllowed)
        #expect(refusal("Space", "command") == .commandNotAllowed)
        #expect(refusal("Enter", "command+shift") == .commandNotAllowed)
        #expect(refusal("Backspace", "command+shift") == .commandNotAllowed)
        #expect(refusal("Home", "command") == .commandNotAllowed)
    }

    @Test func controlIsNeverSentAndCommandNeverMeetsOption() {
        for key in ["a", "w", "Enter", "ArrowLeft", "Tab"] {
            #expect(refusal(key, "control") == .control)
            #expect(refusal(key, "ctrl+shift") == .control)
            #expect(refusal(key, "control+command") == .control)
        }
        for key in ["a", "z", "ArrowLeft", "Enter", "i", "Escape"] {
            #expect(refusal(key, "command+option") == .commandWithOption, "Command+Option+\(key)")
            #expect(refusal(key, "alt+cmd+shift") == .commandWithOption)
        }
    }

    /// Whatever the key and modifiers, a chord with Command or Control exists only as one of the chords listed for it.
    @Test func everyCommandChordOutsideTheListIsRefused() {
        let keys =
            (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }
            + (UInt8(ascii: "0")...UInt8(ascii: "9")).map { String(UnicodeScalar($0)) }
            + ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`", " ", "Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight",
                "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete",
            ]
        let sets = ["", "shift", "option", "command", "control", "shift+option", "command+shift", "command+option", "command+shift+option"]
        var allowed: Set<String> = []
        for key in keys {
            for set in sets {
                guard case .success(let parsed) = PageKeyChord.parse(key: key, modifiers: set), parsed.modifiers.contains(.command) else {
                    continue
                }
                allowed.insert(parsed.name)
            }
        }
        #expect(
            allowed
                == [
                    "Command+A", "Command+Z", "Command+Shift+Z", "Command+ArrowLeft", "Command+Shift+ArrowLeft", "Command+ArrowRight",
                    "Command+Shift+ArrowRight", "Command+ArrowUp", "Command+Shift+ArrowUp", "Command+ArrowDown", "Command+Shift+ArrowDown",
                    "Command+Backspace", "Command+Delete", "Command+Enter",
                ])
    }

    @Test func shiftAndOptionBuildTheirEvents() throws {
        let shiftedLetter = try chord("a", "shift")
        #expect(shiftedLetter.characters == "A")
        #expect(shiftedLetter.keyCode == UInt16(kVK_ANSI_A))
        #expect(shiftedLetter.eventFlags == .shift)
        #expect(try chord("a").characters == "a")
        #expect(try chord("B").characters == "b")

        let arrow = try chord("ArrowLeft", "shift+option")
        #expect(arrow.name == "Shift+Option+ArrowLeft")
        #expect(arrow.keyCode == 123)
        #expect(arrow.eventFlags == [.shift, .option])
        #expect(try chord("left", "alt").name == "Option+ArrowLeft")

        // A shifted symbol is Shift on its physical key.
        let question = try chord("?")
        #expect(question.name == "Shift+/")
        #expect(question.keyCode == UInt16(kVK_ANSI_Slash))
        #expect(question.characters == "?")
        #expect(question.eventFlags == .shift)
        #expect(try chord("1", "shift").characters == "!")
        #expect(try chord(" ").name == "Space")

        let pageDown = try chord("PageDown")
        #expect(pageDown.keyCode == 121)
        #expect(pageDown.eventFlags.isEmpty)
    }

    @Test func allowedCommandChordsKeepTheirPurpose() throws {
        let selectAll = try chord("A", "command")
        #expect(selectAll.selectsAll)
        #expect(selectAll.name == "Command+A")
        #expect(try chord("Enter", "command").activates)
        #expect(try chord("Space").activates)
        // Keys that edit text go to a text field only; Enter, A and Z are the Command chords any control may receive.
        for key in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Backspace", "Delete"] {
            #expect(try chord(key, "command").needsTextField, "\(key)")
        }
        #expect(try chord("ArrowRight", "command+shift").needsTextField)
        #expect(try chord("ArrowLeft", "shift").needsTextField == false)
        for key in ["a", "z", "Enter"] {
            #expect(try chord(key, "command").needsTextField == false, "\(key)")
        }
        #expect(try chord("z", "command+shift").eventFlags == [.command, .shift])
    }

    @Test func modifierTextIsStrict() {
        #expect(refusal("a", "super") == .unknownModifier("super"))
        #expect(refusal("a", "shift+hyper") == .unknownModifier("hyper"))
        #expect(refusal("nonsense", "") == .unknownKey(extended: true))
        #expect(refusal("é", "") == .unknownKey(extended: true))
        #expect(refusal("ab", "") == .unknownKey(extended: true))
        #expect(refusal("Command+W", "") == .unknownKey(extended: true))
        #expect(refusal("", "") == .unknownKey(extended: true))
        #expect((try? chord("a", " Shift , Option ")) != nil, "case, spaces and commas are tolerated")
    }

    /// The assistant's tool keeps its original twelve named keys and takes no modifiers.
    @Test func theOriginalContractIsUnchanged() {
        for key in ["Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", "Home", "End", "Backspace", "Delete"] {
            #expect((try? PageKeyChord.parse(key: key, extended: false).get()) != nil, "\(key)")
        }
        for key in ["PageUp", "PageDown", "a", "?", " 1"] {
            #expect(PageKeyChord.parse(key: key, extended: false) == .failure(.unknownKey(extended: false)), "\(key)")
        }
        #expect(PageKeyChord.parse(key: "Enter", modifiers: "shift", extended: false) == .failure(.unknownKey(extended: false)))
        #expect(PageKeyChord.Refusal.unknownKey(extended: false).message.hasPrefix("Use Enter, Tab, Escape, Space,"))
    }

    @Test func refusalsNameTheRuleWithoutNamingAnApp() {
        #expect(PageKeyChord.Refusal.clipboard.message.contains("Clipboard"))
        #expect(PageKeyChord.Refusal.appShortcut.message.contains("never sent"))
        #expect(PageKeyChord.Refusal.control.message == "Control chords are never sent.")
        #expect(PageKeyChord.Refusal.unknownModifier("x").message.contains("shift, option, or command"))
    }
}
