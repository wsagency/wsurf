// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Task 7: the history preflight of a removal (`StoreVerifier.verifyHistories`: source and Trash ledgers, run inside `perform`'s
// transaction before the first write) and the verification scratch it needs. Shared plumbing lives in VaultMoveSupport.swift.

struct VaultMoveReplayTests {
    /// The same-count, same-AAD replay: the fixture's delete/undelete cycle re-sealed the victim's source rows, so the ciphertext it
    /// first wrote (real, opens under the vault key and the row's own AAD) is no longer the one the journal expects. Put one back:
    /// counts, metadata and AEAD all still hold, only the journal ledger's digest differs. A MOVE that journalled that row's digest
    /// as a `remove` would succeed and leave a store whose next unlock rejects it.
    @Test(arguments: [HiddenHistoryOperation.deleteAccount, .deletePassword])
    func sameCountReplayOfPreCycleCiphertextFailsClosed(_ operation: HiddenHistoryOperation) async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander], historyRows: 4, moves: 2,
            extraHistory: [FixtureHistoryRun(subject: .password, count: 2, ownerIndex: 1)]
        ) { f in
            let current = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            let saved = f.preMoveSourceHistory.filter { $0.ownerID == victim.id }
            let replayed = try #require(saved.first { old in current.contains { $0.recordID == old.recordID && $0.sealed != old.sealed } })
            _ = try f.movePlaintext(of: replayed)  // genuine: opens under the vault key and its own AAD
            let (store, access) = try await f.unlocked()
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            try f.mutate { try StoreTables.putRecord($0, replayed) }
            #expect(try f.moveRevisions(in: f.vaultID, owner: victim.id).count == current.count)

            let before = try f.headWriteImage()
            let revisions = try f.moveHeadRevisions()
            do {
                _ = try await operation.run(store, access, f, snapshot, victim)
                Issue.record("\(operation) committed over a replayed pre-cycle ciphertext")
            } catch let error as CredentialStoreError {
                guard case .integrityFailure = error else {
                    Issue.record("expected integrityFailure, got \(error)")
                    return
                }
            }
            #expect(try f.headWriteImage() == before)
            #expect(try f.moveHeadRevisions() == revisions)
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 0)
        }
    }

    /// The same invariant on the destination: after delete/undelete/delete the Trash holds the victim's rows re-sealed twice, and the
    /// ciphertext of the first delete (real Trash ciphertext, same AAD) is put back over one. Removing a bystander extends the Trash
    /// journal and would return a receipt, then the next unlock would reject the Trash history. Both bystander removal scopes must
    /// throw `integrityFailure` and leave rows, journals, heads and registry byte-identical.
    @Test(arguments: [HiddenHistoryOperation.deleteAccount, .deletePassword])
    func sameCountReplayOfOldTrashCiphertextFailsClosed(_ operation: HiddenHistoryOperation) async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [victim, bystander], historyRows: 4, moves: 3) { f in
            let current = try f.moveRevisions(in: f.trashID, owner: victim.id)
            let saved = f.firstDeleteTrashHistory.filter { $0.kind == .revision && $0.ownerID == victim.id }
            let replayed = try #require(saved.first { old in current.contains { $0.recordID == old.recordID && $0.sealed != old.sealed } })
            _ = try f.movePlaintext(of: replayed)  // genuine: opens under the Trash key and its own AAD
            let (store, access) = try await f.unlocked()
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            try f.mutate { try StoreTables.putRecord($0, replayed) }
            #expect(try f.moveRevisions(in: f.trashID, owner: victim.id).count == current.count)

            let before = try f.headWriteImage()
            let revisions = try f.moveHeadRevisions()
            let registry = try f.storedRegistry()
            do {
                _ = try await operation.run(store, access, f, snapshot, bystander)
                Issue.record("\(operation) committed over a replayed old Trash ciphertext")
            } catch let error as CredentialStoreError {
                guard case .integrityFailure = error else {
                    Issue.record("expected integrityFailure, got \(error)")
                    return
                }
            }
            #expect(try f.headWriteImage() == before)
            #expect(try f.moveHeadRevisions() == revisions)
            #expect(try f.storedRegistry().mac == registry.mac)
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: bystander.id) == 0)
        }
    }

    /// The delete's verification scratch (attached before `BEGIN IMMEDIATE`) is detached and unlinked on success.
    @Test func deleteLeavesNoScratchFile() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 2) { f in
            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                _ = try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: snapshot.revision, using: access)
            }
            let scratch = VerificationScratch.directory(in: f.directory)
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        }
    }
}
