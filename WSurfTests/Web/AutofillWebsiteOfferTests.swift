// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A login of a sibling website used on this page is offered this page's website instead of a saved copy. Real managers in the
/// registry, the real session and the vault's ordinary commit; only the page's document proof is replaced.
@MainActor
struct AutofillWebsiteOfferTests {
    private static let page = "https://login.example.test"
    private static let sibling = "https://www.example.test"

    private func account(_ username: String, password: String = "pw", origins: [String] = [Self.sibling]) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: origins, loginURLs: [], password: password, passkeys: [],
            totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func login(_ username: String, password: String = "pw", origin: String = Self.page) throws -> AutofillSaveCandidate {
        .password(try SavedPassword(website: origin, username: username, password: password))
    }

    /// A session attached to a page at `url`, shown in a window, of a context on a profile with `vaults`.
    private func withSession(
        url: String = Self.page + "/login",
        vaults: [VaultState] = [.unlocked],
        _ body: (AutofillSaveSession, [FixtureVault]) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: vaults) { profile, _, vaults in
            let context = BrowserProfileContext(profile: profile)
            let configuration = WebViewPool.makeConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = BrowserPage(webKit: WKWebView(frame: .zero, configuration: configuration), context: context)
            page.url = URL(string: url)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = page
            let session = AutofillSaveSession()
            AutofillSaveCoordinator.shared.install(in: page, session: session)
            session.liveness = { _, _, _ in true }
            do {
                try await body(session, vaults)
            } catch {
                window.contentView = nil
                window.close()
                await page.close()
                throw error
            }
            window.contentView = nil
            window.close()
            await page.close()
        }
    }

    @Test(.boundedWebViews) func aFilledSiblingLoginIsOfferedThePagesWebsite() async throws {
        try await withSession { session, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            let before = try await vaults[0].manager.snapshot().revision

            await session.offerWebsite(accountID: ada.id, epoch: epoch, origin: Self.page, documentID: "")

            let offer = try #require(session.websiteOffer)
            #expect(offer.accountID == ada.id && offer.origin == Self.page && offer.name == "ada" && offer.managerEpoch == epoch)
            #expect(offer.host == "login.example.test")
            #expect(session.current == nil && session.isPopoverPresented)
            #expect(try await vaults[0].manager.snapshot().revision == before, "offering writes nothing")
        }
    }

    @Test(.boundedWebViews) func confirmingAddsExactlyOneWebsiteAndHistoryKeepsTheEarlierList() async throws {
        try await withSession { session, vaults in
            let ada = account("ada"), bob = account("bob", password: "other")
            try await VaultManagerFixture.save([ada, bob], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            let storedBob = try await vaults[0].manager.snapshot().accounts.first { $0.id == bob.id }
            await session.offerWebsite(accountID: ada.id, epoch: epoch, origin: Self.page, documentID: "")
            let offer = try #require(session.websiteOffer)

            await session.addWebsite(offer)

            #expect(session.websiteOffer == nil && session.error == nil)
            let accounts = try await vaults[0].manager.snapshot().accounts
            let saved = try #require(accounts.first { $0.id == ada.id })
            #expect(saved.origins == [Self.sibling, Self.page])
            #expect(saved.username == ada.username && saved.password == ada.password && saved.loginURLs == ada.loginURLs)
            #expect(accounts.first { $0.id == bob.id } == storedBob, "no other credential changes")
            let history = try await vaults[0].manager.revisionPage(accountID: ada.id, after: nil).items
            #expect(history.map(\.subject) == [.metadata])
            #expect(history.first?.cause == CredentialChangeCause.addWebsite)
            #expect(try await vaults[0].manager.revisionPage(accountID: bob.id, after: nil).items.isEmpty)
        }
    }

    @Test(.boundedWebViews) func notNowWritesNothingAndIsNotOfferedAgainOnThePage() async throws {
        try await withSession { session, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            let before = try await vaults[0].manager.snapshot().revision
            await session.offerWebsite(accountID: ada.id, epoch: epoch, origin: Self.page, documentID: "")
            let offer = try #require(session.websiteOffer)

            session.dismissWebsite(offer)

            #expect(session.websiteOffer == nil && !session.isPopoverPresented)
            #expect(try await vaults[0].manager.snapshot().revision == before)
            await session.offerWebsite(accountID: ada.id, epoch: epoch, origin: Self.page, documentID: "")
            #expect(session.websiteOffer == nil, "the choice is remembered for this page")
            // Submitting the same login afterwards does not make a copy of it either.
            await session.offer(try login("ada"), origin: Self.page)
            #expect(session.current == nil && session.websiteOffer == nil)
            #expect(try await vaults[0].manager.snapshot().revision == before)
        }
    }

    @Test(.boundedWebViews) func submittingASiblingsExactLoginOffersTheWebsiteInsteadOfACopy() async throws {
        try await withSession { session, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])

            await session.offer(try login("ada"), origin: Self.page)

            #expect(session.current == nil, "no new credential is offered")
            #expect(session.websiteOffer?.accountID == ada.id)
        }
    }

    @Test(.boundedWebViews) func anotherPasswordOrUsernameIsStillANewLogin() async throws {
        try await withSession { session, vaults in
            try await VaultManagerFixture.save([account("ada")], in: vaults[0])

            await session.offer(try login("ada", password: "changed"), origin: Self.page)
            #expect(session.websiteOffer == nil && session.current?.plan == .create)

            await session.offer(try login("grace"), origin: Self.page)
            #expect(session.websiteOffer == nil && session.current?.plan == .create)
        }
    }

    @Test(.boundedWebViews) func aPublicSuffixSiblingIsNeverOfferedTheWebsite() async throws {
        try await withSession(url: "https://b.github.io/login") { session, vaults in
            let ada = account("ada", origins: ["https://a.github.io"])
            try await VaultManagerFixture.save([ada], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)

            await session.offer(try login("ada", origin: "https://b.github.io"), origin: "https://b.github.io")
            #expect(session.websiteOffer == nil && session.current?.plan == .create)

            await session.offerWebsite(accountID: ada.id, epoch: epoch, origin: "https://b.github.io", documentID: "")
            #expect(session.websiteOffer == nil)
        }
    }

    @Test(.boundedWebViews) func aCredentialWithSixtyFourWebsitesIsNeverWidened() async throws {
        try await withSession { session, vaults in
            let others = (1..<CredentialAccount.websiteLimit).map { "https://site\($0).example.test" }
            let full = account("ada", origins: [Self.sibling] + others)
            #expect(full.origins.count == CredentialAccount.websiteLimit)
            try await VaultManagerFixture.save([full], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)

            await session.offerWebsite(accountID: full.id, epoch: epoch, origin: Self.page, documentID: "")
            #expect(session.websiteOffer == nil)
            #expect(throws: CredentialVaultError.self) {
                try CredentialAccountSelection.addingWebsite(Self.page, to: full.id, in: [full])
            }
            // With no room, submitting the login is an ordinary save offer: nothing is dropped to make room.
            await session.offer(try login("ada"), origin: Self.page)
            #expect(session.websiteOffer == nil && session.current?.plan == .create)
        }
    }

    @Test(.boundedWebViews) func aLockBeforeConfirmingWritesNothing() async throws {
        try await withSession { session, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            await session.offerWebsite(accountID: ada.id, epoch: epoch, origin: Self.page, documentID: "")
            let offer = try #require(session.websiteOffer)

            vaults[0].manager.lock(reason: .manual)
            await session.addWebsite(offer)

            #expect(session.websiteOffer == nil, "the offer of the locked vault is withdrawn")
            try await VaultManagerFixture.unlock(vaults[0])
            #expect(try await vaults[0].manager.snapshot().accounts.first?.origins == [Self.sibling])
        }
    }

    @Test func addingAWebsiteChangesOnlyThatCredentialsWebsites() throws {
        let ada = account("ada"), bob = account("bob")
        let added = try CredentialAccountSelection.addingWebsite(Self.page, to: ada.id, in: [ada, bob])
        #expect(added.map(\.origins) == [[Self.sibling, Self.page], [Self.sibling]])
        #expect(throws: CredentialVaultError.self) {
            try CredentialAccountSelection.addingWebsite(Self.page, to: ada.id, in: added)
        }
        #expect(throws: CredentialVaultError.self) {
            try CredentialAccountSelection.addingWebsite("https://b.github.io", to: ada.id, in: [ada])
        }
        #expect(!CredentialAccountSelection.canAddWebsite("http://login.example.test", to: ada))
    }
}
