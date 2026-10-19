// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Undo (spec §11.3b) as the store and manager do it: one commit with the cause `undo` puts back what an earlier action changed.
// Test-only in-memory unlock keys and synthetic credentials; nothing here is evidence of Apple provider behavior.

@MainActor
struct VaultUndoTests {
    private struct State {
        let accounts: [CredentialAccount]
        let stamps: [UUID: AccountStamp]
        let revision: UInt64
        let epoch: UInt64

        func account(_ id: UUID) -> CredentialAccount? {
            accounts.first { $0.id == id }
        }
    }

    private func account(
        _ username: String = "ada", _ password: String? = "pw", on origin: String = "https://example.test", id: UUID = UUID()
    ) -> CredentialAccount {
        VaultFixtures.account(id: id, username: username, password: password, origin: origin)
    }

    private func read(_ vault: FixtureVault) async throws -> State {
        let snapshot = try await vault.manager.snapshot()
        let epoch = try #require(vault.manager.authorizationEpoch)
        return State(accounts: snapshot.accounts, stamps: snapshot.stamps, revision: snapshot.revision, epoch: epoch)
    }

    /// What the page does for Move to Trash: the per-account write with the stamps it read.
    @discardableResult
    private func moveToTrash(_ ids: [UUID], in vault: FixtureVault) async throws -> State {
        let state = try await read(vault)
        var removing: [UUID: AccountStamp] = [:]
        for id in ids {
            let stamp = try #require(state.stamps[id])
            removing[id] = stamp
        }
        _ = try await vault.manager.commitAccounts([], removing: removing, authorizedEpoch: state.epoch)
        return try await read(vault)
    }

    private func trashedIDs(_ vault: FixtureVault) async throws -> [UUID] {
        try await vault.manager.trashPage(after: nil).items.map(\.ownerID)
    }

    // MARK: Move to Trash

    @Test func undoOfMoveToTrashRestoresEveryAccountWithItsHistoryInOneCommit() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let first = account("ada", "one")
            var second = account("grace", "two", on: "https://b.example.test")
            try await VaultManagerFixture.save([first, second], in: vault)
            second.password = "two-b"
            try await VaultManagerFixture.save([first, second], in: vault)
            let trashed = try await moveToTrash([first.id, second.id], in: vault)
            #expect(trashed.accounts.isEmpty)
            #expect(try await vault.manager.trashPage(after: nil).items.count == 2)

            let receipt = try await vault.manager.undo(
                writes: [], returning: [.account(first.id), .account(second.id)], removing: [:], authorizedEpoch: trashed.epoch
            )

