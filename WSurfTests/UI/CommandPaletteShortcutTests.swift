// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct CommandPaletteShortcutTests {
    @Test(arguments: [
        NSEvent.ModifierFlags.command,
        [.command, .capsLock],
        [.command, .option, .shift],
        [.command, .option, .shift, .capsLock],
    ])
    func pasteEventKeepsThePaletteOpenAndReachesTheEditor(modifiers: NSEvent.ModifierFlags) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.setString("https://example.com/pasted", forType: .string))
        let editor = PasteEditor(frame: .zero)
        editor.pasteboard = board

        let previousMenu = NSApp.mainMenu
        let mainMenu = MainMenu(coordinator: AppCoordinator())
        mainMenu.install()
        defer { NSApp.mainMenu = previousMenu }
        let root = try #require(NSApp.mainMenu)
        for item in root.items.compactMap(\.submenu).flatMap(\.items)
        where item.action == #selector(NSText.paste(_:)) || item.action == #selector(NSTextView.pasteAsPlainText(_:)) {
            item.target = editor
        }

        let event = try pasteEvent(modifiers: modifiers)
        try #require(!CommandPaletteShortcutPolicy.shouldDismiss(event))
        #expect(root.performKeyEquivalent(with: event))
        #expect(editor.string == "https://example.com/pasted")
    }

    @Test func nativeEventTranslationRecognizesTheCommandCharacter() throws {
        let event = try pasteEvent(modifiers: .command, typingCharacter: "м")
        #expect(event.charactersIgnoringModifiers == "м")
        #expect(event.characters(byApplyingModifiers: .command)?.lowercased() == "v")
        #expect(!CommandPaletteShortcutPolicy.shouldDismiss(event))
    }

    /// The palette's shortcut monitor belongs to its own window. The events here are addressed to another window (`windowNumber`)
    /// and handed to the handler the monitor runs; no step depends on the test host being the active app: nothing is activated,
    /// and nothing waits for key status, so a person using another app during the run changes nothing.
    @Test func backgroundPaletteCannotConsumeAnotherWindowsKeyboardEvents() async throws {
        let app = BrowserApplication()
        let source = app.newWindow(profile: .original(), show: false)
        let destination = app.newWindow(profile: .original(), show: false)
        defer { source.closeWindow(); destination.closeWindow() }
        let originalURL = source.browser.activeTab?.urlString
        source.openPalette()
        let sourceWindow = try #require(source.nativeWindow)
        try #require(await waitUntil { sourceWindow.firstResponder is NSTextView })
        destination.showBrowser(activate: false)
        let destinationWindow = try #require(destination.nativeWindow)

        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
        let optionReturn = try key("\r", code: 36, modifiers: .option, in: destinationWindow)
        let commandL = try key("l", code: 37, modifiers: .command, in: destinationWindow)
        let ownReturn = try key("\r", code: 36, modifiers: .option, in: sourceWindow)
        let ownCommandL = try key("l", code: 37, modifiers: .command, in: sourceWindow)

        // The policy's decision, even were the palette's window key.
        for event in [optionReturn, commandL] {
            #expect(!CommandPaletteShortcutPolicy.isAddressedToPalette(event, paletteWindow: sourceWindow, isKey: true))
        }
        #expect(CommandPaletteShortcutPolicy.isAddressedToPalette(ownReturn, paletteWindow: sourceWindow, isKey: true))
        #expect(!CommandPaletteShortcutPolicy.isAddressedToPalette(ownReturn, paletteWindow: sourceWindow, isKey: false))

        // The handler the palette's monitor runs, driven directly: no active app and no key window are needed to ask it. Keys
        // addressed to another window come back unconsumed and move nothing in the palette, even with the palette's window key.
        var submitted = 0, dismissed = 0
        func consumed(_ event: NSEvent, isKey: Bool = true) -> Bool {
            CommandPaletteShortcutPolicy.consumes(
                event, paletteWindow: sourceWindow, isKey: isKey,
                setOptionHeld: { _ in }, submitInCurrentTab: { submitted += 1 }, dismiss: { dismissed += 1 }
            )
        }
        #expect(!consumed(optionReturn), "another window's Option-Return is not the palette's")
        #expect(!consumed(commandL), "nor is its Command-L")
        #expect(submitted == 0 && dismissed == 0, "and the palette did nothing for either")

        // Positive control: the same keys addressed to the palette's own window are the palette's, so the handler is live.
        #expect(consumed(ownReturn), "the palette's own Option-Return is consumed")
        #expect(submitted == 1)
        #expect(!consumed(ownCommandL), "its own Command-L passes on, after the palette closes itself")
        #expect(dismissed == 1)
        #expect(!consumed(ownReturn, isKey: false) && submitted == 1, "a palette window that is not key takes nothing")

        #expect(source.isPaletteOpen)
        #expect(source.browser.activeTab?.urlString == originalURL)
    }

    private func pasteEvent(
        modifiers: NSEvent.ModifierFlags,
        typingCharacter: String? = nil
    ) throws -> NSEvent {
        // Find V in the current Command layout without changing the input source.
        for keyCode in UInt16(0)..<128 {
            let probe = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
            ))
            guard probe.characters(byApplyingModifiers: .command)?.lowercased() == "v" else { continue }
            let characters = try #require(probe.characters(byApplyingModifiers: modifiers))
            let typing = try #require(typingCharacter ?? probe.characters(byApplyingModifiers: modifiers.intersection(.shift)))
            return try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: typing,
                isARepeat: false, keyCode: keyCode
            ))
        }
        throw MissingPasteKey()
    }

    private struct MissingPasteKey: Error {}

    private final class PasteEditor: NSTextView {
        var pasteboard: NSPasteboard?

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            // Native validation checks the general clipboard; this editor uses a private one.
            if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
                return pasteboard?.availableType(from: [.string]) != nil
            }
            return super.validateUserInterfaceItem(item)
        }

        override func paste(_ sender: Any?) {
            if let pasteboard {
                _ = readSelection(from: pasteboard, type: .string)
            }
        }

        override func pasteAsPlainText(_ sender: Any?) {
            paste(sender)
        }
    }
}
