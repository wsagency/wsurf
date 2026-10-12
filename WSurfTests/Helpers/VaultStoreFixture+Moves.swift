// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import WSurf

/// Extra `.revision` rows `VaultStoreFixture.make(extraHistory:)` seeds beside the default password rows (`historyRows`): `count`
/// rows of `subject` owned by `accounts[ownerIndex]`, versions `1...count`, journalled in the source journal like the others.
/// `plaintext` replaces the default filler (`historyRowBytes` bytes of a repeated counter) for every row of the run; a run's
/// bytes are opaque to the store, so a test can plant a recognisable secret in them.
nonisolated struct FixtureHistoryRun: Sendable {
    var subject: RecordSubject
    var count: Int
    var ownerIndex = 0
    var plaintext: Data?
}
