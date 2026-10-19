// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The merge rules are pure: accounts in, one account out. Nothing is written and no secret is returned by the preview.
struct CredentialMergeTests {
    private func account(
        _ username: String = "ada", _ password: String? = "pw", _ origins: [String] = ["https://example.test"], title: String? = nil
    ) -> CredentialAccount {
        var result = VaultFixtures.account(username: username, password: password, origin: origins.first ?? "https://example.test")
        result.origins = origins
        result.loginURLs = origins.map { URL(string: $0 + "/login")! }
        result.displayName = title
        return result
    }

    private func picks(_ survivor: CredentialAccount, login: CredentialAccount? = nil, code: CredentialAccount? = nil) -> MergePicks {
        MergePicks(survivor: survivor.id, name: survivor.id, login: (login ?? survivor).id, code: (code ?? survivor).id)
    }

    @Test func mergeKeepsTheSurvivorsLoginAndAddsPasskeysCodeAndNotes() throws {
        var keeper = account("ada", "keep")
        keeper.notes = [CredentialNote(text: "shared", field: nil), CredentialNote(text: "mine", field: nil)]
        var other = account("ada", "drop")
        other.passkeys = [try VaultFixtures.passkey(credentialID: Data(repeating: 9, count: 32))]
        other.totp = VaultFixtures.totp()
        other.notes = [CredentialNote(text: "shared", field: nil), CredentialNote(text: "theirs", field: nil)]
        let merged = try CredentialMerge.merged([keeper, other], picks: picks(keeper, code: other))
        #expect(merged.id == keeper.id)
        #expect(merged.password == "keep")
        #expect(merged.passkeys.map(\.id) == other.passkeys.map(\.id))
        #expect(merged.totp == other.totp)
        #expect(merged.notes?.map(\.text) == ["shared", "mine", "theirs"])
        #expect(merged.exchangeItemID == keeper.exchangeItemID)
        #expect(merged.createdAt == keeper.createdAt)
    }

    @Test func mergeAddsSharedSiteWebsitesOnly() throws {
        let keeper = account("ada", "pw", ["https://www.example.test"])
        let other = account("ada", "pw", ["https://login.example.test", "https://elsewhere.test"])
        let merged = try CredentialMerge.merged([keeper, other], picks: picks(keeper))
        #expect(merged.origins == ["https://www.example.test", "https://login.example.test"])
        #expect(merged.loginURLs.map(\.absoluteString) == ["https://www.example.test/login", "https://login.example.test/login"])
    }

    @Test func anotherSitesWebsiteIsAddedOnlyWhenTicked() throws {
        let keeper = account("ada", "pw", ["https://example.test"])
        let other = account("ada", "pw", ["https://other.test"])
        let plain = try CredentialMerge.merged([keeper, other], picks: picks(keeper))
        #expect(plain.origins == ["https://example.test"])

        var ticked = picks(keeper)
        ticked.extraWebsites = ["https://other.test"]
        let merged = try CredentialMerge.merged([keeper, other], picks: ticked)
        #expect(merged.origins == ["https://example.test", "https://other.test"])
        #expect(merged.loginURLs.last?.absoluteString == "https://other.test/login")

        var foreign = picks(keeper)
        foreign.extraWebsites = ["https://never-offered.test"]
        #expect(throws: CredentialMergeError.invalidPicks) { try CredentialMerge.merged([keeper, other], picks: foreign) }
    }

    @Test func theLoginSourcesWebsiteOnAnotherSiteIsOfferedToo() throws {
        // Taking the password from `other` is a choice of value, not of where it fills: other.test stays a box to tick, and the
        // preview says the merged credential won't fill there.
        let keeper = account("ada", nil, ["https://example.test"])
        let other = account("ada", "pw", ["https://other.test"])
        let merged = try CredentialMerge.merged([keeper, other], picks: picks(keeper, login: other))
        #expect(merged.password == "pw")
        #expect(merged.origins == ["https://example.test"])
        let preview = try CredentialMerge.preview([keeper, other], picks: picks(keeper, login: other))
        #expect(preview.otherSite == ["https://other.test"])
        #expect(preview.notKept == ["other.test"])
        #expect(preview.fillsOn == ["example.test"])

        var ticked = picks(keeper, login: other)
        ticked.extraWebsites = ["https://other.test"]
        #expect(try CredentialMerge.merged([keeper, other], picks: ticked).origins == ["https://example.test", "https://other.test"])
    }

