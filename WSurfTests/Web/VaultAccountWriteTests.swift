// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Task 12 (§13.5), store boundary: `commitAccounts` re-verifies only the touched accounts' stamps, writes only them, and leaves every
// other row and the head's policy byte-identical. State is read back from the file (`CommitProbe`, the fixture), never from the writer.

private nonisolated enum StaleExpectation: CaseIterable, Sendable {
    /// The account changed after the stamp was taken.
    case changedStamp
    /// `.absent` for an id that is live.
    case absentOnLive
    /// `.stamp` for an id that is not live.
    case stampOnMissing
}

private nonisolated enum PairCase: CaseIterable, Sendable {
    /// One exporter account owning two items (a 600-item import is this, 600 times).
    case twoItemsOneExternalAccount
    /// Item ids are unique per exporter account only.
    case sameItemDifferentExternalAccount
    /// Add Separately: same website and username, fresh exchange identity.
    case sameOriginAndUsernameAddedSeparately
    case samePair
    /// A native account's fallback pair is its own id for both halves.
    case nilFallbackCollision
    case emptyExternalID
    /// An existing account edited into another existing account's pair.
    case touchedAccountEditedIntoAnotherPair
}

private nonisolated enum InvalidWrites: CaseIterable, Sendable {
    case empty, repeatedAccountID, replacementIDMismatch
}

/// The store as the file holds it: every record and journal row, both heads, the registry.
private nonisolated struct StoreImage: Equatable {
    let rows: [String: Data]
    let heads: [String: Data]
    let registryRevision: UInt64
    let catalog: RegistryCatalog
    let mac: Data

    init(_ f: VaultStoreFixture) throws {
        let registry = try f.storedRegistry()
        rows = try f.recordAndJournalImage()
        heads = try f.headWriteImage()
        registryRevision = registry.revision
        catalog = registry.catalog
        mac = registry.mac
    }
}

private nonisolated func exchanging(_ account: CredentialAccount, account external: UInt8?, item: UInt8?) -> CredentialAccount {
    var edited = account
    edited.exchangeAccountID = external.map { Data([$0]) }
    edited.exchangeItemID = item.map { Data([$0]) }
    return edited
}

private nonisolated func longOrigin(_ index: Int) -> String {
    let label = String(format: "%04d", index) + String(repeating: "x", count: 58)
    return "https://" + [label, label, label, label].joined(separator: ".")
}

struct VaultAccountWriteTests {
    private func write(_ rig: RevisionRig, _ writes: [AccountWrite], cause: String? = nil) async throws -> VaultCommitReceipt {
        try await rig.store.commitAccounts(vaultID: rig.f.vaultID, writes, cause: cause, using: rig.access)
    }

    private func expectNothingWritten(
        _ rig: RevisionRig, throwing expected: any Error, _ writes: [AccountWrite], sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let before = try StoreImage(rig.f)
        let revision = try await rig.snapshot().revision
        do {
            _ = try await write(rig, writes)
            Issue.record("expected \(expected)", sourceLocation: sourceLocation)
        } catch {
            #expect(String(describing: error) == String(describing: expected), sourceLocation: sourceLocation)
        }
        #expect(try StoreImage(rig.f) == before, sourceLocation: sourceLocation)
        #expect(try await rig.snapshot().revision == revision, sourceLocation: sourceLocation)
        try rig.f.verify()
    }

    // MARK: stamps

