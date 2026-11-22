// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

struct CredentialVaultMergePlanTests {
    private typealias Plan = CredentialVaultMergePlan

    private func file() -> CredentialAttachment {
        CredentialAttachment(
            id: UUID(), name: "example.pdf", contentType: "com.adobe.pdf", size: 12,
            sha256: Data(repeating: 11, count: 32), wrappedKey: Data(repeating: 7, count: 60), addedAt: nil
        )
    }

    private func card(number: String) -> SecureItem {
        SecureItem(kind: .creditCard, fields: [SecureItemField(name: "number", value: number)])
    }

    private func nativeCard(_ number: String) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: "", displayName: "Travel card", origins: [], loginURLs: [], passkeys: [], secureItems: [card(number: number)]
        )
    }

    @Test func copyReturnsOnlySelectedWholeEntriesAndClearsSourceVaultKeyedImportMemory() throws {
        var source = try VaultFixtures.richAccount()
        source.notes = [CredentialNote(text: "synthetic private note")]
        source.secureItems = [card(number: "4242424242424242")]
        source.attachments = [file()]
        source.importTrace = ImportTrace(logins: [Data(repeating: 9, count: 32)])
        let other = VaultFixtures.account(username: "other")
        let untouched = VaultFixtures.account(username: "untouched")
        let rows = try Plan.rows(source: [source, other], destination: [untouched])
        #expect(rows.map(\.kind) == [.new, .new])
        let writes = try Plan.replacements(
            rows: rows, choices: [source.id: .copy, other.id: .skip], source: [source, other], destination: [untouched]
        )
        var expected = source
        expected.importTrace = nil
        #expect(writes == [expected])
        #expect(source.importTrace != nil)
    }

    @Test func anIndependentCopyWithTheSamePasskeyAndRewrappedFilesIsAlreadySaved() throws {
        var source = try VaultFixtures.richAccount()
        source.attachments = [file()]
        source.exchangeAccountID = nil
        source.exchangeItemID = nil
        var saved = source
        saved.id = UUID()
        saved.passkeys[0].id = UUID()
        saved.passkeys[0].lastSignedAt = .now
        saved.attachments?[0].id = UUID()
        saved.attachments?[0].wrappedKey = Data(repeating: 3, count: 60)
        saved.createdAt = .now
        let rows = try Plan.rows(source: [source], destination: [saved])
        #expect(rows.first?.kind == .duplicate && rows.first?.targetID == saved.id)
        #expect(rows.first?.choices == [.skip])
        #expect(try Plan.replacements(rows: rows, choices: [source.id: .skip], source: [source], destination: [saved]).isEmpty)
    }

    @Test func noteBytesAndFilesWithTheSameNameAndSizeButDifferentContentNeedReview() throws {
        var source = VaultFixtures.account()
        source.notes = [CredentialNote(text: "\u{e9}")]
        source.attachments = [file()]
        var saved = source
        saved.notes = [CredentialNote(text: "e\u{301}")]
        saved.attachments?[0].sha256 = Data(repeating: 22, count: 32)
        let row = try #require(Plan.rows(source: [source], destination: [saved]).first)
        #expect(row.kind == .conflict)
        #expect(row.choices.contains(.replace) && !row.choices.contains(.copy))
        #expect(row.differences.count >= 2)
    }

    @Test func siteAndUsernameRequireAnExplicitDecisionAndReplaceRetainsTheDestinationIdentity() throws {
        var local = VaultFixtures.account(password: "local secret")
        local.notes = [CredentialNote(text: "new note")]
        var shared = VaultFixtures.account(password: "shared secret")
        shared.exchangeAccountID = Data([10])
        shared.exchangeItemID = Data([11])
        let unrelated = VaultFixtures.account(username: "another")
        let rows = try Plan.rows(source: [local], destination: [shared, unrelated])
        let row = try #require(rows.first)
        #expect(row.kind == .conflict && Set(row.choices) == [.copy, .replace, .skip])
        #expect(row.differences.contains(String(localized: "Password")) && !row.differences.contains(String(localized: "Login")))
        #expect(throws: (any Error).self) {
            _ = try Plan.replacements(rows: rows, choices: [:], source: [local], destination: [shared, unrelated])
        }
        let writes = try Plan.replacements(rows: rows, choices: [local.id: .replace], source: [local], destination: [shared, unrelated])
        let updated = try #require(writes.first)
        #expect(writes.count == 1 && updated.id == shared.id && updated.notes == local.notes && updated.password == local.password)
        #expect(updated.exchangeAccountID == shared.exchangeAccountID && updated.exchangeItemID == shared.exchangeItemID)
        #expect(try Plan.rows(source: [local], destination: [updated, unrelated]).first?.kind == .duplicate)
        let copies = try Plan.replacements(rows: rows, choices: [local.id: .copy], source: [local], destination: [shared, unrelated])
        #expect(copies.map(\.id) == [local.id])
        #expect(try Plan.rows(source: [local], destination: [shared, unrelated] + copies).first?.kind == .duplicate)
    }

    @Test func secureOnlyEntriesAreRecognizedWithoutLoginOrExchangeIDs() throws {
        let first = nativeCard("4242424242424242")
        let same = nativeCard("4242424242424242")
        let different = nativeCard("4000000000000002")
        #expect(try Plan.rows(source: [first], destination: [same]).first?.kind == .duplicate)
        let row = try #require(Plan.rows(source: [first], destination: [different]).first)
        #expect(row.kind == .conflict && row.choices.contains(.copy))
        #expect(!row.choices.contains(.replace), "a shared display name alone cannot identify a safe replacement")
        #expect(!([row.title] + row.matches + row.differences).joined().contains("4242424242424242"))
    }

    @Test func collidingPasskeyMaterialOrADestinationOnlyKeyCannotBeReplaced() throws {
        let saved = try VaultFixtures.account(passkeys: [VaultFixtures.passkey()])
        var collision = saved
        collision.id = UUID()
        collision.passkeys[0] = try VaultFixtures.passkey(credentialID: saved.passkeys[0].credentialID)
        let dangerous = try #require(Plan.rows(source: [collision], destination: [saved]).first)
        #expect(dangerous.kind == .conflict && dangerous.choices == [.skip])
        collision.passkeys[0].credentialID = Data([6])
        collision.passkeys[0].id = saved.passkeys[0].id
        #expect(try Plan.rows(source: [collision], destination: [saved]).first?.choices == [.skip])
        let fewer = VaultFixtures.account(password: "updated")
        let partial = try #require(Plan.rows(source: [fewer], destination: [saved]).first)
        #expect(Set(partial.choices) == [.copy, .skip])
    }

    @Test func updatedDetailsOfAnExistingPasskeyCannotBeReplacedAcrossMacs() throws {
        let saved = try VaultFixtures.account(passkeys: [VaultFixtures.passkey()])
        var source = saved
        source.id = UUID()
        source.passkeys[0].id = UUID()
        source.passkeys[0].userDisplayName = "Updated label"
        source.password = "also changed"
        let rows = try Plan.rows(source: [source], destination: [saved])
        #expect(rows.first?.kind == .conflict && rows.first?.choices == [.skip] && rows.first?.reason != nil)
        #expect(throws: (any Error).self) {
            _ = try Plan.replacements(rows: rows, choices: [source.id: .replace], source: [source], destination: [saved])
        }
    }

    @Test func replacingAPasswordAndAddingAPasskeyRetainsTheSharedPasskeyID() throws {
        let saved = try VaultFixtures.account(passkeys: [VaultFixtures.passkey()])
        var source = saved
        source.id = UUID()
        source.passkeys[0].id = UUID()
        source.password = "new password"
        let newKey = try VaultFixtures.passkey(credentialID: Data([5]))
        source.passkeys.append(newKey)
        let rows = try Plan.rows(source: [source], destination: [saved])
        #expect(rows.first?.kind == .conflict && rows.first?.choices.contains(.replace) == true)
        let applied = try #require(Plan.replacements(rows: rows, choices: [source.id: .replace], source: [source], destination: [saved]).first)
        #expect(applied.password == source.password && applied.passkeys == saved.passkeys + [newKey])
        #expect(try Plan.rows(source: [source], destination: [applied]).first?.kind == .duplicate)
        source.passkeys.swapAt(0, 1)
        #expect(try Plan.rows(source: [source], destination: [saved]).first?.choices == [.skip])
    }

    @Test(arguments: [false, true]) func aPreviouslyReplacedSourceCanChangeBothItsUsernameAndWebsite(regenerateSourceID: Bool) throws {
        var source = VaultFixtures.account(password: "first revision")
        if regenerateSourceID {
            source.exchangeAccountID = Data([77])
            source.exchangeItemID = Data([78])
        }
        let saved = VaultFixtures.account(password: "old")
        let rows = try Plan.rows(source: [source], destination: [saved])
        let first = try #require(Plan.replacements(rows: rows, choices: [source.id: .replace], source: [source], destination: [saved]).first)
        if regenerateSourceID {
            source.id = UUID()
        }
        source.username = "renamed"
        source.origins = ["https://renamed.example.test"]
        source.loginURLs = []
        let later = try Plan.rows(source: [source], destination: [first])
        #expect(later.first?.choices.contains(.replace) == true && later.first?.targetID == saved.id)
        #expect(later.first?.differences.contains(String(localized: "Login")) == true)
        let second = try #require(Plan.replacements(rows: later, choices: [source.id: .replace], source: [source], destination: [first]).first)
        #expect(second.id == saved.id && second.mergedFrom == first.mergedFrom && second.username == "renamed" && second.origins == source.origins)
    }

    @Test func aStoredEntryTheSyncCodecCannotSendCanBeSkippedWithoutBlockingOtherEntries() throws {
        var legacy = VaultFixtures.account()
        legacy.exchangeMetadata = Data("older opaque metadata".utf8)
        try legacy.validate()
        #expect(VaultSyncCodec.syncable(legacy) == nil)
        let good = VaultFixtures.account(username: "another")
        let rows = try Plan.rows(source: [legacy, good], destination: [])
        #expect(rows.map(\.kind) == [.conflict, .new] && rows[0].choices == [.skip] && rows[0].reason != nil)
        #expect(try Plan.replacements(rows: rows, choices: [legacy.id: .skip, good.id: .copy], source: [legacy, good], destination: []) == [good])
    }

    @Test func ambiguousTargetsCannotBeReplacedAndTwoCandidatesCannotWriteTheSameTarget() throws {
        let local = VaultFixtures.account(password: "a")
        let first = VaultFixtures.account(password: "b")
        let second = VaultFixtures.account(password: "c")
        let ambiguous = try #require(Plan.rows(source: [local], destination: [first, second]).first)
        #expect(ambiguous.kind == .conflict && Set(ambiguous.choices) == [.copy, .skip])
        #expect(ambiguous.matches.count == 2)
        let rows = try Plan.rows(source: [local, second], destination: [first])
        #expect(rows.allSatisfy { $0.kind == .conflict })
        #expect(throws: (any Error).self) {
            _ = try Plan.replacements(rows: rows, choices: [local.id: .replace, second.id: .replace], source: [local, second], destination: [first])
        }
    }

    @Test(arguments: [false, true]) func aForcedDuplicateKeepsItsSharedEntryWhenAnotherRowSharesTheLogin(reverse: Bool) throws {
        let saved = VaultFixtures.account(password: "first")
        let exact = VaultFixtures.account(password: "first")
        let different = VaultFixtures.account(password: "second")
        let source = reverse ? [different, exact] : [exact, different]
        let rows = try Plan.rows(source: source, destination: [saved])
        let duplicate = try #require(rows.first { $0.id == exact.id })
        let conflict = try #require(rows.first { $0.id == different.id })
        #expect(duplicate.kind == .duplicate && duplicate.choices == [.skip] && duplicate.targetID == saved.id)
        #expect(conflict.kind == .conflict && Set(conflict.choices) == [.copy, .skip] && conflict.targetID == nil && conflict.reason != nil)
        let copied = try Plan.replacements(rows: rows, choices: [different.id: .copy], source: source, destination: [saved])
        #expect(copied == [different])
        #expect(try Plan.rows(source: source, destination: [saved] + copied).allSatisfy { $0.kind == .duplicate })
        #expect(try Plan.replacements(rows: rows, choices: [different.id: .skip], source: source, destination: [saved]).isEmpty)
        #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
            _ = try Plan.replacements(rows: rows, choices: [different.id: .replace], source: source, destination: [saved])
        }

        // An earlier review had no exact duplicate. Its Replace must be refused even though its source and target ids still match.
        var earlier = exact
        earlier.password = "third"
        let stale = try Plan.rows(source: reverse ? [different, earlier] : [earlier, different], destination: [saved])
        #expect(stale.first { $0.id == different.id }?.choices.contains(.replace) == true)
        #expect(throws: (any Error).self) {
            _ = try Plan.replacements(rows: stale, choices: [exact.id: .skip, different.id: .replace], source: source, destination: [saved])
        }
    }

    @Test func theOnlySafeChoiceIsSkipWhenADuplicateNeedsTheSameDestinationIdentity() throws {
        let saved = VaultFixtures.account(password: "first")
        let exact = VaultFixtures.account(password: "first")
        var changed = saved
        changed.password = "second"
        let rows = try Plan.rows(source: [exact, changed], destination: [saved])
        #expect(rows.last?.kind == .conflict && rows.last?.choices == [.skip] && rows.last?.targetID == nil)
    }

    @Test func aSharedExporterClaimInsideTheBatchCanOnlyBeCopiedOnce() throws {
        var left = VaultFixtures.account(username: "one")
        left.exchangeAccountID = Data([1])
        left.exchangeItemID = Data([2])
        var right = VaultFixtures.account(username: "two")
        right.exchangeAccountID = left.exchangeAccountID
        right.exchangeItemID = left.exchangeItemID
        let rows = try Plan.rows(source: [left, right], destination: [])
        #expect(rows.map(\.kind) == [.conflict, .conflict])
        #expect(throws: (any Error).self) {
            _ = try Plan.replacements(rows: rows, choices: [left.id: .copy, right.id: .copy], source: [left, right], destination: [])
        }
        #expect(try Plan.replacements(rows: rows, choices: [left.id: .skip, right.id: .copy], source: [left, right], destination: []) == [right])
    }

    @Test func aCommonLoginStillAllowsAnIndependentCopyAndFindsItAtTheEndOnRetry() throws {
        let local = VaultFixtures.account(password: "mine")
        let shared = (0..<65).map { VaultFixtures.account(password: "other-\($0)") }
        let rows = try Plan.rows(source: [local], destination: shared)
        #expect(rows.first?.kind == .conflict && rows.first?.choices.contains(.copy) == true)
        let retry = try #require(Plan.rows(source: [local], destination: shared + [local]).first)
        #expect(retry.kind == .duplicate && retry.matches.count == 1 && retry.targetID == local.id)
    }

    @Test func previouslyMarkedSeparateEntriesCanCoexistEvenIfTheirCurrentContentMatches() throws {
        let first = VaultFixtures.account()
        var separate = VaultFixtures.account()
        separate.notSameAs = [first.id]
        let rows = try Plan.rows(source: [first], destination: [separate])
        #expect(rows.first?.kind == .conflict && Set(rows[0].choices) == [.copy, .skip])
        #expect(try Plan.replacements(rows: rows, choices: [first.id: .copy], source: [first], destination: [separate]) == [first])
    }

    @Test func hiddenUsernamesNeverAppearInReviewWhilePasskeyExtensionDifferencesDo() throws {
        var saved = try VaultFixtures.account(username: "synthetic hidden name", passkeys: [VaultFixtures.passkey()])
        saved.origins = []
        saved.loginURLs = []
        saved.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(fieldType: .concealedString), password: CredentialEditableFieldMetadata(fieldType: .concealedString)
        )
        var source = saved
        source.passkeys[0].exchangeFIDO2Metadata = Data([1])
        let row = try #require(Plan.rows(source: [source], destination: [saved]).first)
        #expect(row.kind == .conflict && row.choices == [.skip] && !row.differences.isEmpty)
        #expect(!([row.title] + row.matches + row.differences).joined().contains("synthetic hidden name"))
    }

    @Test func nativeCardNetworkCodeAndFileCanBeReviewedWithoutEntryNames() throws {
        var savedCard = nativeCard("4242424242424242")
        savedCard.displayName = nil
        var updatedCard = savedCard
        updatedCard.secureItems?[0].fields.append(SecureItemField(name: "expiryDate", value: "2030-10"))
        let savedWiFi = CredentialAccount(
            id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [],
            secureItems: [SecureItem(kind: .wifi, fields: [SecureItemField(name: "ssid", value: "Example network")])]
        )
        var updatedWiFi = savedWiFi
        updatedWiFi.secureItems?[0].fields.append(SecureItemField(name: "passphrase", value: "new example password"))
        var savedCode = CredentialAccount(id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [], totp: VaultFixtures.totp())
        savedCode.totp?.userName = "ada"
        var updatedCode = savedCode
        updatedCode.totp?.secret = Data([7])
        let savedFile = CredentialAccount(id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [], attachments: [file()])
        var updatedFile = savedFile
        updatedFile.attachments?[0].size = 13
        updatedFile.attachments?[0].sha256 = Data(repeating: 31, count: 32)
        let pairs = [(savedCard, updatedCard), (savedWiFi, updatedWiFi), (savedCode, updatedCode), (savedFile, updatedFile)]
        for (stored, var source) in pairs {
            source.id = UUID()
            let row = try #require(Plan.rows(source: [source], destination: [stored]).first)
            #expect(row.kind == .conflict && row.choices.contains(.copy))
            #expect(row.choices.contains(.replace) == (source.secureItems?.first?.kind == .creditCard))
            #expect(!([row.title] + row.matches + row.differences).joined().contains("4242424242424242"))
        }
    }
}
