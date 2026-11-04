// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

@testable import WSurfVault

/// Two entries of one person, synced on A and B at version 1, and the merge of one into the other on A. `gone` is the one A merges away
/// or deletes. The merge is what `CredentialMerge.merged` makes of two entries: the survivor is replaced by one that carries a
/// `mergedFrom` link to the other, and the other goes to the Trash.
@MainActor
struct MergedEntries {
    typealias Rig = VaultSyncRig

    let a: SimulatedMac
    let va: FakeVault
    let b: SimulatedMac
    let vb: FakeVault
    let keep: CredentialAccount
    let gone: CredentialAccount

    var goneRecord: SyncRecordID {
        SyncRecordID(zone: SyncZone.vault(profileID: va.profileID, vaultID: va.vaultID), name: gone.id.uuidString)
    }

    static func synced(_ rig: Rig) async throws -> MergedEntries {
        let keep = SyncVaultFixtures.account(username: "ada", password: "newer", origin: "https://example.test")
        let gone = SyncVaultFixtures.account(username: "ada", password: "older", origin: "https://example.test", notes: ["kept"])
        let (a, va) = try await rig.syncedMac(holding: [keep, gone])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        return MergedEntries(a: a, va: va, b: b, vb: vb, keep: keep, gone: gone)
    }

    /// The survivor as the merge leaves it: the link to `gone`, whose identity is its own ID when it has no link to the other app.
    func survivor(changing change: (inout CredentialAccount) -> Void = { _ in }) throws -> CredentialAccount {
        let identity = try CredentialExchangeCodec.externalItemID(for: gone)
        var result = keep
        result.mergedFrom = [MergedItemLink(accountID: gone.id, exchangeAccountID: identity.account, exchangeItemID: identity.item)]
        change(&result)
        return result
    }

    /// The merge on A: the survivor replaced, `gone` in the Trash, the pass produced, and sent unless `send` is false.
    func merge(send: Bool, changing change: (inout CredentialAccount) -> Void = { _ in }) async throws {
        va.edit(try survivor(changing: change))
        va.remove(gone.id)
        await a.wrote(va)
        if send {
            try await a.pump()
        }
    }

    func rounds(_ count: Int = 3) async throws {
        for _ in 0..<count {
            try await converge([a, b])
        }
    }
}
