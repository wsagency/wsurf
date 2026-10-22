// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension CredentialSettingsModel {
    /// The vault's verified Trash and earlier-version counts, for the Statistics section. They live in the authorization session like
    /// the Trash's, so a lock, a re-unlock or another vault starts again from nothing, and a write that reloads the page refreshes them.
    func loadStatistics() async throws {
        guard let live, let manager else { throw CredentialVaultError.unauthorized }
        let counts = try await manager.historyCounts()
        try Task.checkCancellation()
        try update(live.epoch) { $0.counts = counts }
    }

    /// How many earlier versions the vault keeps; `nil` until the counts are loaded.
    var earlierVersionCount: Int? {
        live?.counts?.live.revision
    }
}
