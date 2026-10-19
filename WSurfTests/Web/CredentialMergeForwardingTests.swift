// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

/// After two imported items are merged into one credential, a later import of either item finds that credential, not the Trash the
/// absorbed one left for: what changed in the other app is told from what changed here by the base recorded for the item that
/// supplied each part. Synthetic items only; every step goes through `preview`, `classify` and `apply`.
@MainActor
struct CredentialMergeForwardingTests {
    private let h = CredentialExchangeTests()
    private let appleAccount = Data([0xA0, 0x01])
    private let itemX = Data([0xB0, 0x01])
    private let itemY = Data([0xB0, 0x02])

    private func export(
        _ item: Data, title: String, password: String?, extra: [ASImportableCredential] = [], urls: [String] = ["https://example.test/login"]
    ) -> ASExportedCredentialData {
        let login = password.map { [h.basicAuthentication(username: "ada", password: $0)] } ?? []
        return h.data(
            accountID: appleAccount, itemID: item, title: title,
            scope: ASImportableCredentialScope(urls: urls.map { URL(string: $0)! }, androidApps: []), credentials: login + extra
        )
    }

    /// The account an import of `data` into an empty vault saves: linked to the item, with the bases the import recorded.
    private func imported(_ data: ASExportedCredentialData) throws -> CredentialAccount {
        let preview = try CredentialExchangeCodec.preview(data, against: h.snapshot([]))
        return try #require(try CredentialExchangeCodec.apply(preview, decisions: []).first)
    }

    private func picks(_ survivor: CredentialAccount, login: CredentialAccount? = nil) -> MergePicks {
        MergePicks(survivor: survivor.id, name: survivor.id, login: (login ?? survivor).id, code: survivor.id)
    }

    private func removed(_ account: CredentialAccount) -> RemovedIdentifier {
        RemovedIdentifier(
            entryID: UUID(), isTombstone: false, accountID: account.id, exchangeAccountID: account.exchangeAccountID,
            exchangeItemID: account.exchangeItemID, passkeyCredentialID: nil, rpID: nil
        )
    }

    private func classify(
        _ data: ASExportedCredentialData, _ kind: (CredentialIdentity) -> Bool, in accounts: [CredentialAccount], removed: [RemovedIdentifier]
    ) throws -> CredentialImportClass {
        let preview = try CredentialExchangeCodec.preview(data, against: h.snapshot([]))
        let identities = preview.candidates.flatMap(CredentialExchangeCodec.identities(in:))
        guard let identity = identities.first(where: kind) else { throw CredentialVaultError.invalidData }
        return try CredentialExchangeCodec.classify(
            identity, in: preview, destination: ImportDestinationView(accounts: accounts, removed: RemovedIdentifiers(items: removed))
        )
    }

    private func isPassword(_ identity: CredentialIdentity) -> Bool {
        guard case .password = identity else { return false }
        return true
    }

    private func isPasskey(_ identity: CredentialIdentity) -> Bool {
        guard case .passkey = identity else { return false }
        return true
    }

    private func isNote(_ identity: CredentialIdentity) -> Bool {
        guard case .note = identity else { return false }
        return true
    }

    /// Both items, merged into the first: the survivor, and the first item's account as it was before.
    private func merged(
        x password: String = "same", y yPassword: String = "same", loginFromY: Bool = false
    ) throws -> (survivor: CredentialAccount, x: CredentialAccount, y: CredentialAccount) {
        let x = try imported(export(itemX, title: "Mail", password: password))
        let y = try imported(export(itemY, title: "Webmail", password: yPassword, urls: ["https://www.example.test/login"]))
        let survivor = try CredentialMerge.merged([x, y], picks: picks(x, login: loginFromY ? y : nil))
        return (survivor, x, y)
    }

    /// Every real conflict kept as it is saved: what a person who changes nothing decides.
    private func keepSaved(_ preview: CredentialImportPreview) -> [CredentialImportDecision] {
        preview.conflicts.map { .keep(incoming: $0.incoming) }
    }

    // MARK: Gap 1