    @Test func unrelatedConcurrentWriteSurvivesAnAccountWrite() async throws {
        let ada = VaultFixtures.account(username: "ada", password: "old")
        let grace = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.withRig(accounts: [ada, grace]) { rig in
            let probe = CommitProbe(f: rig.f)
            let bound = try await rig.snapshot()
            // Another writer changes only grace after the review bound ada's stamp.
            _ = try await rig.commit(commitEditing(bound.accounts, grace.id) { $0.password = "grace-new" })
            let afterGrace = try await rig.snapshot()
            let graceRow = try probe.liveRow(grace.id)
            var edited = ada
            edited.password = "new"

            let receipt = try await write(rig, [AccountWrite(accountID: ada.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: edited)])

            #expect(receipt.revision == afterGrace.revision + 1)
            let after = try await rig.snapshot()
            #expect(try after.account(ada.id).password == "new")
            #expect(try after.account(grace.id).password == "grace-new")
            #expect(after.stamps[grace.id] == afterGrace.stamps[grace.id])
            #expect(try probe.liveRow(grace.id).plaintext == graceRow.plaintext)
            try probe.expectRegistryMatchesStore()
            try rig.f.verify()
        }
    }

    @Test(arguments: StaleExpectation.allCases)
    private func staleExpectationsWriteNothing(_ stale: StaleExpectation) async throws {
        let ada = VaultFixtures.account(username: "ada")
        let grace = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.withRig(accounts: [ada], historyRows: 2) { rig in
            let bound = try await rig.snapshot()
            let writes: [AccountWrite]
            switch stale {
            case .changedStamp:
                _ = try await rig.commit(commitEditing(bound.accounts, ada.id) { $0.password = "moved on" })
                writes = [AccountWrite(accountID: ada.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: ada)]
            case .absentOnLive:
                writes = [AccountWrite(accountID: ada.id, expected: .absent, replacement: ada)]
            case .stampOnMissing:
                writes = [AccountWrite(accountID: grace.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: grace)]
            }
            try await expectNothingWritten(rig, throwing: CredentialVaultError.staleRevision, writes)
        }
    }

    @Test func oneStaleWriteRefusesTheWholeCallEvenWithAValidSibling() async throws {
        let ada = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.withRig(accounts: [ada]) { rig in
            let bound = try await rig.snapshot()
            var edited = ada
            edited.password = "new"
            let fresh = VaultFixtures.account(username: "grace", origin: "https://b.example")
            let writes = [
                AccountWrite(accountID: ada.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: edited),
                AccountWrite(accountID: fresh.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: fresh),
            ]
            try await expectNothingWritten(rig, throwing: CredentialVaultError.staleRevision, writes)
        }
    }

    // MARK: identity

