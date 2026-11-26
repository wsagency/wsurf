// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

/// While a profile shares Space tabs across windows, every window holds its own page for each row. One window, the one
/// that holds most of the profile's slots, stands for all of them: only it captures and applies the catalog, so each
/// row uploads once and a remote edit reaches the other windows through the profile's `ProfilePinStore`.
extension CloudSharedSpaces {
    func spaceTabsOwner(of profile: Profile, among models: [BrowserModel]? = nil) -> BrowserModel? {
        slotOwner(of: profile, among: (models ?? regularWindows(profile)).filter(\.sharesSpaceTabs))
    }

    /// The window of `windows` that holds most of the profile's slots, or `fallback` when none holds any.
    func slotOwner(of profile: Profile, among windows: [BrowserModel], fallback: BrowserModel? = nil) -> BrowserModel? {
        guard windows.count > 1 else { return windows.first }
        let slots = links[profile.id].map { Array($0.slots.values) } ?? []
        let counts = slots.reduce(into: [UUID: Int]()) { $0[$1.window, default: 0] += 1 }
        if let fallback, windows.contains(where: { $0 === fallback }), !windows.contains(where: { counts[$0.windowID] != nil }) {
            return fallback
        }
        return windows.max { (counts[$0.windowID, default: 0], $0.windowID.uuidString) < (counts[$1.windowID, default: 0], $1.windowID.uuidString) }
    }

    /// False when another window captures for the profile of `browser`. The owner first takes the other windows' slots.
    func capturesSpaceTabs(of browser: BrowserModel, link: inout SharedProfileLinks) -> Bool {
        guard browser.sharesSpaceTabs, let owner = spaceTabsOwner(of: browser.context.profile) else { return true }
        guard owner === browser else { return false }
        adoptSpaceTabSlots(into: browser, link: &link)
        return true
    }

    /// The owner's local ID and window for a row another window of the profile shows as `id`.
    /// A pin's page has no row; the owner's page for the same pin holds the slot of the shared tab it was pinned from.
    func spaceTabsTarget(of id: UUID, link spaceTabID: UUID?, pin pinID: UUID? = nil, in browser: BrowserModel) -> (window: BrowserModel, id: UUID)? {
        guard browser.sharesSpaceTabs, let owner = spaceTabsOwner(of: browser.context.profile), owner !== browser else { return (browser, id) }
        if spaceTabID == nil, let pinID {
            return owner.tabs.first { $0.pinID == pinID }.map { (owner, $0.id) }
        }
        guard let spaceTabID else { return owner.folder(id: id) == nil ? nil : (owner, id) }
        return owner.tabs.first { $0.spaceTabID == spaceTabID }.map { (owner, $0.id) }
    }

    /// Moves the slots of rows that another window showed to the owner's page for the same row. A closed window's slot
    /// finds its row through the link it saved, so the owner can change while a window is closed. A row a window started
    /// takes that window's tab ID as its own, so a slot saved before links (or by a window still restoring) finds it too.
    func adoptSpaceTabSlots(into owner: BrowserModel, link: inout SharedProfileLinks) {
        let live = Dictionary(regularWindows(owner.context.profile).map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var pages: [UUID: UUID] = [:]
        for tab in owner.tabs {
            if let row = tab.spaceTabID {
                pages[row] = tab.id
            }
        }
        for (id, slot) in link.slots where slot.window != owner.windowID && slot.pinID == nil && slot.closedAfterRevision == nil {
            let target: UUID?, row: UUID?
            if owner.spaceFolderIDs.contains(id) {
                (target, row) = (id, nil)
            } else {
                row = live[slot.window]?.tab(id: id)?.spaceTabID ?? slot.spaceTabID ?? id
                target = row.flatMap { pages[$0] }
            }
            guard let target, target == id || link.slots[target] == nil else { continue }
            var moved = slot
            moved.spaceTabID = row
            moved.window = owner.windowID
            moved.movingFrom = nil
            // The owner's page already shows the edit; its next save retires it.
            if moved.editedAfterRevision != nil {
                moved.editedAfterRevision = owner.sessionRevision
            }
            link.slots[id] = nil
            link.slots[target] = moved
        }
    }
}