    @Test func aChangeToTheMergedAwayItemIsChangedInPasswordsNotPreviouslyRemoved() throws {
        let (survivor, _, y) = try merged()
        let link = try #require(survivor.mergedFrom?.first)
        #expect(link.exchangeItemID == itemY)
        #expect(link.passwordBase != nil)

        let reimport = export(itemY, title: "Webmail", password: "changed", urls: ["https://www.example.test/login"])
        let result = try classify(reimport, isPassword, in: [survivor], removed: [removed(y)])
        #expect(result == .remoteChanged)
    }

    @Test func theSameChangeWithALocalEditNeedsADecision() throws {
        let parts = try merged()
        var survivor = parts.survivor
        let y = parts.y
        survivor.password = "edited here"
        let reimport = export(itemY, title: "Webmail", password: "changed", urls: ["https://www.example.test/login"])
        #expect(try classify(reimport, isPassword, in: [survivor], removed: [removed(y)]) == .bothChanged)

        // Nothing changed in the other app: the local edit stays, and nothing is asked.
        let unchanged = export(itemY, title: "Webmail", password: "same", urls: ["https://www.example.test/login"])
        #expect(try classify(unchanged, isPassword, in: [survivor], removed: [removed(y)]) == .localChanged)
    }

    @Test func acceptingTheChangeUpdatesTheSurvivorAndRecordsTheNewBase() throws {
        let (survivor, _, _) = try merged()
        let reimport = export(itemY, title: "Webmail", password: "changed", urls: ["https://www.example.test/login"])
        let preview = try CredentialExchangeCodec.preview(reimport, against: h.snapshot([survivor]))
        let conflict = try #require(preview.conflicts.first)
        #expect(preview.conflicts.count == 1)
        #expect(conflict.existing == .password(accountID: survivor.id))

        let result = try CredentialExchangeCodec.apply(preview, decisions: [.replace(incoming: conflict.incoming, target: conflict.existing)])
        let updated = try #require(result.first)
        #expect(result.count == 1)
        #expect(updated.id == survivor.id)
        #expect(updated.password == "changed")
        #expect(updated.exchangeItemID == itemX, "the survivor keeps its own identity")
        #expect(updated.passwordBase == survivor.passwordBase, "the survivor's own base is for its own item")
        let link = try #require(updated.mergedFrom?.first)
        #expect(link.passwordBase?.contentHash == (try CredentialContent.hash(.password(updated))))
        // The next import of the same data finds nothing to do.
        let again = try classify(reimport, isPassword, in: result, removed: [])
        #expect(again == .unchanged)
    }

    @Test func aNewPasskeyOnTheMergedAwayItemIsAddedToTheSurvivor() throws {
        let (survivor, _, y) = try merged()
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let reimport = export(
            itemY, title: "Webmail", password: "same", extra: [h.passkey(id: Data([0xC0, 0x09]), key: key)],
            urls: ["https://www.example.test/login"]
        )
        #expect(try classify(reimport, isPasskey, in: [survivor], removed: [removed(y)]) == .new)

        let preview = try CredentialExchangeCodec.preview(reimport, against: h.snapshot([survivor]))
        let result = try CredentialExchangeCodec.apply(preview, decisions: keepSaved(preview))
        let updated = try #require(result.first)
        #expect(result.count == 1)
        #expect(updated.passkeys.map(\.credentialID) == [Data([0xC0, 0x09])])
        #expect(updated.exchangeItemID == itemX)
        #expect(updated.displayName == survivor.displayName, "the survivor keeps its own name")
    }

    @Test func aLocalNoteOnTheSurvivorSurvivesAReimport() throws {
        let parts = try merged()
        var survivor = parts.survivor
        let y = parts.y
        survivor.notes = [CredentialNote(text: "written here", field: nil)]

        let plain = export(itemY, title: "Webmail", password: "same", urls: ["https://www.example.test/login"])
        let first = try CredentialExchangeCodec.preview(plain, against: h.snapshot([survivor]))
        let kept = try CredentialExchangeCodec.apply(first, decisions: keepSaved(first))
        #expect(kept.first?.notes?.map(\.text) == ["written here"])

        // The item brings a note of its own: the saved note is not replaced unless the user says so.
        let note = ASImportableCredential.note(.init(content: .init(id: nil, fieldType: .string, value: "from the other app", label: nil)))
        let withNote = export(itemY, title: "Webmail", password: "same", extra: [note], urls: ["https://www.example.test/login"])
        let second = try CredentialExchangeCodec.preview(withNote, against: h.snapshot([survivor]))
        let decisions = keepSaved(second)
        #expect(second.conflicts.contains { isNote($0.incoming) })
        let result = try CredentialExchangeCodec.apply(second, decisions: decisions)
        #expect(result.first?.notes?.map(\.text) == ["written here"])
        let noteClass = try classify(withNote, isNote, in: [survivor], removed: [removed(y)])
        if case .previouslyRemoved = noteClass {
            Issue.record("a note of a merged-away item was classified as previously removed")
        }
    }

