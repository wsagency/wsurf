// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// Notes are a credential of their own in the exchange: imported, kept in order, merged without loss and exported on request.
extension CredentialExchangeTests {
    func note(
        _ text: String, id: Data? = nil, label: String? = nil, type: ASImportableEditableField.FieldType = .string
    ) -> ASImportableCredential {
        .note(.init(content: .init(id: id, fieldType: type, value: text, label: label)))
    }

    private func importCandidate(_ credentials: [ASImportableCredential]) throws -> CredentialAccount {
        let preview = try CredentialExchangeCodec.preview(data(credentials: credentials), against: snapshot([]))
        return try #require(preview.candidates.first)
    }

    private func noteIdentity(of account: CredentialAccount) -> CredentialIdentity {
        .note(accountID: account.id)
    }

    // MARK: Import

    /// The shape that was refused: a login with a note after it, in either order, and a note by itself.
    @Test func transferWithNoteIsNeverMalformed() throws {
        let login = basicAuthentication(username: "ada", password: "pw")
        for credentials in [[login, note("memo")], [note("memo"), login], [note("memo")]] {
            let candidate = try importCandidate(credentials)
            #expect(candidate.notes?.map(\.text) == ["memo"])
        }
        let withLogin = try importCandidate([login, note("memo")])
        #expect(withLogin.password == "pw" && withLogin.username == "ada")
    }

