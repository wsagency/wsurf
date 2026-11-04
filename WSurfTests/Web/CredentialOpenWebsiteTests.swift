// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// "Open Website" from a row, the right-click menu and the editor: which address, and that it goes to the page's own window and
/// only as HTTPS. Synthetic data; nothing is opened, the opener is a recording seam.
@MainActor
struct CredentialOpenWebsiteTests {
    private final class Recorder {
        var opened: [URL] = []
    }

    @Test func theLoginAddressComesFirstThenTheWebsiteThenThePasskeysSite() throws {
        var account = VaultFixtures.account(origin: "https://example.test")
        #expect(CredentialSummary(account).website?.absoluteString == "https://example.test/login")
        account.loginURLs = []
        #expect(CredentialSummary(account).website?.absoluteString == "https://example.test")
        account.origins = []
        account.passkeys = [try VaultFixtures.passkey(rpID: "passkeys.example.test")]
        #expect(CredentialSummary(account).website?.absoluteString == "https://passkeys.example.test")
        account.passkeys = []
        account.notes = [CredentialNote(text: "note only", field: nil)]
        #expect(CredentialSummary(account).website == nil, "nothing to open")
    }

    @Test func anAddressGoesToTheOpenerOnlyAsHTTPS() async throws {
        let profile = Profile(id: UUID(), name: "Open Website", symbol: "key", color: .blue)
        let vault = try #require(try await VaultManagerFixture.make(profile: profile, passkeys: VaultPasskeys(), vaults: [.unlocked]).vaults.first)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        let recorder = Recorder()

        #expect(!model.openWebsite(URL(string: "https://example.test")), "a page without a window opens nothing")
        model.websiteOpener = { recorder.opened.append($0) }

        #expect(model.openWebsite(URL(string: "https://example.test/login")))
        #expect(!model.openWebsite(URL(string: "http://example.test")))
        #expect(!model.openWebsite(URL(string: "javascript:alert(1)")))
        #expect(!model.openWebsite(URL(string: "https:///nohost")))
        #expect(!model.openWebsite(nil))
        #expect(recorder.opened.map(\.absoluteString) == ["https://example.test/login"])
        await VaultManagerFixture.cleanup(profile)
    }

    @Test func aPrivateProfileOpensNothing() {
        let model = CredentialSettingsModel(profile: .privateBrowsing())
        let recorder = Recorder()
        model.websiteOpener = { recorder.opened.append($0) }
        #expect(!model.openWebsite(URL(string: "https://example.test")))
        #expect(recorder.opened.isEmpty)
    }
}
