// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

extension BrowserModel {
    /// Transfer the same live page; navigation and POST state belong to the tab.
    @discardableResult
    func adoptTab(_ tab: BrowserTab, from source: BrowserModel) -> Bool {
        guard source !== self, source.windowID != windowID, source.context === context,
              !opensPrivately, source.sessionClosedAt == nil, sessionClosedAt == nil,
              context.isRegistered(source), context.isRegistered(self),
              (source.database.writer as AnyObject) === (database.writer as AnyObject),
              source.tabsByID[tab.id] === tab, tab.context === context,
              !tabs.contains(where: { $0.id == tab.id }), !tab.isClosed else { return false }

        source.onTabWillTransferOut?(tab)
        guard source.context === context, tab.context === context,
              source.sessionClosedAt == nil, sessionClosedAt == nil,
              context.isRegistered(source), context.isRegistered(self),
              (source.database.writer as AnyObject) === (database.writer as AnyObject),
              let oldIndex = source.tabs.firstIndex(where: { $0 === tab }),
              !tabs.contains(where: { $0.id == tab.id }), !tab.isClosed else { return false }
        source.cancelPendingSave()
        cancelPendingSave()
        // Undo snapshots contain tab and tree ownership; neither old stack may replay across a move.
        source.sidebarUndoManager.removeAllActions()
        sidebarUndoManager.removeAllActions()
        source.closedTabs.removeAll { $0.id == tab.id }
        closedTabs.removeAll { $0.id == tab.id }
        let survivor = source.splits.others(of: tab.id).first.flatMap { source.tabsByID[$0] }
            ?? source.tabs.dropFirst(oldIndex + 1).first
            ?? source.tabs.prefix(oldIndex).last
        let wasActive = source.activeTabID == tab.id
        let visitID = source.lastVisitID.removeValue(forKey: tab.id)
        source.splits = source.splits.removing(tab.id)
        source.storedTree = source.reconciledTree().removing([.tab(tab.id)])
        source.tabs.remove(at: oldIndex)
        source.recentlyActive.removeAll { $0 == tab.id }
        source.switcherRecency = nil
        if source.paneInAir == tab.id {
            source.paneInAir = nil
        }
        source.sidebarDidChange()
        if wasActive {
            source.activeTabID = survivor?.id
        }
        if let page = tab.liveView {
            AutofillSuggestions.shared.dismiss(in: page)
            page.removeFromSuperview()
        }
        bindCallbacks(to: tab)
        insert(tab, after: nil)
        lastVisitID[tab.id] = visitID
        writtenStateGeneration[tab.id] = nil
        source.onTabTransferredOut?(tab, oldIndex)
        onTabTransferredIn?(tab, source, oldIndex)
        activeTabID = tab.id
        saveTransferredSession(from: source)
        return true
    }
}
