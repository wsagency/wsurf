// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension ProfileVaultStore {
    /// The earlier versions of every live account of `vaultID`, by account: which part, when and why (`RevisionItem`). One pass over the
    /// vault's history rows, each opened for its date and cause only; the superseded value is decoded with the row and dropped, never
    /// returned. The import report reads it to say what was changed in WSurf, so it asks for it once and not once per credential.
    func revisionLog(vaultID: UUID, using access: VaultAccess) async throws -> [UUID: [RevisionItem]] {
        try await readHistory(vaultID, access) { db, grant, _ in
            var log: [UUID: [RevisionItem]] = [:]
            try mapIntegrity(grant.ordinal) {
                try StoreTables.forEachHistoryRecord(db, vaultID: vaultID) { row in
                    guard row.kind == .revision else { return }
                    let body = try JSONDecoder().decode(RevisionBody.self, from: row.opened(key: grant.dek, ids: grant.ids))
                    log[row.ownerID, default: []].append(
                        RevisionItem(id: row.recordID, subject: row.subject, version: row.version, recordedAt: body.recordedAt, cause: body.cause)
                    )
                }
            }
            return log
        }
    }
}