    @Test func aSitesPasskeyMakesItsWebsitesShared() throws {
        // A passkey-only survivor has no website of its own; its relying party is the site the login's websites are on.
        var passkeyOnly = account("", nil, [])
        passkeyOnly.passkeys = [try VaultFixtures.passkey(rpID: "example.test", credentialID: Data(repeating: 6, count: 32))]
        let login = account("ada", "pw", ["https://www.example.test"])
        let merged = try CredentialMerge.merged([passkeyOnly, login], picks: picks(passkeyOnly, login: login))
        #expect(merged.origins == ["https://www.example.test"])
        #expect(merged.password == "pw")
        #expect(merged.passkeys.count == 1)
    }

    @Test func previewNamesEverySiteThePasswordWillFillOn() throws {
        let keeper = account("ada", "pw", ["https://www.example.test"])
        let other = account("ada", "pw", ["https://login.example.test", "https://elsewhere.test"])
        let preview = try CredentialMerge.preview([keeper, other], picks: picks(keeper))
        #expect(preview.fillsOn == ["www.example.test", "login.example.test"])
        #expect(preview.notKept == ["elsewhere.test"])
        #expect(preview.otherSite == ["https://elsewhere.test"])
        #expect(preview.websitesBefore == ["https://www.example.test"])
        #expect(preview.websitesAfter == ["https://www.example.test", "https://login.example.test"])
        #expect(!preview.loginsDiffer)

        var ticked = picks(keeper)
        ticked.extraWebsites = ["https://elsewhere.test"]
        let wider = try CredentialMerge.preview([keeper, other], picks: ticked)
        #expect(wider.fillsOn.contains("elsewhere.test"))
        #expect(wider.notKept.isEmpty)
    }

    @Test func previewCarriesNoSecretAndFlagsWhatDiffers() throws {
        var keeper = account("ada", "pw-secret-one", title: "Mail")
        keeper.totp = VaultFixtures.totp()
        var other = account("ada", "pw-secret-two", title: "Webmail")
        other.totp = TOTPGenerator(secret: Data([4, 4]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
        let preview = try CredentialMerge.preview([keeper, other], picks: picks(keeper))
        #expect(preview.loginsDiffer)
        #expect(preview.codesDiffer)
        #expect(preview.namesDiffer)
        #expect(preview.items.map(\.title) == ["Mail", "Webmail"])
        #expect(preview.items.map(\.username) == ["ada", "ada"])
        #expect(preview.items.map(\.hasPassword) == [true, true])
        let text = String(describing: preview)
        #expect(!text.contains("pw-secret"))
    }

    @Test func mergeRefusesDifferentUsernames() throws {
        let ada = account("ada")
        let bob = account("bob")
        #expect(throws: CredentialMergeError.usernamesDiffer) { try CredentialMerge.merged([ada, bob], picks: picks(ada)) }

        // A passkey for another person is as different as a login for one.
        var passkeyOnly = account("", nil, [])
        var passkey = try VaultFixtures.passkey(credentialID: Data(repeating: 5, count: 32))
        passkey.userName = "carol"
        passkeyOnly.passkeys = [passkey]
        #expect(throws: CredentialMergeError.usernamesDiffer) { try CredentialMerge.merged([ada, passkeyOnly], picks: picks(ada)) }
        passkey.userName = "ada"
        passkeyOnly.passkeys = [passkey]
        _ = try CredentialMerge.merged([ada, passkeyOnly], picks: picks(ada))

        // Passkeys for two people and no username: there is no telling whose credential it is.
        var second = try VaultFixtures.passkey(credentialID: Data(repeating: 6, count: 32))
        second.userName = "carol"
        passkeyOnly.passkeys.append(second)
        #expect(throws: CredentialMergeError.usernamesDiffer) { try CredentialMerge.merged([ada, passkeyOnly], picks: picks(ada)) }
    }

    @Test func mergeRefusesPastTheWebsiteOrNoteLimit() {
        let sites = (0..<CredentialAccount.websiteLimit).map { "https://a\($0).example.test" }
        let keeper = account("ada", "pw", sites)
        let other = account("ada", "pw", ["https://extra.example.test"])
        #expect(throws: CredentialMergeError.websiteLimit) { try CredentialMerge.merged([keeper, other], picks: picks(keeper)) }

        var manyNotes = account()
        manyNotes.notes = (0..<CredentialAccount.noteLimit).map { CredentialNote(text: "note \($0)", field: nil) }
        var oneMore = account()
        oneMore.notes = [CredentialNote(text: "one more", field: nil)]
        #expect(throws: CredentialMergeError.noteLimit) { try CredentialMerge.merged([manyNotes, oneMore], picks: picks(manyNotes)) }
    }

    @Test func takingTheOtherPasswordTakesItsUsernameAndMetadataToo() throws {
        var keeper = account("ada", "keep")
        keeper.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: .init(id: Data([1]), label: "User", fieldType: .string), password: .init(id: Data([2]), label: "Pass", fieldType: .concealedString)
        )
        var other = account("ada", "take")
        other.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: .init(id: Data([3]), label: "Email", fieldType: .email), password: .init(id: Data([4]), label: "Secret", fieldType: .concealedString)
        )
        let merged = try CredentialMerge.merged([keeper, other], picks: picks(keeper, login: other))
        #expect(merged.password == "take")
        #expect(merged.username == "ada")
        #expect(merged.basicAuthenticationMetadata == other.basicAuthenticationMetadata)
    }

