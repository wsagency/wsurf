// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension AppCoordinator {
    func openSharedSpace(_ entry: SpaceEntry) {
        guard !isClosed, !isSwitchingProfile, !entry.profile.isPrivate, profiles.profiles.contains(where: { $0.id == entry.profile.id }) else { return }
        let windows = ([self] + (application?.windows ?? []).filter { $0 !== self }).filter {
            !$0.isClosed && !$0.isSwitchingProfile && !$0.isMicro && !$0.context.profile.isPrivate
        }
        let owners = browser.sharedSpaceService?.tabWindows(in: entry) ?? [:]
        let target = windows.first { $0.page(in: entry, owners: owners) != nil }
            ?? windowOwningSharedTabs(Set(owners.values), for: entry, among: windows)
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

    /// A shared tab keeps its local window ID when a window closes or switches profiles.
    private func windowOwningSharedTabs(_ owners: Set<UUID>, for entry: SpaceEntry, among open: [AppCoordinator]) -> AppCoordinator? {
        guard !owners.isEmpty else { return nil }
        if let switched = open.first(where: { owners.contains($0.windowID) && $0.context.profile.id != entry.profile.id }) {
            return switched
        }
        guard let application else { return nil }
        let closed = owners.subtracting(application.windows.map(\.windowID))
        guard let fallback = closed.min(by: { $0.uuidString < $1.uuidString }) else { return nil }
        let database = BrowserProfileContext.shared(for: entry.profile).database
        let saved = BrowserModel.savedWindows(in: database, includeClosed: true).first { $0.windowKind == .standard && closed.contains($0.id) }
        // The catalog can restore the shared tabs even when SQLite no longer has the window's session.
        return application.newWindow(profile: entry.profile, windowID: saved?.id ?? fallback, restoring: true, show: false)
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
