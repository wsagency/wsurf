// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import WSurfVault

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

enum SpaceEditorError: LocalizedError, Equatable {
    case vaultUnavailable, spaceUnavailable

    var errorDescription: String? {
        switch self {
        case .vaultUnavailable:
            String(localized: "The selected vault is unavailable. Reopen the editor to choose a vault.")
        case .spaceUnavailable:
            String(localized: "The Space or its profile changed. Reopen the editor and try again.")
        }
    }
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
    func switchSpace(to entry: SpaceEntry, afterOpening: ((AppCoordinator) -> Void)? = nil) {
        guard entry.profile.id != context.profile.id else {
            browser.switchSpace(to: entry.space.id)
            afterOpening?(self)
            return
        }
        guard !isSwitchingProfile else { return }
        Task { [weak self] in
            guard let self, !isClosed, await confirmProfileSwitch(to: entry), !isClosed else { return }
            await switchProfile(to: entry.profile, landingIn: entry.space.id)
            afterOpening?(self)
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
        if let window = nativeWindow ?? NSApp.keyWindow?.sheetHost {
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
        let store = spaceStore
        for window in profileWindows {
            window.browser.adoptSpaces(from: store)
        }
    }

    private func refreshSpaces(of profile: Profile) {
        let store = SpaceStore.shared(for: profile)
        for window in application?.windows ?? [self] where !window.isClosed && window.context.profile.id == profile.id {
            window.browser.adoptSpaces(from: store)
        }
    }

    // MARK: - Organizing

    func moveToSpace(_ items: [SidebarItem], space: Space) {
        browser.move(items, toSpace: space.id)
    }

    /// Adds a space and shows it. Sharing an existing profile's sign-ins adds the space to that profile; separate
    /// sign-ins add a profile with WSurf's usual defaults, whose first space is this one. A space of another profile
    /// is shown by switching the window to it.
    @discardableResult
    func createSpace(name: String, symbol: String, sharing: SpaceSharing? = nil) -> Space? {
        guard spaceStore != nil, let choice = SpaceEditor.choice(name: name, symbol: symbol, sharing: sharing) else { return nil }
        return try? createSpace(choice, among: profiles.profiles, persist: false).space
    }

    private func createSpace(_ choice: SpaceEditor.Choice, among available: [Profile], persist: Bool) throws -> SpaceEntry {
        let entry: SpaceEntry
        switch choice.sharing ?? .profile(context.profile.id) {
        case .profile(let id):
            guard let profile = available.first(where: { $0.id == id }),
                  let store = SpaceStore.shared(for: profile) else { throw SpaceEditorError.spaceUnavailable }
            let space = persist ? try store.saveEditorChoice(choice) : store.add(name: choice.name, symbol: choice.symbol)
            entry = SpaceEntry(space: space, profile: profile)
            refreshSpaces(of: profile)
        case .separate:
            let used = Set(available.map(\.color)).union(spaceStore?.spaces.map(\.color) ?? [])
            let color = TabFolderColor.allCases.first { $0 != .gray && !used.contains($0) } ?? .blue
            let space = Space(id: UUID(), name: choice.name, symbol: choice.symbol, color: color, vault: choice.vault)
            let profile = try profiles.addProfile(forFirstSpace: space)
            entry = SpaceEntry(space: space, profile: profile)
        }
        switchSpace(to: entry)
        return entry
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
        openSpaceEditor(editing: nil)
    }

    func showSpaceEditor(for space: Space) {
        showSpaceEditor(for: SpaceEntry(space: space, profile: context.profile))
    }

    func showSpaceEditor(for entry: SpaceEntry) {
        openSpaceEditor(editing: entry)
    }

    private func openSpaceEditor(editing entry: SpaceEntry?) {
        guard spaceStore != nil else { return }
        let windowProfile = context.profile.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let available = try profiles.profilesForSpaceEditor()
                guard available.contains(where: { $0.id == windowProfile }) else { throw SpaceEditorError.spaceUnavailable }
                let vaults = await SpaceVaultPicker.Choices.load(from: available)
                guard !isClosed, context.profile.id == windowProfile else { return }
                let editing: SpaceEntry?
                if let entry {
                    guard let profile = available.first(where: { $0.id == entry.profile.id }),
                          let live = SpaceStore.shared(for: profile)?.space(id: entry.id) else { throw SpaceEditorError.spaceUnavailable }
                    editing = SpaceEntry(space: live, profile: profile)
                } else {
                    editing = nil
                }
                let sharing = available.map { SpaceEditor.SharingOption(profile: $0, among: available) }
                guard let choice = try await SpaceEditor.ask(
                    editing: editing?.space, sharing: sharing, currentProfile: windowProfile, vaults: vaults, in: nativeWindow
                ) else { return }
                try await saveSpace(choice, editing: editing, openedIn: windowProfile)
            } catch {
                guard !isClosed, context.profile.id == windowProfile else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Couldn’t update Spaces")
                alert.informativeText = error.localizedDescription
                if let window = nativeWindow ?? NSApp.keyWindow?.sheetHost {
                    _ = await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    @discardableResult
    func saveSpace(_ choice: SpaceEditor.Choice, editing entry: SpaceEntry?, openedIn windowProfile: UUID) async throws -> SpaceEntry {
        guard !isClosed, spaceStore != nil, context.profile.id == windowProfile else { throw SpaceEditorError.spaceUnavailable }
        if let ref = choice.vault {
            guard let owner = try profiles.profilesForSpaceEditor().first(where: { $0.id == ref.profileID }) else {
                throw SpaceEditorError.vaultUnavailable
            }
            let listing = try? await BrowserVaultScope.selected(owner: owner, vaultID: ref.vaultID).listing()
            guard listing?.contains(where: { $0.vaultID == ref.vaultID }) == true else { throw SpaceEditorError.vaultUnavailable }
        }
        guard !isClosed, context.profile.id == windowProfile else { throw SpaceEditorError.spaceUnavailable }
        let available = try profiles.profilesForSpaceEditor()
        guard available.contains(where: { $0.id == windowProfile }) else { throw SpaceEditorError.spaceUnavailable }
        if let ref = choice.vault, !available.contains(where: { $0.id == ref.profileID }) {
            throw SpaceEditorError.vaultUnavailable
        }
        if let entry {
            guard let profile = available.first(where: { $0.id == entry.profile.id }),
                  let store = SpaceStore.shared(for: profile) else { throw SpaceEditorError.spaceUnavailable }
            let edited = try store.saveEditorChoice(choice, editing: entry.space)
            return SpaceEntry(space: edited, profile: profile)
        }
        return try createSpace(choice, among: available, persist: true)
    }
}
