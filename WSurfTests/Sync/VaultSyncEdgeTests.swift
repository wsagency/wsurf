// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// The edges of what a Mac reads, keeps and shows: a full read with a record that cannot be read, entries with files, rows of a vault
// that is gone, rows that wait for the owner, and a removal from iCloud that did not happen. Nothing here touches CloudKit, the
// Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncEdgeTests {
    // MARK: A full read

    @Test func oneRecordThatCannotBeReadDoesNotBlockTheOthersOrThisMacsUploads() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(3)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try rig.mac(unlocked: false)
        b.engine.unreadable = [held[2].id.uuidString]

        await b.sync.adopted(profileID: rig.profile, vaultID: rig.vaultID)
        await b.unlock(vb)
        try await b.pump()

        #expect(Set(vb.accounts.keys) == [held[0].id, held[1].id], "the entries that could be read arrived")
        #expect(b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).unreadable == 1, "the one that could not is counted")
        #expect(rig.status(b) == .synced, "the read finished")
        let own = SyncVaultFixtures.account(username: "made on B")
        vb.add(own)
        await b.wrote(vb)
        try await b.pump()
        #expect(rig.item(own) != nil, "this Mac’s own changes are not held back by it")
    }
}
