// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Task 8 (item 17, §11.4): after a password and a TOTP were removed, the metadata edited, the account deleted and purged, no
// reachable record of the vault or its Trash still holds a planted secret.

struct VaultResidueTests {
    /// Raw and base64 spellings (`Data` is base64 inside JSON) of every secret of `account`. Credential ids and relying parties are
    /// identity, which a tombstone keeps on purpose, so they are not listed.
    private static func secrets(of account: CredentialAccount) -> [Data] {
        let texts = [
            account.username, account.password ?? "", account.basicAuthenticationMetadata?.username?.label ?? "",
            account.basicAuthenticationMetadata?.password?.label ?? "",
        ]
        let blobs = [account.totp?.secret ?? Data(), account.passkeys[0].privateKeyPKCS8]
        return texts.map { Data($0.utf8) } + blobs + blobs.map { Data($0.base64EncodedString().utf8) }
    }

    /// Raw and base64 spellings of each text.
    private static func spellings(_ texts: [String]) -> [Data] {
        texts.flatMap { [Data($0.utf8), Data(Data($0.utf8).base64EncodedString().utf8)] }
    }

    @Test func removedEditedDeletedAndPurgedSecretsLeaveNoPlaintextAnywhere() async throws {
        let planted = try RevisionFixtures.plantedAccount()
        let secrets = Self.secrets(of: planted) + Self.spellings(["replaced-pw-3", "replacement-totp-secret"])
        try await VaultStoreFixture.with(accounts: [planted], historyRows: 0) { f in
            try await f.withWallStore { store, access in
                // Replace, then remove: the replaced values become revisions, the removed ones Trash entries.
                let replacementTOTP = TOTPGenerator(
                    secret: Data("replacement-totp-secret".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: nil
                )
                try await f.edit(store, access) { accounts in
                    accounts.map { var live = $0; live.password = "replaced-pw-3"; live.totp = replacementTOTP; return live }
                }
                try await f.edit(store, access) { accounts in
                    accounts.map {
                        var live = $0
                        live.password = nil
                        live.basicAuthenticationMetadata = nil
                        live.totp = nil
                        return live
                    }
                }
                try await f.edit(store, access) { accounts in accounts.map { var live = $0; live.displayName = "Renamed"; return live } }
                // A credential's removal takes its own revisions to the Trash with it; the metadata revision stays.
                let subjects = try f.sourceRevisions(of: planted.id).map(\.subject.sqlName)
                #expect(subjects == ["metadata"], "\(subjects)")
                #expect(try f.trashEntryIDs().count == 2)
                #expect(try f.moveRevisions(in: f.trashID, owner: planted.id).map(\.subject.sqlName).sorted() == ["password", "totp"])

                // The sweep sees what it claims to see: before the purge the Trash still holds the secrets.
                try await f.deleteAccount(store, access, planted.id)
                let plaintexts = try f.reachablePlaintexts()
                #expect(secrets.contains { secret in plaintexts.contains { $0.includes(secret) } })

                _ = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access
                )
            }

            for plaintext in try f.reachablePlaintexts() {
                for secret in secrets {
                    #expect(!plaintext.includes(secret))
                }
            }
            let rows = try f.moveHistoryRows(of: f.trashID)
            #expect(!rows.isEmpty && rows.allSatisfy { $0.kind == .tombstone })
            // Journal rows and sealed rows are ciphertext and digests; the raw file bytes must not carry a secret either.
            let image = try f.recordAndJournalImage()
            for secret in secrets {
                #expect(!image.values.contains { $0.includes(secret) })
            }
            let scratch = try FileManager.default.contentsOfDirectory(atPath: VerificationScratch.directory(in: f.directory).path)
            #expect(scratch.isEmpty, "\(scratch)")
            try f.verify()
        }
    }
}
