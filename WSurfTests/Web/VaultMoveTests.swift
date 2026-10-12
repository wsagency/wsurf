// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurf

// Task 7: the MOVE-to-Trash engine behind `delete` and the removals of `commit`, read back through `StoreTables`, `StoreSeal` and
// `StoreVerifier` (via the fixture). Shared plumbing lives in VaultMoveSupport.swift.

// MARK: - Parameters

/// One credential removed by `delete(scope: .credential)`.
nonisolated enum MoveSingleRemoval: CaseIterable, Sendable {
    case password, totp, passkey
    /// A password removal on an account whose display name is longer than the 256 UTF-8 bytes a label keeps.
    case longNamedPassword

    var subject: RecordSubject {
        switch self {
        case .password, .longNamedPassword:
            .password
        case .totp:
            .totp
        case .passkey:
            .passkey
        }
    }

    func scope(of victim: CredentialAccount) -> RemovalScope {
        .credential(ownerID: victim.id, subject: subject, passkeyID: self == .passkey ? victim.passkeys[0].id : nil)
    }

    /// The account the removal must leave behind (before the `modifiedAt` stamp).
    func remainder(of victim: CredentialAccount) -> CredentialAccount {
        var account = victim
        switch self {
        case .password, .longNamedPassword:
            account.username = ""
            account.password = nil
            account.basicAuthenticationMetadata = nil
        case .totp:
            account.totp = nil
        case .passkey:
            account.passkeys.removeFirst()
        }
        return account
    }
}

nonisolated enum MovePasskeyReplacement: CaseIterable, Sendable {
    case credentialID, rpID, userHandle, privateKey
    /// Not a material change: the old passkey is removed and a new one with another id is added.
    case differentID
}

nonisolated enum MoveEmptyHistoryScope: CaseIterable, Sendable {
    case account, credential
}

nonisolated enum MoveSecretScope: CaseIterable, Sendable {
    case account, passwordCredential
}

/// How many Trash `record` inserts succeed before the injected failure (the delete below moves six revisions plus one entry).
nonisolated enum MoveFailurePoint: Int, CaseIterable, Sendable {
    case first = 0, second = 1, middle = 3, last = 6
}

/// One clear column of one revision row, changed behind the store's back after it unlocked.
nonisolated enum MoveTamper: CaseIterable, Sendable, CustomStringConvertible {
    case ownerToAnotherAccount, ownerNotAUUID, subjectToTOTP, kindToTombstone

    var description: String {
        switch self {
        case .ownerToAnotherAccount, .ownerNotAUUID:
            "ownerID"
        case .subjectToTOTP:
            "subject"
        case .kindToTombstone:
            "kind"
        }
    }

    /// Bound to `(vaultID, recordID)`.
    var sql: String {
        let set = switch self {
        case .ownerToAnotherAccount:
            "ownerID = '\(UUID().lowerText)'"
        case .ownerNotAUUID:
            "ownerID = 'not-a-uuid'"
        case .subjectToTOTP:
            "subject = '\(RecordSubject.totp.sqlName)'"
        case .kindToTombstone:
            "kind = '\(RecordKind.tombstone.sqlName)'"
        }
        return "UPDATE record SET \(set) WHERE vaultID = ? AND recordID = ?"
    }
}

nonisolated enum MoveTamperScope: CaseIterable, Sendable {
    case account, passwordCredential
}

/// One hidden-history scenario. A commit that never reaches the Trash cannot notice a hidden Trash row, so the Trash rows are only
/// paired with the operations that MOVE.
nonisolated struct HiddenHistoryCase: Sendable, CustomTestStringConvertible {
    let hidden: HiddenHistory
    let operation: HiddenHistoryOperation

    var testDescription: String { "\(hidden) / \(operation)" }

    static let all: [HiddenHistoryCase] = HiddenHistory.allCases.flatMap { hidden in
        HiddenHistoryOperation.allCases
            .filter { !hidden.inTrash || $0 != .commitPasswordChange }
            .map { HiddenHistoryCase(hidden: hidden, operation: $0) }
    }
}

/// A history row made invisible to a scan of its vault after unlock: deleted, or its `vaultID` changed.
nonisolated enum HiddenHistory: CaseIterable, Sendable {
    case sourceOwnedDeleted, sourceBystanderDeleted, sourceOwnedReparented, sourceBystanderReparented, trashDeleted, trashReparented

    var inTrash: Bool {
        self == .trashDeleted || self == .trashReparented
    }

    /// The vault the row is in and the owner of the revision rows to pick from.
    func target(_ f: VaultStoreFixture, victim: UUID, bystander: UUID) -> (vault: UUID, owner: UUID) {
        switch self {
        case .sourceOwnedDeleted, .sourceOwnedReparented:
            (f.vaultID, victim)
        case .sourceBystanderDeleted, .sourceBystanderReparented:
            (f.vaultID, bystander)
        case .trashDeleted, .trashReparented:
            (f.trashID, victim)
        }
    }

    /// Bound to `(vaultID, recordID)`.
    var sql: String {
        switch self {
        case .sourceOwnedDeleted, .sourceBystanderDeleted, .trashDeleted:
            "DELETE FROM record WHERE vaultID = ? AND recordID = ?"
        case .sourceOwnedReparented, .sourceBystanderReparented, .trashReparented:
            "UPDATE record SET vaultID = '\(UUID().lowerText)' WHERE vaultID = ? AND recordID = ?"
        }
    }
}

