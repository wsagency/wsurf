// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

// Task 7: the public `commit` boundary. State is read back from the file (`CommitProbe`, `StoreTables`, the fixture) and
// through the public snapshot; `f.verify()` runs V1-V5 on the stored pair after every write.

nonisolated enum CommitDeniedAccess: CaseIterable, Sendable {
    /// The granted access, revoked.
    case revoked
    /// An access of the same profile whose epoch no unlock ever granted on this store.
    case otherEpoch
    case foreignProfile
}

nonisolated enum CommitDuplicate: CaseIterable, Sendable {
    case repeatedAccountID
    /// The very same account twice (byte-identical entries).
    case identicalAccountTwice
    case repeatedPasskeyID
}

nonisolated enum CommitLimit: CaseIterable, Sendable {
    case accounts, accountBytes
}

struct VaultCommitTests {
    // MARK: no-op and persist-only

    @Test func trueNoOpWritesNothing() async throws {
        let rich = try VaultFixtures.richAccount()
        let plain = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [rich, plain], historyRows: 2) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let image = try f.headWriteImage()
            let registry = try f.storedRegistry()

            let receipt = try await store.commit(
                vaultID: f.vaultID, before.accounts, expectedRevision: before.revision, cause: "ignored on a no-op", using: access
            )

            #expect(receipt.revision == before.revision)
            #expect(try f.headWriteImage() == image)
            let after = try f.storedRegistry()
            #expect(after.revision == registry.revision)
            #expect(after.catalog == registry.catalog)
            #expect(after.mac == registry.mac)
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(snapshot.revision == before.revision)
            #expect(snapshot.stamps == before.stamps)
            try f.verify()
        }
    }

    @Test func canonicallyEquivalentButByteDifferentPasswordIsNotANoOp() async throws {
        let composed = "\u{00E9}", decomposed = "e\u{301}"
        #expect(composed == decomposed)  // Swift `==` is canonical equivalence ...
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))  // ... the persisted bytes differ.
        let account = VaultFixtures.account(username: "ada", password: composed)
        try await VaultStoreFixture.with(accounts: [account]) { f in
            let probe = CommitProbe(f: f)
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let registry = try f.storedRegistry()
            let journalBefore = try f.journalRows(of: f.vaultID).count

            let receipt = try await store.commit(
                vaultID: f.vaultID,
                commitEditing(before.accounts, account.id) { $0.password = decomposed },
                expectedRevision: before.revision,
                cause: nil,
                using: access
            )

            #expect(receipt.revision == before.revision + 1)
            #expect(try f.headRevision(of: f.vaultID) == before.revision + 1)
            #expect(try f.storedRegistry().revision == registry.revision + 1)
            try probe.expectRegistryMatchesStore()

            // The stored live row holds the new bytes exactly (not the old composed spelling).
            let live = try probe.liveRow(account.id)
            #expect(live.account.password?.utf8.elementsEqual(decomposed.utf8) == true)
            #expect(live.plaintext.range(of: Data(decomposed.utf8)) != nil)
            #expect(live.plaintext.range(of: Data(composed.utf8)) == nil)
            #expect(live.account.modifiedAt != nil)
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(snapshot.stamps[account.id]?.version == before.stamps[account.id].map { $0.version + 1 })
            #expect(live.version == snapshot.stamps[account.id]?.version)

            // The old password became exactly one `PasswordValue` revision holding the composed bytes.
            let revisions = try f.recordIDs(of: f.vaultID, kind: .revision)
            #expect(revisions.count == 1)
            let stored = try probe.opened(f.vaultID, try #require(revisions.first))
            #expect(stored.row.ownerID == account.id)
            #expect(stored.row.subject == .password)
            #expect(stored.row.version == 1)
            let body = try JSONDecoder().decode(RevisionBody.self, from: stored.plaintext)
            let superseded = try JSONDecoder().decode(PasswordValue.self, from: body.value)
            #expect(superseded.username == "ada")
            #expect(superseded.password?.utf8.elementsEqual(composed.utf8) == true)
            let journal = try f.journalRows(of: f.vaultID)
            #expect(journal.count == journalBefore + 1)
            #expect(journal.last?.transfer == nil)
            #expect(journal.last?.ops.map(\.op) == [.add])
            #expect(journal.last?.ops.map(\.recordID) == revisions)
            try f.verify()
        }
    }

    @Test func persistOnlyChangeBumpsHeadWithoutHistory() async throws {
        let owner = VaultFixtures.account(username: "ada", passkeys: [try VaultFixtures.passkey()])
        let other = VaultFixtures.account(username: "grace", origin: "https://b.example")
        let signedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try await VaultStoreFixture.with(accounts: [owner, other], historyRows: 2) { f in
            let probe = CommitProbe(f: f)
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let image = try f.recordAndJournalImage()
            let headsBefore = try probe.heads()
            let registry = try f.storedRegistry()
            #expect(headsBefore.source.journalSeq >= 1)
            let proposed = commitEditing(before.accounts, owner.id) { $0.passkeys[0].lastSignedAt = signedAt }

            let receipt = try await store.commit(vaultID: f.vaultID, proposed, expectedRevision: before.revision, cause: nil, using: access)

            #expect(receipt.revision == before.revision + 1)
            #expect(try f.headRevision(of: f.vaultID) == before.revision + 1)
            #expect(try f.headRevision(of: f.trashID) == headsBefore.trash.revision)
            #expect(try f.storedRegistry().revision == registry.revision + 1)
            try probe.expectRegistryMatchesStore()

            // Only the live row was rewritten: no revision, journal or history row, no counter moved.
            #expect(try probe.rowsChanged(since: image) == [probe.recordKey(f.vaultID, owner.id)])
            let headsAfter = try probe.heads()
            #expect(headsAfter.source.historyCounts == headsBefore.source.historyCounts)
            #expect(headsAfter.source.journalSeq == headsBefore.source.journalSeq)
            #expect(headsAfter.source.chainTip == headsBefore.source.chainTip)
            #expect(headsAfter.trash == headsBefore.trash)

            // The head's catalog entry for the rewritten row matches the stored bytes; the other entries are untouched.
            let stored = try probe.opened(f.vaultID, owner.id)
            let entry = try #require(headsAfter.source.liveCatalog.first { $0.recordID == owner.id })
            #expect(entry.digest == StoreSeal.digest(stored.row.sealed))
            #expect(entry.version == stored.row.version)
            #expect(entry != headsBefore.source.liveCatalog.first { $0.recordID == owner.id })
            let untouched = { (head: VaultHead) in head.liveCatalog.filter { $0.recordID != owner.id } }
            #expect(untouched(headsAfter.source) == untouched(headsBefore.source))

            // The content changed, `modifiedAt` did not.
            let live = try probe.liveRow(owner.id)
            #expect(live.account.passkeys.first?.lastSignedAt == signedAt)
            #expect(live.account.modifiedAt == nil)
            let expected = try #require(proposed.first { $0.id == owner.id })
            #expect(try VaultFixtures.sortedJSON(live.account) == VaultFixtures.sortedJSON(expected))
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.revision == before.revision + 1)
            #expect(after.stamps[owner.id]?.digest == entry.digest)
            #expect(after.stamps[other.id] == before.stamps[other.id])
            try f.verify()
        }
    }

    /// What a snapshot decoded is remembered for the next read, never instead of it: a live row changed on disk after the snapshot
    /// still fails the next write of another account, whole-payload or per-account, and nothing is written.
    @Test func aRowChangedAfterASnapshotStillFailsTheNextWrite() async throws {
        let ada = VaultFixtures.account(username: "ada")
        let grace = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [ada, grace], historyRows: 1) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let row = try f.storedRecord(f.vaultID, grace.id)
            try f.mutate { db in
                try db.execute(
                    sql: "UPDATE record SET sealed = ? WHERE vaultID = ? AND recordID = ?",
                    arguments: [VaultStoreFixture.flipped(row.sealed), f.vaultID.lowerText, grace.id.lowerText]
                )
            }
            let image = try f.headWriteImage()
            let edited = commitEditing(before.accounts, ada.id) { $0.password = "changed" }

            let whole = await store.vaultCommitFailure(vaultID: f.vaultID, edited, expectedRevision: before.revision, using: access)
            var perAccount: (any Error)?
            do {
                let replacement = try #require(edited.first { $0.id == ada.id })
                let stamp = try #require(before.stamps[ada.id])
                _ = try await store.commitAccounts(
                    vaultID: f.vaultID, [AccountWrite(accountID: ada.id, expected: .stamp(stamp), replacement: replacement)], cause: nil,
                    using: access
                )
            } catch {
                perAccount = error
            }

            #expect(whole as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            #expect(perAccount as? CredentialStoreError == .integrityFailure(vaultOrdinal: 1))
            #expect(try f.headWriteImage() == image)
        }
    }

    /// The handoff hash is local evidence: it persists across a reopen as a persist-only commit (no history, no `modifiedAt`,
    /// no base), and a wrong-length hash is refused before anything is written.
    @Test func exportHandoffHashPersistsAsPersistOnlyAndRejectsBadLength() async throws {
        let owner = VaultFixtures.account(username: "ada", passkeys: [try VaultFixtures.passkey()])
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            let probe = CommitProbe(f: f)
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let hash = Data((0..<32).map(UInt8.init))

            let wrong = commitEditing(before.accounts, owner.id) { $0.passwordEvents = CredentialEvents(lastExportHandoffHash: Data(repeating: 1, count: 31)) }
            let image = try f.headWriteImage()
            let failure = await store.vaultCommitFailure(vaultID: f.vaultID, wrong, expectedRevision: before.revision, using: access)
            #expect(failure as? CredentialVaultError == .invalidData)
            #expect(try f.headWriteImage() == image)

            let headsBefore = try probe.heads()
            let proposed = commitEditing(before.accounts, owner.id) {
                $0.passwordEvents = CredentialEvents(lastExportHandoffHash: hash)
                $0.passkeys[0].events = CredentialEvents(lastExportHandoffHash: hash)
            }
            let receipt = try await store.commit(vaultID: f.vaultID, proposed, expectedRevision: before.revision, cause: nil, using: access)
            #expect(receipt.revision == before.revision + 1)
            #expect(try probe.heads().source.historyCounts == headsBefore.source.historyCounts)

            let (fresh, freshAccess) = try await f.reopenedStore(proving: f.proof)
            let reloaded = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            let account = try #require(reloaded.accounts.first { $0.id == owner.id })
            #expect(account.passwordEvents?.lastExportHandoffHash == hash)
            #expect(account.passkeys[0].events?.lastExportHandoffHash == hash)
            #expect(account.modifiedAt == nil)
            #expect(account.passwordBase == nil)
            try f.verify()
        }
    }

    @Test func twentyTOTPCopiesAndFiveSignInsCreateZeroRevisions() async throws {
        var owner = VaultFixtures.account(username: "ada", passkeys: [try VaultFixtures.passkey()])
        owner.totp = VaultFixtures.totp()
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            let probe = CommitProbe(f: f)
            let (store, access) = try await f.unlocked()
            let start = try await store.snapshot(vaultID: f.vaultID, using: access)
            let image = try f.recordAndJournalImage()
            let writeImage = try f.headWriteImage()
            let revisionRows = try f.recordIDs(of: f.vaultID, kind: .revision)
            let journalCount = try f.journalRows(of: f.vaultID).count
            let headsBefore = try probe.heads()
            let registry = try f.storedRegistry()

            // A TOTP copy only reads the account: the unchanged list comes back as a commit and writes nothing.
            for _ in 0..<20 {
                let current = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.commit(
                    vaultID: f.vaultID, current.accounts, expectedRevision: start.revision, cause: nil, using: access
                )
                #expect(receipt.revision == start.revision)
            }
            #expect(try f.headWriteImage() == writeImage)
            #expect(try f.headRevision(of: f.vaultID) == start.revision)
            #expect(try f.storedRegistry().revision == registry.revision)
            #expect(try probe.rowsChanged(since: image).isEmpty)

            // A sign-in is a persist-only commit: head and registry move, history does not.
            var revision = start.revision
            for signIn in 1...5 {
                let current = try await store.snapshot(vaultID: f.vaultID, using: access)
                let date = Date(timeIntervalSinceReferenceDate: Double(signIn) * 1_000)
                let proposed = commitEditing(current.accounts, owner.id) { $0.passkeys[0].lastSignedAt = date }
                let receipt = try await store.commit(vaultID: f.vaultID, proposed, expectedRevision: revision, cause: nil, using: access)
                #expect(receipt.revision == revision + 1)
                revision = receipt.revision
            }

            #expect(revision == start.revision + 5)
            #expect(try f.headRevision(of: f.vaultID) == start.revision + 5)
            #expect(try f.storedRegistry().revision == registry.revision + 5)
            #expect(try f.recordIDs(of: f.vaultID, kind: .revision) == revisionRows)
            #expect(try f.journalRows(of: f.vaultID).count == journalCount)
            #expect(try probe.rowsChanged(since: image) == [probe.recordKey(f.vaultID, owner.id)])
            let headsAfter = try probe.heads()
            #expect(headsAfter.source.historyCounts == headsBefore.source.historyCounts)
            #expect(headsAfter.source.chainTip == headsBefore.source.chainTip)
            let live = try probe.liveRow(owner.id)
            #expect(live.account.passkeys.first?.lastSignedAt == Date(timeIntervalSinceReferenceDate: 5_000))
            #expect(live.account.modifiedAt == nil)
            try probe.expectRegistryMatchesStore()
            try f.verify()
        }
    }

    // MARK: stale revisions and other vaults

    @Test(arguments: StalePolicyRevision.allCases)
    func staleRevisionIsRefused(_ staleness: StalePolicyRevision) async throws {
        let first = VaultFixtures.account(username: "ada")
        let second = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [first, second], historyRows: 1) { f in
            let (store, access) = try await f.unlocked()
            var current = try await store.snapshot(vaultID: f.vaultID, using: access)
            let revision = current.revision
            let stale: UInt64
            switch staleness {
            case .behind:
                stale = revision - 1
            case .ahead:
                stale = revision + 1
            case .replayed:
                let edited = commitEditing(current.accounts, first.id) { $0.password = "first edit" }
                _ = try await store.commit(vaultID: f.vaultID, edited, expectedRevision: revision, cause: nil, using: access)
                stale = revision
                current = try await store.snapshot(vaultID: f.vaultID, using: access)
            }
            let image = try f.headWriteImage()
            let proposed = commitEditing(current.accounts, second.id) { $0.password = "second edit" }

            let error = await store.vaultCommitFailure(vaultID: f.vaultID, proposed, expectedRevision: stale, using: access)

            #expect(error as? CredentialVaultError == .staleRevision, "\(staleness)")
            #expect(try f.headWriteImage() == image)
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.revision == current.revision)
            #expect(after.accounts.first { $0.id == second.id }?.password == second.password)
            try f.verify()
        }
    }

    @Test func otherVaultsCommitDoesNotInvalidateThisVault() async throws {
        let mine = VaultFixtures.account(username: "ada")
        let theirs = VaultFixtures.account(username: "bea", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [mine], secondVault: true, secondAccounts: [theirs]) { f in
            let secondID = try #require(f.secondVaultID)
            let store = f.makeStore()
            let accessA = f.makeAccess(epoch: 1), accessB = f.makeAccess(epoch: 2)
            #expect(await unlockResult(f, store, vault: f.vaultID, access: accessA) == nil)
            #expect(await unlockResult(f, store, vault: secondID, access: accessB) == nil)
            let snapA = try await store.snapshot(vaultID: f.vaultID, using: accessA)
            let snapB = try await store.snapshot(vaultID: secondID, using: accessB)
            let registry = try f.storedRegistry()

            // A commit on vault B lands between A's snapshot and A's commit.
            let receiptB = try await store.commit(
                vaultID: secondID,
                commitEditing(snapB.accounts, theirs.id) { $0.password = "b edit" },
                expectedRevision: snapB.revision,
                cause: nil,
                using: accessB
            )
            #expect(receiptB.revision == snapB.revision + 1)
            #expect(try f.headRevision(of: f.vaultID) == snapA.revision)
            #expect(try f.storedRegistry().revision == registry.revision + 1)

            let receiptA = try await store.commit(
                vaultID: f.vaultID,
                commitEditing(snapA.accounts, mine.id) { $0.password = "a edit" },
                expectedRevision: snapA.revision,
                cause: nil,
                using: accessA
            )

            #expect(receiptA.revision == snapA.revision + 1)
            #expect(try f.headRevision(of: f.vaultID) == snapA.revision + 1)
            #expect(try f.headRevision(of: secondID) == receiptB.revision)
            #expect(try f.storedRegistry().revision == registry.revision + 2)
            try CommitProbe(f: f).expectRegistryMatchesStore()
            let afterB = try await store.snapshot(vaultID: secondID, using: accessB)
            #expect(afterB.accounts.first?.password == "b edit")
            let afterA = try await store.snapshot(vaultID: f.vaultID, using: accessA)
            #expect(afterA.accounts.first?.password == "a edit")
            try f.verify()
        }
    }

    @Test func commitOnlyBumpsItsOwnVaultsRegistryEntry() async throws {
        let mine = VaultFixtures.account(username: "ada")
        let theirs = VaultFixtures.account(username: "bea", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [mine], secondVault: true, secondAccounts: [theirs]) { f in
            let probe = CommitProbe(f: f)
            let secondID = try #require(f.secondVaultID), secondTrashID = try #require(f.secondTrashID)
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let registry = try f.storedRegistry()
            let secondRows = try probe.rows(of: secondID).merging(probe.rows(of: secondTrashID)) { first, _ in first }
            let secondRevision = try f.headRevision(of: secondID)

            let receipt = try await store.commit(
                vaultID: f.vaultID,
                commitEditing(before.accounts, mine.id) { $0.password = "edit" },
                expectedRevision: before.revision,
                cause: nil,
                using: access
            )

            #expect(receipt.revision == before.revision + 1)
            let after = try f.storedRegistry()
            #expect(after.revision == registry.revision + 1)
            #expect(try f.registryEntries(except: f.vaultID) == registry.catalog.vaults.filter { $0.vaultID != f.vaultID })
            let entry = try f.registryEntry(of: f.vaultID)
            let head = try #require(try f.read { try StoreTables.head($0, vaultID: f.vaultID) })
            #expect(entry.headRevision == before.revision + 1)
            #expect(entry.headDigest == StoreSeal.digest(head.sealed))
            #expect(entry.headDigest != registry.catalog.vaults.first { $0.vaultID == f.vaultID }?.headDigest)
            try probe.expectRegistryMatchesStore()
            #expect(try f.headRevision(of: secondID) == secondRevision)
            let secondRowsAfter = try probe.rows(of: secondID).merging(probe.rows(of: secondTrashID)) { first, _ in first }
            #expect(secondRowsAfter == secondRows)
            try f.verify()
        }
    }

    // MARK: scale

    /// A transfer the size of a real Passwords library, read by the real codec and written by the real commit: the checks of the
    /// preview, `apply` and the store agree, so what the codec accepted the store keeps.
    @Test func importOf5000ItemsCommitsToTheStore() async throws {
        let transfer = try ExchangeScale.transfer(items: 5_000)
        let base = StoreSnapshot(vaultID: UUID(), revision: 0, accounts: [], blockedPasswordOrigins: [], stamps: [:])
        let preview = try CredentialExchangeCodec.preview(transfer, against: base)
        let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(imported.count == 5_000)

        try await VaultStoreFixture.with(accounts: [VaultFixtures.account(username: "stored")]) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)

            let receipt = try await store.commit(
                vaultID: f.vaultID, before.accounts + imported, expectedRevision: before.revision, cause: nil, using: access
            )

            #expect(receipt.revision == before.revision + 1)
            #expect(try f.recordIDs(of: f.vaultID, kind: .account).count == 5_001)
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.accounts.count == 5_001)
            #expect(Set(after.accounts.map(\.id)) == Set((before.accounts + imported).map(\.id)))
            #expect(after.accounts.filter { !$0.passkeys.isEmpty }.count == 500)
            #expect(after.accounts.filter { $0.notes != nil }.count == 5_000)
            try f.verify()
        }
    }

    // MARK: limits

    @Test(arguments: CommitLimit.allCases)
    func liveLimitRefusalsNameTheLimit(_ limit: CommitLimit) async throws {
        switch limit {
        case .accounts:
            try await refusesOneAccountOverTheLiveCap()
        case .accountBytes:
            try await refusesAnOversizedAccount()
        }
    }

    private func refusesOneAccountOverTheLiveCap() async throws {
        let stored = (0..<CredentialVaultLimits.accounts).map { VaultFixtures.account(username: "user\($0)", password: "pw\($0)") }
        try await VaultStoreFixture.with(accounts: stored) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(before.accounts.count == CredentialVaultLimits.accounts)

            // Exactly at the cap an edit still commits ...
            let atCap = commitEditing(before.accounts, stored[0].id) { $0.password = "changed" }
            let receipt = try await store.commit(vaultID: f.vaultID, atCap, expectedRevision: before.revision, cause: nil, using: access)
            #expect(receipt.revision == before.revision + 1)
            let image = try f.headWriteImage()

            // ... and one account over it is refused by name, with nothing written.
            let error = await store.vaultCommitFailure(
                vaultID: f.vaultID, atCap + [VaultFixtures.account(username: "one too many")], expectedRevision: receipt.revision, using: access
            )
            #expect(error as? CredentialStoreError == .limit(.accounts))
            #expect(try f.headWriteImage() == image)
            try f.verify()
        }
    }

    private func refusesAnOversizedAccount() async throws {
        let stored = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.with(accounts: [stored], historyRows: 1) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let image = try f.headWriteImage()
            // Each field is within its own bound; together they exceed the cap of one account.
            let big = String(repeating: "x", count: 2_500_000)
            #expect(big.utf8.count * 2 > CredentialVaultLimits.accountBytes)
            let proposed = commitEditing(before.accounts, stored.id) {
                $0.username = big
                $0.displayName = big
            }

            let error = await store.vaultCommitFailure(vaultID: f.vaultID, proposed, expectedRevision: before.revision, using: access)

            #expect(error as? CredentialStoreError == .limit(.accountBytes))
            #expect(try f.headWriteImage() == image)
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.revision == before.revision)
            #expect(after.accounts.first?.username == "ada")
            try f.verify()
        }
    }

    @Test func hugeAccountCountIsRefusedBeforeAnyWrite() async throws {
        let stored = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.with(accounts: [stored], historyRows: 1) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let image = try f.headWriteImage()
            let flood = (0..<CredentialVaultLimits.accounts).map { VaultFixtures.account(username: "flood\($0)") }

            let error = await store.vaultCommitFailure(
                vaultID: f.vaultID, before.accounts + flood, expectedRevision: before.revision, using: access
            )

            #expect(error as? CredentialStoreError == .limit(.accounts))
            #expect(try f.headWriteImage() == image)
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.revision == before.revision)
            #expect(after.accounts.count == 1)
            try f.verify()
        }
    }

    // MARK: blocked origins, access, duplicates

    @Test func commitCopiesBlockedOriginsUnchanged() async throws {
        let blocked = ["https://a.example", "https://b.example"]
        let owner = VaultFixtures.account(username: "ada", passkeys: [try VaultFixtures.passkey()])
        let other = VaultFixtures.account(username: "grace", origin: "https://c.example")
        try await VaultStoreFixture.with(accounts: [owner, other], blockedOrigins: blocked) { f in
            let probe = CommitProbe(f: f)
            let (store, access) = try await f.unlocked()
            let first = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(first.blockedPasswordOrigins == Set(blocked))

            // A semantic commit, then a persist-only commit on top of it.
            let semantic = try await store.commit(
                vaultID: f.vaultID,
                commitEditing(first.accounts, other.id) { $0.password = "edit" },
                expectedRevision: first.revision,
                cause: nil,
                using: access
            )
            #expect(semantic.revision == first.revision + 1)
            #expect(try probe.heads().source.blockedOrigins == blocked)
            let second = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(second.blockedPasswordOrigins == Set(blocked))

            let persistOnly = try await store.commit(
                vaultID: f.vaultID,
                commitEditing(second.accounts, owner.id) { $0.passkeys[0].lastSignedAt = Date(timeIntervalSinceReferenceDate: 1_000) },
                expectedRevision: second.revision,
                cause: nil,
                using: access
            )
            #expect(persistOnly.revision == second.revision + 1)
            let heads = try probe.heads()
            #expect(heads.source.blockedOrigins == blocked)
            #expect(heads.trash.blockedOrigins.isEmpty)

            // A fresh unlock re-reads the set from the rewritten head.
            let (fresh, freshAccess) = try await f.reopenedStore(proving: f.proof)
            let reloaded = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            #expect(reloaded.blockedPasswordOrigins == Set(blocked))
            #expect(reloaded.revision == persistOnly.revision)
            try f.verify()
        }
    }

    @Test(arguments: CommitDeniedAccess.allCases)
    func revokedOrOtherEpochAccessIsRefused(_ fault: CommitDeniedAccess) async throws {
        let first = VaultFixtures.account(username: "ada")
        let second = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [first, second], historyRows: 1) { f in
            let (store, granted) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: granted)
            let denied: VaultAccess
            switch fault {
            case .revoked:
                granted.revoke()
                denied = granted
            case .otherEpoch:
                denied = f.makeAccess(epoch: 2)
            case .foreignProfile:
                denied = f.makeAccess(epoch: 1, profileID: UUID())
            }
            let image = try f.headWriteImage()

            // Refused before the diff runs: an unchanged list is refused just like a real edit.
            let edited = commitEditing(before.accounts, first.id) { $0.password = "edit" }
            for proposed in [before.accounts, edited] {
                let error = await store.vaultCommitFailure(vaultID: f.vaultID, proposed, expectedRevision: before.revision, using: denied)
                #expect(error as? CredentialVaultError == .unauthorized, "\(fault)")
            }

            #expect(try f.headWriteImage() == image)
            if fault != .revoked {
                // The store itself is fine: the granted access still commits.
                let receipt = try await store.commit(
                    vaultID: f.vaultID, edited, expectedRevision: before.revision, cause: nil, using: granted
                )
                #expect(receipt.revision == before.revision + 1)
            }
            try f.verify()
        }
    }

    @Test(arguments: CommitDuplicate.allCases)
    func duplicateIdentitiesAreRefusedAtomically(_ duplicate: CommitDuplicate) async throws {
        let passkey = try VaultFixtures.passkey()
        let owner = VaultFixtures.account(username: "ada", passkeys: [passkey])
        let other = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [owner, other], historyRows: 2) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            // Something genuinely new rides along, so a partial write would show.
            let base = commitEditing(before.accounts, other.id) { $0.password = "rides along" }
            let proposed: [CredentialAccount]
            switch duplicate {
            case .repeatedAccountID:
                var clone = other
                clone.username = "grace again"
                proposed = base + [clone]
            case .identicalAccountTwice:
                let twin = try #require(base.first { $0.id == other.id })
                proposed = base + [twin]
            case .repeatedPasskeyID:
                var twin = try VaultFixtures.passkey(credentialID: Data(repeating: 2, count: 32))
                twin.id = passkey.id
                proposed = commitEditing(base, owner.id) { $0.passkeys.append(twin) }
            }
            let image = try f.headWriteImage()

            let error = await store.vaultCommitFailure(vaultID: f.vaultID, proposed, expectedRevision: before.revision, using: access)

            let refusal = error as? CredentialVaultError
            #expect(refusal == .invalidData || refusal == .duplicateIdentifier, "\(duplicate): \(String(describing: error))")
            #expect(try f.headWriteImage() == image)
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.revision == before.revision)
            #expect(after.stamps == before.stamps)
            try f.verify()
        }
    }
}
