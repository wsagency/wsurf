// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing

@testable import WSurf
@testable import WSurfVault

// D5 PR-6: a pick reads its own row (`ProfileVaultStore.readOne`), the full read every row (`readLive`). The same tamper cases run
// through both, so the two keep the same row checks: a case on the picked row or on the head fails both reads alike, and a row
// rewritten at the same revision is read as it is on disk by both. A case on another row, or one only the row count sees, fails the
// full read only. The pick returns its own row's authentic value, which the head and the row's digest and AAD still prove, and the
// next list refuses the tampering: the trade-off the owner accepted for the single-row read. Synthetic vaults only; a failure never
// prints a value.

private nonisolated enum Tamper: CaseIterable, Sendable {
    /// The picked row's stored bytes changed.
    case pickedFlipped
    /// The picked row is gone, while the head still lists it.
    case pickedDeleted
    /// The head lists another digest for the picked row (a legitimately re-sealed head), the row itself unchanged.
    case pickedWrongCatalogDigest
    /// The picked row replaced by a valid seal of other content under its own AAD, the head's digest unchanged.
    case pickedResealed
    /// The picked row replaced by a valid seal of an older version; the head's digest follows, its version does not.
    case pickedOlderVersion
    /// The picked row sealed under the Trash's AAD; the head's digest follows.
    case pickedOtherVaultAAD
    /// The picked row sealed under another store's ids; the head's digest follows.
    case pickedForeignStore
    /// The picked row holding another row's sealed bytes; the head's digest follows.
    case pickedSwappedCiphertext
    /// Another credential's content sealed under the picked row's own AAD; the head's digest follows. Only the decoded id tells.
    case pickedOtherIDUnderItsAAD
    /// The picked row rewritten with a new password under its own AAD, the head's digest following at the same revision, after the
    /// list remembered its earlier decode: both reads must decode the row on disk, not reuse the earlier one.
    case pickedRewrittenSameRevision
    /// The head's stored bytes changed.
    case head
    /// Another row's stored bytes changed.
    case otherFlipped
    /// Another row gone, while the head still lists it.
    case otherDeleted
    /// A sealed row the head does not list.
    case extraRow

    static let rewrittenPassword = "pw-rewritten-5a90"

    /// What the two reads must do.
    enum Expected {
        /// Both refuse with `integrityFailure`: the picked row or the head.
        case bothRefuse
        /// The full read refuses; the pick returns its own row's password.
        case fullReadOnly
        /// Both return the picked row as rewritten on disk.
        case bothReadTheRewrite
    }

    var expected: Expected {
        switch self {
        case .otherFlipped, .otherDeleted, .extraRow:
            .fullReadOnly
        case .pickedRewrittenSameRevision:
            .bothReadTheRewrite
        default:
            .bothRefuse
        }
    }

    func apply(_ f: inout VaultStoreFixture, picked: CredentialAccount, other: CredentialAccount) throws {
        let vault = f.vaultID
        let foreign = StoreIDs(storeID: UUID(), profileID: f.ids.profileID)
        switch self {
        case .pickedFlipped:
            let row = try f.storedRecord(vault, picked.id)
            try Self.put(&f, row, sealed: VaultStoreFixture.flipped(row.sealed))
        case .pickedDeleted:
            try f.mutate { try StoreTables.deleteRecord($0, vaultID: vault, recordID: picked.id) }
        case .pickedWrongCatalogDigest:
            try Self.setCatalogDigest(&f, picked.id, Data(repeating: 0xEE, count: 32))
        case .pickedResealed:
            var changed = picked
            changed.password = "pw-resealed-4c1d"
            let row = try f.storedRecord(vault, picked.id)
            try Self.put(&f, row, sealed: try VaultStoreFixture.sealAccount(changed, ids: f.ids, vaultID: vault, key: f.dek))
        case .pickedOlderVersion:
            var row = try f.storedRecord(vault, picked.id)
            row.version = 1
            let sealed = try VaultStoreFixture.sealAccount(picked, ids: f.ids, vaultID: vault, key: f.dek, version: 1)
            try Self.put(&f, row, sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .pickedOtherVaultAAD:
            let sealed = try VaultStoreFixture.sealAccount(picked, ids: f.ids, vaultID: f.trashID, key: f.dek)
            try Self.put(&f, try f.storedRecord(vault, picked.id), sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .pickedForeignStore:
            let sealed = try VaultStoreFixture.sealAccount(picked, ids: foreign, vaultID: vault, key: f.dek)
            try Self.put(&f, try f.storedRecord(vault, picked.id), sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .pickedSwappedCiphertext:
            let sealed = try f.storedRecord(vault, other.id).sealed
            try Self.put(&f, try f.storedRecord(vault, picked.id), sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .pickedOtherIDUnderItsAAD:
            let aad = RowAAD(
                ids: f.ids, vaultID: vault, recordID: picked.id, kind: .account, ownerID: picked.id, subject: .account,
                version: VaultStoreFixture.accountVersion
            )
            let sealed = try StoreSeal.sealRow(try VaultFixtures.sortedJSON(other), key: f.dek, aad: aad)
            try Self.put(&f, try f.storedRecord(vault, picked.id), sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .pickedRewrittenSameRevision:
            var rewritten = picked
            rewritten.password = Self.rewrittenPassword
            let sealed = try VaultStoreFixture.sealAccount(rewritten, ids: f.ids, vaultID: vault, key: f.dek)
            try Self.put(&f, try f.storedRecord(vault, picked.id), sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .head:
            try f.mutate { db in
                guard let stored = try StoreTables.head(db, vaultID: vault) else { throw CredentialStoreError.malformed }
                try StoreTables.putHead(db, vaultID: vault, revision: stored.revision, sealed: VaultStoreFixture.flipped(stored.sealed))
            }
        case .otherFlipped:
            let row = try f.storedRecord(vault, other.id)
            try Self.put(&f, row, sealed: VaultStoreFixture.flipped(row.sealed))
        case .otherDeleted:
            try f.mutate { try StoreTables.deleteRecord($0, vaultID: vault, recordID: other.id) }
        case .extraRow:
            let extra = VaultFixtures.account(username: "extra", origin: "https://extra.example")
            let row = StoreTables.RecordRow(
                vaultID: vault, recordID: extra.id, kind: .account, ownerID: extra.id, subject: .account,
                version: VaultStoreFixture.accountVersion, sealed: try VaultStoreFixture.sealAccount(extra, ids: f.ids, vaultID: vault, key: f.dek)
            )
            try f.mutate { try StoreTables.putRecord($0, row) }
        }
    }

    private static func put(_ f: inout VaultStoreFixture, _ row: StoreTables.RecordRow, sealed: Data, catalogDigest: Data? = nil) throws {
        var replaced = row
        replaced.sealed = sealed
        try f.mutate { [replaced] in try StoreTables.putRecord($0, replaced) }
        if let catalogDigest {
            try setCatalogDigest(&f, row.recordID, catalogDigest)
        }
    }

    private static func setCatalogDigest(_ f: inout VaultStoreFixture, _ recordID: UUID, _ digest: Data) throws {
        try f.editHead(f.vaultID) { head in
            guard let index = head.liveCatalog.firstIndex(where: { $0.recordID == recordID }) else { return }
            head.liveCatalog[index] = LiveEntry(recordID: recordID, version: head.liveCatalog[index].version, digest: digest)
        }
    }
}

struct VaultPickReadTests {
    private static let password = "pw-picked-9b2e"

    private static func accounts() -> (picked: CredentialAccount, other: CredentialAccount, all: [CredentialAccount]) {
        let picked = VaultFixtures.account(username: "ada", password: password, origin: "https://pick.example")
        let other = VaultFixtures.account(username: "grace", password: "pw-other-31d0", origin: "https://other.example")
        let third = VaultFixtures.account(username: "alan", password: "pw-third-8e77", origin: "https://third.example")
        return (picked, other, [picked, other, third])
    }

    private static func isIntegrityFailure(_ error: (any Error)?) -> Bool {
        guard let error = error as? CredentialStoreError, case .integrityFailure = error else { return false }
        return true
    }

    /// Each tamper case through the pick (`autofillLogin`, which reads one row) and the full read (`snapshot`, every row), at the
    /// revision the list was read at, after that list remembered its decodes. Both reads refuse the picked row's and the head's cases
    /// alike, and both read a row rewritten at the same revision as it is on disk. For another row or an extra one the pick returns its
    /// own row's password and the full read refuses.
    @Test(arguments: Tamper.allCases)
    private func aPickAndTheFullReadMeetTheSameTampering(_ tamper: Tamper) async throws {
        let (picked, other, all) = Self.accounts()
        try await VaultStoreFixture.with(accounts: all) { fixture in
            var f = fixture
            let (store, access) = try await f.unlocked()
            let revision = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            try tamper.apply(&f, picked: picked, other: other)

            var pickError: (any Error)?
            var pickedPassword: String?
            do {
                let login = try await store.autofillLogin(
                    vaultID: f.vaultID, accountID: picked.id, field: .password, expectedRevision: revision, using: access
                )
                pickedPassword = login.candidate.id == picked.id ? login.password : nil
            } catch {
                pickError = error
            }
            var fullError: (any Error)?
            var fullPassword: String?
            do {
                fullPassword = try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first { $0.id == picked.id }?.password
            } catch {
                fullError = error
            }

            switch tamper.expected {
            case .bothRefuse:
                #expect(Self.isIntegrityFailure(pickError), "the pick did not refuse its own row's or the head's tampering")
                #expect(Self.isIntegrityFailure(fullError), "the full read did not refuse the tampering")
                let returnedNothing = pickedPassword == nil && fullPassword == nil
                #expect(returnedNothing, "a read returned a value")
            case .fullReadOnly:
                #expect(Self.isIntegrityFailure(fullError), "the full read did not refuse the tampering")
                let filled = pickError == nil && pickedPassword == Self.password
                #expect(filled, "the pick did not return its own row's password")
            case .bothReadTheRewrite:
                let rewritten = pickedPassword == Tamper.rewrittenPassword && fullPassword == Tamper.rewrittenPassword
                #expect(rewritten, "a read returned the row it decoded before, not the row on disk")
            }
        }
    }

    /// A pick compares the revision its list was read at before it opens any row. This is a proxy, not a count of the rows opened:
    /// after a write, a pick of a row tampered with since is `staleRevision`, which it could not be had the row been opened first (that
    /// would be `integrityFailure`). A credential the head does not list is `staleRevision` too.
    @Test func aStalePickOpensNoRow() async throws {
        let (picked, other, all) = Self.accounts()
        try await VaultStoreFixture.with(accounts: all) { fixture in
            var f = fixture
            let (store, access) = try await f.unlocked()
            let listed = try await store.autofillCandidates(vaultID: f.vaultID, using: access).revision
            var unknown: (any Error)?
            do {
                _ = try await store.autofillLogin(vaultID: f.vaultID, accountID: UUID(), field: .password, expectedRevision: listed, using: access)
            } catch {
                unknown = error
            }
            #expect(unknown as? CredentialVaultError == .staleRevision, "an unknown credential is not stale")

            _ = try await store.updatePasswordSavePolicy(vaultID: f.vaultID, ["https://c.example"], expectedRevision: listed, using: access)
            try Tamper.pickedFlipped.apply(&f, picked: picked, other: other)
            var stale: (any Error)?
            do {
                _ = try await store.autofillLogin(vaultID: f.vaultID, accountID: picked.id, field: .password, expectedRevision: listed, using: access)
            } catch {
                stale = error
            }
            #expect(stale as? CredentialVaultError == .staleRevision, "a pick after a write opened its row")
        }
    }
}