    @Test(arguments: PairCase.allCases)
    private func exchangeItemIdentityIsThePair(_ pair: PairCase) async throws {
        let native = VaultFixtures.account(username: "native", origin: "https://n.example")
        let linked = exchanging(VaultFixtures.account(username: "ada", origin: "https://a.example"), account: 1, item: 1)
        let other = exchanging(VaultFixtures.account(username: "grace", origin: "https://g.example"), account: 2, item: 2)
        try await VaultStoreFixture.withRig(accounts: [native, linked, other]) { rig in
            let bound = try await rig.snapshot()
            func added(_ account: CredentialAccount) -> [AccountWrite] {
                [AccountWrite(accountID: account.id, expected: .absent, replacement: account)]
            }
            let fresh = VaultFixtures.account(username: "fresh", origin: "https://f.example")
            switch pair {
            case .twoItemsOneExternalAccount:
                _ = try await write(rig, added(exchanging(fresh, account: 1, item: 2)))
                #expect(try await rig.snapshot().accounts.count == 4)
            case .sameItemDifferentExternalAccount:
                _ = try await write(rig, added(exchanging(fresh, account: 3, item: 1)))
                #expect(try await rig.snapshot().accounts.count == 4)
            case .sameOriginAndUsernameAddedSeparately:
                let again = exchanging(VaultFixtures.account(username: "ada", origin: "https://a.example"), account: 9, item: 9)
                _ = try await write(rig, added(again))
                #expect(try await rig.snapshot().accounts.filter { $0.username == "ada" }.count == 2)
            case .samePair:
                try await expectNothingWritten(rig, throwing: CredentialVaultError.duplicateIdentifier, added(exchanging(fresh, account: 1, item: 1)))
            case .nilFallbackCollision:
                var colliding = fresh
                colliding.exchangeAccountID = withUnsafeBytes(of: native.id.uuid) { Data($0) }
                colliding.exchangeItemID = colliding.exchangeAccountID
                try await expectNothingWritten(rig, throwing: CredentialVaultError.duplicateIdentifier, added(colliding))
            case .emptyExternalID:
                var empty = fresh
                empty.exchangeItemID = Data()
                try await expectNothingWritten(rig, throwing: CredentialVaultError.invalidData, added(empty))
            case .touchedAccountEditedIntoAnotherPair:
                let edited = exchanging(other, account: 1, item: 1)
                try await expectNothingWritten(
                    rig, throwing: CredentialVaultError.duplicateIdentifier,
                    [AccountWrite(accountID: other.id, expected: .stamp(try #require(bound.stamps[other.id])), replacement: edited)]
                )
            }
            try rig.f.verify()
        }
    }

    @Test func aPasskeyCredentialAlreadyLiveInAnotherAccountWritesNothing() async throws {
        let holder = VaultFixtures.account(username: "ada", passkeys: [try VaultFixtures.passkey()])
        try await VaultStoreFixture.withRig(accounts: [holder]) { rig in
            let clone = VaultFixtures.account(username: "grace", origin: "https://b.example", passkeys: [try VaultFixtures.passkey()])
            try await expectNothingWritten(
                rig, throwing: CredentialVaultError.duplicateIdentifier, [AccountWrite(accountID: clone.id, expected: .absent, replacement: clone)]
            )
        }
    }

    @Test(arguments: InvalidWrites.allCases)
    private func invalidWriteListsAreMalformed(_ invalid: InvalidWrites) async throws {
        let ada = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.withRig(accounts: [ada]) { rig in
            let bound = try await rig.snapshot()
            let stamp = try #require(bound.stamps[ada.id])
            let writes: [AccountWrite]
            switch invalid {
            case .empty:
                writes = []
            case .repeatedAccountID:
                writes = [.init(accountID: ada.id, expected: .stamp(stamp), replacement: ada), .init(accountID: ada.id, expected: .stamp(stamp), replacement: ada)]
            case .replacementIDMismatch:
                writes = [.init(accountID: ada.id, expected: .stamp(stamp), replacement: VaultFixtures.account(username: "other"))]
            }
            try await expectNothingWritten(rig, throwing: CredentialStoreError.malformed, writes)
        }
    }

    // MARK: what is written

    @Test func untouchedRowsAndPolicyAreByteIdentical() async throws {
        let ada = VaultFixtures.account(username: "ada", password: "old")
        let grace = VaultFixtures.account(username: "grace", origin: "https://b.example")
        let linus = VaultFixtures.account(username: "linus", origin: "https://c.example")
        let blocked = ["https://a.example", "https://b.example"]
        try await VaultStoreFixture.withRig(accounts: [ada, grace, linus], historyRows: 3) { rig in
            let f = rig.f
            let probe = CommitProbe(f: f)
            // The rig fixture has no policy: set it through the public path first.
            let seeded = try await rig.snapshot()
            _ = try await rig.store.updatePasswordSavePolicy(vaultID: f.vaultID, Set(blocked), expectedRevision: seeded.revision, using: rig.access)
            let bound = try await rig.snapshot()
            let headBefore = try probe.heads().source
            let rows = try f.recordAndJournalImage()
            var edited = ada
            edited.password = "new"

            _ = try await write(rig, [AccountWrite(accountID: ada.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: edited)])

            let changed = try probe.rowsChanged(since: rows)
            #expect(changed.contains(probe.recordKey(f.vaultID, ada.id)))
            #expect(!changed.contains(probe.recordKey(f.vaultID, grace.id)))
            #expect(!changed.contains(probe.recordKey(f.vaultID, linus.id)))
            let headAfter = try probe.heads().source
            #expect(headAfter.blockedOrigins == headBefore.blockedOrigins)
            #expect(headAfter.revision == headBefore.revision + 1)
            #expect(try await rig.snapshot().blockedPasswordOrigins == Set(blocked))
            try probe.expectRegistryMatchesStore()
            try f.verify()
        }
    }

    /// One account is capped by its own bytes, not by what the stored policy adds beside it: with a full policy an edit of 3.3 MB
    /// is kept (the old whole-vault budget refused it), an edit over `accountBytes` is refused by name with nothing written, and
    /// the policy is never rewritten. That the policy counts toward the vault total is in `CredentialAccountValidationTests`.
    @Test func anAccountEditIsCappedByItsOwnBytesAndLeavesThePolicyAlone() async throws {
        let origins = (1...4_096).map(longOrigin)
        var big = VaultFixtures.account(username: String(repeating: "x", count: 2_500_000), password: nil)
        big.displayName = nil
        let account = big
        try await VaultStoreFixture.with(accounts: [account], blockedOrigins: origins) { f in
            let probe = CommitProbe(f: f)
            let (store, access) = try await f.unlocked()
            let bound = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(bound.blockedPasswordOrigins.count == 4_096)
            let stamp = try #require(bound.stamps[account.id])
            func resized(_ count: Int, displayName: Int = 0) -> [AccountWrite] {
                var edited = account
                edited.username = String(repeating: "x", count: count)
                edited.displayName = displayName == 0 ? nil : String(repeating: "d", count: displayName)
                return [AccountWrite(accountID: account.id, expected: .stamp(stamp), replacement: edited)]
            }
            let before = try StoreImage(f)
            let policy = try probe.heads().source.blockedOrigins

            // Each field is within its own bound; together they are over the cap of one account.
            #expect(3_900_000 + 200_000 > CredentialVaultLimits.accountBytes)
            await #expect(throws: CredentialStoreError.limit(.accountBytes)) {
                try await store.commitAccounts(vaultID: f.vaultID, resized(3_900_000, displayName: 200_000), cause: nil, using: access)
            }
            #expect(try StoreImage(f) == before)

            let receipt = try await store.commitAccounts(vaultID: f.vaultID, resized(3_300_000), cause: nil, using: access)
            #expect(receipt.revision == bound.revision + 1)
            #expect(try probe.heads().source.blockedOrigins == policy)
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).blockedPasswordOrigins == Set(origins))
            try f.verify()
        }
    }

