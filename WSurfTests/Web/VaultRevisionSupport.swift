// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

// Task 7: plumbing for `VaultRevisionTests` (a store with an injected wall clock, readback of revision rows, fixture accounts).

nonisolated enum RevisionFixtures {
    /// The injected `wall()` of every store `withRig` builds.
    static let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func basicAuthAccount() -> CredentialAccount {
        var account = VaultFixtures.account(username: "ada", password: "pw-secret")
        account.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: Data([1]), label: "User", fieldType: .string),
            password: CredentialEditableFieldMetadata(id: Data([2]), label: "Pass", fieldType: .concealedString)
        )
        return account
    }

    static func totpAccount() -> CredentialAccount {
        var account = VaultFixtures.account(username: "ada", password: "pw-secret")
        account.totp = VaultFixtures.totp()
        return account
    }

    /// Every part populated with a distinctive value: `plantedSecrets(of:)` lists the bytes no metadata revision may carry.
    static func plantedAccount() throws -> CredentialAccount {
        var account = try VaultFixtures.richAccount()
        account.username = "planted-user-name"
        account.password = "planted-password-9"
        account.totp = TOTPGenerator(
            secret: Data("planted-totp-secret".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: nil
        )
        account.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: Data([1]), label: "planted-user-label", fieldType: .string),
            password: CredentialEditableFieldMetadata(id: Data([2]), label: "planted-pass-label", fieldType: .concealedString)
        )
        return account
    }

    /// Raw and base64 (how `Data` is spelled inside JSON) forms of every secret of `account`.
    static func plantedSecrets(of account: CredentialAccount) -> [Data] {
        var texts = [account.username, account.password ?? "", account.basicAuthenticationMetadata?.username?.label ?? ""]
        texts.append(account.basicAuthenticationMetadata?.password?.label ?? "")
        var blobs = account.passkeys.flatMap { [$0.privateKeyPKCS8, $0.credentialID] }
        blobs.append(account.totp?.secret ?? Data())
        return texts.map { Data($0.utf8) } + blobs + blobs.map { Data($0.base64EncodedString().utf8) }
    }
}

nonisolated extension Data {
    func includes(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}

nonisolated extension CredentialAccount {
    /// The account with its stored typed exchange metadata edited and re-encoded the way the exchange codec writes it.
    func editingExchange(_ change: (inout VaultFixtures.ExchangeMetadata) -> Void) throws -> CredentialAccount {
        var metadata = try JSONDecoder().decode(VaultFixtures.ExchangeMetadata.self, from: try #require(exchangeMetadata))
        change(&metadata)
        var edited = self
        edited.exchangeMetadata = try VaultFixtures.sortedJSON(metadata)
        return edited
    }
}

nonisolated extension StoreSnapshot {
    func account(_ id: UUID) throws -> CredentialAccount {
        try #require(accounts.first { $0.id == id })
    }
}

/// One `revision` row of the active vault, opened with the held DEK.
nonisolated struct StoredRevision {
    let recordID: UUID
    let ownerID: UUID
    let subject: RecordSubject
    let version: UInt64
    let sealed: Data
    let plaintext: Data
    let body: RevisionBody

    /// The typed superseded value (`PasswordValue`, `TOTPGenerator` or `MetadataProjection`).
    func value<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body.value)
    }
}

/// The two counters every successful write advances by exactly one.
nonisolated struct WriteMarks {
    let head: UInt64
    let registry: UInt64
}

nonisolated extension VaultStoreFixture {
    func marks() throws -> WriteMarks {
        WriteMarks(head: try headRevision(of: vaultID), registry: try storedRegistry().revision)
    }

    /// The receipt, the source head and the registry each moved by exactly one write.
    func expectOneWrite(since before: WriteMarks, receipt: VaultCommitReceipt) throws {
        #expect(receipt.revision == before.head + 1)
        #expect(try headRevision(of: vaultID) == before.head + 1)
        #expect(try storedRegistry().revision == before.registry + 1)
    }

    /// Every active-vault `revision` row not in `known`, opened under the held DEK (rows in `known` are never decoded).
    func revisions(excluding known: Set<UUID> = []) throws -> [StoredRevision] {
        try recordIDs(of: vaultID, kind: .revision).filter { !known.contains($0) }.map { recordID in
            let row = try storedRecord(vaultID, recordID)
            let aad = RowAAD(
                ids: ids, vaultID: vaultID, recordID: recordID, kind: .revision, ownerID: row.ownerID, subject: row.subject, version: row.version
            )
            let plaintext = try StoreSeal.openRow(row.sealed, key: dek, aad: aad)
            return StoredRevision(
                recordID: recordID,
                ownerID: row.ownerID,
                subject: row.subject,
                version: row.version,
                sealed: row.sealed,
                plaintext: plaintext,
                body: try JSONDecoder().decode(RevisionBody.self, from: plaintext)
            )
        }
    }
}

/// A fixture, and a store on its source vault whose wall clock is `RevisionFixtures.stamp`.
nonisolated struct RevisionRig {
    let f: VaultStoreFixture
    let store: ProfileVaultStore
    let access: VaultAccess

    func snapshot() async throws -> StoreSnapshot {
        try await store.snapshot(vaultID: f.vaultID, using: access)
    }

    /// Commits against the head's current revision.
    func commit(_ accounts: [CredentialAccount], cause: String? = nil) async throws -> VaultCommitReceipt {
        try await store.commit(
            vaultID: f.vaultID, accounts, expectedRevision: f.headRevision(of: f.vaultID), cause: cause, using: access
        )
    }
}

nonisolated extension VaultStoreFixture {
    /// `StoreTracker.makeStore` does not expose `wall`, so the store is built here and closed here (the tracker cannot track it).
    static func withRig(
        accounts: [CredentialAccount],
        historyRows: Int = 0,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (RevisionRig) async throws -> Void
    ) async throws {
        try await with(accounts: accounts, historyRows: historyRows) { f in
            let stamp = RevisionFixtures.stamp
            let store = ProfileVaultStore(profileID: f.env.profileID, directory: f.env.directory, defaults: f.env.defaults, wall: { stamp })
            let access = f.beginAccess()
            do {
                try await store.unlockInitialized(
                    vaultID: f.vaultID,
                    credentialID: f.proof.credentialID,
                    prf: f.proof.prf,
                    access: access,
                    verifying: nil,
                    scratchWarning: nil
                )
                try await body(RevisionRig(f: f, store: store, access: access))
            } catch {
                await store.close()
                throw error
            }
            await store.close()
        }
    }
}
