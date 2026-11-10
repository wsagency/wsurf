// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// The vault reads made through one profile's managers, in order, by kind: never a value. Only tests count them: a test registers an
/// audit for its own fixture profile (`CredentialManager.readAuditsForTesting`), so suites running at the same time never add to each
/// other's, and the app registers none.
@MainActor
final class VaultReadAudit {
    nonisolated enum Read: Equatable, Sendable {
        case snapshot, candidates, health
        case login(AutofillLoginField)
        case items(AutofillItemKind, pick: Bool)
        case passkeys, passwordMatches
    }

    private(set) var reads: [Read] = []

    func note(_ read: Read) {
        reads.append(read)
    }
}

extension CredentialManager {
    /// Test-only, keyed by profile like `CredentialPicker.answersForTesting`. Empty in the app.
    static var readAuditsForTesting: [UUID: VaultReadAudit] = [:]

    /// Counts `read` for `profile` when a test audits it; nothing otherwise.
    static func noteRead(_ read: VaultReadAudit.Read, profile: UUID) {
        readAuditsForTesting[profile]?.note(read)
    }
}