    @Test func anAllUnchangedWriteIsATrueNoOp() async throws {
        let ada = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.withRig(accounts: [ada], historyRows: 2) { rig in
            let bound = try await rig.snapshot()
            let before = try StoreImage(rig.f)

            let receipt = try await write(
                rig, [AccountWrite(accountID: ada.id, expected: .stamp(try #require(bound.stamps[ada.id])), replacement: ada)], cause: "ignored"
            )

            #expect(receipt.revision == bound.revision)
            #expect(try StoreImage(rig.f) == before)
            #expect(try await rig.snapshot().stamps == bound.stamps)
        }
    }

    // MARK: revisions and removals follow commit

    @Test func passwordReplaceMakesOneRevisionAndPersistOnlyNone() async throws {
        let account = try VaultFixtures.richAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            var bound = try await rig.snapshot()
            let metadataOnly = try account.editingExchange {
                $0.created = VaultFixtures.reference(5_000)
                $0.lastModified = VaultFixtures.reference(6_000)
            }
            var marks = try f.marks()

            var receipt = try await write(
                rig, [AccountWrite(accountID: account.id, expected: .stamp(try #require(bound.stamps[account.id])), replacement: metadataOnly)]
            )

            try f.expectOneWrite(since: marks, receipt: receipt)
            #expect(try f.recordIDs(of: f.vaultID, kind: .revision).isEmpty)
            #expect(try await rig.snapshot().account(account.id).modifiedAt == nil)

            bound = try await rig.snapshot()
            marks = try f.marks()
            var rotated = metadataOnly
            rotated.password = "rotated"
            receipt = try await write(
                rig, [AccountWrite(accountID: account.id, expected: .stamp(try #require(bound.stamps[account.id])), replacement: rotated)],
                cause: "rotated"
            )

            try f.expectOneWrite(since: marks, receipt: receipt)
            let revision = try #require(try f.revisions().first)
            #expect(try f.revisions().count == 1)
            #expect(revision.ownerID == account.id)
            #expect(revision.subject == .password)
            #expect(revision.body.cause == "rotated")
            #expect(try await rig.snapshot().account(account.id).modifiedAt == RevisionFixtures.stamp)
            try f.verify()
        }
    }

    @Test func removalsAndAdditionsInOneWriteAreOneTransactionAndOneRevision() async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [victim, bystander], historyRows: 2) { f in
            let probe = CommitProbe(f: f)
            let owned = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            let bystanderRows = try probe.liveRow(bystander.id).plaintext
            let revisions = try f.moveHeadRevisions()
            var proposed = victim
            proposed.password = nil
            proposed.totp = nil
            proposed.passkeys.removeFirst()
            let added = VaultFixtures.account(username: "linus", origin: "https://c.example")

            try await f.withWallStore { store, access in
                let bound = try await store.snapshot(vaultID: f.vaultID, using: access)
                let writes = [
                    AccountWrite(accountID: victim.id, expected: .stamp(try #require(bound.stamps[victim.id])), replacement: proposed),
                    AccountWrite(accountID: added.id, expected: .absent, replacement: added),
                ]
                let receipt = try await store.commitAccounts(vaultID: f.vaultID, writes, cause: nil, using: access)
                #expect(receipt.revision == bound.revision + 1)
                #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.count == 3)
            }

            // Three MOVEs and the new row in one transaction: one head bump per vault, histories only ever moved, never rewritten.
            #expect(try f.moveHeadRevisions() == revisions.advanced())
            let entries = try f.moveTrashEntries()
            #expect(Set(entries.map(\.row.subject)) == [.password, .totp, .passkey])
            #expect(entries.count == 3)
            let trashed = try f.moveRevisions(in: f.trashID, owner: victim.id)
            let moved = Set(owned.filter { $0.subject != .metadata }.map(\.moveKey))
            #expect(Set(trashed.map(\.moveKey)) == moved)
            #expect(try probe.liveRow(bystander.id).plaintext == bystanderRows)
            try probe.expectRegistryMatchesStore()
            try f.verify()
        }
    }

    @Test func aRejectedWriteLeavesAnIncludedRemovalUnmoved() async throws {
        let victim = try MoveFixtures.fullAccount()
        let held = exchanging(VaultFixtures.account(username: "grace", origin: "https://b.example"), account: 1, item: 1)
        try await VaultStoreFixture.with(accounts: [victim, held], historyRows: 2) { f in
            let rig = try await f.unlockedRig()
            let bound = try await rig.snapshot()
            var stripped = victim
            stripped.password = nil
            let collision = exchanging(VaultFixtures.account(username: "linus", origin: "https://c.example"), account: 1, item: 1)
            let writes = [
                AccountWrite(accountID: victim.id, expected: .stamp(try #require(bound.stamps[victim.id])), replacement: stripped),
                AccountWrite(accountID: collision.id, expected: .absent, replacement: collision),
            ]
            try await expectNothingWritten(rig, throwing: CredentialVaultError.duplicateIdentifier, writes)
            #expect(try f.moveTrashEntries().isEmpty)
        }
    }
}

private nonisolated extension VaultStoreFixture {
    func unlockedRig() async throws -> RevisionRig {
        let (store, access) = try await unlocked()
        return RevisionRig(f: self, store: store, access: access)
    }
}