            #expect(receipt.revision == trashed.revision + 1, "one commit for both accounts")
            let restored = try await read(vault)
            #expect(Set(restored.accounts.map(\.id)) == [first.id, second.id])
            #expect(restored.account(second.id)?.password == "two-b")
            #expect(try await vault.manager.trashPage(after: nil).items.isEmpty)
            #expect(try await vault.manager.revisionPage(accountID: second.id, after: nil).items.count == 1, "its history came back with it")
        }
    }

    // MARK: Merge

    @Test func undoOfMergeReturnsTheSurvivorAndTheAbsorbedItemsAtomically() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let keeper = account("ada", "keep")
            var other = account("ada", "take")
            other.totp = VaultFixtures.totp()
            try await VaultManagerFixture.save([keeper, other], in: vault)
            let before = try await read(vault)
            let stored = try #require(before.account(keeper.id))
            let absorbed = try #require(before.account(other.id))
            var picks = try #require(CredentialMerge.defaultPicks(for: [stored, absorbed], survivor: keeper.id))
            picks.login = other.id
            picks.code = other.id
            let merged = try CredentialMerge.merged([stored, absorbed], picks: picks)
            _ = try await vault.manager.commit([merged], expectedRevision: before.revision, authorizedEpoch: before.epoch, cause: "merge")
            let after = try await read(vault)
            #expect(after.accounts.map(\.id) == [keeper.id])
            #expect(after.account(keeper.id)?.mergedFrom?.map(\.accountID) == [other.id])
            let stamp = try #require(after.stamps[keeper.id])

            let receipt = try await vault.manager.undo(
                writes: [AccountWrite(accountID: keeper.id, expected: .stamp(stamp), replacement: stored)],
                returning: [.account(other.id)], removing: [:], authorizedEpoch: after.epoch
            )

            #expect(receipt.revision == after.revision + 1, "one commit")
            let undone = try await read(vault)
            var survivor = try #require(undone.account(keeper.id))
            #expect(survivor.mergedFrom == nil)
            survivor.modifiedAt = stored.modifiedAt
            #expect(survivor == stored, "the survivor is as it was before the merge")
            #expect(undone.account(other.id)?.password == "take")
            #expect(undone.account(other.id)?.totp == absorbed.totp)
            #expect(try await trashedIDs(vault).isEmpty)
        }
    }

    @Test func undoOfMergeLeavesNoPasskeyOrCodeInTrash() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let keeper = account("ada", "keep")
            var other = account("ada", nil)
            other.passkeys = [try VaultFixtures.passkey(rpID: "example.test", credentialID: Data(repeating: 7, count: 32))]
            other.totp = VaultFixtures.totp()
            try await VaultManagerFixture.save([keeper, other], in: vault)
            let before = try await read(vault)
            let stored = try #require(before.account(keeper.id))
            let absorbed = try #require(before.account(other.id))
            var picks = try #require(CredentialMerge.defaultPicks(for: [stored, absorbed], survivor: keeper.id))
            picks.code = other.id
            let merged = try CredentialMerge.merged([stored, absorbed], picks: picks)
            #expect(merged.passkeys.count == 1 && merged.totp != nil)
            _ = try await vault.manager.commit([merged], expectedRevision: before.revision, authorizedEpoch: before.epoch, cause: "merge")
            let after = try await read(vault)
            let stamp = try #require(after.stamps[keeper.id])

            _ = try await vault.manager.undo(
                writes: [AccountWrite(accountID: keeper.id, expected: .stamp(stamp), replacement: stored)],
                returning: [.account(other.id)], removing: [:], authorizedEpoch: after.epoch
            )

            let undone = try await read(vault)
            #expect(undone.account(keeper.id)?.passkeys.isEmpty == true)
            #expect(undone.account(keeper.id)?.totp == nil)
            #expect(undone.account(other.id)?.passkeys == absorbed.passkeys)
            #expect(undone.account(other.id)?.totp == absorbed.totp)
            #expect(try await vault.manager.trashPage(after: nil).items.isEmpty, "the passkey and the code exist once, with their own item")
        }
    }

    // MARK: Edit

    @Test func undoOfAnEditPutsTheOldValuesBackAsNewRevisions() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let original = account("ada", "old")
            try await VaultManagerFixture.save([original], in: vault)
            let before = try #require(try await read(vault).account(original.id))
            var edited = before
            edited.password = "new"
            try await VaultManagerFixture.save([edited], in: vault)
            let after = try await read(vault)
            let stamp = try #require(after.stamps[original.id])

            let receipt = try await vault.manager.undo(
                writes: [AccountWrite(accountID: original.id, expected: .stamp(stamp), replacement: before)],
                returning: [], removing: [:], authorizedEpoch: after.epoch
            )

            #expect(receipt.revision == after.revision + 1)
            #expect(try await read(vault).account(original.id)?.password == "old")
            let revisions = try await vault.manager.revisionValuePage(accountID: original.id, after: nil).items
            #expect(revisions.count == 2, "the edit kept the old value, the undo kept the new one")
            #expect(revisions.first?.item.cause == CredentialChangeCause.undo, "newest first, written by the undo")
            #expect(revisions.map(\.item.cause).filter { $0 == "undo" }.count == 1)
        }
    }

    @Test func undoOfAnEditThatRemovedAPasskeyBringsTheSamePasskeyBackFromTrash() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            var original = account("ada", "pw")
            original.passkeys = [try VaultFixtures.passkey()]
            original.totp = VaultFixtures.totp()
            try await VaultManagerFixture.save([original], in: vault)
            let before = try #require(try await read(vault).account(original.id))
            var edited = before
            edited.passkeys = []
            edited.totp = nil
            let removed = try CredentialDiff.plan(old: [before], new: [edited]).removals
            #expect(removed.count == 2)
            try await VaultManagerFixture.save([edited], in: vault)
            let after = try await read(vault)
            #expect(try await vault.manager.trashPage(after: nil).items.count == 2)
            let stamp = try #require(after.stamps[original.id])

            _ = try await vault.manager.undo(
                writes: [AccountWrite(accountID: original.id, expected: .stamp(stamp), replacement: before)],
                returning: removed, removing: [:], authorizedEpoch: after.epoch
            )

            let restored = try #require(try await read(vault).account(original.id))
            #expect(restored.passkeys == before.passkeys, "the same passkey, once")
            #expect(restored.totp == before.totp)
            #expect(try await vault.manager.trashPage(after: nil).items.isEmpty)
        }
    }

    @Test func undoOfAnEditThatClearedThePasswordAndChangedTheUsernameRestoresBoth() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let original = account("ada", "pw")
            try await VaultManagerFixture.save([original], in: vault)
            let before = try #require(try await read(vault).account(original.id))
            var edited = before
            edited.password = nil
            edited.username = "grace"
            edited.totp = VaultFixtures.totp()
            let removed = try CredentialDiff.plan(old: [before], new: [edited]).removals
            try await VaultManagerFixture.save([edited], in: vault)
            let after = try await read(vault)
            let stamp = try #require(after.stamps[original.id])

            _ = try await vault.manager.undo(
                writes: [AccountWrite(accountID: original.id, expected: .stamp(stamp), replacement: before)],
                returning: removed, removing: [:], authorizedEpoch: after.epoch
            )

            let restored = try #require(try await read(vault).account(original.id))
            #expect(restored.username == "ada" && restored.password == "pw")
            #expect(restored.totp == nil, "the code the edit added is gone again")
            let trash = try await vault.manager.trashPage(after: nil).items
            #expect(trash.map(\.subject) == [.totp], "it went to Trash, where it can be restored, and the password is not there")
        }
    }

    // MARK: Add and Restore

    @Test func undoOfAnAddMovesTheNewCredentialToTrash() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let kept = account("ada", "one")
            try await VaultManagerFixture.save([kept], in: vault)
            let added = account("grace", "two", on: "https://b.example.test")
            try await VaultManagerFixture.save([kept, added], in: vault)
            let after = try await read(vault)
            let stamp = try #require(after.stamps[added.id])

            _ = try await vault.manager.undo(writes: [], returning: [], removing: [added.id: stamp], authorizedEpoch: after.epoch)

            #expect(try await read(vault).accounts.map(\.id) == [kept.id])
            #expect(try await trashedIDs(vault) == [added.id])
        }
    }

    @Test func undoOfARestoredCredentialMovesItBackToTrash() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let first = account("ada", "one")
            let second = account("grace", "two", on: "https://b.example.test")
            try await VaultManagerFixture.save([first, second], in: vault)
            try await moveToTrash([second.id], in: vault)
            let entry = try #require(try await vault.manager.trashPage(after: nil).items.first)
            let trashed = try await read(vault)
            _ = try await vault.manager.undelete(entryID: entry.id, expectedRevision: trashed.revision, authorizedEpoch: trashed.epoch)
            let restored = try await read(vault)
            #expect(restored.accounts.count == 2)
            let stamp = try #require(restored.stamps[second.id])

            _ = try await vault.manager.undo(writes: [], returning: [], removing: [second.id: stamp], authorizedEpoch: restored.epoch)

            #expect(try await read(vault).accounts.map(\.id) == [first.id])
            #expect(try await trashedIDs(vault) == [second.id])
        }
    }

    @Test func undoOfARestoredPasswordMovesItBackToTrash() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            var original = account("ada", "pw")
            original.totp = VaultFixtures.totp()
            try await VaultManagerFixture.save([original], in: vault)
            let before = try #require(try await read(vault).account(original.id))
            var cleared = before
            cleared.totp = nil
            try await VaultManagerFixture.save([cleared], in: vault)
            let entry = try #require(try await vault.manager.trashPage(after: nil).items.first)
            let owner = try await read(vault)
            let withoutCode = try #require(owner.account(original.id))
            _ = try await vault.manager.undelete(entryID: entry.id, expectedRevision: owner.revision, authorizedEpoch: owner.epoch)
            let restored = try await read(vault)
            #expect(restored.account(original.id)?.totp == before.totp)
            let stamp = try #require(restored.stamps[original.id])

            _ = try await vault.manager.undo(
                writes: [AccountWrite(accountID: original.id, expected: .stamp(stamp), replacement: withoutCode)],
                returning: [], removing: [:], authorizedEpoch: restored.epoch
            )

            #expect(try await read(vault).account(original.id)?.totp == nil)
            #expect(try await vault.manager.trashPage(after: nil).items.count == 1, "the code is in Trash again")
        }
    }

    // MARK: Refusals write nothing

    @Test func anAccountChangedSinceTheActionRefusesTheUndoAndWritesNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let original = account("ada", "old")
            try await VaultManagerFixture.save([original], in: vault)
            let before = try #require(try await read(vault).account(original.id))
            var edited = before
            edited.password = "new"
            try await VaultManagerFixture.save([edited], in: vault)
            let after = try await read(vault)
            let stamp = try #require(after.stamps[original.id])
            // A change this undo does not know about.
            var foreign = try #require(after.account(original.id))
            foreign.password = "foreign"
            try await VaultManagerFixture.save([foreign], in: vault)
            let latest = try await read(vault)

            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await vault.manager.undo(
                    writes: [AccountWrite(accountID: original.id, expected: .stamp(stamp), replacement: before)],
                    returning: [], removing: [:], authorizedEpoch: latest.epoch
                )
            }

            let unchanged = try await read(vault)
            #expect(unchanged.revision == latest.revision)
            #expect(unchanged.account(original.id)?.password == "foreign")
        }
    }

    @Test func anUndoWhoseTrashCopyWasPurgedWritesNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let keep = account("ada", "one")
            let gone = account("grace", "two", on: "https://b.example.test")
            try await VaultManagerFixture.save([keep, gone], in: vault)
            let trashed = try await moveToTrash([gone.id], in: vault)
            let entry = try #require(try await vault.manager.trashPage(after: nil).items.first)
            _ = try await vault.manager.purge(entryIDs: [entry.id], emptyAll: false, in: VaultManagerFixture.anchor())
            let purged = try await read(vault)

            await #expect(throws: CredentialVaultError.invalidData) {
                _ = try await vault.manager.undo(writes: [], returning: [.account(gone.id)], removing: [:], authorizedEpoch: trashed.epoch)
            }

            #expect(try await read(vault).revision == purged.revision)
            #expect(try await read(vault).accounts.map(\.id) == [keep.id])
        }
    }

    @Test func undoAfterALockIsRefused() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let first = account("ada", "one")
            try await VaultManagerFixture.save([first], in: vault)
            let trashed = try await moveToTrash([first.id], in: vault)
            vault.manager.lock(reason: .manual)

            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await vault.manager.undo(writes: [], returning: [.account(first.id)], removing: [:], authorizedEpoch: trashed.epoch)
            }
            try await VaultManagerFixture.unlock(vault)
            #expect(try await read(vault).accounts.isEmpty)
        }
    }

    // MARK: Collision rules

    @Test func undoRestoresADuplicateUsernameOnTheSameSite() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let first = account("ada", "one")
            let twin = account("ada", "two")
            try await VaultManagerFixture.save([first, twin], in: vault)
            let trashed = try await moveToTrash([twin.id], in: vault)
            let entry = try #require(try await vault.manager.trashPage(after: nil).items.first)
            // The ordinary Restore refuses a second login for the same username and site; Undo puts back what the user just had.
            #expect(try await vault.manager.previewUndelete(entryID: entry.id).block == .originUsernameOverlap)

            _ = try await vault.manager.undo(writes: [], returning: [.account(twin.id)], removing: [:], authorizedEpoch: trashed.epoch)

            #expect(Set(try await read(vault).accounts.map(\.id)) == [first.id, twin.id])
        }
    }

    @Test func undoIsNotBlockedBySharingAnExportAccountIdWhileRestoreIs() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            var first = account("ada", "one")
            first.exchangeAccountID = Data([5])
            first.exchangeItemID = Data([1])
            var second = account("grace", "two", on: "https://b.example.test")
            second.exchangeAccountID = Data([5])
            second.exchangeItemID = Data([2])
            try await VaultManagerFixture.save([first, second], in: vault)
            let trashed = try await moveToTrash([second.id], in: vault)
            let entry = try #require(try await vault.manager.trashPage(after: nil).items.first)
            #expect(try await vault.manager.previewUndelete(entryID: entry.id).block == .exchangeIDCollision)

            _ = try await vault.manager.undo(writes: [], returning: [.account(second.id)], removing: [:], authorizedEpoch: trashed.epoch)

            #expect(Set(try await read(vault).accounts.map(\.id)) == [first.id, second.id])
        }
    }

    @Test func undoIsStillBlockedByAnExporterItemThatIsLiveAgain() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            var gone = account("ada", "one")
            gone.exchangeAccountID = Data([5])
            gone.exchangeItemID = Data([1])
            try await VaultManagerFixture.save([gone], in: vault)
            let trashed = try await moveToTrash([gone.id], in: vault)
            var again = account("ada", "one", on: "https://b.example.test")
            again.exchangeAccountID = Data([5])
            again.exchangeItemID = Data([1])
            try await VaultManagerFixture.save([again], in: vault)
            let current = try await read(vault)

            await #expect(throws: CredentialStoreError.undeleteBlocked(.exchangeIDCollision)) {
                _ = try await vault.manager.undo(writes: [], returning: [.account(gone.id)], removing: [:], authorizedEpoch: current.epoch)
            }

            #expect(trashed.accounts.isEmpty)
            #expect(try await read(vault).revision == current.revision)
        }
    }

    @Test func undoIsStillBlockedByAPasskeyThatIsLiveAgain() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            var gone = account("ada", "one")
            let passkey = try VaultFixtures.passkey()
            gone.passkeys = [passkey]
            try await VaultManagerFixture.save([gone], in: vault)
            try await moveToTrash([gone.id], in: vault)
            var other = account("grace", "two", on: "https://b.example.test")
            other.passkeys = [try TrashFixtures.clone(of: passkey)]
            try await VaultManagerFixture.save([other], in: vault)
            let current = try await read(vault)

            await #expect(throws: CredentialStoreError.undeleteBlocked(.passkeyCollision)) {
                _ = try await vault.manager.undo(writes: [], returning: [.account(gone.id)], removing: [:], authorizedEpoch: current.epoch)
            }

            #expect(try await read(vault).revision == current.revision)
            #expect(try await trashedIDs(vault) == [gone.id])
        }
    }

    @Test func undoIsStillBlockedByAnAccountWithTheSameId() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let gone = account("ada", "one")
            try await VaultManagerFixture.save([gone], in: vault)
            try await moveToTrash([gone.id], in: vault)
            // A live account that took the removed one's id: the Trash copy must not overwrite it.
            try await VaultManagerFixture.save([account("grace", "two", on: "https://b.example.test", id: gone.id)], in: vault)
            let current = try await read(vault)

            await #expect(throws: CredentialStoreError.undeleteBlocked(.idCollision)) {
                _ = try await vault.manager.undo(writes: [], returning: [.account(gone.id)], removing: [:], authorizedEpoch: current.epoch)
            }
        }
    }

    // MARK: Provenance

    @Test func undoRecordsCauseUndoOnItsRevisions() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
            let vault = vaults[0]
            let original = account("ada", "old")
            try await VaultManagerFixture.save([original], in: vault)
            let before = try #require(try await read(vault).account(original.id))
            var edited = before
            edited.password = "new"
            edited.displayName = "Work"
            try await VaultManagerFixture.save([edited], in: vault)
            let after = try await read(vault)
            let stamp = try #require(after.stamps[original.id])

            _ = try await vault.manager.undo(
                writes: [AccountWrite(accountID: original.id, expected: .stamp(stamp), replacement: before)],
                returning: [], removing: [:], authorizedEpoch: after.epoch
            )

            let revisions = try await vault.manager.revisionPage(accountID: original.id, after: nil).items
            let undone = revisions.filter { $0.cause == "undo" }
            #expect(Set(undone.map(\.subject)) == [.password, .metadata], "every part the undo superseded")
            #expect(CredentialChangeCause.text(for: "undo") == String(localized: "Changed by Undo"))
        }
    }
}
