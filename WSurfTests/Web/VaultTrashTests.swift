// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

// Task 8 (§11.2, §11.3, §11.3a): Trash and earlier-version listings, undelete (the reverse MOVE) and restoring an earlier revision.
// Shared plumbing lives in VaultTrashSupport.swift and VaultMoveSupport.swift.

// MARK: - Parameters

/// A live item that makes restoring a whole account clash.
nonisolated enum WholeCollision: CaseIterable, Sendable {
    case accountID, exchangeAccountID, exchangeItemID, originUsername, passkey

    var expected: UndeleteBlock {
        switch self {
        case .accountID:
            .idCollision
        case .exchangeAccountID, .exchangeItemID:
            .exchangeIDCollision
        case .originUsername:
            .originUsernameOverlap
        case .passkey:
            .passkeyCollision
        }
    }

    /// The live account that clashes with the deleted `victim`.
    func conflicting(with victim: CredentialAccount) throws -> CredentialAccount {
        switch self {
        case .accountID:
            return VaultFixtures.account(id: victim.id, username: "other", origin: "https://clash-id.example")
        case .exchangeAccountID:
            var account = VaultFixtures.account(username: "other", origin: "https://clash-exchange-account.example")
            account.exchangeAccountID = victim.exchangeAccountID
            return account
        case .exchangeItemID:
            var account = VaultFixtures.account(username: "other", origin: "https://clash-item.example")
            account.exchangeItemID = victim.exchangeItemID
            return account
        case .originUsername:
            return VaultFixtures.account(username: victim.username, origin: victim.origins[0])
        case .passkey:
            return VaultFixtures.account(
                username: "other", origin: "https://clash-key.example", passkeys: [try TrashFixtures.clone(of: victim.passkeys[0])]
            )
        }
    }
}

/// One rule of §11.3 for a single credential.
nonisolated enum SingleBlock: CaseIterable, Sendable {
    case passwordSlot, totpSlot, passkeyOnOwner, passkeyOnOther, passkeyBaseItemOnOther, originUsernameOnOther, ownerMissing
    case passwordItemOnOther, totpItemOnOther, passkeyOwnerItemOnOther, totpOriginUsernameOnOther, passkeyOriginUsernameOnOther

    var subject: RecordSubject {
        switch self {
        case .passwordSlot, .originUsernameOnOther, .passwordItemOnOther:
            .password
        case .totpSlot, .totpItemOnOther, .totpOriginUsernameOnOther:
            .totp
        case .passkeyOnOwner, .passkeyOnOther, .passkeyBaseItemOnOther, .ownerMissing, .passkeyOwnerItemOnOther, .passkeyOriginUsernameOnOther:
            .passkey
        }
    }

    var expected: UndeleteBlock {
        switch self {
        case .passwordSlot:
            .slotOccupied(.password)
        case .totpSlot:
            .slotOccupied(.totp)
        case .passkeyOnOwner, .passkeyOnOther:
            .passkeyCollision
        case .passkeyBaseItemOnOther, .passwordItemOnOther, .totpItemOnOther, .passkeyOwnerItemOnOther:
            .exchangeIDCollision
        case .originUsernameOnOther, .totpOriginUsernameOnOther, .passkeyOriginUsernameOnOther:
            .originUsernameOverlap
        case .ownerMissing:
            .ownerMissing
        }
    }
}

nonisolated enum RevisionKind: CaseIterable, Sendable {
    case password, totp, metadata

    var subject: RecordSubject {
        switch self {
        case .password:
            .password
        case .totp:
            .totp
        case .metadata:
            .metadata
        }
    }
}

struct VaultTrashTests {
    // MARK: Round trips

