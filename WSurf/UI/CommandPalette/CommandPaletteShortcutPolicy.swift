// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit

enum CommandPaletteShortcutPolicy {
    static let arrowKeys: Set<String> = Set(
        [NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey]
            .compactMap { UnicodeScalar($0).map(String.init) }
    )

    static let returnKeys: Set<String> = ["\r", "\u{3}"]

    static func showsCurrentTab(modifiers: NSEvent.ModifierFlags) -> Bool {
        let actionModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return modifiers.intersection(actionModifiers) == .option
    }

    static func opensInCurrentTab(modifiers: NSEvent.ModifierFlags, key: String) -> Bool {
        showsCurrentTab(modifiers: modifiers) && returnKeys.contains(key)
    }

    /// Whether the palette's shortcut monitor may act on `event`: only a key event addressed to the palette's own window, while
    /// that window is key. An event for another window of the app is never the palette's, however the app was activated.
    static func isAddressedToPalette(_ event: NSEvent, paletteWindow: NSWindow?, isKey: Bool) -> Bool {
        guard let paletteWindow else { return false }
        return isKey && event.window === paletteWindow
    }

    /// The handler the palette's local key monitor runs for `coordinator`'s window: true when it consumes the event. The view
    /// installs exactly this; `isKey` is injected so a test needs no active app.
    static func monitor(
        for coordinator: AppCoordinator,
        isKey: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
        setOptionHeld: @escaping @MainActor (Bool) -> Void,
        submitInCurrentTab: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) -> @MainActor (NSEvent) -> Bool {
        { event in
            let window = coordinator.nativeWindow
            return consumes(
                event, paletteWindow: window, isKey: window.map(isKey) ?? false,
                setOptionHeld: setOptionHeld, submitInCurrentTab: submitInCurrentTab, dismiss: dismiss
            )
        }
    }

    /// What the palette's local key monitor does with `event`, and whether it consumes it (the event never reaches its window).
    /// Only an event addressed to the palette's own window, while that window is key, is acted on; any other passes untouched.
    static func consumes(
        _ event: NSEvent,
        paletteWindow: NSWindow?,
        isKey: Bool,
        setOptionHeld: (Bool) -> Void,
        submitInCurrentTab: () -> Void,
        dismiss: () -> Void
    ) -> Bool {
        guard isAddressedToPalette(event, paletteWindow: paletteWindow, isKey: isKey) else { return false }
        if event.type == .flagsChanged {
            setOptionHeld(showsCurrentTab(modifiers: event.modifierFlags))
            return false
        }
        let key = event.charactersIgnoringModifiers ?? ""
        if opensInCurrentTab(modifiers: event.modifierFlags, key: key) {
            submitInCurrentTab()
            return true
        }
        if shouldDismiss(event) {
            dismiss()
        }
        return false
    }

    static func shouldDismiss(_ event: NSEvent) -> Bool {
        let commandKey = event.modifierFlags.contains(.command)
            ? event.characters(byApplyingModifiers: .command)
            : nil
        return shouldDismiss(
            modifiers: event.modifierFlags,
            key: event.charactersIgnoringModifiers ?? "",
            commandKey: commandKey
        )
    }

    static func shouldDismiss(modifiers: NSEvent.ModifierFlags, key: String, commandKey: String? = nil) -> Bool {
        // Caps Lock and key-type flags do not change an editing shortcut.
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        let editingKeys: Set<String> = ["a", "c", "v", "x", "z"]
        // Some layouts use different letters while Command is held.
        let normalizedKey = (modifiers.contains(.command) ? commandKey ?? key : key).lowercased()
        let isTextEditing = modifiers == .command && editingKeys.contains(normalizedKey)
            || modifiers == [.command, .shift] && normalizedKey == "z"
            || modifiers == [.command, .option, .shift] && normalizedKey == "v"
        let isPaletteShortcut = modifiers == .command && (normalizedKey == "k" || normalizedKey == "t")
        let isListNavigation = arrowKeys.contains(key)
        let isRun = returnKeys.contains(key)
        let isCommand = !modifiers.isDisjoint(with: [.command, .control, .option])
        return isCommand && !isTextEditing && !isPaletteShortcut && !isListNavigation && !isRun
    }
}
