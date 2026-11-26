// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension AppCoordinator {
    func openSharedSpace(_ entry: SpaceEntry) {
        guard !isClosed, !isSwitchingProfile, !entry.profile.isPrivate, profiles.profiles.contains(where: { $0.id == entry.profile.id }) else { return }
        let owners = browser.sharedSpaceService?.tabWindows(in: entry) ?? [:]
        let windows = regularSpaceWindows
        let target = windowOwningSharedTabs(owners, for: entry, among: windows)
            ?? windows.first { $0.page(in: entry) != nil }
            ?? self
        showSharedSpace(entry, in: target, owners: owners)
    }

    /// Consolidate the selected Space without closing tabs or switching any other window's profile.
    func canGatherSharedTabs(in entry: SpaceEntry) -> Bool {
        guard let application, !application.isLaunching, !application.isTerminating, application.ownsSession,
              let host = browser.sharedSpaceService, host.catalog.ready.contains(.spaces), host.isEnabled(.spaces, for: entry.profile),
              // Every window already shows every tab of the Space.
              !BrowserProfileContext.shared(for: entry.profile).settings.sharesSpaceTabsAcrossWindows else { return false }
        let owners = Set(host.tabWindows(in: entry, includingPinned: false).values)
        let available = Set(regularSpaceWindows.filter { $0.context.profile.id == entry.profile.id }.map(\.windowID))
        return owners.count > 1 && application.windows.allSatisfy { !owners.contains($0.windowID) || available.contains($0.windowID) }
    }

    func gatherSharedTabs(in entry: SpaceEntry) throws {
        guard !isClosed, !isSwitchingProfile, canGatherSharedTabs(in: entry),
              let application, let host = browser.sharedSpaceService else { throw SharedCatalogError.unavailable }
        let owners = host.tabWindows(in: entry, includingPinned: false)
        let counts = tabCounts(owners)
        let available = regularSpaceWindows.filter { $0.context.profile.id == entry.profile.id }
        let live = Dictionary(uniqueKeysWithValues: available.map { ($0.windowID, $0) })
        let database = BrowserProfileContext.shared(for: entry.profile).database
        let occupied = Set(application.windows.map(\.windowID))
        let saved = BrowserModel.savedWindows(in: database, includeClosed: true).filter { $0.windowKind == .standard }
        let restorable = Set(saved.map(\.id)).subtracting(occupied)
        guard counts.count > 1, !database.isEphemeral || AppDatabase.isRunningTests,
              Set(counts.keys).isSubset(of: Set(live.keys).union(restorable)),
              let destinationID = counts.keys.max(by: { (counts[$0, default: 0], $0 == windowID ? 1 : 0, $0.uuidString) <
                  (counts[$1, default: 0], $1 == windowID ? 1 : 0, $1.uuidString) }) else { throw SharedCatalogError.unavailable }

        let target = live[destinationID] ?? application.newWindow(profile: entry.profile, windowID: destinationID, restoring: true, show: false)
        showSharedSpace(entry, in: target, owners: owners)
        var restoredSources: [AppCoordinator] = []
        defer { restoredSources.forEach { $0.closeWindow() } }
        var transfers: [(BrowserModel, [SidebarItem])] = []
        for id in counts.keys.sorted(by: { $0.uuidString < $1.uuidString }) where id != destinationID {
            let window = live[id] ?? application.newWindow(profile: entry.profile, windowID: id, restoring: true, show: false)
            if live[id] == nil {
                restoredSources.append(window)
            }
            let model = window.browser
            let pages = owners.keys.filter { owners[$0] == id }
            guard pages.allSatisfy({ model.tab(id: $0)?.spaceID == entry.id && model.tab(id: $0)?.pinID == nil }) else {
                throw SharedCatalogError.unavailable
            }
            let roots = Set(pages.map { model.rootItem(containing: .tab($0)) })
            transfers.append((model, model.reconciledTree().root.filter(roots.contains)))
        }

        for (source, roots) in transfers {
            try host.gatherSharedRoots(roots, in: entry, from: source, into: target.browser)
        }
        let updated = host.tabWindows(in: entry, includingPinned: false)
        guard owners.keys.allSatisfy({ updated[$0] == destinationID && target.browser.tab(id: $0)?.spaceID == entry.id }) else {
            throw SharedCatalogError.storage
        }
    }

    /// A profile switch can recover an older shared window while leaving windows in other profiles alone.
    func reopenSharedProfileWindow(_ profile: Profile) -> Bool {
        guard !isClosed, !isSwitchingProfile, !isMicro, !context.profile.isPrivate,
              let application, !application.isLaunching, !application.isTerminating,
              profiles.profiles.contains(where: { $0.id == profile.id }),
              let host = browser.sharedSpaceService, host.isEnabled(.spaces, for: profile),
              let store = host.spaces(profile) else { return false }
        let visible = regularSpaceWindows.filter { $0.context.profile.id == profile.id }
        let candidates = store.spaces.compactMap { space -> (entry: SpaceEntry, windowID: UUID, priority: (Int, Date))? in
            let entry = SpaceEntry(space: space, profile: profile)
            let owners = host.tabWindows(in: entry)
            let counts = tabCounts(owners)
            let callerCount = context.profile.id == profile.id ? counts[windowID, default: 0] : 0
            let best = visible.filter { $0 !== self && $0.page(in: entry, owners: owners) != nil }
                .max { counts[$0.windowID, default: 0] < counts[$1.windowID, default: 0] }
            let liveCount = best.map { counts[$0.windowID, default: 0] } ?? 0
            if let saved = preferredSavedSharedWindow(of: profile, counts: counts, moreThan: max(callerCount, liveCount), in: application) {
                return (entry, saved.id, (counts[saved.id, default: 0], saved.lastActiveAt))
            }
            guard let best, liveCount > callerCount else { return nil }
            return (entry, best.windowID, (liveCount, best.browser.activeTab?.lastActiveAt ?? .distantPast))
        }
        guard let choice = candidates.max(by: { $0.priority < $1.priority }) else { return false }
        let window = visible.first(where: { $0.windowID == choice.windowID })
            ?? application.newWindow(profile: profile, windowID: choice.windowID, restoring: true, show: false)
        showSharedSpace(choice.entry, in: window, owners: host.tabWindows(in: choice.entry))
        return true
    }

    private var regularSpaceWindows: [AppCoordinator] {
        ([self] + (application?.windows ?? []).filter { $0 !== self }).filter {
            !$0.isClosed && !$0.isSwitchingProfile && !$0.isMicro && !$0.context.profile.isPrivate
        }
    }

    private func showSharedSpace(_ entry: SpaceEntry, in target: AppCoordinator, owners: [UUID: UUID]) {
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

    private func tabCounts(_ owners: [UUID: UUID]) -> [UUID: Int] {
        owners.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// A shared tab keeps its local window ID when a window closes or switches profiles.
    private func windowOwningSharedTabs(_ owners: [UUID: UUID], for entry: SpaceEntry, among open: [AppCoordinator]) -> AppCoordinator? {
        guard !owners.isEmpty else { return nil }
        let counts = tabCounts(owners)
        let visible = open.filter { $0.page(in: entry, owners: owners) != nil }
        let best = visible.max { counts[$0.windowID, default: 0] < counts[$1.windowID, default: 0] }
        guard let application, !application.isLaunching, !application.isTerminating else { return best }
        let bestCount = best.map { counts[$0.windowID, default: 0] } ?? 0
        if let saved = preferredSavedSharedWindow(of: entry.profile, counts: counts, moreThan: bestCount, in: application) {
            return application.newWindow(profile: entry.profile, windowID: saved.id, restoring: true, show: false)
        }
        if let visible = best ?? open.first(where: { counts[$0.windowID] != nil && $0.context.profile.id != entry.profile.id }) {
            return visible
        }
        // A verified catalog can restore its tabs even if SQLite has pruned their former window.
        let remaining = Set(counts.keys).subtracting(application.windows.map(\.windowID))
        guard let owner = remaining.min(by: { $0.uuidString < $1.uuidString }) else { return nil }
        return application.newWindow(profile: entry.profile, windowID: owner, restoring: true, show: false)
    }

    private func preferredSavedSharedWindow(
        of profile: Profile, counts: [UUID: Int], moreThan minimum: Int, in application: BrowserApplication
    ) -> BrowserModel.SavedBrowserWindow? {
        let candidates = Set(counts.filter { $0.value > minimum }.keys).subtracting(application.windows.map(\.windowID))
        guard !candidates.isEmpty else { return nil }
        let database = BrowserProfileContext.shared(for: profile).database
        return BrowserModel.savedWindows(in: database, includeClosed: true)
            .filter { $0.closedAt != nil && $0.windowKind == .standard && candidates.contains($0.id) }
            .max { (counts[$0.id, default: 0], $0.lastActiveAt) < (counts[$1.id, default: 0], $1.lastActiveAt) }
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