    @Test func deleteUndeleteRoundTripLeavesOneLogicalCopyWithFullHistory() async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander], historyRows: 3, extraHistory: [FixtureHistoryRun(subject: .totp, count: 2)]
        ) { f in
            let owned = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            #expect(owned.count == 5)
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id)
                let revisionsBefore = try await f.nextRevision(store, access)

                let receipt = try await f.undelete(store, access, entry.row.recordID)

                #expect(receipt.revision == revisionsBefore + 1)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(Set(after.accounts.map(\.id)) == [victim.id, bystander.id])
                #expect(after.accounts.first { $0.id == victim.id } == victim)
            }
            #expect(try f.moveHistoryRows(of: f.trashID).isEmpty)
            let restored = try f.moveRevisions(in: f.vaultID, owner: victim.id)
            #expect(Set(restored.map(\.moveKey)) == Set(owned.map(\.moveKey)))
            #expect(try f.moveOwnedRowCount(in: f.trashID, owner: victim.id) == 0)
            let heads = try f.moveStoredHeads()
            #expect(heads.trash.historyCounts == HistoryCounts(revision: 0, trashEntry: 0, tombstone: 0))
            #expect(heads.source.historyCounts.revision == 5)
            try f.expectMoveRegistryMatchesHeads()
            try f.verify()
        }
    }

    @Test(arguments: [3, 5])
    func deleteUndeleteDeleteAndLongerAlternationsVerify(_ rounds: Int) async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 2) { f in
            try await f.withWallStore { store, access in
                for round in 1...rounds {
                    try await f.deleteAccount(store, access, victim.id)
                    try f.verify()
                    #expect(try f.trashEntryIDs().count == 1, "round \(round)")
                    try await f.undelete(store, access, try f.trashEntry(of: victim.id).row.recordID)
                    try f.verify()
                    #expect(try f.trashEntryIDs().isEmpty, "round \(round)")
                    #expect(try f.moveRevisions(in: f.vaultID, owner: victim.id).count == 2, "round \(round)")
                }
                try await f.deleteAccount(store, access, victim.id)
                try f.verify()
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(after.accounts.isEmpty)
            }
            try f.expectMoveRegistryMatchesHeads()
        }
    }

    // MARK: Whole-account collisions

    @Test(arguments: WholeCollision.allCases)
    func everyWholeAccountCollisionBlocks(_ collision: WholeCollision) async throws {
        let victim = try TrashFixtures.exchangeAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [victim, bystander], historyRows: 2) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id)
                let conflicting = try collision.conflicting(with: victim)
                try await f.edit(store, access) { $0 + [conflicting] }

                let image = try f.headWriteImage()
                let revisions = try f.moveHeadRevisions()
                let preview = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                #expect(preview.block == collision.expected)
                #expect(preview.entry.id == entry.row.recordID)
                await #expect(throws: CredentialStoreError.undeleteBlocked(collision.expected)) {
                    try await f.undelete(store, access, entry.row.recordID)
                }
                #expect(try f.headWriteImage() == image)
                #expect(try f.moveHeadRevisions() == revisions)

                // Remove the conflicting live item: the very same undelete now goes through.
                try await f.deleteAccount(store, access, conflicting.id)
                let clear = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                #expect(clear.block == nil)
                try await f.undelete(store, access, entry.row.recordID)
                let after = try await store.snapshot(vaultID: f.vaultID, using: access)
                #expect(after.accounts.first { $0.id == victim.id } == victim)
            }
            try f.verify()
        }
    }

    @Test func passkeyWithSameIdentityDifferentKeyIsAnIdentityConflict() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id)
                let impostor = VaultFixtures.account(
                    username: "other", origin: "https://clash-key.example",
                    passkeys: [try TrashFixtures.clone(of: victim.passkeys[1], differentKey: true)]
                )
                try await f.edit(store, access) { $0 + [impostor] }
                let image = try f.headWriteImage()

                let preview = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                #expect(preview.block == .passkeyIdentityConflict)
                await #expect(throws: CredentialStoreError.undeleteBlocked(.passkeyIdentityConflict)) {
                    try await f.undelete(store, access, entry.row.recordID)
                }
                #expect(try f.headWriteImage() == image)
            }
        }
    }

    // MARK: Single credentials

    @Test func singleCredentialUndeleteRestoresIntoItsLiveOwner() async throws {
        var owner = try MoveFixtures.fullAccount()
        // The owner's own exchange ids never block restoring into the owner.
        owner.exchangeAccountID = Data([3, 3])
        owner.exchangeItemID = Data([6, 6])
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 2) { f in
            try await f.withWallStore { store, access in
                let passkeyID = owner.passkeys[0].id
                try await f.deleteCredential(store, access, owner: owner.id, subject: .password)
                try await f.deleteCredential(store, access, owner: owner.id, subject: .totp)
                try await f.deleteCredential(store, access, owner: owner.id, subject: .passkey, passkeyID: passkeyID)
                let left = try await store.snapshot(vaultID: f.vaultID, using: access).accounts[0]
                #expect(left.password == nil && left.totp == nil && left.passkeys.count == 1)
                #expect(try f.trashEntryIDs().count == 3)

                // The owner's own username, origins and passkey list never block.
                for subject in [RecordSubject.password, .totp, .passkey] {
                    let entry = try f.trashEntry(of: owner.id, subject: subject)
                    let preview = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                    #expect(preview.block == nil, "\(subject)")
                    #expect(preview.entry.scope == .credential && preview.entry.subject == subject)
                    try await f.undelete(store, access, entry.row.recordID)
                }
                let restored = try await store.snapshot(vaultID: f.vaultID, using: access).accounts[0]
                #expect(restored.username == owner.username && restored.password == owner.password)
                #expect(restored.totp == owner.totp)
                #expect(Set(restored.passkeys.map(\.id)) == Set(owner.passkeys.map(\.id)))
                #expect(restored.modifiedAt == TrashFixtures.wall)
            }
            #expect(try f.moveHistoryRows(of: f.trashID).isEmpty)
            try f.verify()
        }
    }

    @Test(arguments: SingleBlock.allCases)
    func singleCredentialUndeleteIsBlockedByTheRules(_ block: SingleBlock) async throws {
        var owner = try MoveFixtures.fullAccount()
        owner.exchangeAccountID = Data([3, 3])
        owner.exchangeItemID = Data([6, 6])
        owner.passkeys[0].base = ExchangeBase(contentHash: Data([1]), itemID: Data([5, 5]))
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                let passkey = owner.passkeys[0]
                try await f.deleteCredential(
                    store, access, owner: owner.id, subject: block.subject, passkeyID: block.subject == .passkey ? passkey.id : nil
                )
                let entry = try f.trashEntry(of: owner.id, subject: block.subject)
                switch block {
                case .passwordSlot:
                    try await f.edit(store, access) { accounts in
                        accounts.map { var live = $0; live.username = "new"; live.password = "new-password"; return live }
                    }
                case .totpSlot:
                    try await f.edit(store, access) { accounts in
                        accounts.map { var live = $0; live.totp = VaultFixtures.totp(); return live }
                    }
                case .passkeyOnOwner:
                    let twin = try TrashFixtures.clone(of: passkey)
                    try await f.edit(store, access) { accounts in accounts.map { var live = $0; live.passkeys.append(twin); return live } }
                case .passkeyOnOther:
                    let twin = try TrashFixtures.clone(of: passkey)
                    let other = VaultFixtures.account(username: "grace", origin: "https://b.example", passkeys: [twin])
                    try await f.edit(store, access) { $0 + [other] }
                case .passkeyBaseItemOnOther:
                    var other = VaultFixtures.account(username: "grace", origin: "https://b.example")
                    other.exchangeItemID = passkey.base?.itemID
                    try await f.edit(store, access) { $0 + [other] }
                case .originUsernameOnOther:
                    var withTOTP = VaultFixtures.account(username: owner.username, password: nil, origin: owner.origins[0])
                    withTOTP.totp = VaultFixtures.totp()
                    try await f.edit(store, access) { accounts in
                        accounts.map { var live = $0; live.username = ""; return live } + [withTOTP]
                    }
                case .passwordItemOnOther, .totpItemOnOther, .passkeyOwnerItemOnOther:
                    // The owner moves to another exchange item after the removal and another account takes the id the entry was removed
                    // with: the id the entry recorded decides, never the owner's current one.
                    var other = VaultFixtures.account(username: "grace", origin: "https://b.example")
                    other.exchangeItemID = owner.exchangeItemID
                    try await f.edit(store, access) { accounts in
                        accounts.map { var live = $0; live.exchangeItemID = Data([0x42]); return live } + [other]
                    }
                case .totpOriginUsernameOnOther, .passkeyOriginUsernameOnOther:
                    // A one-time code belongs to the owner's login; a passkey brings its own user name (also "ada" here).
                    let clash = VaultFixtures.account(username: owner.username, origin: owner.origins[0])
                    try await f.edit(store, access) { $0 + [clash] }
                case .ownerMissing:
                    try await f.deleteAccount(store, access, owner.id)
                }
                let image = try f.headWriteImage()

                let preview = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                #expect(preview.block == block.expected, "\(block)")
                await #expect(throws: CredentialStoreError.undeleteBlocked(block.expected)) {
                    try await f.undelete(store, access, entry.row.recordID)
                }
                #expect(try f.headWriteImage() == image)
            }
            try f.verify()
        }
    }

    @Test func aCredentialsPasskeyWithSameIdentityDifferentKeyIsAnIdentityConflict() async throws {
        let owner = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                let passkey = owner.passkeys[0]
                try await f.deleteCredential(store, access, owner: owner.id, subject: .passkey, passkeyID: passkey.id)
                let impostor = try TrashFixtures.clone(of: passkey, differentKey: true)
                try await f.edit(store, access) { accounts in accounts.map { var live = $0; live.passkeys.append(impostor); return live } }
                let entry = try f.trashEntry(of: owner.id, subject: .passkey)
                let preview = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                #expect(preview.block == .passkeyIdentityConflict)
            }
        }
    }

    // §13.3 identity: the normalized public key, not the stored DER bytes.
    @Test func theSameKeyInAnotherEncodingIsADuplicateNotAnIdentityConflict() async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        var twin = try TrashFixtures.clone(of: victim.passkeys[0])
        twin.privateKeyPKCS8 = try TrashFixtures.bareKeyEncoding(of: twin.privateKeyPKCS8)
        #expect(twin.privateKeyPKCS8 != victim.passkeys[0].privateKeyPKCS8)
        let other = VaultFixtures.account(username: "other", origin: "https://clash-key.example", passkeys: [twin])

        try await VaultStoreFixture.with(accounts: [victim, bystander], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                // One credential of the owner, restored while a live twin of it sits in another account.
                try await f.deleteCredential(store, access, owner: victim.id, subject: .passkey, passkeyID: victim.passkeys[0].id)
                try await f.edit(store, access) { $0 + [other] }
                let single = try f.trashEntry(of: victim.id, subject: .passkey)
                #expect(try await store.previewUndelete(vaultID: f.vaultID, entryID: single.row.recordID, using: access).block == .passkeyCollision)
                try await f.deleteAccount(store, access, other.id)

                // The whole account (its remaining passkey is another credential), with a live twin of that one in another encoding.
                try await f.deleteAccount(store, access, victim.id)
                let whole = try f.trashEntry(of: victim.id)
                var mirrored = try TrashFixtures.clone(of: victim.passkeys[1])
                mirrored.privateKeyPKCS8 = try TrashFixtures.bareKeyEncoding(of: mirrored.privateKeyPKCS8)
                let mirror = VaultFixtures.account(username: "mirror", origin: "https://mirror.example", passkeys: [mirrored])
                try await f.edit(store, access) { $0 + [mirror] }
                #expect(try await store.previewUndelete(vaultID: f.vaultID, entryID: whole.row.recordID, using: access).block == .passkeyCollision)
            }
            try f.verify()
        }
    }

    @Test func theSameKeyWithAnotherUserHandleIsAnIdentityConflict() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id)
                var twin = try TrashFixtures.clone(of: victim.passkeys[0])
                twin.userHandle = Data([0x77])
                let other = VaultFixtures.account(username: "other", origin: "https://clash-key.example", passkeys: [twin])
                try await f.edit(store, access) { $0 + [other] }
                #expect(try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access).block == .passkeyIdentityConflict)
            }
        }
    }

    // MARK: Earlier versions

    /// Edits `account` so a revision of `kind` is created, returning the live account before and the edited one.
    private static func edited(_ account: CredentialAccount, _ kind: RevisionKind) -> CredentialAccount {
        var edited = account
        switch kind {
        case .password:
            edited.password = "second-password"
            edited.username = "grace"
        case .totp:
            edited.totp = TOTPGenerator(secret: Data([9, 9, 9]), algorithm: .sha256, period: 60, digits: 8, issuer: "Other", userName: nil)
        case .metadata:
            edited.displayName = "Renamed"
            edited.origins = ["https://example.test", "https://second.example"]
            edited.loginURLs = [URL(string: "https://example.test/second")!]
        }
        return edited
    }

    @Test(arguments: RevisionKind.allCases)
    func restoreEarlierRevisionKeepsTheChosenRevisionAndMakesCurrentANewOne(_ kind: RevisionKind) async throws {
        let original = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [original]) { f in
            try await f.withWallStore { store, access in
                let second = Self.edited(original, kind)
                try await f.edit(store, access) { _ in [second] }
                let chosen = try #require(try f.sourceRevisions(of: original.id).first { $0.subject == kind.subject })
                let chosenRow = try f.storedRecord(f.vaultID, chosen.recordID)
                let known = Set(try f.sourceRevisions(of: original.id).map(\.recordID))

                let page = try await store.revisionPage(vaultID: f.vaultID, accountID: original.id, after: nil, using: access)
                let item = try #require(page.items.first { $0.id == chosen.recordID })
                #expect(item.subject == kind.subject && item.version == chosen.version && item.recordedAt == TrashFixtures.wall)

                let preview = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: chosen.recordID, using: access)
                let before = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.restoreRevision(
                    vaultID: f.vaultID, revisionID: chosen.recordID, expectedRevision: before.revision, using: access
                )
                #expect(receipt.revision == before.revision + 1)
                let live = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                var expected = preview
                expected.modifiedAt = live.modifiedAt
                #expect(live == expected)
                switch kind {
                case .password:
                    #expect(live.password == original.password && live.username == original.username)
                case .totp:
                    #expect(live.totp == original.totp)
                case .metadata:
                    #expect(live.displayName == original.displayName && live.origins == original.origins)
                    #expect(live.loginURLs == original.loginURLs)
                }

                #expect(try f.storedRecord(f.vaultID, chosen.recordID) == chosenRow)  // byte-identical
                let added = try f.revisions(excluding: known).filter { $0.subject == kind.subject }
                #expect(added.count == 1, "the superseded current value is one new revision")
            }
            #expect(try f.moveHistoryRows(of: f.trashID).isEmpty)
            try f.verify()
        }
    }

    /// Restore is not delete: a valid password revision can hold no password (username only). Restoring it over a real password
    /// supersedes that password as a NEW revision and leaves the chosen row byte-identical; nothing goes to the Trash.
    @Test func restoringAPasswordlessRevisionOverARealPasswordIsARevisionNotARemoval() async throws {
        let usernameOnly = VaultFixtures.account(username: "ada", password: nil)
        try await VaultStoreFixture.with(accounts: [usernameOnly]) { f in
            try await f.withWallStore { store, access in
                var real = usernameOnly
                real.password = "real-password"
                try await f.edit(store, access) { _ in [real] }
                let chosen = try #require(try f.sourceRevisions(of: usernameOnly.id).first { $0.subject == .password })
                let chosenRow = try f.storedRecord(f.vaultID, chosen.recordID)
                let known = Set(try f.sourceRevisions(of: usernameOnly.id).map(\.recordID))

                let preview = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: chosen.recordID, using: access)
                #expect(preview.password == nil && preview.username == "ada")
                let before = try await store.snapshot(vaultID: f.vaultID, using: access)
                let receipt = try await store.restoreRevision(
                    vaultID: f.vaultID, revisionID: chosen.recordID, expectedRevision: before.revision, using: access
                )
                #expect(receipt.revision == before.revision + 1)
                let live = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(live.password == nil && live.username == "ada")

                #expect(try f.storedRecord(f.vaultID, chosen.recordID) == chosenRow)  // still active, byte-identical
                let added = try f.revisions(excluding: known).filter { $0.subject == .password }
                #expect(added.count == 1, "the superseded current password is one new revision")
                let value = try JSONDecoder().decode(PasswordValue.self, from: try #require(added.first).body.value)
                #expect(value.password == "real-password" && value.username == "ada")
            }
            #expect(try f.trashEntryIDs().isEmpty, "nothing was removed")
            #expect(try f.moveHistoryRows(of: f.trashID).isEmpty)
            try f.verify()
        }
    }

    @Test func restoringARevisionWhoseResultIsInvalidIsRefusedWithNothingWritten() async throws {
        let account = VaultFixtures.account(username: "ada")
        var projection = try MetadataProjection(account)
        projection.origins = ["https://example.test", "https://example.test"]  // duplicate origins can never be live
        let planted = try TrashFixtures.revisionBody(projection)
        try await VaultStoreFixture.with(
            accounts: [account], extraHistory: [FixtureHistoryRun(subject: .metadata, count: 1, plaintext: planted)]
        ) { f in
            try await f.withWallStore { store, access in
                let revision = try #require(try f.sourceRevisions(of: account.id).first)
                let image = try f.headWriteImage()
                await #expect(throws: (any Error).self) {
                    _ = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: revision.recordID, using: access)
                }
                await #expect(throws: (any Error).self) {
                    _ = try await store.restoreRevision(
                        vaultID: f.vaultID, revisionID: revision.recordID, expectedRevision: try await f.nextRevision(store, access),
                        using: access
                    )
                }
                #expect(try f.headWriteImage() == image)
            }
            try f.verify()
        }
    }

    @Test func restoreRevisionAppliesOnlyTheTypedValue() async throws {
        var original = try MoveFixtures.fullAccount()
        original.basicAuthenticationMetadata = RevisionFixtures.basicAuthAccount().basicAuthenticationMetadata
        original.exchangeMetadata = try VaultFixtures.sortedJSON(VaultFixtures.exchangeMetadata())
        original.exchangeAccountID = Data([4, 4])
        original.exchangeItemID = Data([5, 5])
        try await VaultStoreFixture.with(accounts: [original]) { f in
            try await f.withWallStore { store, access in
                // Change every part at once; each revision then restores only its own part.
                var changed = original
                changed.username = "grace"
                changed.password = "other-password"
                changed.basicAuthenticationMetadata?.password?.label = "Other"
                changed.totp = TOTPGenerator(secret: Data([9, 9]), algorithm: .sha256, period: 60, digits: 8, issuer: "Other", userName: nil)
                changed.displayName = "Renamed"
                changed.origins = ["https://renamed.example"]
                changed.loginURLs = [URL(string: "https://renamed.example/login")!]
                changed.exchangeAccountID = Data([6, 6])
                changed.exchangeItemID = Data([7, 7])
                changed = try changed.editingExchange { $0.collections = [] }
                try await f.edit(store, access) { _ in [changed] }
                let current = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)

                for kind in RevisionKind.allCases {
                    let revision = try #require(try f.sourceRevisions(of: original.id).first { $0.subject == kind.subject })
                    let preview = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: revision.recordID, using: access)
                    var expected = current
                    switch kind {
                    case .password:
                        expected.username = original.username
                        expected.password = original.password
                        expected.basicAuthenticationMetadata = original.basicAuthenticationMetadata
                    case .totp:
                        expected.totp = original.totp
                    case .metadata:
                        expected.displayName = original.displayName
                        expected.origins = original.origins
                        expected.loginURLs = original.loginURLs
                        expected.exchangeMetadata = try MetadataProjection(original).exchange
                        expected.exchangeAccountID = original.exchangeAccountID
                        expected.exchangeItemID = original.exchangeItemID
                    }
                    #expect(preview == expected, "\(kind)")
                }
            }
        }
    }

    @Test(arguments: [RecordSubject.password, .totp, .metadata])
    func aRevisionWhoseBytesAreTheWrongTypeIsRefusedWithNothingWritten(_ subject: RecordSubject) async throws {
        let account = try MoveFixtures.fullAccount()
        // A whole serialized account is the classic mistake: it decodes leniently as any of the three typed values.
        let wrong = try TrashFixtures.revisionBody(account)
        try await VaultStoreFixture.with(accounts: [account], extraHistory: [FixtureHistoryRun(subject: subject, count: 1, plaintext: wrong)]) { f in
            try await f.withWallStore { store, access in
                let revision = try #require(try f.sourceRevisions(of: account.id).first)
                let image = try f.headWriteImage()
                await #expect(throws: CredentialVaultError.invalidData) {
                    _ = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: revision.recordID, using: access)
                }
                await #expect(throws: CredentialVaultError.invalidData) {
                    _ = try await store.restoreRevision(
                        vaultID: f.vaultID, revisionID: revision.recordID, expectedRevision: try await f.nextRevision(store, access),
                        using: access
                    )
                }
                #expect(try f.headWriteImage() == image)
            }
        }
    }

    // MARK: Listings

    @Test func listingsPageByFifty() async throws {
        let keeper = VaultFixtures.account(username: "keeper", origin: "https://keeper.example")
        let removed = MoveFixtures.tinyAccounts(120)
        let history = FixtureHistoryRun(
            subject: .password, count: 120,
            plaintext: try TrashFixtures.revisionBody(PasswordValue(username: "keeper", password: "old", basicAuthenticationMetadata: nil))
        )
        try await VaultStoreFixture.with(accounts: [keeper] + removed, extraHistory: [history]) { f in
            try await f.withWallStore { store, access in
                try await f.edit(store, access) { $0.filter { $0.id == keeper.id } }

                var pages: [TrashPage] = []
                var cursor: Int?
                repeat {
                    let page = try await store.trashPage(vaultID: f.vaultID, after: cursor, using: access)
                    pages.append(page)
                    cursor = page.next
                } while cursor != nil
                #expect(pages.map(\.items.count) == [50, 50, 20])
                #expect(pages.last?.next == nil)
                let ids = pages.flatMap(\.items).map(\.id)
                #expect(Set(ids).count == 120)
                #expect(Set(ids) == Set(try f.trashEntryIDs()))
                #expect(pages.flatMap(\.items).allSatisfy { $0.scope == .account && $0.subject == nil })

                var revisionPages: [RevisionPage] = []
                cursor = nil
                repeat {
                    let page = try await store.revisionPage(vaultID: f.vaultID, accountID: keeper.id, after: cursor, using: access)
                    revisionPages.append(page)
                    cursor = page.next
                } while cursor != nil
                #expect(revisionPages.map(\.items.count).reduce(0, +) == (try f.moveRevisions(in: f.vaultID, owner: keeper.id).count))
                #expect(revisionPages.dropLast().allSatisfy { $0.items.count == 50 })
            }
        }
    }

    @Test func trashItemsCarryTheScopeLabelAndRevisionCount() async throws {
        let victim = try MoveFixtures.fullAccount(displayName: "Work")
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 3) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: victim.id, subject: .totp)
                try await f.deleteAccount(store, access, victim.id)
                let items = try await store.trashPage(vaultID: f.vaultID, after: nil, using: access).items
                #expect(items.count == 2)
                let whole = try #require(items.first { $0.scope == .account })
                #expect(whole.ownerID == victim.id && whole.subject == nil && !whole.label.isEmpty)
                #expect(whole.revisionCount == 3)
                let single = try #require(items.first { $0.scope == .credential })
                #expect(single.subject == .totp && single.ownerID == victim.id)
            }
        }
    }

    // MARK: Removed identifiers

    @Test func removedIdentifiersCarryOnlyIdsAndCoverTombstones() async throws {
        var victim = try TrashFixtures.exchangeAccount()
        victim.password = "planted-password-9"
        victim.totp = TOTPGenerator(secret: Data("planted-totp-secret".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: nil)
        let native = VaultFixtures.account(username: "native", origin: "https://native.example")
        try await VaultStoreFixture.with(accounts: [victim, native], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                try await f.deleteAccount(store, access, native.id)
                let entry = try f.trashEntry(of: victim.id)
                let nativeEntry = try f.trashEntry(of: native.id)

                let live = try await store.removedIdentifiers(vaultID: f.vaultID, using: access)
                let mine = live.items.filter { $0.entryID == entry.row.recordID }
                #expect(mine.count == 1 + victim.passkeys.count)  // the account, then one row per passkey
                #expect(mine.allSatisfy { !$0.isTombstone && $0.accountID == victim.id })
                #expect(mine.allSatisfy { $0.exchangeAccountID == victim.exchangeAccountID && $0.exchangeItemID == victim.exchangeItemID })
                #expect(mine.filter { $0.passkeyCredentialID == nil }.count == 1)
                #expect(Set(mine.compactMap(\.passkeyCredentialID)) == Set(victim.passkeys.map(\.credentialID)))
                #expect(Set(mine.compactMap(\.rpID)) == Set(victim.passkeys.map(\.rpID)))
                let nativeRows = live.items.filter { $0.entryID == nativeEntry.row.recordID }
                #expect(nativeRows.count == 1 && nativeRows[0].exchangeAccountID == nil && nativeRows[0].exchangeItemID == nil)

                try await store.purge(
                    vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access
                ).expectRemoved(2)
                let purged = try await store.removedIdentifiers(vaultID: f.vaultID, using: access)
                #expect(purged.items.count == live.items.count)
                #expect(purged.items.allSatisfy { $0.isTombstone })
                #expect(Set(purged.items.map(\.entryID)) == Set(live.items.map(\.entryID)))
                let accountLevel = purged.items.filter { $0.accountID == victim.id && $0.passkeyCredentialID == nil }
                #expect(accountLevel.count == 1 && accountLevel[0].exchangeItemID == victim.exchangeItemID)

                for items in [live, purged] {
                    let text = String(describing: items)
                    for secret in ["planted-password-9", "planted-totp-secret", victim.passkeys[0].privateKeyPKCS8.base64EncodedString()] {
                        #expect(!text.contains(secret))
                    }
                }
            }
        }
    }
}

