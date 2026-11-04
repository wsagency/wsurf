// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Showing a tab that was just opened: the sidebar scrolls to its row and the row pulses once. The model only says
/// which tab and when; the list decides whether it can scroll (not while a row is dragged or renamed, or the person is
/// scrolling) and a row draws its own pulse. A sidebar that is not on screen has no list, so it does nothing.
extension BrowserModel {
    /// A new tab that has an address is shown at once. One that opened blank is shown when it first gets one, which is
    /// when a person has typed where it goes. A tab an agent navigates is not shown: nobody asked for it.
    func revealWhenAddressed(_ tab: BrowserTab, hasAddress: Bool) {
        guard !hasAddress else {
            revealInSidebar(tab)
            return
        }
        tab.onFirstAddress = { [weak self, weak tab] in
            guard let self, let tab, tab.pendingTransition != .agent else { return }
            revealInSidebar(tab)
        }
    }

    /// Opens the folders that are shut around `tab` (only those: nothing else opens) and asks the sidebar to show its
    /// row. Clicking or switching to an existing tab never comes here.
    func revealInSidebar(_ tab: BrowserTab) {
        let item = SidebarItem.tab(tab.id)
        guard tabsByID[tab.id] === tab, !tab.isClosed, isShown(item), !hiddenSidebarTabIDs.contains(tab.id) else { return }
        var opened = false
        var walked = Set<UUID>()
        var parent = sidebarTree.parent(of: item)
        while let id = parent, walked.insert(id).inserted {
            if let folder = foldersByID[id], !folder.isExpanded {
                folder.isExpanded = true
                opened = true
            }
            parent = sidebarTree.parent(of: .folder(id))
        }
        if opened {
            scheduleSave()
        }
        let reveal = SidebarReveal(tabID: tab.id, token: (sidebarReveal?.token ?? 0) + 1, start: .now)
        sidebarReveal = reveal
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(SidebarPulse.duration + 0.1))
            guard let self, sidebarReveal == reveal else { return }
            sidebarReveal = nil
        }
    }
}