/// Every route that writes: both removal scopes, and an ordinary commit that only appends a revision.
nonisolated enum HiddenHistoryOperation: CaseIterable, Sendable {
    case deleteAccount, deletePassword, commitPasswordChange

    func run(
        _ store: ProfileVaultStore, _ access: VaultAccess, _ f: VaultStoreFixture, _ snapshot: StoreSnapshot, _ victim: CredentialAccount
    ) async throws -> VaultCommitReceipt {
        switch self {
        case .deleteAccount:
            return try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: snapshot.revision, using: access)
        case .deletePassword:
            return try await store.delete(
                vaultID: f.vaultID, scope: .credential(ownerID: victim.id, subject: .password, passkeyID: nil),
                expectedRevision: snapshot.revision, using: access
            )
        case .commitPasswordChange:
            let changed = snapshot.accounts.map { account -> CredentialAccount in
                var copy = account
                if copy.id == victim.id {
                    copy.password = "changed-after-hide"
                }
                return copy
            }
            return try await store.commit(vaultID: f.vaultID, changed, expectedRevision: snapshot.revision, cause: nil, using: access)
        }
    }
}

nonisolated enum MoveFailingOperation: CaseIterable, Sendable {
    case deleteAccount, commitRemoval

    func run(_ store: ProfileVaultStore, _ access: VaultAccess, _ f: VaultStoreFixture, _ victim: CredentialAccount, _ revision: UInt64) async throws {
        switch self {
        case .deleteAccount:
            _ = try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: revision, using: access)
        case .commitRemoval:
            var proposed = victim
            proposed.password = nil
            _ = try await store.commit(vaultID: f.vaultID, [proposed], expectedRevision: revision, cause: nil, using: access)
        }
    }
}

nonisolated enum MoveCapCase: CaseIterable, Sendable {
    case liveAccountCap, payloadCap, sixteenVaults
}

nonisolated enum MoveNearCapScope: CaseIterable, Sendable {
    case account, passwordCredential
}

// MARK: - Tests

struct VaultMoveTests {
    private static let comparableRowBytes = 3_900_000

    /// `victim` with its first passkey changed the way `change` names (`.differentID`: that passkey swapped for `replacement`).
    private static func replacing(
        _ victim: CredentialAccount, _ change: MovePasskeyReplacement, with replacement: WebsitePasskey
    ) throws -> CredentialAccount {
        var proposed = victim
        switch change {
        case .credentialID:
            proposed.passkeys[0].credentialID = Data(repeating: 0x77, count: 32)
        case .rpID:
            proposed.passkeys[0].rpID = "other.test"
        case .userHandle:
            proposed.passkeys[0].userHandle = Data([9, 9])
        case .privateKey:
            proposed.passkeys[0].privateKeyPKCS8 = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        case .differentID:
            proposed.passkeys = [victim.passkeys[1], replacement]
        }
        return proposed
    }

    // MARK: Whole account