    @Test func aPickWithNothingOfItsKindIsRefused() {
        let withLogin = account("ada", "pw")
        var codeOnly = account("", nil, ["https://example.test"])
        codeOnly.totp = VaultFixtures.totp()
        // The login pick names a credential without a login while the other has one.
        #expect(throws: CredentialMergeError.invalidPicks) {
            try CredentialMerge.merged([withLogin, codeOnly], picks: MergePicks(survivor: withLogin.id, name: withLogin.id, login: codeOnly.id, code: codeOnly.id))
        }
        #expect(throws: CredentialMergeError.invalidPicks) {
            try CredentialMerge.merged([withLogin, codeOnly], picks: MergePicks(survivor: withLogin.id, name: withLogin.id, login: withLogin.id, code: withLogin.id))
        }
        #expect(throws: CredentialMergeError.invalidPicks) {
            try CredentialMerge.merged([withLogin, codeOnly], picks: MergePicks(survivor: UUID(), name: withLogin.id, login: withLogin.id, code: codeOnly.id))
        }
        #expect(throws: CredentialMergeError.fewerThanTwo) {
            try CredentialMerge.merged([withLogin], picks: MergePicks(survivor: withLogin.id, name: withLogin.id, login: withLogin.id, code: withLogin.id))
        }
    }

    @Test func theSurvivorRecordsEveryAbsorbedItemsLinkAndBases() throws {
        var keeper = account("ada", "keep")
        keeper.exchangeAccountID = Data([1, 1])
        keeper.exchangeItemID = Data([1, 2])
        var absorbed = account("ada", "drop")
        absorbed.exchangeAccountID = Data([2, 1])
        absorbed.exchangeItemID = Data([2, 2])
        absorbed.passwordBase = ExchangeBase(contentHash: Data(repeating: 7, count: 32), itemID: Data([2, 2]))
        absorbed.totp = VaultFixtures.totp()
        absorbed.totpBase = ExchangeBase(contentHash: Data(repeating: 8, count: 32), itemID: Data([2, 2]))
        var earlier = account("ada", "older")
        earlier.exchangeAccountID = Data([3, 1])
        earlier.exchangeItemID = Data([3, 2])
        absorbed.mergedFrom = [MergedItemLink(accountID: earlier.id, exchangeAccountID: Data([3, 1]), exchangeItemID: Data([3, 2]))]

        let merged = try CredentialMerge.merged([keeper, absorbed], picks: picks(keeper))
        let links = try #require(merged.mergedFrom)
        #expect(links.map(\.accountID) == [absorbed.id, earlier.id])
        #expect(links[0].exchangeItemID == Data([2, 2]))
        #expect(links[0].passwordBase == absorbed.passwordBase)
        #expect(links[0].totpBase == absorbed.totpBase)
        #expect(links[1].exchangeAccountID == Data([3, 1]))
        #expect(merged.exchangeItemID == Data([1, 2]))
    }

    @Test func aNativeAbsorbedCredentialIsLinkedByTheIdentityItExportsUnder() throws {
        let keeper = account("ada", "keep")
        let native = account("ada", "keep")
        let merged = try CredentialMerge.merged([keeper, native], picks: picks(keeper))
        let identity = try CredentialExchangeCodec.externalItemID(for: native)
        #expect(merged.mergedFrom?.first?.identity == identity)
        #expect(merged.mergedFrom?.first?.passwordBase == nil)
    }

    @Test func theDefaultSurvivorHasTheLinkThenTheMostKindsThenTheEarlierTitle() throws {
        var linked = account("ada", "pw", title: "Zed")
        linked.exchangeItemID = Data([1])
        var rich = account("ada", "pw", title: "Mid")
        rich.totp = VaultFixtures.totp()
        let plain = account("ada", "pw", title: "Alpha")
        #expect(CredentialMerge.defaultPicks(for: [plain, rich, linked])?.survivor == linked.id)
        #expect(CredentialMerge.defaultPicks(for: [plain, rich])?.survivor == rich.id)
        let alsoPlain = account("ada", "pw", title: "Beta")
        #expect(CredentialMerge.defaultPicks(for: [alsoPlain, plain])?.survivor == plain.id)
        let picks = try #require(CredentialMerge.defaultPicks(for: [plain, rich]))
        #expect(picks.code == rich.id)
        #expect(picks.login == rich.id)

        // A credential with a website stays before one without, and the default login is one with a password.
        var codeOnly = account("", nil, [], title: "Aardvark")
        codeOnly.totp = VaultFixtures.totp()
        codeOnly.notes = [CredentialNote(text: "kinds", field: nil)]
        let usernameOnly = account("ada", nil, title: "Able")
        let withWebsite = try #require(CredentialMerge.defaultPicks(for: [codeOnly, usernameOnly, plain]))
        #expect(withWebsite.survivor == usernameOnly.id)
        #expect(withWebsite.login == plain.id)
        #expect(withWebsite.code == codeOnly.id)
    }

    @Test func anItemTheSurvivorAlreadyClaimsIsLinkedOnce() throws {
        // Two credentials that claim one item of the other app (an older vault could hold that): the merge keeps one claim.
        var keeper = account("ada", "pw")
        keeper.exchangeAccountID = Data([1, 1])
        keeper.exchangeItemID = Data([1, 2])
        var twin = account("ada", "pw")
        twin.exchangeAccountID = keeper.exchangeAccountID
        twin.exchangeItemID = keeper.exchangeItemID
        let third = account("ada", "pw")
        let merged = try CredentialMerge.merged([keeper, twin, third], picks: picks(keeper))
        #expect(merged.mergedFrom?.map(\.accountID) == [third.id])
        try merged.validate()
    }

    // MARK: Stored format

    /// A credential as a build without merges stored it: every field it could hold, written out by hand in the stored form.
    private static let storedBeforeMerges = #"""
        {"basicAuthenticationMetadata":{"password":{"fieldType":"concealedString","id":"Ag==","label":"Pass"},\#
        "username":{"fieldType":"string","id":"AQ==","label":"User"}},"createdAt":10,"displayName":"Work",\#
        "exchangeAccountID":"oAE=","exchangeItemID":"sAE=","id":"00000000-0000-0000-0000-0000000000A1",\#
        "loginURLs":["https:\/\/example.test\/login"],"migratedAt":12,"modifiedAt":11,"notes":[{"text":"kept note"}],\#
        "origins":["https:\/\/example.test"],"passkeys":[],"password":"s3cret",\#
        "passwordBase":{"contentHash":"q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s=","itemID":"sAE="},\#
        "passwordEvents":{"lastImportedAt":4},"totp":{"algorithm":"sha1","digits":6,"issuer":"Example","period":30,"secret":"AQIDBAU="},\#
        "totpBase":{"contentHash":"zc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc0=","itemID":"sAE="},"totpEvents":{"lastImportedAt":4},\#
        "username":"ada"}
        """#

    /// What a vault already holds decodes as it was, with no merged items, and is written back with the same stored fields: opening
    /// and saving it with this build changes nothing, and adds no field an older build would have to drop.
    @Test func aCredentialStoredBeforeMergesDecodesAndIsWrittenBackUnchanged() throws {
        let stored = Data(Self.storedBeforeMerges.utf8)
        let account = try JSONDecoder().decode(CredentialAccount.self, from: stored)
        #expect(account.mergedFrom == nil)
        #expect(account.password == "s3cret")
        #expect(account.notes?.map(\.text) == ["kept note"])
        #expect(account.passwordBase?.itemID == Data([0xB0, 0x01]))
        #expect(account.totp?.secret == Data([1, 2, 3, 4, 5]))
        try account.validate()

        let written = try CredentialContent.canonicalJSON(account)
        let before = try #require(try JSONSerialization.jsonObject(with: stored) as? NSDictionary)
        let after = try #require(try JSONSerialization.jsonObject(with: written) as? NSDictionary)
        #expect(after == before)
        #expect(after["mergedFrom"] == nil)

        // A credential this build merged into keeps its links through the same round trip.
        var merged = account
        let link = MergedItemLink(
            accountID: UUID(), exchangeAccountID: Data([0xA0, 0x01]), exchangeItemID: Data([0xB0, 0x02]),
            passwordBase: ExchangeBase(contentHash: Data(repeating: 1, count: 32), itemID: Data([0xB0, 0x02]))
        )
        merged.mergedFrom = [link]
        try merged.validate()
        #expect(try JSONDecoder().decode(CredentialAccount.self, from: CredentialContent.canonicalJSON(merged)) == merged)
    }
}