    @Test func notesTheMergeAlreadyHoldsAreNotAskedAboutAgain() throws {
        // Each item brings a note; the merged credential holds both, so neither item's unchanged note is a decision on re-import.
        let x = try imported(export(itemX, title: "Mail", password: "same", extra: [h.note("from mail")]))
        let y = try imported(export(
            itemY, title: "Webmail", password: "same", extra: [h.note("from webmail")], urls: ["https://www.example.test/login"]
        ))
        var survivor = try CredentialMerge.merged([x, y], picks: picks(x))
        #expect(survivor.notes?.map(\.text) == ["from mail", "from webmail"])
        let xAgain = export(itemX, title: "Mail", password: "same", extra: [h.note("from mail")])
        let yAgain = export(itemY, title: "Webmail", password: "same", extra: [h.note("from webmail")], urls: ["https://www.example.test/login"])
        #expect(try classify(xAgain, isNote, in: [survivor], removed: []) == .unchanged)
        #expect(try classify(yAgain, isNote, in: [survivor], removed: [removed(y)]) == .unchanged)

        // A note added here is kept the same way; a note the other app changed still waits for the user.
        survivor.notes?.append(CredentialNote(text: "written here", field: nil))
        #expect(try classify(yAgain, isNote, in: [survivor], removed: [removed(y)]) == .unchanged)
        let yEdited = export(itemY, title: "Webmail", password: "same", extra: [h.note("edited there")], urls: ["https://www.example.test/login"])
        #expect(try classify(yEdited, isNote, in: [survivor], removed: [removed(y)]) == .noCommonBase)
    }

    @Test func aMergedAwayItemNeverAddsAWebsiteOutsideTheMergedOnes() throws {
        let (survivor, _, _) = try merged()
        let reimport = export(
            itemY, title: "Webmail", password: "same", urls: ["https://www.example.test/login", "https://foreign.test/login"]
        )
        let preview = try CredentialExchangeCodec.preview(reimport, against: h.snapshot([survivor]))
        let result = try CredentialExchangeCodec.apply(preview, decisions: keepSaved(preview))
        #expect(result.first?.origins == survivor.origins)
        #expect(result.first?.loginURLs == survivor.loginURLs)
    }

    @Test func aLoginTakenFromTheMergedAwayItemIsComparedWithThatItemsBase() throws {
        // The survivor's login is Y's: Y changing it in the other app is a change to the survivor's own password.
        let (survivor, x, y) = try merged(x: "x-password", y: "y-password", loginFromY: true)
        #expect(survivor.password == "y-password")
        let yChanged = export(itemY, title: "Webmail", password: "y-new", urls: ["https://www.example.test/login"])
        #expect(try classify(yChanged, isPassword, in: [survivor], removed: [removed(y)]) == .remoteChanged)

        // X's password was dropped by the merge, so X's own item differs from the survivor and stays a local choice.
        let xSame = export(itemX, title: "Mail", password: "x-password")
        #expect(try classify(xSame, isPassword, in: [survivor], removed: []) == .localChanged)
        let xChanged = export(itemX, title: "Mail", password: "x-new")
        #expect(try classify(xChanged, isPassword, in: [survivor], removed: []) == .bothChanged)
        _ = x
    }

