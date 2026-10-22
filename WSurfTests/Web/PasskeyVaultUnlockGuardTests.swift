// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The vault's own unlock passkey (`PasskeyVaultUnlocker`) is a native AuthenticationServices ceremony for the relying party
// wsurf.app, and its passkey is kept in the user's passkey provider (Apple Passwords). It is a different thing from the
// passkeys of websites, which a page's calls reach through `WebAuthnAdapter` and, on the user's choice, the system's
// authenticator. These tests keep the two apart: nothing a page can ask for reaches the unlock relying party, and the pieces
// the unlock needs from the signed app are still declared. The ceremony itself is native and owner-operated; that a request
// handed to the system never uses, spends or blocks an unlock is proved where the adapter runs
// (`WebAuthnAdapterTests+Providers`).
struct PasskeyVaultUnlockGuardTests {
    /// The repository's own copy of the app's entitlements: the declaration the signed app is built from.
    private func entitlements() throws -> [String: Any] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "WSurf/WSurf.entitlements"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theUnlockPasskeyStaysOnItsOwnRelyingPartyAndTheAppStillDeclaresIt() throws {
        #expect(PasskeyVaultUnlocker.relyingParty == "wsurf.app")
        let declared = try entitlements()
        #expect((declared["com.apple.developer.associated-domains"] as? [String])?.contains("webcredentials:wsurf.app") == true)
        // The vaults of the autofill stores, the old password list among them, are read through the data protection keychain.
        #expect((declared["keychain-access-groups"] as? [String])?.isEmpty == false)
        // The app does not ask for the managed browser entitlement; the system's own passkey flow stays the engine's.
        #expect(declared["com.apple.developer.web-browser.public-key-credential"] == nil)
    }

    @Test func noWebsiteCanActAsTheUnlockRelyingParty() throws {
        let site = try #require(URL(string: "https://example.test"))
        #expect(throws: (any Error).self) { try RelyingPartyPolicy.validate(rpID: PasskeyVaultUnlocker.relyingParty, origin: site) }
        // The app's own site is the only origin that can name it, and a lookalike is not it.
        let own = try #require(URL(string: "https://wsurf.app"))
        #expect(try RelyingPartyPolicy.validate(rpID: PasskeyVaultUnlocker.relyingParty, origin: own) == "wsurf.app")
        let lookalike = try #require(URL(string: "https://wsurf.app.example.test"))
        #expect(throws: (any Error).self) { try RelyingPartyPolicy.validate(rpID: PasskeyVaultUnlocker.relyingParty, origin: lookalike) }
    }
}
