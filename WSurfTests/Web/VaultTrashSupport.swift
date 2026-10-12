// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

// Task 8: plumbing shared by `VaultTrashTests`, `VaultPurgeTests` and `VaultResidueTests`. Rows are read back through the fixture; the
// store's own public API does every write under test.

nonisolated extension VaultStoreFixture {
    var freshAuthorization: FreshAuthorization {
        FreshAuthorization(credentialID: proof.credentialID, prf: proof.prf)
    }

    func trashEntryIDs() throws -> [UUID] {
        try recordIDs(of: trashID, kind: .trashEntry)
    }

    /// A store's current head revision of vault A, as the next write's CAS value.
    func nextRevision(_ store: ProfileVaultStore, _ access: VaultAccess) async throws -> UInt64 {
        try await store.snapshot(vaultID: vaultID, using: access).revision
    }

    /// An ordinary commit of `edit` applied to the live accounts.
    @discardableResult
    func edit(
        _ store: ProfileVaultStore, _ access: VaultAccess, _ change: ([CredentialAccount]) -> [CredentialAccount]
    ) async throws -> VaultCommitReceipt {
        let snapshot = try await store.snapshot(vaultID: vaultID, using: access)
        return try await store.commit(
            vaultID: vaultID, change(snapshot.accounts), expectedRevision: snapshot.revision, cause: nil, using: access
        )
    }

    @discardableResult
    func deleteAccount(_ store: ProfileVaultStore, _ access: VaultAccess, _ id: UUID) async throws -> VaultCommitReceipt {
        try await store.delete(vaultID: vaultID, scope: .account(id), expectedRevision: try await nextRevision(store, access), using: access)
    }

    @discardableResult
    func deleteCredential(
        _ store: ProfileVaultStore, _ access: VaultAccess, owner: UUID, subject: RecordSubject, passkeyID: UUID? = nil
    ) async throws -> VaultCommitReceipt {
        try await store.delete(
            vaultID: vaultID, scope: .credential(ownerID: owner, subject: subject, passkeyID: passkeyID),
            expectedRevision: try await nextRevision(store, access), using: access
        )
    }

    @discardableResult
    func undelete(_ store: ProfileVaultStore, _ access: VaultAccess, _ entryID: UUID) async throws -> VaultCommitReceipt {
        try await store.undelete(vaultID: vaultID, entryID: entryID, expectedRevision: try await nextRevision(store, access), using: access)
    }

    /// The Trash entry of `owner` (`subject` nil: the whole-account entry).
    func trashEntry(of owner: UUID, subject: RecordSubject? = nil) throws -> MoveTrashEntry {
        try #require(try moveTrashEntries().first { $0.body.ownerID == owner && $0.body.subject == subject })
    }

    /// Every revision row of `owner` in the source vault, oldest version first, opened.
    func sourceRevisions(of owner: UUID) throws -> [StoredRevision] {
        try revisions().filter { $0.ownerID == owner }.sorted { $0.version < $1.version }
    }

    /// Every decrypted plaintext of every reachable row of the pair (live rows, revisions, entries, tombstones) of vault A.
    func reachablePlaintexts() throws -> [Data] {
        var result: [Data] = []
        for vault in [vaultID, trashID] {
            for row in try moveLiveRows(of: vault) + moveHistoryRows(of: vault) {
                result.append(try moveSearchableBytes(of: row))
            }
        }
        return result
    }
}

nonisolated enum TrashFixtures {
    static let wall = MoveFixtures.wall

    /// username `ada`, password, TOTP, two passkeys, plus exchange ids on the account and `itemID` on the first passkey.
    static func exchangeAccount(id: UUID = UUID(), item: Data = Data([7, 7, 7]), account: Data = Data([8, 8])) throws -> CredentialAccount {
        var result = try MoveFixtures.fullAccount(id: id)
        result.exchangeAccountID = account
        result.exchangeItemID = item
        return result
    }

    /// A passkey sharing `other`'s relying party and credential id; the key and user handle are copied unless `differentKey`.
    static func clone(of other: WebsitePasskey, differentKey: Bool = false) throws -> WebsitePasskey {
        var copy = other
        copy.id = UUID()
        if differentKey {
            copy.privateKeyPKCS8 = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        }
        return copy
    }

    /// The same private key as `pkcs8` in another valid PKCS#8 encoding: without the optional curve and public-key fields.
    static func bareKeyEncoding(of pkcs8: Data) throws -> Data {
        let scalar = try PasskeyKeyEncoding.importPKCS8(pkcs8).rawRepresentation
        func der(_ tag: UInt8, _ contents: Data) -> Data {
            Data([tag, UInt8(contents.count)]) + contents  // every length here is below 128
        }
        let algorithm = der(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])) + der(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]))
        let ecPrivateKey = der(0x02, Data([1])) + der(0x04, scalar)
        let bare = der(0x30, der(0x02, Data([0])) + der(0x30, algorithm) + der(0x04, der(0x30, ecPrivateKey)))
        let imported = try PasskeyKeyEncoding.importPKCS8(bare)
        guard imported.rawRepresentation == scalar, bare != pkcs8 else { throw CredentialVaultError.invalidData }
        return bare
    }

    /// What a re-import of `owner`'s password or one-time code is: the file `owner` exports (raw exchange ids as stored), previewed
    /// against an empty vault, and the credential's identity in it.
    static func incoming(of owner: CredentialAccount, _ subject: RecordSubject) throws -> (preview: CredentialImportPreview, identity: CredentialIdentity) {
        let source = VaultSnapshot(revision: 1, accounts: [owner], blockedPasswordOrigins: [])
        let data = try CredentialExchangeCodec.export(
            source,
            selection: [CredentialExportSelection(accountID: owner.id, password: subject == .password, passkeyIDs: [], totp: subject == .totp)],
            format: .v1
        )
        let preview = try CredentialExchangeCodec.preview(data, against: VaultSnapshot(revision: 1, accounts: [], blockedPasswordOrigins: []))
        let identities = preview.candidates.flatMap(CredentialExchangeCodec.identities(in:))
        let identity = identities.first { identity in
            switch identity {
            case .password:
                subject == .password
            case .totp:
                subject == .totp
            case .passkey:
                false
            }
        }
        guard let identity else { throw CredentialVaultError.invalidData }
        return (preview, identity)
    }

    /// The class of `incoming` against the vault as it stands now: its live accounts and its removed identifiers.
    static func classify(
        _ incoming: (preview: CredentialImportPreview, identity: CredentialIdentity),
        _ f: VaultStoreFixture, _ store: ProfileVaultStore, _ access: VaultAccess
    ) async throws -> CredentialImportClass {
        let destination = ImportDestinationView(
            accounts: try await store.snapshot(vaultID: f.vaultID, using: access).accounts,
            removed: try await store.removedIdentifiers(vaultID: f.vaultID, using: access)
        )
        return try CredentialExchangeCodec.classify(incoming.identity, in: incoming.preview, destination: destination)
    }

    static func revisionBody(_ value: some Encodable, at date: Date = wall, cause: String? = nil) throws -> Data {
        try CredentialContent.canonicalJSON(RevisionBody(recordedAt: date, cause: cause, value: try CredentialContent.canonicalJSON(value)))
    }
}
