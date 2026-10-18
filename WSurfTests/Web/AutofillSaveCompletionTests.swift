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
    private static let loginPage = #"""
    <form id="login" method="post" action="/session">
      <input id="username" autocomplete="username"><input id="password" type="password" autocomplete="current-password">
    </form>
    """#
    private static let homePage = "<p>Welcome back.</p>"

    /// One tab: a page in a window, its session and a vault-backed profile.
    @MainActor
    private final class Flow {
        static let probeWorld = WKContentWorld.world(name: "AutofillSaveCompletionTests")
        let session = AutofillSaveSession()
        let page: BrowserPage
        let window: NSWindow
        var mainFrame: BrowserFrame?
        /// Every `(document, origin)` the session asked the page about, in order.
        var asked: [(documentID: String, origin: String)] = []

        init(context: BrowserProfileContext) {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration), context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            AutofillSaveCoordinator.shared.install(in: page, session: session)
            page.addScriptMessageHandler(name: "wsurfTestProbe", in: Self.probeWorld) { [weak self] message in
                self?.mainFrame = message.frameInfo
            }
            // The real proof of a loaded document, recorded.
            session.liveness = { [weak self] page, documentID, origin in
                self?.asked.append((documentID, origin))
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

        /// What the page script posts when the user submits the login form.
        @discardableResult
        func stage(documentID: String, origin: String = AutofillSaveCompletionTests.loginOrigin) throws -> UUID {
            let id = UUID()
            let login = try SavedPassword(website: origin, username: "ada@example.test", password: "dummy-secret-123")
            session.submissions.stage(
                id: id, documentID: documentID, formID: "1", origin: origin,
                candidates: [.password(login)], frame: try #require(mainFrame), source: "submit"
            )
            return id
        }
    }

    private func withFlow(_ body: (Flow) async throws -> Void) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, _ in
            let flow = Flow(context: BrowserProfileContext(profile: profile))
            do {
                try await body(flow)
            } catch {
                await flow.close()
                throw error
            }
            await flow.close()
        }
    }

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
            #expect(flow.session.current?.origin == Self.loginOrigin)
        }
    }
}
