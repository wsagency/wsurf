// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct VaultDiffTests {
    private nonisolated static let undecodable = Data("not json".utf8)
    private nonisolated static let otherUndecodable = Data("[1, 2".utf8)

    private static func isInvalidData(_ error: Error) -> Bool {
        guard let vaultError = error as? CredentialVaultError, case .invalidData = vaultError else {
            return false
        }
        return true
    }

    private let id = VaultFixtures.fixedAccountID

    private func rich() throws -> CredentialAccount {
        try VaultFixtures.richAccount()
    }

    private func diff(old: CredentialAccount, new: CredentialAccount) throws -> CredentialChangePlan {
        try CredentialDiff.plan(old: [old], new: [new])
    }

    private func diff(editing edit: (inout CredentialAccount) throws -> Void) throws -> CredentialChangePlan {
        let old = try rich()
        var new = old
        try edit(&new)
        return try diff(old: old, new: new)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ revision: RevisionDraft) throws -> T {
        try JSONDecoder().decode(type, from: revision.superseded)
    }

    private func pick(_ subject: RecordSubject, in plan: CredentialChangePlan) throws -> RevisionDraft {
        let matches = plan.revisions.filter { $0.subject == subject }
        #expect(matches.count == 1)
        return try #require(matches.first)
    }

    private func text(_ revision: RevisionDraft) -> String {
        String(decoding: revision.superseded, as: UTF8.self)
    }

    private func keys(_ revision: RevisionDraft) throws -> Set<String> {
        let object = try #require(JSONSerialization.jsonObject(with: revision.superseded) as? [String: Any])
        return Set(object.keys)
    }

    private func expectNoWork(_ plan: CredentialChangePlan) {
        #expect(plan.revisions.isEmpty)
        #expect(plan.removals.isEmpty)
    }

    // MARK: Undo

    @Test func aLossThatReturnsWithAnAccountFromTrashIsNeitherMovedNorKept() throws {
        let merged = try rich()
        var survivor = merged
        survivor.password = "own"
        survivor.totp = nil
        survivor.passkeys = []
        var absorbed = VaultFixtures.account(username: "ada", password: "s3cret", origin: "https://example.test")
        absorbed.totp = merged.totp
        absorbed.passkeys = merged.passkeys

        let plan = try CredentialDiff.plan(old: [merged], new: [survivor], returning: [absorbed])

        #expect(plan.removals.isEmpty, "the code and the passkey come back with their own account")
        #expect(plan.revisions.isEmpty, "so does the password")
        #expect(plan.touched == [id])
        #expect(plan.persistence == .semantic)

        // Without the returning account the same change keeps the old password and moves the code and the passkey.
        let plain = try CredentialDiff.plan(old: [merged], new: [survivor])
        #expect(plain.removals.count == 2)
        #expect(plain.revisions.map(\.subject) == [.password])
    }

    @Test func aLossThatDiffersFromWhatReturnsIsStillKept() throws {
        let merged = try rich()
        var survivor = merged
        survivor.totp = nil
        var absorbed = VaultFixtures.account(username: "ada", password: "other", origin: "https://example.test")
        var otherCode = try #require(merged.totp)
        otherCode.digits = 8
        absorbed.totp = otherCode

        let plan = try CredentialDiff.plan(old: [merged], new: [survivor], returning: [absorbed])

        #expect(plan.removals == [.credential(ownerID: id, subject: .totp, passkeyID: nil)], "a different code is not the one that returns")
    }

    // MARK: Revisions

    @Test func passwordReplaceMakesARevision() throws {
        let plan = try diff { $0.password = "changed" }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let revision = try pick(.password, in: plan)
        #expect(revision.ownerID == id)
        #expect(try decode(PasswordValue.self, revision) == PasswordValue(username: "ada", password: "s3cret", basicAuthenticationMetadata: nil))
        #expect(text(revision) == #"{"password":"s3cret","username":"ada"}"#)
        #expect(plan.removals.isEmpty)
        #expect(plan.touched == [id])
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func usernameReplaceMakesARevision() throws {
        let plan = try diff { $0.username = "grace" }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let value = try decode(PasswordValue.self, try pick(.password, in: plan))
        #expect(value.username == "ada")
        #expect(value.password == "s3cret")
        #expect(plan.removals.isEmpty)
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func basicAuthReplaceMakesARevision() throws {
        let first = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: Data([1]), label: "User", fieldType: .string),
            password: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
        )
        var old = try rich()
        old.basicAuthenticationMetadata = first
        var new = old
        new.basicAuthenticationMetadata?.username?.label = "Name"

        let plan = try diff(old: old, new: new)

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let draft = try pick(.password, in: plan)
        let value = try decode(PasswordValue.self, draft)
        #expect(value == PasswordValue(username: "ada", password: "s3cret", basicAuthenticationMetadata: first))
        #expect(
            text(draft) == #"{"basicAuthenticationMetadata":{"password":{"fieldType":"concealedString"},"#
                + #""username":{"fieldType":"string","id":"AQ==","label":"User"}},"password":"s3cret","username":"ada"}"#
        )
        #expect(plan.removals.isEmpty)
    }

    @Test func totpReplaceMakesARevision() throws {
        let plan = try diff { $0.totp?.digits = 8 }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        #expect(try decode(TOTPGenerator.self, try pick(.totp, in: plan)) == VaultFixtures.totp())
        #expect(text(try pick(.totp, in: plan)) == #"{"algorithm":"sha1","digits":6,"issuer":"Example","period":30,"secret":"AQIDBAU="}"#)
        #expect(plan.removals.isEmpty)
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func metadataChangeMakesAMetadataRevisionWithoutSecrets() throws {
        let plan = try diff {
            $0.displayName = "Home"
            $0.origins = ["https://example.test", "https://other.test"]
            $0.loginURLs = [URL(string: "https://other.test/login")!]
        }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let revision = try pick(.metadata, in: plan)
        let projection = try decode(MetadataProjection.self, revision)
        #expect(projection.displayName == "Work")
        #expect(projection.origins == ["https://example.test"])
        #expect(projection.loginURLs == [URL(string: "https://example.test/login")!])
        // Sorted keys, default strategies (slashes escaped, Data as base64), nil fields omitted.
        let exchangeBase64 = try VaultFixtures.sortedJSON(VaultFixtures.exchangeMetadata()).base64EncodedString()
        let exchange = exchangeBase64.replacingOccurrences(of: "/", with: "\\/")
        let expected = #"{"displayName":"Work","exchange":"\#(exchange)","exchangeAccountID":"CQ==","exchangeItemID":"CA==","#
            + #""loginURLs":["https:\/\/example.test\/login"],"origins":["https:\/\/example.test"]}"#
        #expect(text(revision) == expected)
        #expect(try keys(revision).isSubset(of: ["displayName", "origins", "loginURLs", "exchange", "exchangeAccountID", "exchangeItemID"]))

        let account = try rich()
        let body = text(revision)
        #expect(!body.contains("s3cret"))
        #expect(!body.contains(try #require(account.totp).secret.base64EncodedString()))
        #expect(!body.contains(account.passkeys[0].privateKeyPKCS8.base64EncodedString()))
        #expect(!body.contains(account.passkeys[0].credentialID.base64EncodedString()))
        #expect(!body.contains("basicAuthenticationMetadata"))
        #expect(!body.contains("passkeys"))
    }

    @Test func metadataRevisionWithoutExchangeMetadataHasNilExchange() throws {
        var old = try rich()
        old.exchangeMetadata = nil
        var new = old
        new.displayName = "Home"

        let plan = try diff(old: old, new: new)

        let projection = try decode(MetadataProjection.self, try pick(.metadata, in: plan))
        #expect(projection.exchange == nil)
        #expect(projection.exchangeAccountID == Data([9]))
        #expect(projection.exchangeItemID == Data([8]))
    }

    @Test func metadataRevisionKeepsIDsAndKnownExchangeFieldsIncludingDatesAndDropsUnknownKeys() throws {
        var old = try rich()
        let raw = try #require(old.exchangeMetadata)
        var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object["futureKey"] = "dropped"
        old.exchangeMetadata = try JSONSerialization.data(withJSONObject: object)
        var new = old
        new.displayName = "Home"

        let plan = try diff(old: old, new: new)

        let projection = try decode(MetadataProjection.self, try pick(.metadata, in: plan))
        #expect(projection.exchangeAccountID == Data([9]))
        #expect(projection.exchangeItemID == Data([8]))
        let exchange = try #require(projection.exchange)
        #expect(exchange == (try VaultFixtures.sortedJSON(VaultFixtures.exchangeMetadata())))
        #expect(!String(decoding: exchange, as: UTF8.self).contains("futureKey"))
        let typed = try JSONDecoder().decode(VaultFixtures.ExchangeMetadata.self, from: exchange)
        #expect(typed.created == VaultFixtures.reference(1_000))
        #expect(typed.lastModified == VaultFixtures.reference(2_000))
        #expect(typed.collections[0].created == VaultFixtures.reference(10))
        #expect(typed.collections[0].subcollections[0].lastModified == VaultFixtures.reference(60))
    }

    @Test func supersededValuesAreTypedAndSiblingFree() throws {
        let account = try rich()
        let plan = try diff {
            $0.password = "changed"
            $0.totp?.period = 60
            $0.displayName = "Home"
        }

        #expect(plan.revisions.count == 3)
        let password = try pick(.password, in: plan)
        let totp = try pick(.totp, in: plan)
        let metadata = try pick(.metadata, in: plan)

        #expect(try decode(PasswordValue.self, password).password == "s3cret")
        #expect(try decode(TOTPGenerator.self, totp) == VaultFixtures.totp())
        _ = try decode(MetadataProjection.self, metadata)
        #expect(try keys(password).isSubset(of: ["username", "password", "basicAuthenticationMetadata"]))
        #expect(try keys(totp).isSubset(of: ["secret", "algorithm", "period", "digits", "issuer", "userName"]))
        #expect(try keys(metadata).isSubset(of: ["displayName", "origins", "loginURLs", "exchange", "exchangeAccountID", "exchangeItemID"]))

        let totpSecret = try #require(account.totp).secret.base64EncodedString()
        let passkey = account.passkeys[0]
        for draft in plan.revisions {
            let body = text(draft)
            #expect(!body.contains("passkeys"))
            #expect(!body.contains(passkey.privateKeyPKCS8.base64EncodedString()))
            #expect(!body.contains(passkey.credentialID.base64EncodedString()))
            #expect(!body.contains(account.id.uuidString))
        }
        #expect(!text(password).contains(totpSecret))
        #expect(!text(totp).contains("s3cret"))
        #expect(!text(totp).contains("ada"))
        #expect(!text(metadata).contains("s3cret"))
        #expect(!text(metadata).contains(totpSecret))
    }

    @Test func canonicallyEquivalentButByteDifferentPasswordIsNotANoop() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        #expect(composed == decomposed)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        var old = try rich()
        old.password = composed
        var new = old
        new.password = decomposed

        let plan = try diff(old: old, new: new)

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let value = try decode(PasswordValue.self, try pick(.password, in: plan))
        #expect(Array(try #require(value.password).utf8) == Array(composed.utf8))
        #expect(plan.setsModifiedAt == [id])
    }

    // MARK: Removals

    @Test func passkeyRemovalIsARemovalNotARevision() throws {
        let plan = try diff { $0.passkeys = [] }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.isEmpty)
        #expect(plan.removals == [.credential(ownerID: id, subject: .passkey, passkeyID: VaultFixtures.fixedPasskeyID)])
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func clearingPasswordTOTPAndRemovingAPasskeyInOneEditYieldsRemovalsAndNoRevisionForThem() throws {
        let plan = try diff {
            $0.password = nil
            $0.totp = nil
            $0.passkeys = []
        }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.isEmpty)
        #expect(plan.removals.count == 3)
        #expect(plan.removals.contains(.credential(ownerID: id, subject: .password, passkeyID: nil)))
        #expect(plan.removals.contains(.credential(ownerID: id, subject: .totp, passkeyID: nil)))
        #expect(plan.removals.contains(.credential(ownerID: id, subject: .passkey, passkeyID: VaultFixtures.fixedPasskeyID)))
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func accountRemovedFromTheNewListIsAnAccountRemoval() throws {
        let other = VaultFixtures.account(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, username: "grace")

        let plan = try CredentialDiff.plan(old: [rich(), other], new: [other])

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.isEmpty)
        #expect(plan.removals == [.account(id)])
        #expect(!plan.setsModifiedAt.contains(id))
    }

    // MARK: Notes

    private nonisolated static let planted = [
        CredentialNote(text: "planted-note-1", field: CredentialEditableFieldMetadata(id: Data([1]), label: "Note", fieldType: .string)),
        CredentialNote(text: "planted-note-2", field: nil),
    ]

    private func withNotes(_ edit: (inout CredentialAccount) -> Void = { _ in }) throws -> CredentialAccount {
        var account = try rich()
        account.notes = Self.planted
        edit(&account)
        return account
    }

    @Test func noteEditCreatesNoteRevision() throws {
        let old = try withNotes()
        var new = old
        new.notes = [CredentialNote(text: "changed", field: nil)]

        let plan = try diff(old: old, new: new)

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let revision = try pick(.note, in: plan)
        #expect(revision.ownerID == id)
        #expect(try decode([CredentialNote].self, revision) == Self.planted)
        #expect(plan.removals.isEmpty)
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func addingTheFirstNoteSupersedesNothing() throws {
        let plan = try diff { $0.notes = Self.planted }

        #expect(plan.persistence == .semantic)
        expectNoWork(plan)
        #expect(plan.touched == [id])
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func clearingNotesKeepsThemAsAnEarlierVersion() throws {
        let plan = try diff(old: withNotes(), new: rich())

        #expect(plan.persistence == .semantic)
        #expect(plan.removals.isEmpty)
        #expect(plan.revisions.count == 1)
        let revision = try pick(.note, in: plan)
        #expect(revision.ownerID == id)
        #expect(try decode([CredentialNote].self, revision) == Self.planted)
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func onlyAnExplicitNotesDeleteMovesThemToTrash() throws {
        let notesDelete = RemovalScope.credential(ownerID: id, subject: .note, passkeyID: nil)
        let plan = try CredentialDiff.plan(old: [withNotes()], new: [rich()], removing: notesDelete)

        #expect(plan.removals == [notesDelete])
        #expect(plan.revisions.isEmpty)
        #expect(plan.setsModifiedAt == [id])

        // A delete of another part, or of another account's notes, does not turn a notes edit into a removal.
        let other = [
            RemovalScope.credential(ownerID: id, subject: .totp, passkeyID: nil),
            RemovalScope.credential(ownerID: UUID(), subject: .note, passkeyID: nil),
        ]
        for scope in other {
            let edit = try CredentialDiff.plan(old: [withNotes()], new: [rich()], removing: scope)
            #expect(edit.removals.isEmpty && edit.revisions.map(\.subject) == [.note])
        }
    }

    @Test func aNoteEditLeavesEveryOtherPartAlone() throws {
        let old = try withNotes()
        var new = old
        new.notes?[1].text = "other"

        let plan = try diff(old: old, new: new)

        #expect(plan.revisions.map(\.subject) == [.note])
        #expect(plan.removals.isEmpty)
    }

    @Test func removingThePasswordKeepsAnAccountThatStillHasNotes() throws {
        let owner = try withNotes {
            $0.totp = nil
            $0.passkeys = []
        }
        let scope = RemovalScope.credential(ownerID: id, subject: .password, passkeyID: nil)

        let proposal = try ProfileVaultStore.removing(scope, from: [owner])

        #expect(proposal.requires == scope)
        let kept = try #require(proposal.accounts.first)
        #expect(proposal.accounts.count == 1 && kept.password == nil && kept.username.isEmpty)
        #expect(kept.notes == Self.planted)
        try kept.validate()

        // Without notes the same removal leaves nothing valid, so the whole account goes.
        var noteless = owner
        noteless.notes = nil
        let whole = try ProfileVaultStore.removing(scope, from: [noteless])
        #expect(whole.accounts.isEmpty && whole.requires == .account(id))
    }

    @Test func removingTheNotesKeepsTheRestAndRefusesWhenThereAreNone() throws {
        let scope = RemovalScope.credential(ownerID: id, subject: .note, passkeyID: nil)

        let proposal = try ProfileVaultStore.removing(scope, from: [withNotes()])

        #expect(proposal.requires == scope)
        #expect(proposal.accounts.first?.notes == nil)
        #expect(proposal.accounts.first?.password == "s3cret")
        #expect { try ProfileVaultStore.removing(scope, from: [rich()]) } throws: { Self.isInvalidData($0) }

        // A note-only account has nothing else, so removing its notes removes the account.
        var noteOnly = CredentialAccount(
            id: id, username: "", displayName: nil, origins: [], loginURLs: [], password: nil, passkeys: [], totp: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
        noteOnly.notes = Self.planted
        let whole = try ProfileVaultStore.removing(scope, from: [noteOnly])
        #expect(whole.accounts.isEmpty && whole.requires == .account(id))
    }

    // MARK: No revision

    @Test func passkeyAddLastSignedAtAndFIDO2RefreshMakeNoRevision() throws {
        let added = try diff {
            $0.passkeys.append(try VaultFixtures.passkey(rpID: "other.test", credentialID: Data([4, 4, 4])))
        }
        #expect(added.persistence == .semantic)
        expectNoWork(added)
        #expect(added.setsModifiedAt == [id])

        let signed = try diff { $0.passkeys[0].lastSignedAt = VaultFixtures.reference(99) }
        #expect(signed.persistence == .persistOnly)
        expectNoWork(signed)
        #expect(signed.setsModifiedAt.isEmpty)

        let refreshed = try diff { $0.passkeys[0].exchangeFIDO2Metadata = Data([1, 2, 3]) }
        #expect(refreshed.persistence == .persistOnly)
        expectNoWork(refreshed)
        #expect(refreshed.setsModifiedAt.isEmpty)
    }

    @Test func exchangeDateOnlyChangeMakesNoRevision() throws {
        var metadata = VaultFixtures.exchangeMetadata()
        metadata.created = VaultFixtures.reference(5_000)
        metadata.lastModified = VaultFixtures.reference(6_000)
        metadata.collections[0].created = VaultFixtures.reference(7_000)
        metadata.collections[0].subcollections[0].lastModified = VaultFixtures.reference(8_000)
        let redated = try VaultFixtures.sortedJSON(metadata)

        let plan = try diff { $0.exchangeMetadata = redated }

        #expect(plan.persistence == .persistOnly)
        expectNoWork(plan)
        #expect(plan.touched == [id])
        #expect(plan.setsModifiedAt.isEmpty)
    }

    @Test func trueNoopIsNoop() throws {
        let old = try rich()
        let roundTripped = try JSONDecoder().decode(CredentialAccount.self, from: JSONEncoder().encode(old))

        let plan = try CredentialDiff.plan(old: [old], new: [roundTripped])

        #expect(plan.persistence == .noop)
        expectNoWork(plan)
        #expect(plan.touched.isEmpty)
        #expect(plan.setsModifiedAt.isEmpty)
    }

    @Test func hashUnchangedButPayloadDifferentIsPersistOnly() throws {
        let events = CredentialEvents(
            lastImportedAt: VaultFixtures.reference(1),
            lastExportHandoffAt: VaultFixtures.reference(2),
            remoteLastObservedAt: VaultFixtures.reference(3),
            lastExportHandoffHash: Data(repeating: 4, count: 32)
        )
        let edits: [(inout CredentialAccount) -> Void] = [
            { $0.passkeys[0].lastSignedAt = VaultFixtures.reference(5) },
            { $0.passwordEvents = events },
            { $0.totpEvents = events },
            { $0.passkeys[0].events = events },
            { $0.migratedAt = VaultFixtures.reference(6) },
            { $0.passwordBase = ExchangeBase(contentHash: Data(repeating: 1, count: 32), itemID: nil) },
            { $0.exchangeItemID = Data([0x77]) },
            { $0.exchangeAccountID = nil },
        ]

        for edit in edits {
            let plan = try diff(editing: edit)
            #expect(plan.persistence == .persistOnly)
            expectNoWork(plan)
            #expect(plan.touched == [id])
            #expect(plan.setsModifiedAt.isEmpty)
        }
    }

    @Test func semanticChangeSetsModifiedAtOnlyForChangedAccounts() throws {
        let changedID = id
        let signedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
        let untouchedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        let changed = try rich()
        let signed = VaultFixtures.account(id: signedID, username: "grace", passkeys: [try VaultFixtures.passkey()])
        let untouched = VaultFixtures.account(id: untouchedID, username: "linus")

        var newChanged = changed
        newChanged.password = "changed"
        var newSigned = signed
        newSigned.passkeys[0].lastSignedAt = VaultFixtures.reference(5)

        let plan = try CredentialDiff.plan(old: [changed, signed, untouched], new: [newChanged, newSigned, untouched])

        #expect(plan.persistence == .semantic)
        #expect(plan.touched == [changedID, signedID])
        #expect(plan.setsModifiedAt == [changedID])
        #expect(plan.revisions.count == 1)
        #expect(plan.revisions[0].ownerID == changedID)
        #expect(plan.removals.isEmpty)
    }

    @Test func combinedEditMakesOneRevisionPerChangedKind() throws {
        let plan = try diff {
            $0.password = "changed"
            $0.totp?.secret = Data([9, 9, 9])
            $0.origins = ["https://example.test", "https://other.test"]
            $0.loginURLs = [URL(string: "https://other.test/login")!]
        }

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 3)
        #expect(Set(plan.revisions.map(\.subject)) == [.password, .totp, .metadata])
        #expect(plan.removals.isEmpty)
        #expect(plan.touched == [id])
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func unchangedDraftPreservesPasskeysAndTOTP() throws {
        let old = try rich()
        var new = old
        new.username = old.username
        new.passkeys = old.passkeys
        new.totp = old.totp

        let plan = try diff(old: old, new: new)

        #expect(plan.persistence == .noop)
        expectNoWork(plan)
        #expect(plan.touched.isEmpty)
    }

    // MARK: Undecodable exchange metadata

    @Test func undecodableExchangeMetadataThrowsMetadataUndecodableWhenSuperseded() throws {
        var old = try rich()
        old.exchangeMetadata = Self.undecodable
        var new = old
        new.displayName = "Home"

        #expect(throws: CredentialStoreError.metadataUndecodable) {
            try CredentialDiff.plan(old: [old], new: [new])
        }
    }

    nonisolated enum RefusalCase: CaseIterable, Sendable {
        case renameOldUndecodable, originOldUndecodable, loginURLOldUndecodable
        case renameNewUndecodable, bytesOldGoodNewUndecodable, bytesOldUndecodableNewGood, bytesBothUndecodableButDifferent

        func apply(old: inout CredentialAccount, new: inout CredentialAccount) throws {
            switch self {
            case .renameOldUndecodable:
                old.exchangeMetadata = VaultDiffTests.undecodable
                new.exchangeMetadata = VaultDiffTests.undecodable
                new.displayName = "Home"
            case .originOldUndecodable:
                old.exchangeMetadata = VaultDiffTests.undecodable
                new.exchangeMetadata = VaultDiffTests.undecodable
                new.origins = ["https://other.test"]
            case .loginURLOldUndecodable:
                old.exchangeMetadata = VaultDiffTests.undecodable
                new.exchangeMetadata = VaultDiffTests.undecodable
                new.loginURLs = [URL(string: "https://other.test/login")!]
            case .renameNewUndecodable:
                new.exchangeMetadata = VaultDiffTests.undecodable
                new.displayName = "Home"
            case .bytesOldGoodNewUndecodable:
                new.exchangeMetadata = VaultDiffTests.undecodable
            case .bytesOldUndecodableNewGood:
                old.exchangeMetadata = VaultDiffTests.undecodable
            case .bytesBothUndecodableButDifferent:
                old.exchangeMetadata = VaultDiffTests.undecodable
                new.exchangeMetadata = VaultDiffTests.otherUndecodable
            }
        }
    }

    @Test(arguments: RefusalCase.allCases)
    func changedMetadataWithUndecodableOldOrNewRefuses(refusal: RefusalCase) throws {
        var old = try rich()
        var new = old
        try refusal.apply(old: &old, new: &new)

        #expect(throws: CredentialStoreError.metadataUndecodable) {
            try CredentialDiff.plan(old: [old], new: [new])
        }
    }

    @Test func unchangedRawMetadataBypassesDecoding() throws {
        var old = try rich()
        old.exchangeMetadata = Self.undecodable

        var passwordEdit = old
        passwordEdit.password = "changed"
        let edited = try diff(old: old, new: passwordEdit)
        #expect(edited.persistence == .semantic)
        #expect(edited.revisions.count == 1)
        #expect(edited.revisions[0].subject == .password)
        #expect(edited.removals.isEmpty)

        var idOnly = old
        idOnly.exchangeItemID = Data([0x77])
        idOnly.exchangeAccountID = Data([0x78])
        let identified = try diff(old: old, new: idOnly)
        #expect(identified.persistence == .persistOnly)
        expectNoWork(identified)

        var signed = old
        signed.passkeys[0].lastSignedAt = VaultFixtures.reference(5)
        let signedPlan = try diff(old: old, new: signed)
        #expect(signedPlan.persistence == .persistOnly)
        expectNoWork(signedPlan)
        #expect(signedPlan.setsModifiedAt.isEmpty)

        let same = try diff(old: old, new: old)
        #expect(same.persistence == .noop)
    }

    // MARK: Prior password value without a password or username

    @Test func basicAuthOnlyPasswordStateKeepsItsPriorValueAsARevision() throws {
        // Valid (CredentialAccount.validate): empty username, no password, username-field metadata, other credentials kept.
        var old = try rich()
        old.username = ""
        old.password = nil
        old.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: Data([1]), label: "User", fieldType: .string),
            password: nil
        )
        try old.validate()
        var new = old
        new.basicAuthenticationMetadata?.username?.label = "Name"
        try new.validate()

        let plan = try diff(old: old, new: new)

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let value = try decode(PasswordValue.self, try pick(.password, in: plan))
        #expect(value == PasswordValue(username: "", password: nil, basicAuthenticationMetadata: old.basicAuthenticationMetadata))
        #expect(plan.removals.isEmpty)
    }

    // MARK: Ambiguous identities are refused, never first-wins

    @Test func duplicateAccountIDsAreRefusedEvenWhenTheListsAreIdentical() throws {
        let account = try rich()
        var twin = account
        twin.username = "grace"

        for (old, new) in [([account, twin], [account]), ([account], [account, twin]), ([account, twin], [account, twin])] {
            #expect { try CredentialDiff.plan(old: old, new: new) } throws: { Self.isInvalidData($0) }
        }
    }

    @Test func duplicatePasskeyIDsWithinAnAccountAreRefusedEvenWhenTheListsAreIdentical() throws {
        let account = try rich()
        var twin = account.passkeys[0]
        twin.credentialID = Data([9, 9, 9])
        var duplicated = account
        duplicated.passkeys.append(twin)

        for (old, new) in [(duplicated, account), (account, duplicated), (duplicated, duplicated)] {
            #expect { try CredentialDiff.plan(old: [old], new: [new]) } throws: { Self.isInvalidData($0) }
        }
    }

    // MARK: A passkey id never changes identity or key material (§13.3: no passkey replace)

    nonisolated enum SamePasskeyIDMutation: CaseIterable, Sendable {
        case credentialID, rpID, userHandle, privateKey

        func apply(to passkey: inout WebsitePasskey) throws {
            switch self {
            case .credentialID:
                passkey.credentialID = Data([9, 9, 9])
            case .rpID:
                passkey.rpID = "other.test"
            case .userHandle:
                passkey.userHandle = Data([7, 7])
            case .privateKey:
                passkey.privateKeyPKCS8 = try VaultFixtures.passkey().privateKeyPKCS8
            }
        }
    }

    @Test(arguments: SamePasskeyIDMutation.allCases)
    func changedSemanticMaterialUnderTheSamePasskeyIDIsRefused(mutation: SamePasskeyIDMutation) throws {
        let old = try rich()
        var new = old
        try mutation.apply(to: &new.passkeys[0])
        #expect(new.passkeys[0].id == old.passkeys[0].id)

        #expect { try CredentialDiff.plan(old: [old], new: [new]) } throws: { Self.isInvalidData($0) }
        #expect { try CredentialDiff.plan(old: [new], new: [old]) } throws: { Self.isInvalidData($0) }
    }
}
