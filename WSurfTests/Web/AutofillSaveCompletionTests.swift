// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// What the save pipeline does once a login is over: which document the offer belongs to, how long a staged attempt may wait,
/// and what a click on a dead offer says. Real pages in a real window and a real vault; only the staging (the page script's
/// job) is done by hand, with the arguments the script posts.
@MainActor
@Suite(.boundedWebViews)
struct AutofillSaveCompletionTests {
    private static let loginOrigin = "https://login.example"
    private static let appOrigin = "https://app.example"
    private static let loginPage = #"""
    <form id="login" method="post" action="/session">
      <input id="username" autocomplete="username"><input id="password" type="password" autocomplete="current-password">
    </form>
    """#
    private static let homePage = "<p>Welcome back.</p>"
    private static let deadOfferMessage = String(localized: "This page changed, so nothing was saved.")

    /// A clock the test moves by hand.
    @MainActor
    private final class ManualClock {
        private let start = Date.now
        private var elapsed: TimeInterval = 0
        var now: Date {
            start.addingTimeInterval(elapsed)
        }
        func advance(by seconds: TimeInterval) {
            elapsed += seconds
        }
    }

    /// One tab: a page in a window, its session, and the vault of the profile.
    @MainActor
    private final class Flow {
        static let probeWorld = WKContentWorld.world(name: "AutofillSaveCompletionTests")
        let session = AutofillSaveSession()
        let vault: FixtureVault
        let page: BrowserPage
        let window: NSWindow
        var mainFrame: BrowserFrame?
        /// Every `(document, origin)` the session asked the page about, in order.
        var asked: [(documentID: String, origin: String)] = []
        /// Replaces the page's answer; `nil` asks the real page.
        var forcedAnswer: Bool?

        init(profile: Profile, vault: FixtureVault) {
            self.vault = vault
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration),
                context: BrowserProfileContext(profile: profile)
            )
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            AutofillSaveCoordinator.shared.install(in: page, session: session)
            page.addScriptMessageHandler(name: "wsurfTestProbe", in: Self.probeWorld) { [weak self] message in
                self?.mainFrame = message.frameInfo
            }
            session.liveness = { [weak self] page, documentID, origin in
                self?.asked.append((documentID, origin))
                if let answer = self?.forcedAnswer {
                    return answer
                }
                return await AutofillSaveCoordinator.shared.isLive(page: page, documentID: documentID, origin: origin)
            }
        }

        func close() async {
            window.contentView = nil
            window.close()
            await page.close()
        }

        private func currentDocumentID() async -> String? {
            await AutofillSaveCoordinator.shared.pageStates(in: page)?.first?.documentID
        }

        /// Loads `html` as the page at `url` and returns the new main document's ID, once the page script has registered it.
        func load(_ html: String, at url: String) async throws -> String {
            let previous = await currentDocumentID()
            mainFrame = nil
            _ = page.loadHTMLString("<!doctype html>" + html, baseURL: URL(string: url))
            var found: String?
            #expect(await waitUntil {
                found = await self.currentDocumentID()
                return found != nil && found != previous
            })
            _ = try await page.callAsyncJavaScript("globalThis.__wsurfSend('wsurfTestProbe', 1);", in: nil, contentWorld: Self.probeWorld)
            #expect(await waitUntil { self.mainFrame != nil })
            #expect(await waitUntil { !self.page.isLoading })
            // A string loaded under an https base URL has the origin of that URL but no TLS behind it, so WebKit may not call it
            // secure. The pipeline only reads the page's own flags; they are set as a real https load would have set them.
            if page.url?.host() != URL(string: url)?.host() {
                page.url = URL(string: url)
            }
            if !page.hasOnlySecureContent {
                page.hasOnlySecureContent = true
            }
            return try #require(found)
        }

        func login(_ username: String = "ada@example.test") throws -> SavedPassword {
            try SavedPassword(website: AutofillSaveCompletionTests.loginOrigin, username: username, password: "dummy-secret-123")
        }

        /// What the page script posts when the user submits the login form.
        @discardableResult
        func stage(documentID: String, username: String = "ada@example.test") throws -> UUID {
            let id = UUID()
            session.submissions.stage(
                id: id, documentID: documentID, formID: "1", origin: AutofillSaveCompletionTests.loginOrigin,
                loginURL: URL(string: AutofillSaveCompletionTests.loginOrigin + "/login"),
                candidates: [.password(try login(username))], frame: try #require(mainFrame), source: "submit"
            )
            return id
        }
    }

    private func withFlow(_ body: (Flow) async throws -> Void) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let flow = Flow(profile: profile, vault: vaults[0])
            do {
                try await body(flow)
            } catch {
                await flow.close()
                throw error
            }
            await flow.close()
        }
    }

    // MARK: A login that ends in a navigation

    /// A classic login: the form is posted, the server redirects, and a new document replaces the login page. The login document
    /// is gone by the time the tracker decides the login worked, so the offer can only be bound to the page the user is on now.
    @Test func navigationCompletionOffersAgainstTheNewDocument() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            try flow.stage(documentID: loginDocument)
            let homeDocument = try await flow.load(Self.homePage, at: Self.loginOrigin + "/home")

            #expect(await waitUntil(timeout: .seconds(20)) { !flow.asked.isEmpty }, "the tracker never decided the login was complete")
            #expect(flow.asked.allSatisfy { $0.documentID == homeDocument }, "the offer was checked against a page that is gone")
            #expect(await waitUntil(timeout: .seconds(20)) { flow.session.current != nil })
            let offer = try #require(flow.session.current)
            #expect(offer.documentID == homeDocument)
            #expect(offer.origin == Self.loginOrigin && offer.liveOrigin == Self.loginOrigin)
            // The account remembers the page the form was on, not the page the redirect ended on.
            #expect(offer.loginURL?.path == "/login")
        }
    }

    /// The redirect can end on another site (a sign-in host handing over to the app): the page that is live is the app's, the
    /// password still belongs to the host it was typed on, and saving it works.
    @Test func completionOnAnotherOriginStillOffersForTheLoginOrigin() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            let id = try flow.stage(documentID: loginDocument)
            let appDocument = try await flow.load(Self.homePage, at: Self.appOrigin + "/home")

            // The frame handle the login was staged with may no longer run scripts after a move to another site: that must not stall it.
            let offered = await waitUntil(timeout: .seconds(20)) { flow.session.current != nil }
            #expect(offered, "asked \(flow.asked), attempt still pending: \(flow.session.submissions.lifetime(of: id) != nil)")
            let offer = try #require(flow.session.current)
            #expect(offer.documentID == appDocument)
            #expect(offer.liveOrigin == Self.appOrigin)
            #expect(offer.origin == Self.loginOrigin)
            #expect(flow.asked.allSatisfy { $0.documentID == appDocument && $0.origin == Self.appOrigin })

            await flow.session.save(offer)
            #expect(flow.session.error == nil && flow.session.current == nil)
            let accounts = try await flow.vault.manager.snapshot().accounts
            #expect(accounts.map(\.origins) == [[Self.loginOrigin]])
            #expect(accounts.first?.username == "ada@example.test")
            #expect(accounts.first?.loginURLs.map(\.path) == ["/login"])
        }
    }

    /// A login that finishes inside the page (a fetch, a single-page app) keeps the login document and origin: the page script's
    /// completion message must not be allowed to vouch for a page that is gone.
    @Test func sameDocumentCompletionStillChecksTheLoginDocument() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")

            flow.forcedAnswer = false
            let refused = try flow.stage(documentID: loginDocument, username: "refused@example.test")
            flow.session.submissions.complete(id: refused, documentID: loginDocument, formID: "1")
            #expect(await waitUntil { !flow.asked.isEmpty })
            #expect(flow.asked.allSatisfy { $0.documentID == loginDocument && $0.origin == Self.loginOrigin })
            #expect(flow.session.current == nil)

            flow.forcedAnswer = nil
            let accepted = try flow.stage(documentID: loginDocument, username: "accepted@example.test")
            flow.session.submissions.complete(id: accepted, documentID: loginDocument, formID: "1")
            #expect(await waitUntil { flow.session.current != nil })
            #expect(flow.session.current?.documentID == loginDocument && flow.session.current?.liveOrigin == Self.loginOrigin)
        }
    }

    // MARK: A Save button whose page is gone

    @Test func saveRefusesAndExplainsWhenTheOfferedDocumentIsGone() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            await flow.session.offer(.password(try flow.login()), origin: Self.loginOrigin, documentID: loginDocument)
            let offer = try #require(flow.session.current)

            let homeDocument = try await flow.load(Self.homePage, at: Self.loginOrigin + "/home")
            await flow.session.save(offer)

            // The popover reads exactly this: the offer stays, cannot be saved, and the reason is shown with only a way to close it.
            #expect(flow.session.error == Self.deadOfferMessage)
            #expect(flow.session.current?.id == offer.id && flow.session.current?.isGone == true)
            #expect(try await flow.vault.manager.snapshot().accounts.isEmpty, "nothing is written for a page that is gone")

            // Closing it is not a refusal: the login is still offered from the page the user is on.
            flow.session.dismiss(try #require(flow.session.current), rememberingChoice: false)
            #expect(flow.session.current == nil && flow.session.error == nil)
            await flow.session.offer(.password(try flow.login()), origin: Self.loginOrigin, documentID: homeDocument)
            #expect(flow.session.current?.isGone == false)
        }
    }

    /// The note about a gone page must not swallow the same login when the user types it again on the page they are on.
    @Test func aGoneOfferIsReplacedByTheSameLoginFromThePageTheUserIsOn() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            await flow.session.offer(.password(try flow.login()), origin: Self.loginOrigin, documentID: loginDocument)
            let offer = try #require(flow.session.current)
            let homeDocument = try await flow.load(Self.homePage, at: Self.loginOrigin + "/home")
            await flow.session.save(offer)
            #expect(flow.session.current?.isGone == true)

            await flow.session.offer(.password(try flow.login()), origin: Self.loginOrigin, documentID: homeDocument)
            let fresh = try #require(flow.session.current)
            #expect(fresh.id != offer.id && !fresh.isGone && fresh.documentID == homeDocument)
            #expect(flow.session.error == nil, "the old reason is not shown on the new offer")
        }
    }

    @Test func saveFromTheLivePageStillWritesTheAccount() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            await flow.session.offer(.password(try flow.login()), origin: Self.loginOrigin, documentID: loginDocument)
            let offer = try #require(flow.session.current)

            await flow.session.save(offer)

            #expect(flow.session.error == nil && flow.session.current == nil)
            #expect(try await flow.vault.manager.snapshot().accounts.map(\.username) == ["ada@example.test"])
        }
    }

    // MARK: How long a login may take

    /// A verification step (an SMS, an e-mail, a push approval) takes minutes; once the page asks for one, the attempt waits five.
    @Test func verificationStepExtendsTheAttemptToFiveMinutes() async throws {
        try await withFlow { flow in
            let clock = ManualClock()
            flow.session.submissions.now = { clock.now }
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            let id = try flow.stage(documentID: loginDocument)
            #expect(flow.session.submissions.lifetime(of: id) == AutofillSubmissionTracker.attemptLifetime)

            // The page now asks for the code the login sent.
            _ = try await flow.page.callAsyncJavaScript(
                "document.body.innerHTML = '<input autocomplete=\"one-time-code\">';", in: nil, contentWorld: .page
            )
            #expect(await waitUntil { flow.session.submissions.lifetime(of: id) == AutofillSubmissionTracker.verificationLifetime })

            // Three minutes later the code is accepted and the page reports the form gone.
            clock.advance(by: 200)
            flow.session.submissions.complete(id: id, documentID: loginDocument, formID: "1")
            #expect(await waitUntil { flow.session.current != nil })
        }
    }

    @Test func attemptsWithoutAVerificationStepStillExpireAfterTwoMinutes() async throws {
        try await withFlow { flow in
            let clock = ManualClock()
            flow.session.submissions.now = { clock.now }
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")

            let late = try flow.stage(documentID: loginDocument, username: "late@example.test")
            clock.advance(by: 121)
            flow.session.submissions.complete(id: late, documentID: loginDocument, formID: "1")
            #expect(flow.session.submissions.lifetime(of: late) == nil, "an expired attempt is forgotten")
            // Nothing was dispatched, so nothing can arrive later; a bounded wait is the only way to watch for a missing offer.
            #expect(await waitUntil(timeout: .milliseconds(1500)) { flow.session.current != nil } == false)
            #expect(flow.asked.isEmpty)

            let onTime = try flow.stage(documentID: loginDocument, username: "ontime@example.test")
            clock.advance(by: 119)
            flow.session.submissions.complete(id: onTime, documentID: loginDocument, formID: "1")
            #expect(await waitUntil { flow.session.current != nil })
        }
    }

    // MARK: Contexts

    @Test func offerForAnotherProfileContextIsNeverShown() async throws {
        try await withFlow { flow in
            let loginDocument = try await flow.load(Self.loginPage, at: Self.loginOrigin + "/login")
            let pending = try flow.stage(documentID: loginDocument, username: "pending@example.test")
            await flow.session.offer(.password(try flow.login()), origin: Self.loginOrigin, documentID: loginDocument)
            #expect(flow.session.current != nil)

            // The tab now belongs to another profile: neither the shown offer nor the pending attempt may follow it.
            let other = BrowserProfileContext(profile: Profile(id: UUID(), name: "Other", symbol: "key", color: .blue))
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let otherPage = BrowserPage(webKit: WKWebView(frame: .zero, configuration: configuration), context: other)
            flow.session.attach(to: otherPage, context: other)
            #expect(flow.session.current == nil)

            flow.asked = []
            flow.session.submissions.complete(id: pending, documentID: loginDocument, formID: "1")
            #expect(await waitUntil(timeout: .milliseconds(1500)) { flow.session.current != nil } == false)
            #expect(flow.asked.isEmpty)
            await otherPage.close()
        }
    }
}
