// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

/// One dot of the space switcher: a space and the profile it belongs to.
struct SpaceEntry: Identifiable, Equatable {
    let space: Space
    let profile: Profile

    var id: UUID {
        space.id
    }
}

/// ⌃1–9 show the first nine spaces of the switcher.
enum SpaceShortcut {
    static let slots = 1...9
    static let modifiers: NSEvent.ModifierFlags = [.control]

    static func label(at index: Int) -> String? {
        slots.contains(index + 1) ? "⌃\(index + 1)" : nil
    }
}

extension AppCoordinator {
    // MARK: - Spaces

    /// The spaces of this window's profile; nil in a private window, which has none.
    var spaceStore: SpaceStore? {
        context.spaces
    }

    var currentSpace: Space? {
        spaceStore?.space(id: browser.currentSpaceID)
    }

    /// The switcher's spaces, in order.
    var spaceEntries: [SpaceEntry] {
        guard let spaceStore else { return [] }
        let profile = context.profile
        return spaceStore.spaces.map { SpaceEntry(space: $0, profile: profile) }
    }

    var showsSpaceSwitcher: Bool {
        spaceEntries.count > 1
    }

    func switchSpace(to entry: SpaceEntry) {
        guard entry.profile.id == context.profile.id else { return }
        browser.switchSpace(to: entry.space.id)
    }

    /// ⌃N, counting from zero.
    func switchToSpace(at index: Int) {
        let entries = spaceEntries
        guard entries.indices.contains(index) else { return }
        switchSpace(to: entries[index])
    }

    /// The neighbor `step` places away in the switcher, for a swipe.
    func switchSpace(by step: Int) {
        let entries = spaceEntries
        guard let current = entries.firstIndex(where: { $0.id == browser.currentSpaceID }),
              entries.indices.contains(current + step) else { return }
        switchSpace(to: entries[current + step])
    }

    /// The other open windows of this profile, and this one.
    var profileWindows: [AppCoordinator] {
        (application?.windows ?? [self]).filter { !$0.isClosed && $0.context === context }
    }

    /// Every window of the profile learns the current set of spaces.
    func refreshSpaces() {
        let owned = spaceStore?.spaces.map(\.id) ?? []
        for window in profileWindows {
            window.browser.adoptSpaces(owned)
        }
    }

    // MARK: - Organizing

    var spaceMoveTargets: [Space] {
        browser.spaceMoveTargets
    }

    func moveToSpace(_ items: [SidebarItem], space: Space) {
        guard spaceMoveTargets.contains(where: { $0.id == space.id }) else { return }
        browser.move(items, toSpace: space.id)
    }

    @discardableResult
    func createSpace(name: String, symbol: String) -> Space? {
        guard let spaceStore else { return nil }
        let space = spaceStore.add(name: name, symbol: symbol)
        refreshSpaces()
        browser.switchSpace(to: space.id)
        return space
    }

    func updateSpace(_ space: Space) {
        spaceStore?.update(space)
    }

    func canDeleteSpace(_ space: Space) -> Bool {
        spaceStore?.canRemove(space) == true
    }

    func confirmDeleteSpace(_ space: Space) async {
        guard canDeleteSpace(space) else { return }
        guard await ConfirmAlert.destructive(
            "Delete “\(space.name)”?",
            detail: "Its tabs and folders close. Pins, Favorites, sign-ins, history and passwords stay with the profile.",
            verb: "Delete"
        ) else { return }
        deleteSpace(space)
    }

    /// Closes the space's rows in every window of the profile, forgets its saved rows and removes it. The profile, its
    /// pins and its vault stay; a profile is removed only in Settings › Profiles.
    func deleteSpace(_ space: Space) {
        guard let spaceStore, spaceStore.canRemove(space),
              let index = spaceStore.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        let others = spaceStore.spaces.filter { $0.id != space.id }
        let fallback = others[max(0, min(index - 1, others.count - 1))]
        for window in profileWindows {
            if window.browser.currentSpaceID == space.id {
                window.browser.switchSpace(to: fallback.id)
            }
            window.browser.closeSpace(space.id)
        }
        spaceStore.remove(space)
        BrowserModel.forgetSpace(space.id, in: context.database)
        refreshSpaces()
    }

    // MARK: - The editor

    func showNewSpaceEditor() {
        guard spaceStore != nil else { return }
        Task { [weak self] in
            guard let self, let choice = await SpaceEditor.ask(editing: nil) else { return }
            createSpace(name: choice.name, symbol: choice.symbol)
        }
    }

    func showSpaceEditor(for space: Space) {
        Task { [weak self] in
            guard let choice = await SpaceEditor.ask(editing: space) else { return }
            var edited = space
            edited.name = choice.name
            edited.symbol = choice.symbol
            self?.updateSpace(edited)
        }
    }
}
