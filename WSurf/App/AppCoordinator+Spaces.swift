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

/// Which sign-ins a new space uses: those of an existing profile, or its own in a new profile.
enum SpaceSharing: Equatable {
    case profile(UUID)
    case separate
}

/// A space of another profile is a full profile switch. The switcher says what that costs once, until the person
/// asks it not to.
enum SpaceSwitchNotice {
    static let key = "spaces.profileSwitchExplained"
    #if DEBUG
    static var defaults = StageMode.defaults
    #else
    static var defaults = UserDefaults.standard
    #endif

    static var isNeeded: Bool {
        !defaults.bool(forKey: key)
    }

    static func stopAsking() {
        defaults.set(true, forKey: key)
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

    /// The switcher's spaces: every profile's, in the order of Settings › Profiles. None in a private window.
    var spaceEntries: [SpaceEntry] {
        guard spaceStore != nil else { return [] }
        return profiles.profiles.flatMap { profile in
            (SpaceStore.shared(for: profile)?.spaces ?? []).map { SpaceEntry(space: $0, profile: profile) }
        }
    }

    var showsSpaceSwitcher: Bool {
        spaceEntries.count > 1
    }

    /// A space of this profile is a view change. A space of another profile switches the window to that profile, as
    /// choosing it in the profile menu does: this profile's passwords lock, external apps lose this window, the
    /// assistant stops and the tabs reload.
    func switchSpace(to entry: SpaceEntry) {
        guard entry.profile.id != context.profile.id else {
            browser.switchSpace(to: entry.space.id)
            return
        }
        guard !isSwitchingProfile else { return }
        Task { [weak self] in
            guard let self, !isClosed, await confirmProfileSwitch(to: entry), !isClosed else { return }
            await switchProfile(to: entry.profile, landingIn: entry.space.id)
        }
    }

    private func confirmProfileSwitch(to entry: SpaceEntry) async -> Bool {
        guard SpaceSwitchNotice.isNeeded else { return true }
        guard !isClosed else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Switch to “\(entry.space.name)”?")
        alert.informativeText = String(localized: "“\(entry.space.name)” has its own sign-ins and data, in the profile “\(entry.profile.name)”.")
            + " " + String(localized: "Switching locks this profile’s passwords, disconnects external apps from this window, stops the assistant and reloads your tabs.")
        alert.addButton(withTitle: String(localized: "Switch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        let response: NSApplication.ModalResponse
        if let window = nativeWindow ?? NSApp.keyWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            SpaceSwitchNotice.stopAsking()
        }
        return true
    }

    /// ⌃N, counting from zero.
    func switchToSpace(at index: Int) {
        let entries = spaceEntries
        guard entries.indices.contains(index) else { return }
        switchSpace(to: entries[index])
    }

    /// The neighbor `step` places away among this profile's spaces, for a swipe. A swipe is easy to make by accident,
    /// so it never starts a profile switch; the icons and ⌃1–9 do.
    func switchSpace(by step: Int) {
        let entries = spaceEntries.filter { $0.profile.id == context.profile.id }
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

    private func refreshSpaces(of profile: Profile) {
        let owned = SpaceStore.shared(for: profile)?.spaces.map(\.id) ?? []
        for window in application?.windows ?? [self] where !window.isClosed && window.context.profile.id == profile.id {
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

    /// Adds a space and shows it. Sharing an existing profile's sign-ins adds the space to that profile; separate
    /// sign-ins add a profile with WSurf's usual defaults, whose first space is this one. A space of another profile
    /// is shown by switching the window to it.
    @discardableResult
    func createSpace(name: String, symbol: String, sharing: SpaceSharing? = nil) -> Space? {
        guard spaceStore != nil else { return nil }
        let entry: SpaceEntry
        switch sharing ?? .profile(context.profile.id) {
        case .profile(let id):
            guard let profile = profiles.profiles.first(where: { $0.id == id }),
                  let store = SpaceStore.shared(for: profile) else { return nil }
            entry = SpaceEntry(space: store.add(name: name, symbol: symbol), profile: profile)
            refreshSpaces(of: profile)
        case .separate:
            let used = Set(spaceEntries.map(\.space.color))
            let color = TabFolderColor.allCases.first { $0 != .gray && !used.contains($0) } ?? .blue
            let profile = profiles.add(name: name, symbol: symbol, color: color)
            guard let space = SpaceStore.shared(for: profile)?.spaces.first else { return nil }
            entry = SpaceEntry(space: space, profile: profile)
        }
        switchSpace(to: entry)
        return entry.space
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
        let sharing = profiles.profiles.map { SpaceEditor.SharingOption(profile: $0) }
        Task { [weak self] in
            guard let self,
                  let choice = await SpaceEditor.ask(editing: nil, sharing: sharing, currentProfile: context.profile.id)
            else { return }
            createSpace(name: choice.name, symbol: choice.symbol, sharing: choice.sharing)
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
