// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Why nothing was offered (`AutofillDiagnostics.refused`): which reason each refusal maps to, which reasons a page may report, and
/// the per-page budget of the log, and that the receive path and the menu hooks reach it. The mapping and the budget are pure values;
/// the wiring tests use a page that has no content and only count what was offered to the log, never what it holds.
struct AutofillRefusalDiagnosticsTests {
    typealias Diagnostics = AutofillDiagnostics
    typealias Limiter = AutofillDiagnostics.RefusalLimiter

    // MARK: - Mapping

    struct Offer: Sendable {
        var enabled = true, topIsSecure = true, hasOnlySecureContent = true, agentControlled = false, frameOriginTrusted = true
        var expected: AutofillDiagnostics.Event?
    }

    @Test(arguments: [
        Offer(expected: nil),
        Offer(enabled: false, expected: .disabled),
        Offer(topIsSecure: false, expected: .insecurePage),
        Offer(hasOnlySecureContent: false, expected: .insecurePage),
        Offer(agentControlled: true, expected: .agentControlled),
        Offer(frameOriginTrusted: false, expected: .frameNotTrusted),
        // Several refusals at once: the order of the checks, not the order of the arguments, names the reason.
        Offer(enabled: false, topIsSecure: false, agentControlled: true, frameOriginTrusted: false, expected: .disabled),
        Offer(hasOnlySecureContent: false, agentControlled: true, expected: .insecurePage),
        Offer(hasOnlySecureContent: false, frameOriginTrusted: false, expected: .insecurePage),
    ])
    func theDropdownsRefusalIsTheFirstCheckThatFails(offer: Offer) {
        #expect(Diagnostics.offerRefusal(
            enabled: offer.enabled, topIsSecure: offer.topIsSecure, hasOnlySecureContent: offer.hasOnlySecureContent,
            agentControlled: offer.agentControlled, frameOriginTrusted: offer.frameOriginTrusted
        ) == offer.expected)
    }

    @Test func theMenuReportsNotEditableOnlyWhereThePointIsNotEditable() {
        let refusals: [CredentialPicker.Refusal?] = [nil] + CredentialPicker.Refusal.allCases.map { $0 }
        for refusal in refusals {
            #expect(Diagnostics.menuRefusal(editable: false, offered: false, refusal: refusal) == .menuNotEditable)
            #expect(Diagnostics.menuRefusal(editable: false, offered: true, refusal: refusal) == .menuNotEditable)
        }
    }

    @Test func anEditableMenuReportsTheDisabledItemsReasonOrThatItWasNotOffered() {
        #expect(Diagnostics.menuRefusal(editable: true, offered: true, refusal: nil) == nil)
        #expect(Diagnostics.menuRefusal(editable: true, offered: false, refusal: .agentControl) == .agentControlled)
        #expect(Diagnostics.menuRefusal(editable: true, offered: false, refusal: .insecurePage) == .insecurePage)
        #expect(Diagnostics.menuRefusal(editable: true, offered: false, refusal: nil) == .menuNotOffered)
    }

    // MARK: - What a page may report

    @Test(arguments: ["formUnsafe", "formShape", "notVisible", "disabled"])
    func aPageMayReportItsFourReasons(reason: String) {
        #expect(Diagnostics.Event(skipReason: reason)?.rawValue == reason)
    }

    @Test(arguments: [
        // Native reasons a page cannot know or claim.
        "insecurePage", "agentControlled", "noOriginMatch", "rectRefused", "frameNotTrusted", "menuNotEditable", "menuNotOffered",
        // Other events, other cases, text and addresses.
        "scriptReady", "saveOffered", "", " ", "formunsafe", "formUnsafe ", "https://login.example.test/", "ada@example.test",
    ])
    func aReasonOutsideTheAllowListIsDropped(reason: String) {
        #expect(Diagnostics.Event(skipReason: reason) == nil)
    }

    @Test func aReasonThatIsNoStringIsDropped() {
        let values: [Any?] = [nil, 3, true, ["formUnsafe"], ["reason": "formUnsafe"], Data("formUnsafe".utf8)]
        for value in values {
            #expect(Diagnostics.Event(skipReason: value) == nil)
        }
    }

    @Test func aPageSkipIsLoggedOnlyForAnAllowedReason() {
        // The log's table is shared by the whole process: a time far ahead finds every earlier line expired, so it is never full.
        let owner = NSObject(), now = ContinuousClock.now.advanced(by: .seconds(200_000))
        #expect(Diagnostics.pageSkipped("https://login.example.test/", by: owner, now: now) == nil)
        #expect(Diagnostics.pageSkipped("insecurePage", by: owner, now: now) == nil)
        #expect(Diagnostics.pageSkipped(nil, by: owner, now: now) == nil)
        #expect(Diagnostics.pageSkipped("formShape", by: owner, now: now) == .formShape)
    }

    // MARK: - Budget

    @Test func aPageGetsTenLinesPerReasonAndMinuteAndTheRestIsCounted() {
        var limiter = Limiter()
        let page = NSObject(), start = ContinuousClock.now
        let key = ObjectIdentifier(page)
        for _ in 0..<Limiter.limit {
            #expect(limiter.admit(key, .formUnsafe, at: start) == 0)
        }
        for _ in 0..<5 {
            #expect(limiter.admit(key, .formUnsafe, at: start.advanced(by: .seconds(30))) == nil)
        }
        // The next window opens with the number of lines the last one dropped.
        #expect(limiter.admit(key, .formUnsafe, at: start.advanced(by: Limiter.window)) == 5)
        #expect(limiter.admit(key, .formUnsafe, at: start.advanced(by: Limiter.window + .seconds(1))) == 0)
    }

    @Test func eachPageAndEachReasonHasABudgetOfItsOwn() {
        var limiter = Limiter()
        let noisy = NSObject(), quiet = NSObject(), start = ContinuousClock.now
        for _ in 0..<(Limiter.limit + 3) {
            _ = limiter.admit(ObjectIdentifier(noisy), .formShape, at: start)
        }
        #expect(limiter.admit(ObjectIdentifier(noisy), .formShape, at: start) == nil)
        #expect(limiter.admit(ObjectIdentifier(noisy), .notVisible, at: start) == 0, "another reason of the same page")
        #expect(limiter.admit(ObjectIdentifier(quiet), .formShape, at: start) == 0, "the same reason of another page")
    }

    @Test func theLogKeepsToItsBudgetWhateverThePageDoes() {
        // The log's table is shared by the whole process: a time far ahead keeps any earlier line of a recycled address out of the count.
        let page = NSObject(), start = ContinuousClock.now.advanced(by: .seconds(100_000))
        let logged = (0..<(Limiter.limit * 4)).filter { _ in Diagnostics.refused(.formUnsafe, by: page, now: start) }
        #expect(logged.count == Limiter.limit)
    }

    /// A full table drops the new line. It never empties the table: that would hand every key a fresh allowance at once.
    @Test func aFullTableDropsTheNewLineAndKeepsEveryBudgetItHolds() {
        var limiter = Limiter()
        let start = ContinuousClock.now
        let pages = (0..<(Limiter.capacity + 1)).map { _ in NSObject() }
        let limited = ObjectIdentifier(pages[0])
        for _ in 0..<(Limiter.limit + 2) {
            _ = limiter.admit(limited, .formUnsafe, at: start)
        }
        #expect(limiter.admit(limited, .formUnsafe, at: start) == nil, "the first key is over its budget")
        for page in pages.dropFirst().prefix(Limiter.capacity - 1) {
            #expect(limiter.admit(ObjectIdentifier(page), .formUnsafe, at: start) == 0)
        }
        #expect(limiter.trackedCount == Limiter.capacity)

        let late = start.advanced(by: .seconds(30))
        #expect(limiter.admit(ObjectIdentifier(pages[Limiter.capacity]), .formUnsafe, at: late) == nil, "the 257th key is dropped")
        #expect(limiter.trackedCount == Limiter.capacity, "and the table is as it was")
        #expect(limiter.admit(limited, .formUnsafe, at: late) == nil, "a key that was over its budget still is")
        #expect(limiter.admit(ObjectIdentifier(pages[1]), .formUnsafe, at: late) == 0, "a key in the table keeps counting from its own window")
    }

    @Test func aFullTableTakesNewKeysAgainOnceItsWindowsHaveExpired() {
        var limiter = Limiter()
        let start = ContinuousClock.now
        let pages = (0..<(Limiter.capacity + 1)).map { _ in NSObject() }
        for page in pages.prefix(Limiter.capacity) {
            _ = limiter.admit(ObjectIdentifier(page), .formUnsafe, at: start)
        }
        #expect(limiter.admit(ObjectIdentifier(pages[Limiter.capacity]), .formUnsafe, at: start) == nil)
        let later = start.advanced(by: Limiter.window)
        #expect(limiter.admit(ObjectIdentifier(pages[Limiter.capacity]), .formUnsafe, at: later) == 0, "the expired windows made room")
        #expect(limiter.trackedCount == 1)
    }

    @Test func manyPagesNeverGrowTheTableWithoutBound() {
        var limiter = Limiter()
        let start = ContinuousClock.now
        let pages = (0..<(Limiter.capacity * 3)).map { _ in NSObject() }
        for (index, page) in pages.enumerated() {
            // The first `capacity` keys are admitted, the rest are dropped while their windows are live.
            #expect(limiter.admit(ObjectIdentifier(page), .formUnsafe, at: start) == (index < Limiter.capacity ? 0 : nil))
            #expect(limiter.trackedCount <= Limiter.capacity)
        }
    }

    // MARK: - Wiring: the receive path

    @MainActor private func makePage() -> BrowserPage {
        BrowserPage(
            webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: interactiveWebViewConfiguration()),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
    }

    @MainActor private func close(_ page: BrowserPage) async {
        await page.close()
        await page.context.endPrivateSession()
    }

    @MainActor private func message(_ body: [String: Any], on page: BrowserPage) -> BrowserScriptMessage {
        let frame = BrowserFrame(
            id: "MAIN", documentID: "main", url: URL(string: "https://login.example.test/")!, isMainFrame: true,
            securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "login.example.test", port: 0)
        )
        return BrowserScriptMessage(page: page, body: body, frameInfo: frame, name: "wsurfPasswords")
    }

    /// A page's `skip` goes to the log (`pageSkipped`) and never to the suggestions: the branch in `PasswordAutofill.receive` that
    /// sends it there comes before the one that hands every other message to `AutofillSuggestions`.
    @MainActor @Test(.boundedWebViews) func aPageSkipReachesTheLogByItsReasonAndLeavesTheSuggestionsAlone() async {
        let page = makePage()
        AutofillDiagnostics.watch(page)
        let before = AutofillSuggestions.shared.presentationID

        for reason in ["formUnsafe", "formShape", "notVisible", "disabled"] {
            PasswordAutofill.shared.receive(message(["action": "skip", "reason": reason], on: page))
        }
        #expect(AutofillDiagnostics.offered(to: page) == [.formUnsafe, .formShape, .notVisible, .disabled])

        // Nothing a page invents gets through: no reason, one of the native ones, an address, a number.
        let others: [Any] = ["insecurePage", "https://login.example.test/", "ada@example.test", 3, true]
        for reason in others {
            PasswordAutofill.shared.receive(message(["action": "skip", "reason": reason], on: page))
        }
        PasswordAutofill.shared.receive(message(["action": "skip"], on: page))
        #expect(AutofillDiagnostics.offered(to: page) == [.formUnsafe, .formShape, .notVisible, .disabled])
        #expect(AutofillSuggestions.shared.presentationID == before, "no skip is a request for suggestions")
        await close(page)
    }

    /// The skip is read from the engine's page, not from anything in the body.
    @MainActor @Test(.boundedWebViews) func aSkipIsCountedForTheEnginesPageNotForAnythingItNames() async {
        let page = makePage(), other = makePage()
        AutofillDiagnostics.watch(page)
        AutofillDiagnostics.watch(other)
        PasswordAutofill.shared.receive(message(["action": "skip", "reason": "formShape", "page": "x"], on: page))
        #expect(AutofillDiagnostics.offered(to: page) == [.formShape] && AutofillDiagnostics.offered(to: other).isEmpty)
        await close(page)
        await close(other)
    }

    // MARK: - Wiring: the suggestions' hooks

    @MainActor @Test(.boundedWebViews) func aLookupThatFoundNothingForALoginIsLoggedOnlyForTheCurrentRequest() async {
        let page = makePage(), context = page.context
        AutofillDiagnostics.watch(page)
        let current = AutofillSuggestions.shared.presentationID
        let nothing: [AutofillSuggestion] = []

        AutofillSuggestions.shared.noteNoRows(nothing, kind: .password, in: page, context: context, presentation: UUID())
        AutofillSuggestions.shared.noteNoRows(nothing, kind: .contact, in: page, context: context, presentation: current)
        #expect(AutofillDiagnostics.offered(to: page).isEmpty, "an old request, or a kind that is no login")
        AutofillSuggestions.shared.noteNoRows(nothing, kind: .password, in: page, context: context, presentation: current)
        #expect(AutofillDiagnostics.offered(to: page) == [.noOriginMatch])

        AutofillSuggestions.shared.noteRectRefused(in: page, context: context, presentation: UUID())
        let another = BrowserProfileContext(profile: .privateBrowsing())
        AutofillSuggestions.shared.noteRectRefused(in: page, context: another, presentation: current)
        #expect(AutofillDiagnostics.offered(to: page) == [.noOriginMatch], "not for an old request or another profile")
        AutofillSuggestions.shared.noteRectRefused(in: page, context: context, presentation: current)
        #expect(AutofillDiagnostics.offered(to: page) == [.noOriginMatch, .rectRefused])
        await close(page)
        await another.endPrivateSession()
    }
}
