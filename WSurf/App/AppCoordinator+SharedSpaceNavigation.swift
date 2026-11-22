// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension AppCoordinator {
    func openSharedSpace(_ entry: SpaceEntry) {
        guard !isClosed, !isSwitchingProfile, !entry.profile.isPrivate, profiles.profiles.contains(where: { $0.id == entry.profile.id }) else { return }
        let windows = ([self] + (application?.windows ?? []).filter { $0 !== self }).filter {
            !$0.isClosed && !$0.isSwitchingProfile && !$0.isMicro && !$0.context.profile.isPrivate
        }
        let owners = browser.sharedSpaceService?.tabWindows(in: entry) ?? [:]
        let target = windowOwningSharedTabs(owners, for: entry, among: windows)
            ?? windows.first { $0.page(in: entry) != nil }
            ?? self
        if target !== self {
            target.showBrowser()
        }
        target.switchSpace(to: entry) { window in
            guard !window.isClosed, window.context.profile.id == entry.profile.id, window.browser.currentSpaceID == entry.id else { return }
            if let page = window.page(in: entry, owners: owners) ?? window.page(in: entry) {
                window.browser.activate(page)
            } else if window.isShowingSettings {
                window.browser.newTab()
            }
        }
    }

    /// An ordinary profile switch restores this window's session unless another window holds more of a shared Space.
    func openSharedProfile(_ profile: Profile) -> Bool {
        guard !isClosed, !isSwitchingProfile, !isMicro, !context.profile.isPrivate, application?.isTerminating == false,
              profiles.profiles.contains(where: { $0.id == profile.id }),
              let host = browser.sharedSpaceService, host.isEnabled(.spaces, for: profile),
              let store = host.spaces(profile) else { return false }
        let entries = store.spaces.compactMap { space -> (entry: SpaceEntry, count: Int)? in
            let entry = SpaceEntry(space: space, profile: profile)
            let counts = tabCounts(byWindow: host.tabWindows(in: entry))
            guard let count = counts.values.max(), count > counts[windowID, default: 0] else { return nil }
            return (entry, count)
        }
        guard let entry = entries.max(by: { $0.count < $1.count })?.entry else { return false }
        openSharedSpace(entry)
        return true
    }

    private func tabCounts(byWindow owners: [UUID: UUID]) -> [UUID: Int] {
        owners.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// A shared tab keeps its local window ID when a window closes or switches profiles.
    private func windowOwningSharedTabs(_ owners: [UUID: UUID], for entry: SpaceEntry, among open: [AppCoordinator]) -> AppCoordinator? {
        guard !owners.isEmpty else { return nil }
        let counts = tabCounts(byWindow: owners)
        let visible = open.filter {
            counts[$0.windowID] != nil && ($0.context.profile.id != entry.profile.id || $0.page(in: entry, owners: owners) != nil)
        }
        let best = visible.max { counts[$0.windowID, default: 0] < counts[$1.windowID, default: 0] }
        guard let application, !application.isTerminating else { return best }
        let bestCount = best.map { counts[$0.windowID, default: 0] } ?? 0
        let available = Set(counts.filter { $0.value > bestCount }.keys).subtracting(application.windows.map(\.windowID))
        guard !available.isEmpty else { return best }
        // A newer window can hold a few tabs from the same Space. Reopen the saved window with more of its tabs.
        let database = BrowserProfileContext.shared(for: entry.profile).database
        let saved = BrowserModel.savedWindows(in: database, includeClosed: true)
            .filter { $0.windowKind == .standard && available.contains($0.id) }
            .max { (counts[$0.id, default: 0], $0.lastActiveAt) < (counts[$1.id, default: 0], $1.lastActiveAt) }
        // The catalog can restore shared tabs even when SQLite no longer has their window.
        let owner = saved?.id ?? (best == nil ? available.min(by: { $0.uuidString < $1.uuidString }) : nil)
        guard let owner else { return best }
        return application.newWindow(profile: entry.profile, windowID: owner, restoring: true, show: false)
    }

    private func page(in entry: SpaceEntry, owners: [UUID: UUID]? = nil) -> BrowserTab? {
        guard context.profile.id == entry.profile.id, browser.knownSpaceIDs.contains(entry.id) else { return nil }
        func belongs(_ tab: BrowserTab) -> Bool {
            if let owners, owners[tab.id] != windowID {
                return false
            }
            let member = tab.spaceID == entry.id || (owners != nil && tab.isPinnedForProfile)
            return member && tab.microTabID == nil && tab.internalPage == nil && !SystemPages.showsStartFace(tab)
        }
        return browser.recentlyActive.lazy.compactMap(browser.tab(id:)).first(where: belongs) ?? browser.tabs.first(where: belongs)
    }
}
