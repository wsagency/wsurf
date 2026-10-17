// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Testing

@testable import WSurf

/// Both engines hand a key the page leaves unhandled back to the app, where the main menu answers it, so the chords `pressKey`
/// may send are bounded by what that menu binds. This sends every chord the parser accepts through AppKit's own key dispatch to
/// the real main menu, with every action replaced by a recorder.
@MainActor
struct PageKeyChordMenuTests {
    @MainActor
    private final class Recorder: NSObject, NSMenuItemValidation {
        var reached: [String] = []
        var originals: [ObjectIdentifier: String] = [:]

        @objc func fire(_ sender: NSMenuItem) {
            reached.append(originals[ObjectIdentifier(sender)] ?? sender.title)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            true
        }
    }

    private func leaves(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { $0.submenu.map(leaves) ?? [$0] }
    }

    /// Every chord `PageKeyChord` builds: all keys against all modifier sets.
    private func acceptedChords() -> [PageKeyChord] {
        let keys =
            (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }
            + (UInt8(ascii: "0")...UInt8(ascii: "9")).map { String(UnicodeScalar($0)) }
            + ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`", "Enter", "Tab", "Escape", "Space", "ArrowLeft", "ArrowRight",
                "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete",
            ]
        let sets = ["", "shift", "option", "command", "control", "shift+option", "command+shift", "command+option", "command+shift+option"]
        return keys.flatMap { key in sets.compactMap { try? PageKeyChord.parse(key: key, modifiers: $0).get() } }
    }

    /// What a chord may reach in the menu. The Edit commands act on the page that holds focus. Back and Forward are the only
    /// navigation: Command with Left or Right, which only a text field receives, and a text field handles them itself.
    private static let permitted: [String: Set<String>] = [
        "Command+A": ["selectAll:"], "Command+Z": ["undo:"], "Command+Shift+Z": ["redo:"],
        "Command+ArrowLeft": ["goBack"], "Command+Shift+ArrowLeft": ["goBack"],
        "Command+ArrowRight": ["goForward"], "Command+Shift+ArrowRight": ["goForward"],
    ]

    @Test func noChordThePageIsSentCanReachAnAppCommand() throws {
        let previous = NSApp.mainMenu
        MainMenu(coordinator: AppCoordinator()).install()
        defer { NSApp.mainMenu = previous }
        let root = try #require(NSApp.mainMenu)
        let recorder = Recorder()
        for item in leaves(root) {
            recorder.originals[ObjectIdentifier(item)] = item.action.map(NSStringFromSelector)
            item.target = recorder
            item.action = #selector(Recorder.fire(_:))
        }
        func reach(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> [String] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            recorder.reached = []
            NSApp.sendEvent(event)
            return recorder.reached
        }

        // A key without a modifier is not a key equivalent. Dispatched with no key window, as here, AppKit still offers it to the
        // system's Function-key items (Dictation, Emoji, Full Screen); a real keystroke never reaches them, so unmodified keys
        // are left out.
        let chords = acceptedChords().filter { !$0.modifiers.isEmpty }
        #expect(chords.count > 100, "the parser accepts only a small set")
        for chord in chords {
            let reached = Set(try reach(chord.characters, chord.keyCode, chord.eventFlags))
            let allowed = Self.permitted[chord.name] ?? []
            #expect(reached.isSubset(of: allowed), "\(chord.name) reaches \(reached.subtracting(allowed))")
        }

        // The refusals matter: the menu binds these, and a key the page ignores would run them.
        struct Bound {
            let key: String
            let code: UInt16
            let flags: NSEvent.ModifierFlags
            let modifiers: String
        }
        let bound = [
            Bound(key: "w", code: 13, flags: .command, modifiers: "command"), Bound(key: "q", code: 12, flags: .command, modifiers: "command"),
            Bound(key: ",", code: 43, flags: .command, modifiers: "command"), Bound(key: "c", code: 8, flags: .command, modifiers: "command"),
            Bound(key: "W", code: 13, flags: [.command, .shift], modifiers: "command+shift"),
            Bound(key: "n", code: 45, flags: .command, modifiers: "command"),
        ]
        for item in bound {
            let reached = try reach(item.key, item.code, item.flags)
            #expect(!reached.isEmpty, "\(item.modifiers)+\(item.key) reaches nothing, so refusing it protects nothing")
            #expect((try? PageKeyChord.parse(key: item.key, modifiers: item.modifiers).get()) == nil, "\(item.modifiers)+\(item.key) is refused")
        }
    }
}