/// §11.3/§13.3: a single-credential Trash entry keeps its owner's raw exchange ids from the moment of removal, so a re-import of the
/// removed credential is still `previouslyRemoved` after the owner's ids change, the owner is deleted, or the entry is purged.
struct VaultTrashIdentityTests {
    @Test(arguments: [RecordSubject.password, .totp])
    func aCredentialEntryKeepsItsOwnersOriginalExchangeIDsForReimport(_ subject: RecordSubject) async throws {
        // Imported raw ids differ from anything derived from the local UUID.
        let owner = try TrashFixtures.exchangeAccount(item: Data([1, 2, 3]), account: Data([4, 5]))
        let incoming = try TrashFixtures.incoming(of: owner, subject)
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: owner.id, subject: subject)
                let entry = try f.trashEntry(of: owner.id, subject: subject)
                let entryID = entry.row.recordID
                #expect(entry.body.exchangeAccountID == owner.exchangeAccountID && entry.body.exchangeItemID == owner.exchangeItemID)
                let inTrash = CredentialImportClass.previouslyRemoved(entryID: entryID, isTombstone: false)

                // The live owner's ids change (while they matched, the live account itself would be the match); the entry still matches by
                // the ids it was removed with.
                try await f.edit(store, access) { accounts in
                    accounts.map { var live = $0; live.exchangeAccountID = Data([9]); live.exchangeItemID = Data([9, 9]); return live }
                }
                #expect(try await TrashFixtures.classify(incoming, f, store, access) == inTrash)

