// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// One account is bounded by what the store writes for it (its canonical JSON), not only by its raw field bytes. A history row, which
// carries the account encoded, or a part of it as base64 text, is capped at 8 MB, so even the largest account the store accepts has to
// be editable, removable to Trash, restorable and purgeable. Synthetic data only.
struct VaultAccountSizeTests {
    /// The largest account the store accepts: a login and one note of control characters, which are six bytes each once escaped, so
    /// under a million characters of raw text encode to the cap (within six bytes). `character` tells two notes of one size apart.
    static func accountAtTheEncodedCap(id: UUID = UUID(), character: Character = "\u{01}") throws -> CredentialAccount {
        var account = VaultFixtures.account(id: id, username: "ada", password: "secret")
        account.notes = [CredentialNote(text: "x", field: nil)]
        let base = try CredentialVaultCrypto.storedBytes(of: account)
        // The one-byte note becomes `count` six-byte characters.
        let count = (CredentialVaultLimits.encodedAccountBytes - base + 1) / 6
        account.notes = [CredentialNote(text: String(repeating: character, count: count), field: nil)]
        let size = try CredentialVaultCrypto.storedBytes(of: account)
        try #require(size <= CredentialVaultLimits.encodedAccountBytes && size > CredentialVaultLimits.encodedAccountBytes - 6)
        try #require(try CredentialVaultCrypto.liveBytes(of: account) < CredentialVaultLimits.accountBytes / 2)
        return account
    }

    @Test func anAccountAtTheEncodedCapIsEditedRemovedRestoredAndPurged() async throws {
        let victim = try Self.accountAtTheEncodedCap()
        let replacement = try Self.accountAtTheEncodedCap(id: victim.id, character: "\u{02}")
        try await VaultStoreFixture.with(accounts: [victim]) { f in
            func expectRowsFit(in vault: UUID, _ step: String) throws -> Int {
                var largest = 0
                for row in try f.moveHistoryRows(of: vault) {
                    let size = try f.movePlaintext(of: row).count
                    #expect(size <= StoreFormat.historyRowBytes, "\(step): a \(row.kind) row holds \(size) bytes")
                    largest = max(largest, size)
                }
                return largest
            }
            try await f.withWallStore { store, access in
                // The note is replaced: the superseded note list goes into a revision as base64 text, the biggest row an account makes.
                try await f.edit(store, access) { commitEditing($0, victim.id) { $0.notes = replacement.notes } }
                let revisions = try f.moveRevisions(in: f.vaultID, owner: victim.id, subject: .note)
                #expect(revisions.count == 1)
                let largest = try expectRowsFit(in: f.vaultID, "note edit")
                #expect(largest > 7_500_000, "the revision is at the edge of the row bound, not far under it")
                // The store stamped the account when it saved it; the room kept for that keeps it inside the bound.
                let stamped = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(stamped.modifiedAt != nil)
                #expect(try CredentialVaultCrypto.storedBytes(of: stamped) <= CredentialVaultLimits.encodedAccountBytes)

                try await f.edit(store, access) { commitEditing($0, victim.id) { $0.password = "changed" } }
                _ = try expectRowsFit(in: f.vaultID, "password edit")

                // The whole account to Trash and back.
                try await f.deleteAccount(store, access, victim.id)
                _ = try expectRowsFit(in: f.trashID, "account removed")
                try await f.undelete(store, access, try f.trashEntry(of: victim.id).row.recordID)
                var restored = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(restored.notes == replacement.notes && restored.password == "changed")

                // The note alone to Trash and back.
                try await f.deleteCredential(store, access, owner: victim.id, subject: .note)
                _ = try expectRowsFit(in: f.trashID, "note removed")
                try await f.undelete(store, access, try f.trashEntry(of: victim.id, subject: .note).row.recordID)
                restored = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(restored.notes == replacement.notes)

                // Remove it once more and purge everything in Trash.
                try await f.deleteAccount(store, access, victim.id)
                let purged = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access
                )
                #expect(purged.removedEntries >= 1)
                #expect(try f.trashEntryIDs().isEmpty)
            }
            try f.verify()
        }
    }

    @Test func anAccountOneStepOverTheEncodedCapIsRefusedAndNothingIsWritten() async throws {
        let stored = VaultFixtures.account(username: "ada")
        var over = try Self.accountAtTheEncodedCap(id: stored.id)
        // One more control character is six more bytes.
        over.notes = over.notes.map { [CredentialNote(text: $0[0].text + "\u{01}", field: nil)] }
        try #require(try CredentialVaultCrypto.storedBytes(of: over) > CredentialVaultLimits.encodedAccountBytes)
        try await VaultStoreFixture.with(accounts: [stored], historyRows: 1) { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            let image = try f.headWriteImage()

            let error = await store.vaultCommitFailure(vaultID: f.vaultID, [over], expectedRevision: before.revision, using: access)

            #expect(error as? CredentialStoreError == .limit(.accountBytes))
            #expect(try f.headWriteImage() == image)
            try f.verify()
        }
    }
}
