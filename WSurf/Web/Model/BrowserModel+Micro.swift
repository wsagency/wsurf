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
