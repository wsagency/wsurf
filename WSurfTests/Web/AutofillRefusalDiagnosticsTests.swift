// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// Why nothing was offered (`AutofillDiagnostics.refused`): which reason each refusal maps to, which reasons a page may report, and
/// the per-page budget of the log. Pure functions and values: nothing here reads a page, an address or a field.
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
        let owner = NSObject()
        #expect(Diagnostics.pageSkipped("https://login.example.test/", by: owner) == nil)
        #expect(Diagnostics.pageSkipped("insecurePage", by: owner) == nil)
        #expect(Diagnostics.pageSkipped(nil, by: owner) == nil)
        #expect(Diagnostics.pageSkipped("formShape", by: owner) == .formShape)
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

    @Test func manyPagesNeverGrowTheTableWithoutBound() {
        var limiter = Limiter()
        let start = ContinuousClock.now
        let pages = (0..<(Limiter.capacity * 3)).map { _ in NSObject() }
        for page in pages {
            #expect(limiter.admit(ObjectIdentifier(page), .formUnsafe, at: start) == 0)
            #expect(limiter.trackedCount <= Limiter.capacity)
        }
    }
}
