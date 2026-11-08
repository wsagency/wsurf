// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// What the "…" of a Credential Manager row offers. The menu is made when it is clicked, from this list, so what each kind of
/// credential offers is checked here without a view.
@MainActor
struct CredentialRowMoreItemTests {
    private func items(_ account: CredentialAccount, _ revealed: CredentialRowMoreItem.Revealed = .init()) -> [CredentialRowMoreItem] {
        CredentialRowMoreItem.items(for: CredentialSummary(account), revealed: revealed)
    }

    @Test func aLoginOffersItsCopiesAndShowsThePasswordOnRequest() {
        let account = VaultFixtures.account(username: "ada", password: "secret", origin: "https://example.test")
        #expect(items(account) == [.copyUsername, .copyPassword, .copyWebsite, .showPassword, .divider, .history, .merge])
        #expect(items(account, .init(password: true)) == [.copyUsername, .copyPassword, .copyWebsite, .hidePassword, .divider, .history, .merge])
    }

    @Test func aCredentialOffersOnlyWhatItHolds() {
        var account = VaultFixtures.account(username: "", password: nil, origin: "https://example.test")
        account.origins = []
        #expect(items(account) == [.divider, .history, .merge], "no username, no password, no website")

        var withCode = VaultFixtures.account(username: "ada", password: nil)
        withCode.totp = TOTPGenerator(secret: Data("seed".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: "Example", userName: "ada")
        #expect(items(withCode) == [.copyUsername, .copyWebsite, .copyCode, .showCode, .divider, .history, .merge])
        #expect(items(withCode, .init(code: true)).contains(.hideCode))
    }

    @Test func aCardOffersItsHiddenValuesAndTheDetails() throws {
        let account = SecureItemFixtures.account([SecureItemFixtures.custom(label: "Locker", values: [("Code", "4711", true)])])
        let summary = CredentialSummary(account)
        let hidden = try #require(summary.hiddenItemFields.first)
        let offered = CredentialRowMoreItem.items(for: summary, revealed: .init())
        #expect(offered.contains(.copyHidden(hidden)))
        #expect(offered.contains(.showDetails))
        #expect(CredentialRowMoreItem.items(for: summary, revealed: .init(details: true)).contains(.hideDetails))
        #expect(offered.suffix(3) == [.divider, .history, .merge])
    }

    @Test func everyEntryHasATitleExceptTheDivider() throws {
        let account = SecureItemFixtures.account([SecureItemFixtures.custom()])
        for item in items(account, .init(password: true, username: true, code: true, details: true)) where item != .divider {
            #expect(!item.title.isEmpty)
        }
        #expect(CredentialRowMoreItem.history.title == String(localized: "History…"))
    }
}
