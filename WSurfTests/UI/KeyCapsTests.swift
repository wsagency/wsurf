// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Shortcuts drawn as key caps: how a shortcut splits into keys, and that every one the palette and the sidebar draw is the
/// key the menu bar answers to, not a copy of what another browser says.
@MainActor
struct KeyCapsTests {
    // MARK: - Splitting

    @Test func aShortcutSplitsIntoOneCapPerKey() {
        #expect(KeyCaps("⇧⌘N").caps == ["⇧", "⌘", "N"])
        #expect(KeyCaps("⌃⌘→").caps == ["⌃", "⌘", "→"])
        #expect(KeyCaps("⌘↩").caps == ["⌘", "↩"])
        #expect(KeyCaps("⌥⌘.").caps == ["⌥", "⌘", "."])
        #expect(KeyCaps("⌃1").caps == ["⌃", "1"])
        #expect(KeyCaps("").caps.isEmpty)
    }

    @Test func recordedKeysKeepTheirNames() {
        #expect(KeyCaps(caps: ["left ⌘"]).caps == ["left ⌘"])
    }

    @Test func voiceOverReadsTheShortcutAsWrittenAndNamesApartKeepSeparate() {
        #expect(KeyCaps("⇧⌘N").spoken == "⇧⌘N")
        #expect(KeyCaps(caps: ["left ⌘"]).spoken == "left ⌘")
        #expect(KeyCaps(caps: ["⌃", "left ⌘"]).spoken == "⌃ left ⌘")
    }

    // MARK: - What the menu bar answers to