    @Test func aPasswordTheMergeDroppedNeedsADecisionWhenItsItemChanges() throws {
        // X kept its login; Y's differing login was dropped. Y changing it must not silently replace X's.
        let (survivor, _, y) = try merged(x: "x-password", y: "y-password")
        #expect(survivor.password == "x-password")
        let unchanged = export(itemY, title: "Webmail", password: "y-password", urls: ["https://www.example.test/login"])
        #expect(try classify(unchanged, isPassword, in: [survivor], removed: [removed(y)]) == .localChanged)
        let changed = export(itemY, title: "Webmail", password: "y-new", urls: ["https://www.example.test/login"])
        #expect(try classify(changed, isPassword, in: [survivor], removed: [removed(y)]) == .bothChanged)
    }

    @Test func aReimportOfBothItemsWithoutChangesFindsEverythingSaved() throws {
        let (survivor, _, y) = try merged()
        let xData = export(itemX, title: "Mail", password: "same")
        let yData = export(itemY, title: "Webmail", password: "same", urls: ["https://www.example.test/login"])
        #expect(try classify(xData, isPassword, in: [survivor], removed: [removed(y)]) == .unchanged)
        #expect(try classify(yData, isPassword, in: [survivor], removed: [removed(y)]) == .unchanged)
    }

    @Test func twoItemsThatBothChangedAreNotBothReplacedByDefault() throws {
        let (survivor, _, _) = try merged()
        // Both items changed their login in the other app: each is a change to the one saved password, which takes only one.
        let items = [
            h.importableItem(id: itemX, title: "Mail", credentials: [h.basicAuthentication(username: "ada", password: "x-new")]),
            h.importableItem(id: itemY, title: "Webmail", credentials: [h.basicAuthentication(username: "ada", password: "y-new")]),
        ]
        let both = ASExportedCredentialData(
            accounts: [ASImportableAccount(id: appleAccount, userName: "ada", email: "ada@example.test", collections: [], items: items)],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let preview = try CredentialExchangeCodec.preview(both, against: h.snapshot([survivor]))
        let destination = ImportDestinationView(accounts: [survivor], removed: RemovedIdentifiers(items: []))
        var classes: [CredentialIdentity: CredentialImportClass] = [:]
        for candidate in preview.candidates {
            for identity in CredentialExchangeCodec.identities(in: candidate) {
                classes[identity] = try CredentialExchangeCodec.classify(identity, of: candidate, destination: destination)
            }
        }
        let context = CredentialExchangeCoordinator.ReviewContext(
            classes: classes, profileName: "Profile", vaultName: nil, csvReport: nil, origin: .system
        )
        let choices = CredentialExchangeCoordinator.ReviewIndex(preview, context).defaultChoices()

        let passwords = preview.candidates.flatMap(CredentialExchangeCodec.identities(in:)).filter(isPassword)
        #expect(passwords.count == 2)
        #expect(passwords.filter { choices[$0] == .replace }.count == 1)
        #expect(passwords.filter { choices[$0] == nil }.count == 1)
        // Once the user decides the other one, the codec accepts the plan.
        var decided = choices
        for identity in passwords where choices[identity] == nil {
            decided[identity] = .skip
        }
        _ = try CredentialExchangeCoordinator.plan(preview, choices: decided, required: [])
    }

    // MARK: Ambiguity

    @Test func twoAccountsCannotClaimOneItem() throws {
        let (survivor, _, y) = try merged()
        // The absorbed item comes back as an account of its own beside the survivor that holds it.
        #expect(throws: CredentialVaultError.duplicateIdentifier) {
            try CredentialExchangeCodec.validateAccounts([survivor, y])
        }
        #expect(survivor.holdsMergedItem(of: y))
        try CredentialExchangeCodec.validateAccounts([survivor])
    }

    @Test func aSurvivorCannotListItsOwnItemOrTheSameItemTwice() throws {
        let (survivor, x, y) = try merged()
        var ownItem = survivor
        ownItem.mergedFrom = [MergedItemLink(accountID: UUID(), exchangeAccountID: appleAccount, exchangeItemID: itemX)]
        #expect(throws: CredentialVaultError.duplicateIdentifier) { try ownItem.validate() }

        var twice = survivor
        twice.mergedFrom = (survivor.mergedFrom ?? []) + (survivor.mergedFrom ?? [])
        #expect(throws: CredentialVaultError.duplicateIdentifier) { try twice.validate() }
        _ = (x, y)
    }
}
