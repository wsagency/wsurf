// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The consent gate, in a suite of its own. Each page's private profile context
/// owns its grant storage, keeping these consent checks isolated.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AgentConsentGateTests {
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

    private func js(_ page: BrowserPage, _ script: String) async -> Any? {
        try? await page.evaluateJavaScript(script)
    }

    private func refs(in observation: String, matching needle: String) -> [Int] {
        observation
            .components(separatedBy: "\n")
            .filter { $0.contains(needle) }
            .compactMap { line -> Int? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<close])
            }
    }

    private func firstRef(in observation: String, matching needle: String) -> Int? {
        refs(in: observation, matching: needle).first
    }

    /// The consent question runs on the element's own label, so addressing a
    /// payment button by number instead of by name changes nothing - and the
    /// user's decline is final: no click, and the model is told to stop
    /// rather than to try another route.
    @Test func aDeclinedConsequentialClickDoesNotHappen() async throws {
        let webView = await loadedWebView(#"<button onclick="window.__paid=1">Place order</button>"#)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(firstRef(in: observation, matching: "Place order"))

        var asked: (label: String, category: SensitiveAction.Category)?
        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ label, category, _, _ in
            asked = (label, category)
            return .decline
        })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }
        #expect(asked?.label == "Place order")
        #expect(asked?.category == .purchase)
        #expect(result.contains("declined"))
        #expect(result.contains("do not try another way"))
        #expect(await js(webView, "typeof window.__paid === 'undefined'") as? Bool == true)
    }

    /// And the user saying yes is equally final: the click proceeds exactly
    /// as an ordinary one would.
    @Test func anAllowedConsequentialClickProceeds() async throws {
        let webView = await loadedWebView(#"<button onclick="window.__paid=1">Place order</button>"#)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(firstRef(in: observation, matching: "Place order"))

        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, _, _, _ in .allowOnce })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }
        #expect(result.hasPrefix("Clicked"))
        #expect(await js(webView, "window.__paid") as? Int == 1)
    }

    @Test func aDeceptiveLabelCannotHideAConsequentialForm() async throws {
        let webView = await loadedWebView("""
        <form aria-label="Checkout" onsubmit="window.__paid=1; return false;">
          <p>Review and complete purchase</p>
          <button>Continue</button>
        </form>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(firstRef(in: observation, matching: "Continue"))

        var asked: (label: String, category: SensitiveAction.Category)?
        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ label, category, _, _ in
            asked = (label, category)
            return .decline
        })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }

        #expect(asked?.label == "Continue")
        #expect(asked?.category == .purchase)
        #expect(result.contains("declined"))
        #expect(await js(webView, "typeof window.__paid === 'undefined'") as? Bool == true)
    }

    @Test func anOrdinaryContinueButtonDoesNotTriggerConsequentialConsent() async throws {
        let webView = await loadedWebView("""
        <form onsubmit="window.__continued=1; return false;">
          <p>Continue profile setup</p>
          <button>Continue</button>
        </form>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(firstRef(in: observation, matching: "Continue"))

        var asked = false
        let result = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, _, _, _ in
            asked = true
            return .decline
        })) {
            await PageDriver.click(ref: ref, label: "", in: webView)
        }

        #expect(!asked)
        #expect(result.hasPrefix("Clicked"))
        #expect(await js(webView, "window.__continued") as? Int == 1)
    }

    @Test func aSensitiveFieldIsRefusedEvenByRef() async throws {
        let webView = await loadedWebView(#"<input type="password" placeholder="Password">"#)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "Password").first)

        let result = await PageDriver.type(text: "hunter2", intoField: "", ref: ref, submit: false, in: webView)
        #expect(result.contains("sensitive") || result.contains("password"))
        #expect(await js(webView, "document.querySelector('input').value") as? String == "")
    }

    /// Refusing to *write* a secret is half the duty. An observation is sent
    /// verbatim to whichever provider the user configured, so a value already
    /// in the field - a password manager fills one on load, without the user
    /// touching the page - must not travel with it.
    @Test func anObservationNeverCarriesASensitiveValue() async {
        let webView = await loadedWebView("""
        <input name="user" value="ada@example.com">
        <input type="password" name="password" value="hunter2-SECRET">
        """)
        let observation = await PageDriver.readRenderedPage(webView)

        #expect(!observation.contains("hunter2-SECRET"))
        // Still visible as a field, and still known to be filled: the model
        // has to be able to tell a completed form from an empty one.
        #expect(observation.contains("field \"password\" (password) = (filled, hidden)"))
        #expect(observation.contains("ada@example.com"))
    }

    /// The same predicate the writing half uses, so the two cannot drift:
    /// a card number is caught by its `autocomplete`, a code by its label.
    @Test func anObservationHidesPaymentAndCodeValuesToo() async {
        let webView = await loadedWebView("""
        <input autocomplete="cc-number" placeholder="Card number" value="4111111111111111">
        <input autocomplete="cc-csc" placeholder="CVC" value="737">
        <input placeholder="One-time code" value="908321">
        <input placeholder="Delivery note" value="leave at the door">
        """)
        let observation = await PageDriver.readRenderedPage(webView)

        #expect(!observation.contains("4111111111111111"))
        #expect(!observation.contains("908321"))
        #expect(observation.contains("field \"Card number\" = (filled, hidden)"))
        // An ordinary field is untouched - the denylist errs toward hiding,
        // but it is still a denylist, not a blanket.
        #expect(observation.contains("leave at the door"))
    }

    /// An empty sensitive field says so, rather than going quiet and leaving
    /// "is the form filled in?" unanswerable.
    @Test func anEmptySensitiveFieldReportsThatItIsEmpty() async {
        let webView = await loadedWebView(#"<input type="password" placeholder="Password">"#)
        let observation = await PageDriver.readRenderedPage(webView)

        #expect(observation.contains("= (empty)"))
    }

    /// A grant is scoped to a site, so a page with no host to scope it to
    /// must never count as granted - otherwise `data:`, `file:` and
    /// `about:` pages would walk through the gate unasked.
    @Test func aPageWithNoHostIsNeverAlreadyAllowed() {
        let policy = BrowserProfileContext(profile: .privateBrowsing()).actionPolicy
        for category in SensitiveAction.Category.allCases {
            #expect(!policy.isAlwaysAllowed(category, host: nil))
            #expect(!policy.isAlwaysAllowed(category, host: ""))
        }
    }
}