                // The owner is deleted too: its own whole-account entry carries the new ids, the credential entry the old ones.
                try await f.deleteAccount(store, access, owner.id)
                #expect(try await TrashFixtures.classify(incoming, f, store, access) == inTrash)
                let rows = try await store.removedIdentifiers(vaultID: f.vaultID, using: access).items.filter { $0.entryID == entryID }
                #expect(rows.count == 1 && rows[0].exchangeAccountID == owner.exchangeAccountID && rows[0].exchangeItemID == owner.exchangeItemID)

                // Only the credential entry is purged: its tombstone keeps the same ids.
                try await store.purge(
                    vaultID: f.vaultID, entryIDs: [entryID], emptyAll: false, authorization: f.freshAuthorization, using: access
                ).expectRemoved(1)
                let tombstone = try await store.removedIdentifiers(vaultID: f.vaultID, using: access).items.filter { $0.entryID == entryID }
                #expect(tombstone.count == 1 && tombstone[0].isTombstone)
                #expect(tombstone[0].exchangeAccountID == owner.exchangeAccountID && tombstone[0].exchangeItemID == owner.exchangeItemID)
                let purged = CredentialImportClass.previouslyRemoved(entryID: entryID, isTombstone: true)
                #expect(try await TrashFixtures.classify(incoming, f, store, access) == purged)
            }
            try f.verify()
        }
    }

    @Test func aNativeOwnersCredentialEntryHasNoExchangeIDs() async throws {
        let owner = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: owner.id, subject: .totp)
                try await f.deleteCredential(store, access, owner: owner.id, subject: .passkey, passkeyID: owner.passkeys[0].id)
                for subject in [RecordSubject.totp, .passkey] {
                    let body = try f.trashEntry(of: owner.id, subject: subject).body
                    #expect(body.exchangeAccountID == nil && body.exchangeItemID == nil)
                }
                let rows = try await store.removedIdentifiers(vaultID: f.vaultID, using: access).items
                #expect(rows.count == 2 && rows.allSatisfy { $0.exchangeAccountID == nil && $0.exchangeItemID == nil })
            }
        }
    }

    @Test func aStoredEmptyExchangeIDIsInvalidData() async throws {
        var owner = try MoveFixtures.fullAccount()
        owner.exchangeItemID = Data()
        try await VaultStoreFixture.with(accounts: [owner], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: owner.id, subject: .totp)
                await #expect(throws: CredentialVaultError.invalidData) {
                    try await store.removedIdentifiers(vaultID: f.vaultID, using: access)
                }
            }
        }
    }
}

nonisolated extension PurgeReceipt {
    func expectRemoved(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(removedEntries == count, sourceLocation: sourceLocation)
    }
}