    @Test func wholeAccountDeleteMovesLiveRowAndEveryOwnedRevision() async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander],
            historyRows: 3,
            extraHistory: [
                FixtureHistoryRun(subject: .totp, count: 2),
                FixtureHistoryRun(subject: .metadata, count: 2),
                FixtureHistoryRun(subject: .passkey, count: 1),
                FixtureHistoryRun(subject: .password, count: 2, ownerIndex: 1),
            ]
        ) { f in
            let owned = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            #expect(owned.count == 8)
            let originals = Dictionary(uniqueKeysWithValues: owned.map { ($0.recordID, $0) })
            let plaintexts = try Dictionary(uniqueKeysWithValues: owned.map { ($0.recordID, try f.movePlaintext(of: $0)) })
            let liveKey = try f.storedRecord(f.vaultID, victim.id).imageKey
            let removedKeys = Set(owned.map(\.imageKey)).union([liveKey])
            let before = try f.recordAndJournalImage()
            let revisions = try f.moveHeadRevisions()

            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.delete(
                    vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: snapshot.revision, using: access
                )
                #expect(receipt.revision == snapshot.revision + 1)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(after.accounts.map(\.id) == [bystander.id])
                #expect(after.stamps[victim.id] == nil)
                #expect(after.revision == receipt.revision)
            }

            #expect(try f.moveOwnedRowCount(in: f.vaultID, owner: victim.id) == 0)
            let moved = try f.moveHistoryRows(of: f.trashID).filter { $0.kind == .revision }
            #expect(Set(moved.map(\.moveKey)) == Set(owned.map(\.moveKey)))
            for row in moved {
                let original = try #require(originals[row.recordID])
                #expect(row.sealed != original.sealed)
                #expect(try f.movePlaintext(of: row) == plaintexts[row.recordID])
            }
            let entries = try f.moveTrashEntries()
            #expect(entries.count == 1)
            let entry = try #require(entries.first)
            #expect(entry.row.ownerID == victim.id)
            #expect(entry.row.subject == .account)
            #expect(entry.row.version == 1)
            #expect(entry.body.scope == .account)
            #expect(entry.body.ownerID == victim.id)
            #expect(entry.body.subject == nil)
            #expect(entry.body.passkeyID == nil)
            #expect(entry.body.snapshot == victim)
            #expect(entry.body.credentialValue == nil)
            #expect(entry.body.deletedAt == MoveFixtures.wall)
            try f.expectMoveTransferPair(
                for: entry,
                MoveExpectation(
                    scope: .account, ownerID: victim.id, subject: nil, liveVersion: VaultStoreFixture.accountVersion,
                    movedKeys: Set(owned.map(\.moveKey))
                )
            )

            let heads = try f.moveStoredHeads()
            #expect(!heads.source.liveCatalog.contains { $0.recordID == victim.id })
            #expect(heads.source.liveCatalog.contains { $0.recordID == bystander.id })
            #expect(heads.source.historyCounts.revision == 2)
            #expect(heads.trash.historyCounts == HistoryCounts(revision: 8, trashEntry: 1, tombstone: 0))
            f.expectMoveUntouched(before: before, after: try f.recordAndJournalImage(), except: removedKeys)
            #expect(try f.moveHeadRevisions() == revisions.advanced())
            try f.expectMoveRegistryMatchesHeads()
            try f.verify()
        }
    }

    // MARK: Single credential

    @Test(arguments: MoveSingleRemoval.allCases)
    func singleCredentialDeleteLeavesAccountSiblingsAndMetadataRevisions(_ removal: MoveSingleRemoval) async throws {
        let name = removal == .longNamedPassword ? String(repeating: "é", count: 300) : "Work"
        let victim = try MoveFixtures.fullAccount(displayName: name)
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander],
            historyRows: 2,
            extraHistory: [
                FixtureHistoryRun(subject: .totp, count: 2),
                FixtureHistoryRun(subject: .metadata, count: 2),
                FixtureHistoryRun(subject: .passkey, count: 1),
            ]
        ) { f in
            let owned = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            let movedKeys = Set(owned.filter { $0.subject == removal.subject }.map(\.moveKey))
            #expect(movedKeys.count == (removal == .passkey ? 1 : 2))
            let stayingKeys = Set(owned.map(\.moveKey)).subtracting(movedKeys)
            let liveKey = try f.storedRecord(f.vaultID, victim.id).imageKey
            let removedImageKeys = Set(owned.filter { $0.subject == removal.subject }.map(\.imageKey)).union([liveKey])
            let before = try f.recordAndJournalImage()
            let revisions = try f.moveHeadRevisions()

            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.delete(
                    vaultID: f.vaultID, scope: removal.scope(of: victim), expectedRevision: snapshot.revision, using: access
                )
                #expect(receipt.revision == snapshot.revision + 1)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                var expected = removal.remainder(of: victim)
                expected.modifiedAt = MoveFixtures.wall
                #expect(after.accounts.first { $0.id == victim.id } == expected)
                #expect(after.stamps[victim.id]?.version == VaultStoreFixture.accountVersion + 1)
                #expect(after.accounts.contains { $0.id == bystander.id })
            }

            let active = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            #expect(Set(active.map(\.moveKey)) == stayingKeys)
            #expect(Set(try f.moveRevisions(in: f.trashID, owner: victim.id).map(\.moveKey)) == movedKeys)
            let entries = try f.moveTrashEntries()
            #expect(entries.count == 1)
            let entry = try #require(entries.first)
            try Self.expectCredentialEntry(entry, removal: removal, victim: victim)
            try f.expectMoveTransferPair(
                for: entry,
                MoveExpectation(
                    scope: .credential, ownerID: victim.id, subject: removal.subject, liveVersion: VaultStoreFixture.accountVersion + 1,
                    movedKeys: movedKeys
                )
            )
            let heads = try f.moveStoredHeads()
            #expect(heads.source.liveCatalog.first { $0.recordID == victim.id }?.version == VaultStoreFixture.accountVersion + 1)
            #expect(heads.source.historyCounts.revision == stayingKeys.count)
            #expect(heads.trash.historyCounts == HistoryCounts(revision: movedKeys.count, trashEntry: 1, tombstone: 0))
            f.expectMoveUntouched(before: before, after: try f.recordAndJournalImage(), except: removedImageKeys)
            #expect(try f.moveHeadRevisions() == revisions.advanced())
            try f.expectMoveRegistryMatchesHeads()
            try f.verify()
        }
    }

    private static func expectCredentialEntry(_ entry: MoveTrashEntry, removal: MoveSingleRemoval, victim: CredentialAccount) throws {
        let body = entry.body
        #expect(entry.row.subject == removal.subject)
        #expect(entry.row.version == 1)
        #expect(body.scope == .credential)
        #expect(body.ownerID == victim.id)
        #expect(body.subject == removal.subject)
        #expect(body.passkeyID == (removal == .passkey ? victim.passkeys[0].id : nil))
        #expect(body.snapshot == nil)
        #expect(body.deletedAt == MoveFixtures.wall)
        let label = try #require(body.label)
        #expect(label.contains("https://example.test"))
        if removal == .longNamedPassword {
            #expect(label.contains(String(repeating: "é", count: 128)))
            #expect(!label.contains(String(repeating: "é", count: 129)))
        } else {
            #expect(label.contains("Work"))
        }
        let value = try #require(body.credentialValue)
        let decoder = JSONDecoder()
        switch removal {
        case .password, .longNamedPassword:
            let expected = PasswordValue(username: victim.username, password: victim.password, basicAuthenticationMetadata: nil)
            #expect(try decoder.decode(PasswordValue.self, from: value) == expected)
        case .totp:
            #expect(try decoder.decode(TOTPGenerator.self, from: value) == victim.totp)
        case .passkey:
            #expect(try decoder.decode(WebsitePasskey.self, from: value) == victim.passkeys[0])
        }
    }

    // MARK: Removal by commit

    @Test func removalByCommitIsAMoveWithNoActiveResidue() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(
            accounts: [victim],
            historyRows: 2,
            extraHistory: [
                FixtureHistoryRun(subject: .totp, count: 1),
                FixtureHistoryRun(subject: .passkey, count: 1),
                FixtureHistoryRun(subject: .metadata, count: 1),
            ]
        ) { f in
            let owned = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            let keys: (RecordSubject) -> Set<MoveRowKey> = { subject in Set(owned.filter { $0.subject == subject }.map(\.moveKey)) }
            let sourceJournal = try f.journalRows(of: f.vaultID).count
            let trashJournal = try f.journalRows(of: f.trashID).count
            let revisions = try f.moveHeadRevisions()
            var proposed = victim
            proposed.password = nil
            proposed.totp = nil
            proposed.passkeys.removeFirst()

            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.commit(
                    vaultID: f.vaultID, [proposed], expectedRevision: snapshot.revision, cause: nil, using: access
                )
                #expect(receipt.revision == snapshot.revision + 1)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                var stamped = proposed
                stamped.modifiedAt = MoveFixtures.wall
                #expect(after.accounts == [stamped])
            }

            // Three MOVEs in one transaction: one head bump per vault, one transfer pair each, nothing else journalled.
            #expect(try f.moveHeadRevisions() == revisions.advanced())
            #expect(try f.journalRows(of: f.vaultID).count == sourceJournal + 3)
            #expect(try f.journalRows(of: f.trashID).count == trashJournal + 3)
            let entries = try f.moveTrashEntries()
            #expect(Set(entries.map(\.row.subject)) == [.password, .totp, .passkey])
            #expect(entries.count == 3)
            for entry in entries {
                #expect(entry.body.scope == .credential)
                #expect(entry.body.ownerID == victim.id)
                #expect(entry.body.passkeyID == (entry.row.subject == .passkey ? victim.passkeys[0].id : nil))
                try f.expectMoveTransferPair(
                    for: entry,
                    MoveExpectation(
                        scope: .credential, ownerID: victim.id, subject: entry.row.subject,
                        liveVersion: VaultStoreFixture.accountVersion + 1, movedKeys: keys(entry.row.subject)
                    )
                )
            }
            // Each history is in Trash; the active vault keeps only the metadata revision, and no revision was made for the removals.
            let active = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            #expect(Set(active.map(\.moveKey)) == keys(.metadata))
            #expect(active.count == 1)
            let trashed = try f.moveRevisions(in: f.trashID, owner: victim.id)
            #expect(Set(trashed.map(\.moveKey)) == keys(.password).union(keys(.totp)).union(keys(.passkey)))
            #expect(trashed.count == 4)
            let heads = try f.moveStoredHeads()
            #expect(heads.source.historyCounts.revision == 1)
            #expect(heads.trash.historyCounts == HistoryCounts(revision: 4, trashEntry: 3, tombstone: 0))
            try f.expectMoveRegistryMatchesHeads()
            try f.verify()
        }
    }

    // MARK: Same-id passkey material

    @Test(arguments: MovePasskeyReplacement.allCases)
    func sameIDPasskeyMaterialChangeIsRefusedAtomically(_ change: MovePasskeyReplacement) async throws {
        let victim = try MoveFixtures.fullAccount()
        let replacement = try VaultFixtures.passkey(credentialID: Data(repeating: 0x55, count: 32))
        try await VaultStoreFixture.with(
            accounts: [victim], historyRows: 2, extraHistory: [FixtureHistoryRun(subject: .passkey, count: 1)]
        ) { f in
            let proposed = try Self.replacing(victim, change, with: replacement)
            let before = try f.headWriteImage()
            let registry = try f.storedRegistry()
            let revisions = try f.moveHeadRevisions()

            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                guard change == .differentID else {
                    await #expect(throws: CredentialVaultError.invalidData) {
                        _ = try await store.commit(
                            vaultID: f.vaultID, [proposed], expectedRevision: snapshot.revision, cause: nil, using: access
                        )
                    }
                    #expect(try f.headWriteImage() == before)
                    #expect(try f.storedRegistry().revision == registry.revision)
                    #expect(try f.storedRegistry().catalog == registry.catalog)
                    let unchanged = try await store.snapshot(vaultID: f.vaultID, using: access)
                    #expect(unchanged.revision == snapshot.revision)
                    #expect(unchanged.accounts == [victim])
                    return
                }
                let receipt = try await store.commit(
                    vaultID: f.vaultID, [proposed], expectedRevision: snapshot.revision, cause: nil, using: access
                )
                #expect(receipt.revision == snapshot.revision + 1)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(after.accounts.first?.passkeys.map(\.id) == [victim.passkeys[1].id, replacement.id])
            }

            if change == .differentID {
                #expect(try f.moveHeadRevisions() == revisions.advanced())
                let entries = try f.moveTrashEntries()
                #expect(entries.count == 1)
                let entry = try #require(entries.first)
                #expect(entry.body.scope == .credential)
                #expect(entry.body.subject == .passkey)
                #expect(entry.body.passkeyID == victim.passkeys[0].id)
                let value = try #require(entry.body.credentialValue)
                #expect(try JSONDecoder().decode(WebsitePasskey.self, from: value) == victim.passkeys[0])
                #expect(try f.moveRevisions(in: f.trashID, owner: victim.id, subject: .passkey).count == 1)
                #expect(try f.moveRevisions(in: f.vaultID, owner: victim.id, subject: .passkey).isEmpty)
                try f.expectMoveRegistryMatchesHeads()
            } else {
                #expect(try f.moveHeadRevisions() == revisions)
                #expect(try f.moveTrashEntries().isEmpty)
            }
            try f.verify()
        }
    }

    // MARK: Transfer rows

    @Test(arguments: MoveEmptyHistoryScope.allCases)
    func moveWritesTransferRowsOnBothSidesEvenForEmptyHistory(_ scope: MoveEmptyHistoryScope) async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim]) { f in
            #expect(try f.journalRows(of: f.vaultID).isEmpty)
            #expect(try f.journalRows(of: f.trashID).isEmpty)
            let removal: RemovalScope = scope == .account
                ? .account(victim.id)
                : .credential(ownerID: victim.id, subject: .totp, passkeyID: nil)
            try await f.withWallStore { store, access in
                let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
                _ = try await store.delete(vaultID: f.vaultID, scope: removal, expectedRevision: revision, using: access)
            }

            let sourceRows = try f.journalRows(of: f.vaultID)
            let trashRows = try f.journalRows(of: f.trashID)
            #expect(sourceRows.count == 1)
            #expect(trashRows.count == 1)
            let out = try #require(sourceRows.first)
            let into = try #require(trashRows.first)
            #expect(out.ops.isEmpty)
            #expect(into.ops.count == 1)
            #expect(into.ops.first?.op == .add)
            #expect(into.ops.first?.kind == .trashEntry)
            #expect(out.transfer?.direction == .out)
            #expect(into.transfer?.direction == .in)
            #expect(out.transfer?.transferID == into.transfer?.transferID)
            let entry = try #require(try f.moveTrashEntries().first)
            try f.expectMoveTransferPair(
                for: entry,
                MoveExpectation(
                    scope: scope == .account ? .account : .credential,
                    ownerID: victim.id,
                    subject: scope == .account ? nil : .totp,
                    liveVersion: VaultStoreFixture.accountVersion + (scope == .account ? 0 : 1),
                    movedKeys: []
                )
            )
            try f.verify()
        }
    }

    // MARK: One secret-bearing copy

    @Test(arguments: MoveSecretScope.allCases)
    func exactlyOneSecretBearingLogicalCopy(_ scope: MoveSecretScope) async throws {
        let victim = try MoveFixtures.fullAccount(password: MoveFixtures.plantedPassword)
        try await VaultStoreFixture.with(
            accounts: [victim],
            extraHistory: [FixtureHistoryRun(subject: .password, count: 1, plaintext: Data(MoveFixtures.oldSecret.utf8))]
        ) { f in
            // The scan sees both secrets before the delete (one live copy, one revision copy), so a zero below means gone.
            #expect(try f.moveSecretCount(of: MoveFixtures.plantedPassword, in: f.vaultID) == 1)
            #expect(try f.moveSecretCount(of: MoveFixtures.oldSecret, in: f.vaultID) == 1)
            let removal: RemovalScope = scope == .account
                ? .account(victim.id)
                : .credential(ownerID: victim.id, subject: .password, passkeyID: nil)
            try await f.withWallStore { store, access in
                let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
                _ = try await store.delete(vaultID: f.vaultID, scope: removal, expectedRevision: revision, using: access)
            }

            for secret in [MoveFixtures.plantedPassword, MoveFixtures.oldSecret] {
                #expect(try f.moveSecretCount(of: secret, in: f.vaultID) == 0, "\(secret) is still readable in the active vault")
                #expect(try f.moveSecretCount(of: secret, in: f.trashID) == 1, "\(secret) must live once in Trash")
            }
            try f.verify()
        }
    }

    // MARK: Atomicity

    @Test(arguments: MoveFailurePoint.allCases, MoveFailingOperation.allCases)
    func failureMidMoveRollsBackWhole(_ point: MoveFailurePoint, _ operation: MoveFailingOperation) async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 6) { f in
            let baseline = try f.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record WHERE vaultID = ?", arguments: [f.trashID.lowerText]) ?? 0
            }
            try f.mutate { db in
                try db.execute(
                    sql: """
                        CREATE TRIGGER boom BEFORE INSERT ON record
                        WHEN (SELECT COUNT(*) FROM record WHERE vaultID = '\(f.trashID.lowerText)') >= \(baseline + point.rawValue)
                        BEGIN SELECT RAISE(ABORT, 'injected'); END
                        """
                )
            }
            let before = try f.headWriteImage()
            let revisions = try f.moveHeadRevisions()
            let registry = try f.storedRegistry()
            let (store, access) = try await f.unlocked()
            let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision

            await #expect(throws: (any Error).self) {
                try await operation.run(store, access, f, victim, revision)
            }

            #expect(try f.headWriteImage() == before)
            #expect(try f.moveHeadRevisions() == revisions)
            #expect(try f.storedRegistry().catalog == registry.catalog)
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).revision == revision)
            try f.mutate { try $0.execute(sql: "DROP TRIGGER boom") }
            try f.verify()

            // Nothing is wedged: a fresh unlock sees the old state and the same operation now commits whole.
            let (fresh, freshAccess) = try await f.unlocked()
            let snapshot = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            #expect(snapshot.accounts.map(\.id) == [victim.id])
            try await operation.run(fresh, freshAccess, f, victim, snapshot.revision)
            #expect(try f.moveHeadRevisions() == revisions.advanced())
            try f.verify()
        }
    }

    /// A real `Task.cancel` issued from inside the write transaction (see `MoveCancelSeam`) after `point` Trash rows were written.
    @Test(arguments: MoveFailurePoint.allCases, MoveFailingOperation.allCases)
    func cancellationMidMoveRollsBackWhole(_ point: MoveFailurePoint, _ operation: MoveFailingOperation) async throws {
        let victim = try MoveFixtures.fullAccount()
        let seam = MoveCancelSeam()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 6) { f in
            let baseline = try f.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record WHERE vaultID = ?", arguments: [f.trashID.lowerText]) ?? 0
            }
            try f.mutate { db in
                try db.execute(
                    sql: """
                        CREATE TRIGGER cancelmid BEFORE INSERT ON record
                        WHEN (SELECT COUNT(*) FROM record WHERE vaultID = '\(f.trashID.lowerText)') >= \(baseline + point.rawValue)
                        BEGIN SELECT wsurf_cancel(); END
                        """
                )
            }
            let before = try f.headWriteImage()
            let revisions = try f.moveHeadRevisions()
            let registry = try f.storedRegistry()
            let (store, access) = try await f.unlocked()
            let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
            let grant = try await store.authorizedGrant(f.vaultID, access)
            let (clock, wallClock) = await (store.now, store.wall)
            let request = CommitRequest(
                grant: grant,
                intent: CommitIntent(
                    vaultID: f.vaultID, access: access, expectedRevision: revision, cause: nil, isCommit: operation == .commitRemoval
                ),
                now: clock, wall: wallClock()
            )
            let pool = try seam.pool(at: f.storeURL)
            let removing = operation == .deleteAccount

            let running = Task {
                try MoveCancelSeam.transact(on: pool, supportDirectory: f.directory, request) { old in
                    if removing {
                        return try ProfileVaultStore.removing(.account(victim.id), from: old)
                    }
                    var proposed = victim
                    proposed.password = nil
                    return Proposal(accounts: [proposed], requires: nil)
                }
            }
            await #expect(throws: CancellationError.self) { _ = try await running.value }

            #expect(seam.fires >= 1, "the cancel never ran inside the transaction")
            #expect(try f.headWriteImage() == before)
            #expect(try f.moveHeadRevisions() == revisions)
            #expect(try f.storedRegistry().catalog == registry.catalog)
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 0)
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).revision == revision)
            try f.mutate { try $0.execute(sql: "DROP TRIGGER cancelmid") }
            try f.verify()

            let (fresh, freshAccess) = try await f.unlocked()
            let snapshot = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            try await operation.run(fresh, freshAccess, f, victim, snapshot.revision)
            #expect(try f.moveHeadRevisions() == revisions.advanced())
            try f.verify()
        }
    }

    /// The selector reads clear columns the AAD binds. Changed after unlock, a row stops matching its owner: the MOVE has to refuse
    /// (and leave everything as it was) rather than commit a delete that leaves that history in the source vault.
    @Test(arguments: MoveTamper.allCases, MoveTamperScope.allCases)
    func clearMetadataTamperedAfterUnlockFailsClosed(_ tamper: MoveTamper, _ scope: MoveTamperScope) async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 6) { f in
            let (store, access) = try await f.unlocked()
            let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
            let rows = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            let target = try #require(rows.dropFirst(2).first)
            try f.mutate { try $0.execute(sql: tamper.sql, arguments: [f.vaultID.lowerText, target.recordID.lowerText]) }

            let before = try f.headWriteImage()
            let revisions = try f.moveHeadRevisions()
            let registry = try f.storedRegistry()
            let removal: RemovalScope = scope == .account
                ? .account(victim.id) : .credential(ownerID: victim.id, subject: .password, passkeyID: nil)
            do {
                _ = try await store.delete(vaultID: f.vaultID, scope: removal, expectedRevision: revision, using: access)
                Issue.record("a MOVE over a row whose clear \(tamper) was changed after unlock committed")
            } catch let error as CredentialStoreError {
                guard case .integrityFailure = error else {
                    Issue.record("expected integrityFailure, got \(error)")
                    return
                }
            }

            #expect(try f.headWriteImage() == before)
            #expect(try f.moveHeadRevisions() == revisions)
            #expect(try f.storedRegistry().catalog == registry.catalog)
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 0)
        }
    }

    /// A history row that is deleted or moved to another vault after unlock is invisible to a scan of this vault, so a scan can never
    /// notice it. The head's authenticated counts are what still say it should be there: a write that seals the head from the
    /// pre-image counts would succeed now and leave a store whose next unlock fails. Every route that writes must refuse instead.
    @Test(arguments: HiddenHistoryCase.all)
    func historyHiddenAfterUnlockFailsClosed(_ scenario: HiddenHistoryCase) async throws {
        let hidden = scenario.hidden
        let mover = VaultFixtures.account(username: "mover", origin: "https://m.example")
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        // `accounts[0]` is moved to the Trash first (so the Trash holds history rows); owner 1 and 2 keep theirs in the source.
        try await VaultStoreFixture.with(
            accounts: [mover, victim, bystander], historyRows: 3, moves: 1,
            extraHistory: [
                FixtureHistoryRun(subject: .password, count: 4, ownerIndex: 1), FixtureHistoryRun(subject: .password, count: 3, ownerIndex: 2),
            ]
        ) { f in
            let (store, access) = try await f.unlocked()
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            let (vault, owner) = hidden.target(f, victim: victim.id, bystander: bystander.id)
            let rows = try f.moveHistoryRows(of: vault).filter { vault == f.trashID ? $0.kind == .revision : $0.ownerID == owner && $0.kind == .revision }
            let target = try #require(rows.first)
            try f.mutate { try $0.execute(sql: hidden.sql, arguments: [vault.lowerText, target.recordID.lowerText]) }

            let before = try f.headWriteImage()
            let revisions = try f.moveHeadRevisions()
            let registry = try f.storedRegistry()
            do {
                _ = try await scenario.operation.run(store, access, f, snapshot, victim)
                Issue.record("\(scenario) committed after a history row was hidden")
            } catch let error as CredentialStoreError {
                guard case .integrityFailure = error else {
                    Issue.record("expected integrityFailure, got \(error)")
                    return
                }
            }

            #expect(try f.headWriteImage() == before)
            #expect(try f.moveHeadRevisions() == revisions)
            #expect(try f.storedRegistry().catalog == registry.catalog)
        }
    }

    // MARK: Caps

    @Test(arguments: MoveCapCase.allCases)
    func deleteAtLiveCapAndWithManyVaultsAlwaysWorks(_ cap: MoveCapCase) async throws {
        let victim = try cap == .payloadCap ? MoveFixtures.payloadCapAccount() : VaultFixtures.account(username: "ada")
        let others = cap == .liveAccountCap
            ? MoveFixtures.tinyAccounts(CredentialVaultLimits.accounts - 1)
            : [VaultFixtures.account(username: "grace", origin: "https://b.example")]
        try await VaultStoreFixture.with(
            accounts: [victim] + others, historyRows: 3, secondVault: cap == .sixteenVaults, extraVaults: cap == .sixteenVaults ? 14 : 0
        ) { f in
            let registryBefore = try f.storedRegistry()
            #expect(registryBefore.catalog.vaults.count == (cap == .sixteenVaults ? 32 : 2))
            let revisions = try f.moveHeadRevisions()

            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(snapshot.accounts.count == others.count + 1)
                let receipt = try await store.delete(
                    vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: snapshot.revision, using: access
                )
                #expect(receipt.revision == snapshot.revision + 1)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(after.accounts.count == others.count)
                #expect(!after.accounts.contains { $0.id == victim.id })
            }

            #expect(try f.moveHeadRevisions() == revisions.advanced())
            let registryAfter = try f.storedRegistry()
            let pair: Set<UUID> = [f.vaultID, f.trashID]
            #expect(registryAfter.catalog.vaults.count == registryBefore.catalog.vaults.count)
            let untouchedAfter = registryAfter.catalog.vaults.filter { !pair.contains($0.vaultID) }
            #expect(untouchedAfter == registryBefore.catalog.vaults.filter { !pair.contains($0.vaultID) })
            try f.expectMoveRegistryMatchesHeads()
            let entry = try #require(try f.moveTrashEntries().first)
            #expect(entry.body.ownerID == victim.id)
            #expect(entry.body.snapshot == victim)
            #expect(try f.moveRevisions(in: f.trashID, owner: victim.id).count == 3)
            for row in try f.moveHistoryRows(of: f.trashID) {
                #expect(try f.movePlaintext(of: row).count <= StoreFormat.historyRowBytes)
            }
            try f.verify()
        }
    }

    @Test(arguments: MoveNearCapScope.allCases)
    func nearCapAccountWithComparableRevisionsDeletes(_ scope: MoveNearCapScope) async throws {
        let victim = try MoveFixtures.payloadCapAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 3, historyRowBytes: Self.comparableRowBytes) { f in
            let removal: RemovalScope = scope == .account
                ? .account(victim.id)
                : .credential(ownerID: victim.id, subject: .password, passkeyID: nil)
            try await f.withWallStore { store, access in
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.delete(vaultID: f.vaultID, scope: removal, expectedRevision: snapshot.revision, using: access)
                #expect(receipt.revision == snapshot.revision + 1)
            }

            let rows = try f.moveHistoryRows(of: f.trashID)
            #expect(rows.count == 4)
            for row in rows {
                let plaintext = try f.movePlaintext(of: row).count
                #expect(plaintext <= StoreFormat.historyRowBytes, "a Trash row holds \(plaintext) plaintext bytes")
                if row.kind == .revision {
                    #expect(plaintext == Self.comparableRowBytes)
                } else {
                    // The snapshot (whole account) or the base64 PasswordValue (username alone is about 4 MB) fills the entry.
                    #expect(plaintext > Self.comparableRowBytes)
                }
            }
            #expect(try f.moveOwnedRowCount(in: f.vaultID, owner: victim.id) == (scope == .account ? 0 : 1))
            #expect(try f.moveRevisions(in: f.vaultID, owner: victim.id).isEmpty)
            try f.expectMoveRegistryMatchesHeads()
            try f.verify()
        }
    }

    // MARK: Sequences and chunks

    /// Real saved ciphertext (opens under the vault's own key and AAD) put back after the authenticated count went to zero. The MOVE
    /// of the owner's rows would take that count below zero; a bystander's delete would leave the extra row behind. Both have to end
    /// in `integrityFailure` and roll back, never a trap or a head that disagrees with the table.
    @Test(arguments: [true, false])
    func replayedSavedHistoryRowsAfterCountReachedZeroFailClosed(ownerIsRemoved: Bool) async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander], extraHistory: [FixtureHistoryRun(subject: .password, count: 3)]
        ) { f in
            let saved = try f.moveRevisions(in: f.vaultID, owner: victim.id, subject: .password)
            #expect(saved.count == 3)
            try await f.withWallStore { store, access in
                let first = try await store.delete(
                    vaultID: f.vaultID, scope: .credential(ownerID: victim.id, subject: .password, passkeyID: nil),
                    expectedRevision: try await store.snapshot(vaultID: f.vaultID, using: access).revision, using: access
                )
                #expect(try f.moveStoredHeads().source.historyCounts.revision == 0)
                try f.mutate { db in
                    for row in saved {
                        try StoreTables.putRecord(db, row)
                    }
                }

                let before = try f.headWriteImage()
                let removed = ownerIsRemoved ? victim.id : bystander.id
                do {
                    _ = try await store.delete(vaultID: f.vaultID, scope: .account(removed), expectedRevision: first.revision, using: access)
                    Issue.record("a delete committed over replayed history rows")
                } catch let error as CredentialStoreError {
                    guard case .integrityFailure = error else {
                        Issue.record("expected integrityFailure, got \(error)")
                        return
                    }
                }
                #expect(try f.headWriteImage() == before)
                #expect(try f.moveStoredHeads().source.historyCounts.revision == 0)
            }
        }
    }

    @Test func consecutiveDeletesOfDifferentAccountsVerify() async throws {
        let accounts = try (0..<3).map { _ in try MoveFixtures.fullAccount() }
        try await VaultStoreFixture.with(
            accounts: accounts,
            historyRows: 2,
            extraHistory: [
                FixtureHistoryRun(subject: .password, count: 2, ownerIndex: 1),
                FixtureHistoryRun(subject: .password, count: 2, ownerIndex: 2),
            ]
        ) { f in
            let scopes: [RemovalScope] = [
                .account(accounts[0].id),
                .account(accounts[1].id),
                .credential(ownerID: accounts[2].id, subject: .password, passkeyID: nil),
            ]
            let start = try f.moveHeadRevisions()
            try await f.withWallStore { store, access in
                var revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
                for (index, scope) in scopes.enumerated() {
                    let receipt = try await store.delete(vaultID: f.vaultID, scope: scope, expectedRevision: revision, using: access)
                    #expect(receipt.revision == revision + 1)
                    revision = receipt.revision
                    #expect(try f.moveHeadRevisions() == start.advanced(by: UInt64(index + 1)))
                    try f.verify()
                }
                let last = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(last.accounts.map(\.id) == [accounts[2].id])
            }

            let entries = try f.moveTrashEntries()
            #expect(Set(entries.map(\.body.ownerID)) == Set(accounts.map(\.id)))
            #expect(entries.filter { $0.body.scope == .account }.count == 2)
            #expect(try f.moveTransferGroups(of: f.trashID).count == 3)
            #expect(try f.moveTransferGroups(of: f.vaultID).count == 3)
            #expect(try f.moveHistoryRows(of: f.vaultID).isEmpty)
            #expect(try f.moveStoredHeads().trash.historyCounts == HistoryCounts(revision: 6, trashEntry: 3, tombstone: 0))
            let (fresh, freshAccess) = try await f.unlocked()
            #expect(try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess).accounts.count == 1)
            try f.verify()
        }
    }

    @Test(arguments: [999, 1_000, 1_001, 2_300])
    func deleteOfAnAccountWithMoreThan1000RevisionsChunksJournalRowsWithTheSameHeader(_ revisions: Int) async throws {
        let victim = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.with(accounts: [victim], historyRows: revisions) { f in
            let perRow = StoreFormat.journalOpsPerRow
            let outRows = max(1, (revisions + perRow - 1) / perRow)
            let inRows = (revisions + 1 + perRow - 1) / perRow
            let sourceBefore = try f.journalRows(of: f.vaultID).count
            #expect(sourceBefore == outRows)
            try await f.withWallStore { store, access in
                let revision = try await store.snapshot(vaultID: f.vaultID, using: access).revision
                _ = try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: revision, using: access)
            }

            #expect(try f.journalRows(of: f.vaultID).count == sourceBefore + outRows)
            #expect(try f.journalRows(of: f.trashID).count == inRows)
            let out = try #require(try f.moveTransferGroups(of: f.vaultID).first)
            let into = try #require(try f.moveTransferGroups(of: f.trashID).first)
            #expect(try f.moveTransferGroups(of: f.vaultID).count == 1)
            #expect(out.rows.count == outRows)
            #expect(into.rows.count == inRows)
            #expect(out.rows.allSatisfy { $0.transfer == out.header })
            #expect(into.rows.allSatisfy { $0.transfer == into.header })
            #expect(out.rows.dropLast().allSatisfy { $0.ops.count == perRow })
            #expect(into.rows.dropLast().allSatisfy { $0.ops.count == perRow })
            #expect(out.ops.count == revisions)
            #expect(into.ops.count == revisions + 1)
            #expect(out.header.transferID == into.header.transferID)
            let entryIDs = try f.moveTrashEntries().map(\.row.recordID)
            #expect(Set(out.ops.map(\.recordID)).union(entryIDs) == Set(into.ops.map(\.recordID)))
            try f.verify()
        }
    }
}
