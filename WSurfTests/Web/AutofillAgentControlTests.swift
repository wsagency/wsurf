// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit
import WSurfVault

@testable import WSurf

/// No autofill offer in a tab an agent controls, on both engines, for the page's own frame and a cross-site frame: while the
/// assistant works in the tab or a connected app is in a call on it or holds it, a field asks for suggestions in vain and nothing is
/// staged or offered for saving; when control ends, the next request is offered again. The tab's own predicate decides
/// (`BrowserTab.isAgentControlled`, the one Pick Credential… uses), through the session the tab owns. Messages carry the frames the
/// engines report for an https page and an https sign-in frame of another site (loopback fixtures are http, which autofill refuses).
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AutofillAgentControlTests {
    enum Control: String, CaseIterable, Sendable {
        case assistant, connectedAppCall, connectedAppHolds
    }

    private static let shop = "https://shop.example"
    private static let idp = "https://login.idp.example"
    private let connection = UUID()

    private func set(_ control: Control, _ on: Bool, on tab: BrowserTab) {
        switch control {
        case .assistant:
            tab.setAgentWorking(on)
        case .connectedAppCall:
            tab.setExternalAutomationWorking(on)
        case .connectedAppHolds:
            tab.processState.setExternalController(connection, holds: on)
        }
    }

    /// One tab of a normal profile, a page of `engine` it owns (secure, on the shop), and the frames messages come from: the page's
    /// own and a cross-site sign-in frame.
    @MainActor
    private final class Rig {
        let tab: BrowserTab
        let page: BrowserPage
        let window: NSWindow
        let main: BrowserFrame
        let signIn: BrowserFrame

        init(engine: BrowserEngine, context: BrowserProfileContext) throws {
            tab = BrowserTab(opensBlank: false, context: context)
            if engine == .webKit {
                let configuration = interactiveWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration), context: context)
            } else {
                try ChromiumRuntime.shared.ensureInitialized()
                page = BrowserPage(chromium: ChromiumPage(context: context))
            }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            AutofillSaveCoordinator.shared.install(in: page, session: tab.autofillSave)
            tab.autofillSave.liveness = { _, _, _ in true }
            page.url = URL(string: AutofillAgentControlTests.shop + "/checkout")
            page.hasOnlySecureContent = true
            main = BrowserFrame(
                id: "MAIN", documentID: "loader-main", url: URL(string: AutofillAgentControlTests.shop + "/checkout")!, isMainFrame: true,
                securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "shop.example", port: 0)
            )
            signIn = BrowserFrame(
                id: "IDP", documentID: "loader-idp", url: URL(string: AutofillAgentControlTests.idp + "/embed")!, isMainFrame: false,
                securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "login.idp.example", port: 0), parentID: "MAIN"
            )
        }

        func close() async {
            window.contentView = nil
            window.close()
            await page.close()
            if page.chromium != nil {
                await ChromiumRuntime.shared.releaseContext(contextID: page.context.contextID)
            }
        }

        /// What a focused field of `frame` sends to ask for suggestions.
        func select(in frame: BrowserFrame) -> BrowserScriptMessage {
            BrowserScriptMessage(page: page, body: [
                "action": "select", "token": UUID().uuidString, "url": frame.request.url!.absoluteString, "documentID": UUID().uuidString,
                "formID": "1", "fieldID": "2", "rect": ["x": 10.0, "y": 10.0, "width": 200.0, "height": 24.0, "viewportWidth": 600.0, "viewportHeight": 400.0],
            ], frameInfo: frame, name: "wsurfPasswords")
        }

        /// Announces `frame`'s document to the save coordinator, then stages a submitted login from it; whether it was staged.
        func stageLogin(in frame: BrowserFrame) -> Bool {
            let documentID = UUID().uuidString, attempt = UUID()
            let url = frame.request.url!.absoluteString
            for body: [String: Any] in [
                ["action": "ready", "documentID": documentID, "url": url],
                [
                    "action": "stage", "documentID": documentID, "url": url, "attemptID": attempt.uuidString, "formID": "1", "source": "submit",
                    "password": ["username": "ada@example.test", "password": "dummy-secret-123"],
                ],
            ] {
                AutofillSaveCoordinator.shared.receive(BrowserScriptMessage(page: page, body: body, frameInfo: frame, name: "wsurfAutofillSave"))
            }
            return tab.autofillSave.submissions.lifetime(of: attempt) != nil
        }
    }

    private func withRig(_ engine: BrowserEngine, _ body: (Rig) async throws -> Void) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, _ in
            let rig = try Rig(engine: engine, context: BrowserProfileContext(profile: profile))
            do {
                try await body(rig)
            } catch {
                await rig.close()
                throw error
            }
            await rig.close()
        }
    }

    @Test(arguments: BrowserEngine.allCases, Control.allCases)
    func aControlledTabIsOfferedNoSuggestionsAndNoSaveInAnyFrame(engine: BrowserEngine, control: Control) async throws {
        try await withRig(engine) { rig in
            for frame in [rig.main, rig.signIn] {
                let origin = try #require(frame.autofillOrigin(reportedURL: frame.request.url!))
                #expect(AutofillSuggestions.offerOrigin(for: rig.select(in: frame), kind: .password) == origin, "offered while nobody controls the tab")

                set(control, true, on: rig.tab)
                #expect(rig.tab.isAgentControlled && !rig.tab.allowsCredentialPicker)
                #expect(AutofillSuggestions.isAgentControlled(rig.page))
                for kind in AutofillSaveKind.allCases {
                    #expect(AutofillSuggestions.offerOrigin(for: rig.select(in: frame), kind: kind) == nil, "no \(kind) dropdown")
                }
                #expect(!rig.stageLogin(in: frame), "a login typed in a controlled tab is not staged")
                await rig.tab.autofillSave.offer(.password(try SavedPassword(website: origin, username: "ada", password: "dummy-secret")), origin: origin)
                #expect(rig.tab.autofillSave.current == nil, "and nothing is offered for saving")

                set(control, false, on: rig.tab)
                #expect(AutofillSuggestions.offerOrigin(for: rig.select(in: frame), kind: .password) == origin, "the next request is offered again")
                #expect(rig.stageLogin(in: frame))
            }
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func controlStartingTakesTheTabsOffersAway(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig in
            let origin = Self.idp
            await rig.tab.autofillSave.offer(.password(try SavedPassword(website: origin, username: "ada", password: "dummy-secret")), origin: origin)
            let offer = try #require(rig.tab.autofillSave.current)
            #expect(offer.origin == origin && rig.tab.autofillSave.isPopoverPresented)
            #expect(rig.stageLogin(in: rig.signIn))

            set(.connectedAppHolds, true, on: rig.tab)
            #expect(rig.tab.autofillSave.current == nil && rig.tab.autofillSave.websiteOffer == nil)
            #expect(!rig.tab.autofillSave.isPopoverPresented, "no offer stays on screen")

            set(.connectedAppHolds, false, on: rig.tab)
            #expect(rig.tab.autofillSave.current == nil, "a login staged before control is not offered after it")
        }
    }
}
