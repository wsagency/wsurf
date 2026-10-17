// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// Clicking "Continue with Google" or an OAuth "Allow" button hands another website the user's account, so it asks
/// like a purchase does. A plain "Sign in" link must stay clickable.
struct AccountAccessActionTests {
    @Test(arguments: [
        "Sign in with Google", "Log in with Apple", "Login with Microsoft", "Sign up with Facebook",
        "Continue with Google", "Continue with Apple", "Continue with Microsoft", "Continue with Facebook",
        "Continue with GitHub", "Authorize", "Authorize app", "Allow access", "Grant access",
        "Connect account", "Link account", "  SIGN IN WITH GOOGLE  ", "Continue with Google »",
    ])
    func accountAccessLabelsAreConfirmed(_ label: String) {
        #expect(SensitiveAction.category(of: label) == .accountAccess)
        #expect(SensitiveAction.isConsequentialClick(label))
    }

    @Test(arguments: [
        "Sign in", "Log in", "Login", "Sign up", "Create account", "Continue", "Continue with email",
        "Continue with phone", "Forgot password", "Authorized users", "Allow all cookies", "Allow cookies",
        "Access denied", "Account settings", "Link to this page", "Connect", "Sign out",
    ])
    func plainSignInLinksDoNotAsk(_ label: String) {
        #expect(SensitiveAction.category(of: label) == nil)
    }

    /// A form's own text often names its social sign-in options. The plain button inside it is not one of them.
    @Test func aPlainButtonInsideASocialSignInFormStaysClickable() {
        let form = "Sign in with Google Continue with Apple Email Password Forgot password"
        #expect(SensitiveAction.category(of: "Sign in", context: form) == nil)
        #expect(SensitiveAction.category(of: "Continue", context: form) == nil)
    }

    @Test func aPurchaseOrTransferLabelKeepsItsOwnCategory() {
        #expect(SensitiveAction.category(of: "Pay now") == .purchase)
        #expect(SensitiveAction.category(of: "Authorize and pay") == .purchase)
        #expect(SensitiveAction.category(of: "Send money") == .transfer)
        #expect(SensitiveAction.category(of: "Delete account") == .deletion)
    }

    @Test func theCategoryHasItsOwnApprovalName() {
        #expect(SensitiveAction.Category.allCases.contains(.accountAccess))
        #expect(String(localized: SensitiveAction.Category.accountAccess.listName) == "signing in")
        #expect(SensitiveAction.Category.accountAccess.consequenceForModel.contains("access to your account"))
    }

    @MainActor
    @Test func theQuestionSaysWhatTheClickDoesWithoutSayingItCannotBeUndone() {
        let body = AgentActionConsent.body(label: "Continue with Google", category: .accountAccess, site: "example.com")
        #expect(body.contains("Continue with Google"))
        #expect(body.contains("signs in or gives another website access to your account"))
        #expect(!body.contains("can’t be undone"))

        let purchase = AgentActionConsent.body(label: "Place order", category: .purchase, site: "example.com")
        #expect(purchase.contains("can’t be undone"))
    }

    @MainActor
    @Test func anApprovalForSigningInCoversOnlyThatSite() {
        let policy = AgentActionPolicy(storage: SessionAgentGrantStorage())
        policy.allowAlways(.accountAccess, host: "www.example.com")

        #expect(policy.isAlwaysAllowed(.accountAccess, host: "example.com"))
        #expect(!policy.isAlwaysAllowed(.accountAccess, host: "other.example.com"))
        #expect(!policy.isAlwaysAllowed(.purchase, host: "example.com"))
    }
}

/// The click confirmation on a live page: the account-access question comes from the page driver, so it holds under
/// every access level, including an Allow Control default.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AccountAccessConsentTests {
    private func loadedWebView(_ body: String) async -> BrowserPage {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            ),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        page.loadHTMLString("<!doctype html><html><body>\(body)</body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        return page
    }

    /// The numbered control line that names `needle`; the page text above the controls repeats the same words.
    private func ref(in observation: String, matching needle: String) -> Int? {
        observation
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") && $0.contains(needle) }
            .compactMap { line -> Int? in
                guard let close = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<close])
            }
            .first
    }

    private let buttons = """
        <button onclick="window.__google=1">Continue with Google</button>
        <button onclick="window.__plain=1">Sign in</button>
        <button onclick="window.__paid=1">Place order</button>
        """

    @Test func aDeclinedSocialSignInDoesNotHappen() async throws {
        let webView = await loadedWebView(buttons)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(ref(in: observation, matching: "Continue with Google"))

        var asked: (label: String, category: SensitiveAction.Category)?
        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ label, category, _, _ in
            asked = (label, category)
            return .decline
        })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }

        #expect(asked?.label == "Continue with Google")
        #expect(asked?.category == .accountAccess)
        #expect(result.contains("declined"))
        #expect(try await webView.evaluateJavaScript("typeof window.__google === 'undefined'") as? Bool == true)
    }

    @Test func anAllowedSocialSignInProceeds() async throws {
        let webView = await loadedWebView(buttons)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(ref(in: observation, matching: "Continue with Google"))

        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, _, _, _ in .allowOnce })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }

        #expect(result.hasPrefix("Clicked"))
        #expect(try await webView.evaluateJavaScript("window.__google") as? Int == 1)
    }

    @Test func aPlainSignInButtonClicksWithoutAsking() async throws {
        let webView = await loadedWebView(buttons)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(ref(in: observation, matching: "Sign in"))

        var asked = false
        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, _, _, _ in
            asked = true
            return .decline
        })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }

        #expect(!asked)
        #expect(result.hasPrefix("Clicked"))
        #expect(try await webView.evaluateJavaScript("window.__plain") as? Int == 1)
    }

    @Test func aPurchaseStillAsksAlongsideTheNewCategory() async throws {
        let webView = await loadedWebView(buttons)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(ref(in: observation, matching: "Place order"))

        var asked: SensitiveAction.Category?
        _ = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, category, _, _ in
            asked = category
            return .decline
        })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }

        #expect(asked == .purchase)
        #expect(try await webView.evaluateJavaScript("typeof window.__paid === 'undefined'") as? Bool == true)
    }
}