    /// A menu item's key as the menu draws it: ⌃⌥⇧⌘ in that order, an uppercase letter standing for Shift, arrows as arrows.
    private func glyphs(of item: NSMenuItem) -> String? {
        var key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask.intersection([.control, .option, .shift, .command])
        let named: [String: String] = [
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            "\t": "⇥",
            "\r": "↩",
        ]
        if let name = named[key] {
            key = name
        } else if key.count == 1, key != key.lowercased() {
            modifiers.insert(.shift)
        }
        return (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
            + key.uppercased()
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems(in:)) ?? []) }
    }

    /// The installed main menu's items, and what puts the previous menu back.
    private func installedMenu() throws -> (items: [NSMenuItem], restore: () -> Void) {
        let previous = NSApp.mainMenu
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        let root = try #require(NSApp.mainMenu)
        return (allItems(in: root), {
            NSApp.mainMenu = previous
            coordinator.browser.cancelPendingSave()
        })
    }

    private func commands(_ context: CommandPaletteContext) -> [CommandPaletteCommand] {
        CommandPaletteCatalog.commands(context: context, perform: { _ in })
    }

    /// Everything on, and everything off: the union holds every command and both titles of the ones that flip.
    private var everyContext: [CommandPaletteContext] {
        var on = CommandPaletteContext()
        on.isSpeechMuted = true
        on.isListening = true
        on.historyCount = 12
        on.tabCount = 9
        on.hasActiveTab = true
        on.canReload = true
        on.canGoBack = true
        on.canGoForward = true
        on.isLoading = true
        on.isZoomed = true
        on.isShowingPin = true
        on.canReopenClosedTab = true
        on.archivedCount = 3
        on.hasSpaces = true
        on.canSplit = true
        on.isSplit = true
        on.canSwapPanes = true
        on.isStacked = true
        on.hasSplitAxis = true
        on.isActivityVisible = true
        on.isLyricsVisible = true
        on.canShowLyrics = true
        on.isFullScreen = true
        on.canCheckForUpdates = true
        on.hasExternalConnections = true
        on.isMinimal = true
        var away = on
        away.isAwayFromPin = true
        return [on, away, CommandPaletteContext(), CommandPaletteContext(isSidebarVisible: false)]
    }

    /// Every shortcut the palette advertises is a key the main menu really has, hidden aliases included.
    @Test func everyPaletteShortcutIsAMenuKey() throws {
        let (items, restore) = try installedMenu()
        defer { restore() }
        let keys = Set(items.compactMap(glyphs(of:)))
        try #require(keys.contains("⌘T"), "the menu's keys are read")

        var seen: Set<String> = []
        var unbound: [String] = []
        for command in everyContext.flatMap(commands) where !command.shortcut.isEmpty {
            seen.insert(command.shortcut)
            if !keys.contains(command.shortcut) {
                unbound.append("\(command.id) \(command.shortcut)")
            }
        }

        #expect(seen.count > 30, "the whole catalog was read")
        #expect(unbound.isEmpty, "palette shortcuts the menu bar does not have: \(unbound)")
    }

    /// The ones that changed meaning or have two titles: ⌘W closes or unloads and the palette must not claim it for Unload,
    /// ⌘D pins, updates the pinned page or unpins, ⇧⌘M changes the window style.
    @Test func theNamedShortcutsAreTheOnesTheMenuHas() throws {
        let (items, restore) = try installedMenu()
        defer { restore() }
        func menuTitle(for glyph: String) -> [String] {
            items.filter { glyphs(of: $0) == glyph }.map(\.title)
        }

        #expect(menuTitle(for: "⌘W") == [String(localized: "Close Tab")], "closes an unpinned tab, unloads a pinned one")
        #expect(menuTitle(for: "⌘D") == [String(localized: "Pin This Page")], "updates or unpins when the page is pinned")
        #expect(menuTitle(for: "⇧⌘M") == [String(localized: "Use Minimal Window Style")])
        #expect(menuTitle(for: "⇧⌘N") == [String(localized: "New Private Window")])

        let unload = try #require(everyContext.flatMap(commands).first { $0.id == "action-unloadTab" })
        #expect(unload.shortcut.isEmpty, "⌘W no longer unloads an unpinned tab, so the palette does not say it does")

        for context in [
            CommandPaletteContext(hasActiveTab: true),
            CommandPaletteContext(hasActiveTab: true, isShowingPin: true),
            CommandPaletteContext(hasActiveTab: true, isShowingPin: true, isAwayFromPin: true),
        ] {
            let pin = try #require(commands(context).first { $0.id == "action-togglePin" })
            #expect(pin.shortcut == "⌘D", "\(pin.title)")
        }
        let titles = [
            commands(CommandPaletteContext(hasActiveTab: true)),
            commands(CommandPaletteContext(hasActiveTab: true, isShowingPin: true)),
            commands(CommandPaletteContext(hasActiveTab: true, isShowingPin: true, isAwayFromPin: true)),
        ].compactMap { $0.first { $0.id == "action-togglePin" }?.title }
        #expect(titles == [
            String(localized: "Pin This Page"), String(localized: "Unpin Tab"), String(localized: "Update Pinned URL"),
        ])

        let style = try #require(everyContext.flatMap(commands).first { $0.id == "action-toggleWindowStyle" })
        #expect(style.shortcut == "⇧⌘M")
    }

    /// ⌃1–9 for the first nine spaces: the labels the switcher shows are the keys the menu answers to.
    @Test func theSpaceLabelsAreTheSpaceKeys() throws {
        let (items, restore) = try installedMenu()
        defer { restore() }

        for slot in SpaceShortcut.slots {
            let item = try #require(items.first { $0.title == "Show Space \(slot)" }, "slot \(slot)")
            #expect(SpaceShortcut.label(at: slot - 1) == glyphs(of: item))
            #expect(SpaceShortcut.label(at: slot - 1) == "⌃\(slot)")
        }
        #expect(SpaceShortcut.label(at: 9) == nil)
    }

    /// The sidebar's profile menu draws the key of the command it names, as the menu bar has it.
    @Test func theSidebarsPrivateWindowRowShowsTheMenuKey() throws {
        let (items, restore) = try installedMenu()
        defer { restore() }
        let item = try #require(items.first { $0.title == String(localized: "New Private Window") })
        let glyph = try #require(glyphs(of: item))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "WSurf/UI/Sidebar/ProfileButton.swift"), encoding: .utf8)

        #expect(source.contains(#"shortcut: "\#(glyph)""#))
    }
}
