// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

/// §13.3 import classification against the destination vault, the passkey hard conflict, the removal of passkey
/// replace, and the truthful export dates of §12.2. Everything goes through `preview`, `classify`, `apply` and `export`.
@MainActor
struct VaultExchangeClassificationTests {
    enum Kind {
        case password, passkey, totp
    }

    let h = CredentialExchangeTests()
    let importedCreated = Date(timeIntervalSince1970: 1_700_000_100)
    let importedModified = Date(timeIntervalSince1970: 1_700_000_200)

    // MARK: Fixtures

    func newKey() throws -> Data {
        try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
    }

    func login(_ password: String) -> ASImportableCredential {
        h.basicAuthentication(username: "ada", password: password)
    }

    /// The account held after applying `data` to an empty vault.
    func stored(_ data: ASExportedCredentialData) throws -> CredentialAccount {
        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(data, against: h.snapshot([])),
            decisions: []
        )
        return try #require(imported.first)
    }

    /// An account saved before imports recorded what they brought in: linked to the item, but with no base for any part.
    func unbound(_ data: ASExportedCredentialData) throws -> CredentialAccount {
        var account = try stored(data)
        account.passwordBase = nil
        account.totpBase = nil
        return account
    }

    func isInvalidData(_ error: any Error) -> Bool {
        guard case CredentialVaultError.invalidData = error else { return false }
        return true
    }

    func identity(_ kind: Kind, in preview: CredentialImportPreview) throws -> CredentialIdentity {
        let all = preview.candidates.flatMap(CredentialExchangeCodec.identities(in:))
        return try #require(all.first { identity in
            switch (kind, identity) {
            case (.password, .password), (.passkey, .passkey), (.totp, .totp):
                true
            default:
                false
            }
        })
    }

    /// Classifies the first `kind` credential of `data` against `accounts` only: the preview is made against an
    /// empty vault, so nothing but the destination view can decide the class.
    func classify(
        _ data: ASExportedCredentialData,
        _ kind: Kind,
        against accounts: [CredentialAccount],
        removed: [RemovedIdentifier] = []
    ) throws -> CredentialImportClass {
        let preview = try CredentialExchangeCodec.preview(data, against: h.snapshot([]))
        return try CredentialExchangeCodec.classify(
            identity(kind, in: preview),
            in: preview,
            destination: ImportDestinationView(accounts: accounts, removed: RemovedIdentifiers(items: removed))
        )
    }

    func removedEntry(
        entryID: UUID = UUID(),
        isTombstone: Bool = false,
        itemID: Data? = nil,
        credentialID: Data? = nil,
        rpID: String? = nil
    ) -> RemovedIdentifier {
        RemovedIdentifier(
            entryID: entryID,
            isTombstone: isTombstone,
            accountID: UUID(),
            exchangeAccountID: itemID == nil ? nil : h.accountExternalID,
            exchangeItemID: itemID,
            passkeyCredentialID: credentialID,
            rpID: rpID
        )
    }

    func exported(
        _ account: CredentialAccount,
        password: Bool = true,
        totp: Bool = false,
        passkeyIDs: Set<UUID> = []
    ) throws -> ASExportedCredentialData {
        try CredentialExchangeCodec.export(
            h.snapshot([account]),
            selection: [.init(accountID: account.id, password: password, passkeyIDs: passkeyIDs, totp: totp)],
            format: .v1
        )
    }

    func exportedItem(
        _ account: CredentialAccount,
        password: Bool = true,
        totp: Bool = false,
        passkeyIDs: Set<UUID> = []
    ) throws -> ASImportableItem {
        let data = try exported(account, password: password, totp: totp, passkeyIDs: passkeyIDs)
        return try #require(data.accounts.first?.items.first)
    }

    func datedAccount() throws -> CredentialAccount {
        try h.bound(stored(h.data(
            created: importedCreated,
            lastModified: importedModified,
            credentials: [login("v1"), h.totp()]
        )))
    }

    // MARK: Passkeys

    @Test func samePasskeyIdentityDifferentKeyOrHandleIsAHardConflict() throws {
        let keyA = try newKey()
        let local = try stored(h.data(credentials: [h.passkey(key: keyA)]))
        let differentKey = h.data(credentials: [h.passkey(key: try newKey())])
        let differentHandle = h.data(credentials: [h.passkey(userHandle: Data([0x99]), key: keyA)])

        for incoming in [differentKey, differentHandle] {
            #expect(try classify(incoming, .passkey, against: [local]) == .passkeyHardConflict)

            let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
            let conflict = try #require(preview.conflicts.first)
            let attempts: [[CredentialImportDecision]] = [
                [],
                [.replace(incoming: conflict.incoming, target: conflict.existing)],
                [.add(incoming: conflict.incoming, targetAccountID: nil)],
                [.add(incoming: conflict.incoming, targetAccountID: local.id)],
            ]
            for decisions in attempts {
                #expect { try CredentialExchangeCodec.apply(preview, decisions: decisions) } throws: { isInvalidData($0) }
            }
            let kept = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: conflict.incoming)])
            #expect(kept == [local])
            #expect(kept.first?.passkeys == local.passkeys)
        }
    }

    @Test func aHardConflictDominatesTheOtherPartsOfTheSameTransfer() throws {
        let local = try stored(h.data(credentials: [h.passkey(key: try newKey())]))
        let incoming = h.data(credentials: [h.passkey(key: try newKey()), h.passkey(id: Data([0xC0, 0x02]), key: try newKey())])
        let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
        let conflict = try #require(preview.conflicts.first)
        // The distinct credential still appends; only the conflicting one is fixed.
        let result = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: conflict.incoming)])
        #expect(result.first?.passkeys.map(\.credentialID) == [Data([0xC0, 0x01]), Data([0xC0, 0x02])])
        #expect(result.first?.passkeys.first == local.passkeys.first)
    }

    @Test func equivalentKeyWithDifferentDERIsUnchanged() throws {
        let fixed = try VaultFixtures.fixedPKCS8()
        let incoming = h.data(credentials: [h.passkey(key: fixed)])
        var local = try stored(incoming)
        local.passkeys[0].privateKeyPKCS8 = try VaultFixtures.fixedPKCS8(embeddingPublicKey: false)
        #expect(local.passkeys[0].privateKeyPKCS8 != fixed)

        let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
        let conflict = try #require(preview.conflicts.first)
        #expect(try classify(incoming, .passkey, against: [local]) == .unchanged)
        #expect(try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: conflict.incoming)]) == [local])

        // Names, FIDO2 metadata and dates never decide.
        var annotated = local
        annotated.passkeys[0].userName = "renamed locally"
        annotated.passkeys[0].userDisplayName = "Renamed Locally"
        annotated.passkeys[0].exchangeFIDO2Metadata = Data([0x7b, 0x7d])
        annotated.passkeys[0].createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        annotated.passkeys[0].lastSignedAt = Date(timeIntervalSince1970: 1_650_000_000)
        #expect(try classify(incoming, .passkey, against: [annotated]) == .unchanged)

        // An equivalent stored passkey is never written again, here or in another account: only keep is valid.
        let other = h.account(username: "grace", password: "unrelated")
        let duplicatePreview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local, other]))
        let duplicate = try #require(duplicatePreview.conflicts.first)
        for target in [nil, other.id] as [UUID?] {
            #expect {
                try CredentialExchangeCodec.apply(duplicatePreview, decisions: [.add(incoming: duplicate.incoming, targetAccountID: target)])
            } throws: { isInvalidData($0) }
        }
        #expect(try CredentialExchangeCodec.apply(duplicatePreview, decisions: [.keep(incoming: duplicate.incoming)]) == [local, other])
    }

    @Test func differentCredentialIDAppends() throws {
        let local = try stored(h.data(credentials: [h.passkey(key: try newKey())]))
        let incoming = h.data(credentials: [h.passkey(id: Data([0xC0, 0x02]), key: try newKey())])
        #expect(try classify(incoming, .passkey, against: [local]) == .new)

        let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
        #expect(preview.conflicts.isEmpty)
        let result = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(result.count == 1)
        #expect(result.first?.passkeys.map(\.credentialID) == [Data([0xC0, 0x01]), Data([0xC0, 0x02])])
        #expect(result.first?.passkeys.first == local.passkeys.first)
    }

    @Test func passkeyReplaceDecisionIsRejectedByApply() throws {
        let key = try newKey()
        let local = try stored(h.data(credentials: [h.passkey(key: key)]))
        let storedIdentity = CredentialIdentity.passkey(accountID: local.id, passkeyID: local.passkeys[0].id)

        // The same credential, even with the same key.
        let same = try CredentialExchangeCodec.preview(h.data(credentials: [h.passkey(key: key)]), against: h.snapshot([local]))
        let conflict = try #require(same.conflicts.first)
        #expect { try CredentialExchangeCodec.apply(same, decisions: [.replace(incoming: conflict.incoming, target: conflict.existing)]) }
            throws: { isInvalidData($0) }

        // A distinct credential: not a conflict, still never a replacement of a stored passkey.
        let other = try CredentialExchangeCodec.preview(
            h.data(credentials: [h.passkey(id: Data([0xC0, 0x02]), key: try newKey())]),
            against: h.snapshot([local])
        )
        let candidate = try #require(other.candidates.first)
        let incoming = CredentialIdentity.passkey(accountID: candidate.id, passkeyID: candidate.passkeys[0].id)
        #expect { try CredentialExchangeCodec.apply(other, decisions: [.replace(incoming: incoming, target: storedIdentity)]) }
            throws: { isInvalidData($0) }
        #expect(other.base.accounts == [local])
    }

    // MARK: Identity

    /// An id match without an accepted pairing is only a hint: content that differs is the user's call, and nothing says who changed it.
    @Test func idMatchWithoutBoundPairingIsAmbiguous() throws {
        let unbound = try unbound(h.data(credentials: [login("v1")]))
        #expect(try classify(h.data(credentials: [login("v2")]), .password, against: [unbound]) == .ambiguous)
        let unboundTOTP = try self.unbound(h.data(credentials: [login("v1"), h.totp()]))
        #expect(try classify(h.data(credentials: [login("v2"), h.totp()]), .password, against: [unboundTOTP]) == .ambiguous)
        // A code the saved item doesn't hold yet: with no pairing there is nothing to compare it with, so it is not called new either.
        #expect(try classify(h.data(credentials: [login("v1"), h.totp()]), .totp, against: [unbound]) == .ambiguous)
    }

    /// An item saved before imports recorded what they brought in has no base. A login or code that equals what is sent is the same
    /// credential whoever pairs it, so it is unchanged and the next import records the base; it is not a question.
    @Test func anUnboundLinkedItemWithIdenticalContentIsUnchanged() throws {
        let data = h.data(credentials: [login("v1"), h.totp()])
        let unbound = try unbound(data)
        #expect(try classify(data, .password, against: [unbound]) == .unchanged)
        #expect(try classify(data, .totp, against: [unbound]) == .unchanged)
    }

    /// What an import records is what the next one compares with (§13.2a): applying a transfer binds every login and code it brought
    /// in, and a later transfer is unchanged, changed in the other app, changed here, or both, by content hash alone.
    @Test func reimportClassifiesAgainstTheRecordedBase() throws {
        let v1 = h.data(credentials: [login("v1"), h.totp()])
        let v2 = h.data(credentials: [login("v2"), h.totp()])
        let imported = try stored(v1)
        #expect(imported.passwordBase?.itemID == imported.exchangeItemID && imported.totpBase?.itemID == imported.exchangeItemID)
        var editedLocally = imported
        editedLocally.password = "local"

        #expect(try classify(v1, .password, against: [imported]) == .unchanged)
        #expect(try classify(v2, .password, against: [imported]) == .remoteChanged)
        #expect(try classify(v1, .password, against: [editedLocally]) == .localChanged)
        #expect(try classify(v2, .password, against: [editedLocally]) == .bothChanged)
        #expect(try classify(v1, .totp, against: [imported]) == .unchanged)
    }

    @Test func idMatchSeveralLocalIsAmbiguous() throws {
        let first = try h.bound(stored(h.data(credentials: [login("v1")])))
        var second = first
        second.id = UUID()
        #expect(try classify(h.data(credentials: [login("v1")]), .password, against: [first, second]) == .ambiguous)
    }

    @Test func neverMatchesBySiteAndUsername() throws {
        let sameSiteAndName = h.account(username: "ada", password: "old-password")
        let incoming = h.data(credentials: [login("v2")])
        #expect(try classify(incoming, .password, against: [sameSiteAndName]) == .new)

        let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([sameSiteAndName]))
        #expect(preview.conflicts.isEmpty)
        let result = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(result.count == 2)
        #expect(result.first == sameSiteAndName)
    }

    @Test func boundPairingClassifiesByContentHash() throws {
        let v1 = h.data(credentials: [login("v1"), h.totp()])
        let v2 = h.data(credentials: [login("v2"), h.totp()])
        let base = try h.bound(stored(v1))
        var editedLocally = base
        editedLocally.password = "local"

        #expect(try classify(v1, .password, against: [base]) == .unchanged)
        #expect(try classify(v2, .password, against: [base]) == .remoteChanged)
        #expect(try classify(v1, .password, against: [editedLocally]) == .localChanged)
        #expect(try classify(v2, .password, against: [editedLocally]) == .bothChanged)
        // Both sides arrived at the same content: nothing to review.
        #expect(try classify(h.data(credentials: [login("local"), h.totp()]), .password, against: [editedLocally]) == .unchanged)

        // A pairing that exists through another credential but has no observed base for this one: even equal
        // password content is not "unchanged" (§13.3); only an identical TOTP is.
        var withoutPasswordBase = base
        withoutPasswordBase.passwordBase = nil
        #expect(try classify(v2, .password, against: [withoutPasswordBase]) == .noCommonBase)
        #expect(try classify(v1, .password, against: [withoutPasswordBase]) == .noCommonBase)
        var withoutTOTPBase = base
        withoutTOTPBase.totpBase = nil
        #expect(try classify(v1, .totp, against: [withoutTOTPBase]) == .unchanged)
    }

    @Test func previouslyRemovedMatchesIdentifiersNotSecrets() throws {
        let incoming = h.data(credentials: [login("v1")])
        let entryID = UUID()

        let inTrash = removedEntry(entryID: entryID, itemID: h.itemExternalID)
        #expect(try classify(incoming, .password, against: [], removed: [inTrash]) == .previouslyRemoved(entryID: entryID, isTombstone: false))

        let purged = removedEntry(entryID: entryID, isTombstone: true, itemID: h.itemExternalID)
        #expect(try classify(incoming, .password, against: [], removed: [purged]) == .previouslyRemoved(entryID: entryID, isTombstone: true))

        // Another item id is a different item, whatever its contents.
        let otherItem = removedEntry(itemID: Data([0xB0, 0x99]))
        #expect(try classify(incoming, .password, against: [], removed: [otherItem]) == .new)
        #expect(try classify(incoming, .password, against: [], removed: []) == .new)

        // A removed passkey is matched by relying party and credential id, never by key.
        let passkeyIncoming = h.data(credentials: [h.passkey(key: try newKey())])
        let removedPasskey = removedEntry(entryID: entryID, credentialID: Data([0xC0, 0x01]), rpID: "example.test")
        #expect(
            try classify(passkeyIncoming, .passkey, against: [], removed: [removedPasskey])
                == .previouslyRemoved(entryID: entryID, isTombstone: false)
        )
        let otherCredential = removedEntry(credentialID: Data([0xC0, 0x77]), rpID: "example.test")
        #expect(try classify(passkeyIncoming, .passkey, against: [], removed: [otherCredential]) == .new)
        // A removed passkey identifier never marks a password of the same item as removed.
        #expect(try classify(incoming, .password, against: [], removed: [removedPasskey]) == .new)
    }

    @Test func aLiveMatchWinsOverARemovedIdentifier() throws {
        let local = try h.bound(stored(h.data(credentials: [login("v1")])))
        let removed = removedEntry(itemID: h.itemExternalID)
        #expect(try classify(h.data(credentials: [login("v1")]), .password, against: [local], removed: [removed]) == .unchanged)
    }

    @Test func aNativeAccountsRemovedRowMatchesWithoutRecordedExternalIDs() throws {
        // A native account exports under its own id; its Trash/tombstone row keeps the external ids as stored (nil).
        let native = h.account(username: "ada", password: "secret")
        let nativeExport = try exported(native)
        let entryID = UUID()
        func row(accountID: UUID, exchangeAccountID: Data? = nil, exchangeItemID: Data? = nil, isTombstone: Bool = false) -> RemovedIdentifier {
            RemovedIdentifier(
                entryID: entryID, isTombstone: isTombstone, accountID: accountID, exchangeAccountID: exchangeAccountID,
                exchangeItemID: exchangeItemID, passkeyCredentialID: nil, rpID: nil
            )
        }
        #expect(
            try classify(nativeExport, .password, against: [], removed: [row(accountID: native.id)])
                == .previouslyRemoved(entryID: entryID, isTombstone: false)
        )
        #expect(
            try classify(nativeExport, .password, against: [], removed: [row(accountID: native.id, isTombstone: true)])
                == .previouslyRemoved(entryID: entryID, isTombstone: true)
        )
        // Another native account, or another recorded exporter account, is a different item.
        #expect(try classify(nativeExport, .password, against: [], removed: [row(accountID: UUID())]) == .new)
        #expect(try classify(nativeExport, .password, against: [], removed: [row(accountID: native.id, exchangeAccountID: Data([0x99]))]) == .new)
        // An item id alone never matches another exporter account: the account side is compared exactly too.
        let foreign = h.data(credentials: [login("v1")])
        #expect(
            try classify(foreign, .password, against: [], removed: [row(accountID: UUID(), exchangeItemID: h.itemExternalID)]) == .new
        )
    }

    // MARK: TOTP and logins

    @Test func totpClassification() throws {
        let identical = h.data(credentials: [login("v1"), h.totp()])
        let local = try h.bound(stored(identical))
        #expect(try classify(identical, .totp, against: [local]) == .unchanged)

        let variants: [ASImportableCredential] = [
            h.totp(secret: Data("a-different-seed-value".utf8)),
            h.totp(period: 30),
            h.totp(digits: 6),
            h.totp(algorithm: .sha1),
            h.totp(issuer: "Another Issuer"),
        ]
        for variant in variants {
            let incoming = h.data(credentials: [login("v1"), variant])
            let outcome = try classify(incoming, .totp, against: [local])
            #expect(outcome == .remoteChanged)

            let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
            #expect(preview.conflicts.contains { $0.incoming == .totp(accountID: preview.candidates[0].id) })
        }
    }

    @Test func usernameOnlyIncomingNeverRemovesAStoredPassword() throws {
        let local = try unbound(h.data(credentials: [login("keep-me")]))
        let usernameOnly = h.data(credentials: [
            .basicAuthentication(.init(
                userName: .init(id: Data([0x11]), fieldType: .string, value: "ada", label: "Login"),
                password: nil
            )),
        ])
        let preview = try CredentialExchangeCodec.preview(usernameOnly, against: h.snapshot([local]))
        let conflict = try #require(preview.conflicts.first)
        #expect(conflict.incoming == .password(accountID: preview.candidates[0].id))
        #expect(try classify(usernameOnly, .password, against: [local]) == .ambiguous)

        let kept = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: conflict.incoming)])
        #expect(kept == [local])
        let added = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: conflict.incoming, targetAccountID: nil)])
        #expect(added.first == local)
        #expect(added.first?.password == "keep-me")
    }

    @Test func usernameOnlyExplicitReplaceNeverClearsAStoredPassword() throws {
        let local = try stored(h.data(credentials: [login("keep-me")]))
        let usernameOnly = h.data(credentials: [
            .basicAuthentication(.init(
                userName: .init(id: Data([0x11]), fieldType: .string, value: "ada", label: "Login"),
                password: nil
            )),
        ])
        let preview = try CredentialExchangeCodec.preview(usernameOnly, against: h.snapshot([local]))
        let conflict = try #require(preview.conflicts.first)
        #expect { try CredentialExchangeCodec.apply(preview, decisions: [.replace(incoming: conflict.incoming, target: conflict.existing)]) }
            throws: { isInvalidData($0) }
        #expect(preview.base.accounts == [local])
        #expect(preview.base.accounts.first?.password == "keep-me")

        // A replacement that carries a password still replaces.
        let withPassword = try CredentialExchangeCodec.preview(h.data(credentials: [login("new-secret")]), against: h.snapshot([local]))
        let replacing = try #require(withPassword.conflicts.first)
        let replaced = try CredentialExchangeCodec.apply(
            withPassword, decisions: [.replace(incoming: replacing.incoming, target: replacing.existing)]
        )
        #expect(replaced.first?.password == "new-secret")
    }

    @Test func defaultMergeThatWouldThrowInvalidDataBecomesAConflict() throws {
        let local = try unbound(h.data(credentials: [login("keep-me")]))
        let incoming = h.data(credentials: [login("another-secret")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
        // The default merge into the linked account would throw `invalidData`; the user is asked instead.
        #expect(preview.conflicts.count == 1)
        #expect { try CredentialExchangeCodec.apply(preview, decisions: []) } throws: { isInvalidData($0) }
        #expect(try classify(incoming, .password, against: [local]) == .ambiguous)
    }

    @Test func malformedPayloadStillFailsClosedWholeWithPositionOnly() throws {
        let secret = "must-not-appear-in-diagnostics"
        let good = h.importableItem(id: Data([0xB0, 0x01]), title: "Good", credentials: [login("fine")])
        // One field id for the username and the password cannot be told apart, which no import keeps.
        let bad = h.importableItem(
            id: Data([0xB0, 0x02]),
            title: "Bad",
            credentials: [h.basicAuthentication(username: "other", password: secret, usernameID: Data([0x66]), passwordID: Data([0x66]))]
        )
        let payload = ASExportedCredentialData(
            accounts: [ASImportableAccount(id: h.accountExternalID, userName: "ada", email: "ada@example.test", collections: [], items: [good, bad])],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        do {
            _ = try CredentialExchangeCodec.preview(payload, against: h.snapshot([]))
            Issue.record("Expected the whole payload to be rejected")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 0, item: 1, credential: 0))
            #expect(diagnostic.reason == .duplicateIdentifier)
            #expect(!String(describing: error).contains(secret))
        }
    }

    @Test func replaceSupersedesPasswordAndTotpIntoARevisionPlan() throws {
        let local = try stored(h.data(credentials: [login("old-secret"), h.totp()]))
        let incoming = h.data(credentials: [login("new-secret"), h.totp(secret: Data("replacement-seed".utf8))])
        let preview = try CredentialExchangeCodec.preview(incoming, against: h.snapshot([local]))
        #expect(preview.conflicts.count == 2)
        let result = try CredentialExchangeCodec.apply(
            preview,
            decisions: preview.conflicts.map { .replace(incoming: $0.incoming, target: $0.existing) }
        )
        #expect(result.first?.password == "new-secret")

        let plan = try CredentialDiff.plan(old: [local], new: result)
        let password = try #require(plan.revisions.first { $0.ownerID == local.id && $0.subject == .password })
        let totp = try #require(plan.revisions.first { $0.ownerID == local.id && $0.subject == .totp })
        #expect(String(decoding: password.superseded, as: UTF8.self).contains("old-secret"))
        #expect(try JSONDecoder().decode(TOTPGenerator.self, from: totp.superseded).secret == local.totp?.secret)
    }

    // MARK: Export

    @Test func exportLastModifiedIsModifiedAtWhenWSurfChanged() throws {
        var account = try datedAccount()
        let changedAt = Date(timeIntervalSince1970: 1_750_000_000)
        account.password = "edited in WSurf"
        account.modifiedAt = changedAt
        #expect(try exportedItem(account).lastModified == changedAt)

        // Even content that still equals its base reports the WSurf change time once WSurf stamped one.
        var touched = try datedAccount()
        touched.modifiedAt = changedAt
        #expect(try exportedItem(touched).lastModified == changedAt)
    }

    @Test func inheritedDatesOnlyWhileContentHashEqualsBase() throws {
        let account = try datedAccount()
        let untouched = try exportedItem(account, totp: true)
        #expect(untouched.created == importedCreated && untouched.lastModified == importedModified)

        var editedPassword = account
        editedPassword.password = "edited in WSurf"
        let editedItem = try exportedItem(editedPassword)
        #expect(editedItem.created == nil && editedItem.lastModified == nil)

        // Only the exported credentials count: an edited TOTP does not taint a password-only export.
        var editedTOTP = account
        editedTOTP.totp?.digits = 6
        let passwordOnly = try exportedItem(editedTOTP)
        #expect(passwordOnly.created == importedCreated && passwordOnly.lastModified == importedModified)
        let withTOTP = try exportedItem(editedTOTP, totp: true)
        #expect(withTOTP.created == nil && withTOTP.lastModified == nil)
    }

    @Test func otherwiseNilNeverNow() throws {
        // The dates are far from the clock, so any `Date()` would be visible.
        var unbound = try datedAccount()
        unbound.passwordBase = nil
        let data = try exported(unbound)
        let item = try #require(data.accounts.first?.items.first)
        #expect(item.created == nil && item.lastModified == nil)
        // `timestamp` stays the exporter's own time.
        #expect(abs(data.timestamp.timeIntervalSinceNow) < 60)

        var staleBase = try datedAccount()
        staleBase.password = "edited in WSurf"
        let staleItem = try exportedItem(staleBase)
        #expect(staleItem.created == nil && staleItem.lastModified == nil)

        // An account WSurf created has no inherited dates to show.
        let created = h.account(username: "ada", password: "secret")
        let createdItem = try exportedItem(created)
        #expect(createdItem.created == nil && createdItem.lastModified == nil)
    }

    // MARK: Hash failures

    @Test func contentHashFailuresPropagateInsteadOfTrapping() throws {
        // A destination account whose exchange metadata does not decode.
        var corrupt = try h.bound(stored(h.data(created: importedCreated, lastModified: importedModified, credentials: [login("v1")])))
        corrupt.exchangeMetadata = Data("not metadata".utf8)
        #expect(throws: CredentialStoreError.metadataUndecodable) {
            try classify(h.data(credentials: [login("v2")]), .password, against: [corrupt])
        }
        #expect(throws: CredentialStoreError.metadataUndecodable) {
            try exportedItem(corrupt)
        }

        // A destination passkey whose key cannot be imported, or whose algorithm is not ES256.
        let incoming = h.data(credentials: [h.passkey(key: try newKey())])
        let local = try stored(incoming)
        var unreadable = local
        unreadable.passkeys[0].privateKeyPKCS8 = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        #expect { try classify(incoming, .passkey, against: [unreadable]) } throws: { isInvalidData($0) }
        var wrongAlgorithm = local
        wrongAlgorithm.passkeys[0].algorithm = -257
        #expect { try classify(incoming, .passkey, against: [wrongAlgorithm]) } throws: { isInvalidData($0) }
    }
}
