// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import os

/// What a window is for. A micro window shows one page with no chrome until the pointer reaches the top. Every other
/// window is a standard one, drawn in the app-wide window style.
nonisolated enum WindowKind: String, Sendable {
    case standard
    case micro
}

extension BrowserModel {
    /// Ends the saved session of a window that has no page left, so Reopen Last Closed Window and the next launch never
    /// bring back a blank micro window. A closed window normally keeps its rows to be reopened; this one has nothing to keep.
    /// The retirement row refuses any save still queued, and the window's own rows go in the same write: rows left behind
    /// would be adopted again as a window the next time the database opens (`AppDatabase.defineWindowSessions`).
    func retireSession() {
        guard tabs.isEmpty else { return }
        cancelPendingSave()
        sessionClosedAt = Date()
        sessionRevision += 1
        let windowID = windowID
        let revision = sessionRevision
        do {
            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessionWindowRetirement (id, revision) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET revision = MAX(revision, excluded.revision)
                    """, arguments: [windowID, revision])
                for table in ["sessionItem", "sessionSplitPane", "sessionSplitTree", "sessionTab", "sessionFolder"] {
                    guard try db.tableExists(table) else { continue }
                    try db.execute(sql: "DELETE FROM \(table) WHERE windowID = ?", arguments: [windowID])
                }
                try db.execute(sql: "DELETE FROM sessionWindow WHERE id = ?", arguments: [windowID])
            }
        } catch {
            Pipeline.log.error("session: retiring a micro window failed")
        }
    }
}

// MARK: - The row a page leaves behind

extension BrowserModel {
    /// The row this window keeps for `tabID` of a micro window, if it keeps one.
    func microPlaceholder(for tabID: UUID) -> BrowserTab? {
        tabs.first { $0.microTabID == tabID }
    }

    /// Leaves a row where `tab` is, for while its page is in a micro window: an unloaded page at the same place, with the
    /// same name, icon, pin, favorite and space, that refers to the tab (`BrowserTab.microTabID`) and is not one. It is
    /// made before the page leaves, right after it, so it takes the page's place, and for a pin it becomes the pin's page:
    /// the pin set never changes. It keeps the page's state for the day it stops referring to it (its micro window gone at
    /// launch), when it is an ordinary row that opens the page again.
    @discardableResult
    func insertMicroPlaceholder(for tab: BrowserTab) -> BrowserTab {
        let url = URL(string: tab.urlString)
        let row = makeTab(for: url, restoring: true)
        row.pageTitle = tab.pageTitle
        row.customTitle = tab.customTitle
        row.urlString = tab.urlString
        row.favicon = tab.favicon
        row.faviconHost = tab.faviconHost
        row.pinID = tab.pinID
        row.pinnedURL = tab.pinnedURL
        row.pinnedTitle = tab.pinnedTitle
        row.isFavorite = tab.isFavorite
        row.spaceID = tab.spaceID
        row.lastActiveAt = tab.lastActiveAt
        row.deferRestore(state: tab.sessionState, url: url)
        row.microTabID = tab.id
        let index = tabs.firstIndex { $0 === tab }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(row, at: index)
        storedTree = reconciledTree().inserting(.tab(row.id), after: .tab(tab.id))
        sidebarDidChange()
        return row
    }

    /// Puts `tab`, just taken back from its micro window, where `row` stood, with the row's name, pin, favorite and space,
    /// and removes the row. The page is the same page; only the row that stood for it goes.
    func settle(_ tab: BrowserTab, into row: BrowserTab) {
        guard tab !== row, tabsByID[tab.id] === tab, tabsByID[row.id] === row else { return }
        place([.tab(tab.id)], in: reconciledTree().parent(of: .tab(row.id)), before: .tab(row.id))
        tab.customTitle = row.customTitle
        tab.pinnedURL = row.pinnedURL
        tab.pinnedTitle = row.pinnedTitle
        tab.isFavorite = row.isFavorite
        tab.spaceID = row.spaceID
        let pinID = row.pinID
        // Unlinked first, so closing the row is closing a row and nothing it stood for.
        row.microTabID = nil
        row.pinID = nil
        tab.pinID = pinID
        close(row, recordForReopening: false)
        syncTabOrder()
        followSpace(of: tab)
        scheduleSave()
    }
}