    @Test func noteOnlyItemImports() throws {
        let candidate = try importCandidate([note("only a note", id: Data([7]), label: "Memo")])

        #expect(candidate.username.isEmpty && candidate.password == nil && candidate.passkeys.isEmpty && candidate.totp == nil)
        #expect(candidate.notes == [
            CredentialNote(text: "only a note", field: CredentialEditableFieldMetadata(id: Data([7]), label: "Memo", fieldType: .string)),
        ])
        #expect(CredentialExchangeCodec.identities(in: candidate) == [noteIdentity(of: candidate)])
        try candidate.validate()

        let preview = try CredentialExchangeCodec.preview(data(credentials: [note("only a note")]), against: snapshot([]))
        let placed = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(placed.count == 1 && placed[0].notes?.map(\.text) == ["only a note"])
    }

    @Test func multipleNotesKeepOrder() throws {
        let candidate = try importCandidate([
            note("third"), basicAuthentication(username: "ada", password: "pw"), note("first"), note("second"),
        ])
        #expect(candidate.notes?.map(\.text) == ["third", "first", "second"])

        let exported = try CredentialExchangeCodec.export(
            snapshot([candidate]),
            selection: [.init(accountID: candidate.id, password: true, passkeyIDs: [], totp: false, notes: true)],
            format: .v1
        )
        let texts = credentials(in: exported).compactMap { credential -> String? in
            guard case let .note(value) = credential else { return nil }
            return value.content.value
        }
        #expect(texts == ["third", "first", "second"])
    }

    @Test func anEmptyNoteHoldsNothingToKeep() throws {
        let candidate = try importCandidate([basicAuthentication(username: "ada", password: "pw"), note("")])
        #expect(candidate.notes == nil)
    }

    @Test func tooManyNotesInOneItemAreRefusedNotTruncated() throws {
        let many = (0...CredentialAccount.noteLimit).map { note("note \($0)") }
        do {
            _ = try CredentialExchangeCodec.preview(data(credentials: [basicAuthentication(username: "ada", password: "pw")] + many), against: snapshot([]))
            Issue.record("Expected the note limit to refuse the item")
        } catch {
            #expect((error as? CredentialExchangeError)?.reason == .oversized)
            #expect((error as? CredentialExchangeError)?.limit == .notes)
        }
    }

    // MARK: Store and export

    @Test func noteRoundTripsThroughImportStoreReloadExport() async throws {
        let incoming = data(credentials: [
            basicAuthentication(username: "ada", password: "pw"),
            note("first note", id: Data([1, 2]), label: "Memo"),
            note("second note"),
        ])
        let accounts = try CredentialExchangeCodec.apply(
            try CredentialExchangeCodec.preview(incoming, against: snapshot([])), decisions: []
        )
        let expected = [
            CredentialNote(text: "first note", field: CredentialEditableFieldMetadata(id: Data([1, 2]), label: "Memo", fieldType: .string)),
            CredentialNote(text: "second note", field: nil),
        ]
        #expect(accounts.first?.notes == expected)

        try await VaultStoreFixture.with { f in
            try await f.withWallStore { store, access in
                let before = try await store.snapshot(vaultID: f.vaultID, using: access)
                _ = try await store.commit(vaultID: f.vaultID, accounts, expectedRevision: before.revision, cause: nil, using: access)
            }
            // A second store reads the vault from disk.
            try await f.withWallStore { store, access in
                let stored = try await store.snapshot(vaultID: f.vaultID, using: access)
                let account = try #require(stored.accounts.first)
                #expect(account.notes == expected)

                let withNotes = try CredentialExchangeCodec.export(
                    stored,
                    selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false, notes: true)],
                    format: .v1
                )
                let exportedNotes = credentials(in: withNotes).compactMap { credential -> ASImportableEditableField? in
                    guard case let .note(value) = credential else { return nil }
                    return value.content
                }
                #expect(exportedNotes.map(\.value) == ["first note", "second note"])
                #expect(exportedNotes.first?.id == Data([1, 2]) && exportedNotes.first?.label == "Memo")
                #expect(exportedNotes.allSatisfy { $0.fieldType == .string })

                // Notes leave only when they are selected.
                let withoutNotes = try CredentialExchangeCodec.export(
                    stored,
                    selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false)],
                    format: .v1
                )
                #expect(!credentials(in: withoutNotes).contains { if case .note = $0 { true } else { false } })

                // Notes alone are a valid selection, and the file reads back as the same notes.
                let notesOnly = try CredentialExchangeCodec.export(
                    stored,
                    selection: [.init(accountID: account.id, password: false, passkeyIDs: [], totp: false, notes: true)],
                    format: .v1
                )
                let reread = try CredentialExchangeCodec.preview(notesOnly, against: snapshot([]))
                #expect(reread.candidates.first?.notes == expected)
            }
            try f.verify()
        }
    }

    // MARK: Conflicts and merging

    private func linked(notes: [String]?, password: String = "old") -> CredentialAccount {
        var stored = account(id: accountID, externalID: accountExternalID, itemID: itemExternalID, username: "ada", password: password)
        stored.notes = notes.map { $0.map { CredentialNote(text: $0, field: nil) } }
        return stored
    }

    @Test func linkedItemWithDifferentNoteIsConflict() throws {
        let stored = try bound(linked(notes: ["old note"]))
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "old"), note("new note")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)

        let conflict = try #require(preview.conflicts.first { $0.incoming == noteIdentity(of: candidate) })
        #expect(conflict.existing == .note(accountID: stored.id))
        let destination = ImportDestinationView(accounts: [stored], removed: RemovedIdentifiers(items: []))
        #expect(try CredentialExchangeCodec.classify(noteIdentity(of: candidate), in: preview, destination: destination) == .noCommonBase)

        // The conflict must be decided: the default never overwrites or merges it silently.
        #expect(throws: CredentialVaultError.invalidData) { try CredentialExchangeCodec.apply(preview, decisions: []) }
    }

    @Test func identicalNotesAreUnchangedAndNeedNoDecision() throws {
        let stored = try bound(linked(notes: ["same", "other"]))
        let incoming = data(credentials: [note("same"), note("other")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)

        #expect(preview.conflicts.isEmpty)
        let destination = ImportDestinationView(accounts: [stored], removed: RemovedIdentifiers(items: []))
        #expect(try CredentialExchangeCodec.classify(noteIdentity(of: candidate), in: preview, destination: destination) == .unchanged)
        let placed = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(placed.count == 1 && placed[0].notes?.map(\.text) == ["same", "other"])
    }

    @Test func aStoredAccountWithoutNotesTakesTheImportedOnesByDefault() throws {
        let stored = linked(notes: nil)
        let preview = try CredentialExchangeCodec.preview(data(credentials: [note("kept")]), against: snapshot([stored]))

        #expect(preview.conflicts.isEmpty)
        let placed = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(placed.count == 1 && placed[0].id == stored.id && placed[0].notes?.map(\.text) == ["kept"])
    }

    @Test func skippingTheLoginSkipsItsUndecidedNote() throws {
        let stored = linked(notes: nil)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "old"), note("kept")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)

        // Only the login is a conflict (the stored account has no notes to clash with); skipping it takes the note with it.
        #expect(preview.conflicts.map(\.incoming) == [.password(accountID: candidate.id)])
        let placed = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: .password(accountID: candidate.id))])
        #expect(placed == [stored])
    }

    @Test func mergeAppendsOnlyMissingNotesAndReplaceOverwrites() throws {
        let stored = linked(notes: ["kept", "shared"])
        let incoming = data(credentials: [note("shared"), note("added")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)
        let identity = noteIdentity(of: candidate)

        let merged = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: identity, targetAccountID: stored.id)])
        #expect(merged[0].notes?.map(\.text) == ["kept", "shared", "added"])

        let replaced = try CredentialExchangeCodec.apply(
            preview, decisions: [.replace(incoming: identity, target: .note(accountID: stored.id))]
        )
        #expect(replaced[0].notes?.map(\.text) == ["shared", "added"])

        let skipped = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: identity)])
        #expect(skipped == [stored])
    }

    @Test func mergeComparesNotesByExactUTF8() throws {
        var stored = linked(notes: nil)
        stored.notes = [CredentialNote(text: "caf\u{e9}", field: nil)]
        let incoming = data(credentials: [note("cafe\u{301}")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)

        let merged = try CredentialExchangeCodec.apply(
            preview, decisions: [.add(incoming: noteIdentity(of: candidate), targetAccountID: stored.id)]
        )
        #expect(merged[0].notes?.count == 2, "a composed and a decomposed spelling are two notes")
    }

    @Test func anUndecidedNoteGoesWhereItsLoginGoes() throws {
        let bare = account(username: "", password: nil, totp: TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil))
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "pw"), note("memo")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare]))
        let candidate = try #require(preview.candidates.first)
        let login = CredentialIdentity.password(accountID: candidate.id)

        let skipped = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: login)])
        #expect(skipped == [bare])

        let merged = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: login, targetAccountID: bare.id)])
        #expect(merged.count == 1 && merged[0].password == "pw" && merged[0].notes?.map(\.text) == ["memo"])

        let separate = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: login, targetAccountID: nil)])
        #expect(separate.count == 2 && separate[0] == bare)
        #expect(separate[1].password == "pw" && separate[1].notes?.map(\.text) == ["memo"])

        let byDefault = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(byDefault.count == 2 && byDefault[1].password == "pw" && byDefault[1].notes?.map(\.text) == ["memo"])
    }

    @Test func aNoteDecidedOnItsOwnIgnoresTheLogin() throws {
        let bare = account(username: "", password: nil, totp: TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil))
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "pw"), note("memo")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare]))
        let candidate = try #require(preview.candidates.first)

        let placed = try CredentialExchangeCodec.apply(preview, decisions: [
            .keep(incoming: .password(accountID: candidate.id)),
            .add(incoming: noteIdentity(of: candidate), targetAccountID: bare.id),
        ])
        #expect(placed.count == 1 && placed[0].password == nil && placed[0].notes?.map(\.text) == ["memo"])
    }
}
