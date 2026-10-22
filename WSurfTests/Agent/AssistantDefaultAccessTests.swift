// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The global default for websites that have no setting of their own. A website's record always wins; private tabs
/// and embedded frames never use the default; a password or payment field makes control ask first.
@MainActor
struct AssistantDefaultAccessTests {
    private let origin = "https://example.com"

    private func makeStore(default policy: AssistantAccessPolicy = .ask) -> SitePermissions {
        let store = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("AssistantDefaultAccessTests-\(UUID().uuidString).json")
        )
        store.setAssistantDefault(policy)
        return store
    }

    private func makeCenter(
        store: SitePermissions,
        privately: Bool = false,
        url: String = "https://example.com/page"
    ) -> TabAssistantAccessCenter {
        let center = TabAssistantAccessCenter(store: store)
        center.persistsAnswers = !privately
        center.pageChanged(url: URL(string: url))
        return center
    }

    /// Answers every question with `answer` and counts how many were asked.
    private func answering(
        _ answer: AssistantAccessPolicy,
        _ body: (_ asked: () -> [AssistantPageCapability]) async -> Void
    ) async {
        var asked: [AssistantPageCapability] = []
        await TabAssistantAccessCenter.$decisionForTesting.withValue(.init({ capability, _ in
            asked.append(capability)
            return answer
        })) {
            await body { asked }
        }
    }

    // MARK: - The three levels

    @Test func askDefaultKeepsAskingAsToday() async {
        let store = makeStore(default: .ask)
        let center = makeCenter(store: store)
        #expect(center.decision(for: .read) == .ask)
        #expect(center.decision(for: .control) == .ask)

        await answering(.readOnly) { asked in
            #expect(await center.authorize(.read))
            #expect(asked() == [.read])
        }
        #expect(store.assistantRecord(for: origin) == .readOnly)
    }

    @Test func readOnlyDefaultReadsWithoutAskingAndAsksBeforeControl() async {
        let store = makeStore(default: .readOnly)
        let center = makeCenter(store: store)
        #expect(center.decision(for: .read) == .allow)
        #expect(center.decision(for: .control) == .ask)

        await answering(.control) { asked in
            #expect(await center.authorize(.read))
            #expect(asked().isEmpty)
            #expect(await center.authorize(.control))
            #expect(asked() == [.control])
        }
        // The answer is saved as the website's own record, so it is not asked again.
        #expect(store.assistantRecord(for: origin) == .control)
        #expect(center.decision(for: .control) == .allow)
    }

    @Test func aDismissedControlQuestionUnderReadOnlyDefaultSavesNothing() async {
        let store = makeStore(default: .readOnly)
        let center = makeCenter(store: store)

        await answering(.ask) { _ in
            #expect(!(await center.authorize(.control)))
        }
        #expect(store.assistantRecord(for: origin) == nil)
        #expect(center.decision(for: .read) == .allow)
    }

    @Test func allowControlDefaultReadsAndControlsWithoutAsking() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)
        center.sensitivePageProbe = { _ in false }

        await answering(.ask) { asked in
            #expect(await center.authorize(.read))
            #expect(await center.authorize(.control))
            #expect(asked().isEmpty)
        }
        #expect(store.assistantRecord(for: origin) == nil)
    }

    // MARK: - Records win

    @Test func aSiteRecordWinsOverTheDefault() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)
        center.sensitivePageProbe = { _ in false }

        await answering(.control) { asked in
            store.setAssistantAccess(.readOnly, for: origin)
            #expect(await center.authorize(.read))
            #expect(!(await center.authorize(.control)))

            store.setAssistantAccess(.deny, for: origin)
            #expect(!(await center.authorize(.read)))
            #expect(!(await center.authorize(.control)))
            #expect(asked().isEmpty)

            // An explicit Ask is a choice: it asks even though the default would allow.
            store.setAssistantAccess(.ask, for: origin)
            #expect(center.decision(for: .read) == .ask)
            #expect(await center.authorize(.control))
            #expect(asked() == [.control])
        }
    }

    @Test func aRecordCanAllowMoreThanTheDefault() async {
        let store = makeStore(default: .readOnly)
        store.setAssistantAccess(.control, for: origin)
        let center = makeCenter(store: store)

        await answering(.ask) { asked in
            #expect(await center.authorize(.control))
            #expect(asked().isEmpty)
        }
    }

    @Test func useDefaultRemovesTheRecord() {
        let store = makeStore(default: .readOnly)
        store.setAssistantAccess(.deny, for: origin)
        let center = makeCenter(store: store)
        #expect(center.effectivePolicy == .deny)

        center.set(nil)

        #expect(store.assistantRecord(for: origin) == nil)
        #expect(store.assistantOrigins.isEmpty)
        #expect(center.explicitPolicy == nil)
        #expect(center.effectivePolicy == .readOnly)
    }

    // MARK: - Where the default does not reach

    @Test func privateTabsIgnoreTheDefault() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store, privately: true)
        center.sensitivePageProbe = { _ in false }
        #expect(center.defaultPolicy == .ask)
        #expect(center.decision(for: .read) == .ask)
        #expect(center.decision(for: .control) == .ask)

        await answering(.readOnly) { asked in
            #expect(await center.authorize(.read))
            #expect(asked() == [.read])
        }
        // The answer lasts for the visit and is never written to the profile.
        #expect(center.explicitPolicy == .readOnly)
        #expect(store.assistantOrigins.isEmpty)
        center.pageChanged(url: URL(string: "https://other.example/"))
        #expect(center.decision(for: .read) == .ask)
    }

    @Test func aPrivateWindowsStoreCannotHoldADefault() {
        let store = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("PrivateDefault-\(UUID().uuidString).json"),
            persists: false
        )
        store.setAssistantDefault(.control)
        #expect(store.assistantDefault == .ask)
    }

    @Test func embeddedFramesIgnoreTheDefault() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)
        let frame = center.embeddedAccess(for: URL(string: "https://pay.example.net/frame")!)
        frame.sensitivePageProbe = { _ in false }
        #expect(frame.decision(for: .read) == .ask)
        #expect(frame.decision(for: .control) == .ask)

        await answering(.readOnly) { asked in
            #expect(await frame.authorize(.read))
            #expect(asked() == [.read])
        }
        // A frame's answer is its own site's record; the default still covers every other site.
        #expect(store.assistantRecord(for: "https://pay.example.net") == .readOnly)
        #expect(center.decision(for: .read) == .allow)
    }

    // MARK: - Password and payment fields

    @Test func aPasswordFieldMakesControlAskUnderTheDefault() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)
        center.sensitivePageProbe = { _ in true }

        await answering(.ask) { asked in
            #expect(await center.authorize(.read))
            #expect(asked().isEmpty)
            #expect(!(await center.authorize(.control)))
            #expect(asked() == [.control])
        }
        #expect(center.isCappedBySensitiveField)
        #expect(center.decision(for: .read) == .allow)
        #expect(center.decision(for: .control) == .ask)
    }

    @Test func aSavedAllowControlAnswerLiftsTheCapForThatSite() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)
        var looks = 0
        center.sensitivePageProbe = { _ in
            looks += 1
            return true
        }

        await answering(.control) { asked in
            #expect(await center.authorize(.control))
            #expect(asked() == [.control])
            #expect(await center.authorize(.control))
            #expect(asked() == [.control])
        }
        #expect(looks == 1)
        #expect(store.assistantRecord(for: origin) == .control)
        #expect(!center.isCappedBySensitiveField)

        // Another website with a login form still asks.
        let other = makeCenter(store: store, url: "https://login.example.org/")
        other.sensitivePageProbe = { _ in true }
        await answering(.ask) { asked in
            #expect(!(await other.authorize(.control)))
            #expect(asked() == [.control])
        }
    }

    @Test func eachControlRequestLooksAgainSoALoginFormShownLaterStillAsks() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)
        var sensitive = false
        center.sensitivePageProbe = { _ in sensitive }

        await answering(.ask) { asked in
            #expect(await center.authorize(.control))
            sensitive = true
            #expect(!(await center.authorize(.control)))
            #expect(asked() == [.control])
            sensitive = false
            #expect(await center.authorize(.control))
            #expect(asked() == [.control])
        }
    }

    @Test func aPageThatCannotBeInspectedCountsAsSensitive() async {
        let store = makeStore(default: .control)
        let center = makeCenter(store: store)

        // No page to look at, and the built-in look refuses to guess.
        await answering(.ask) { asked in
            #expect(!(await center.authorize(.control)))
            #expect(asked() == [.control])
        }
        #expect(center.isCappedBySensitiveField)
    }

    @Test func thePromptNamesTheFieldWhenThatIsWhyItAsks() {
        let plain = TabAssistantAccessCenter.body(capability: .control, site: "example.com")
        let capped = TabAssistantAccessCenter.body(capability: .control, site: "example.com", pageHasSensitiveField: true)
        #expect(!plain.contains("password or payment field."))
        #expect(capped.hasPrefix("This page has a password or payment field."))
        #expect(capped.hasSuffix(plain))
    }

    // MARK: - Changing the default

    @Test func changingTheDefaultReEvaluatesLiveTabs() async throws {
        let browser = BrowserModel(
            context: BrowserProfileContext(profile: Profile(id: UUID(), name: "Default fixture", symbol: "person", color: .gray)),
            windowID: UUID(), database: .temporary())
        let tab = browser.newTab()
        tab.assistantAccess.pageChanged(url: URL(string: "https://example.com/page"))
        tab.assistantAccess.sensitivePageProbe = { _ in false }
        let previous = tab.assistantAccess.onPolicyChanged
        var notified = 0
        tab.assistantAccess.onPolicyChanged = {
            previous?()
            notified += 1
        }
        #expect(tab.assistantAccess.decision(for: .control) == .ask)

        browser.sitePermissions.setAssistantDefault(.control)
        #expect(notified == 1)
        #expect(tab.assistantAccess.decision(for: .control) == .allow)

        browser.sitePermissions.setAssistantDefault(.ask)
        #expect(notified == 2)
        #expect(tab.assistantAccess.decision(for: .control) == .ask)

        // Setting what is already set changes nothing and tells no one.
        browser.sitePermissions.setAssistantDefault(.ask)
        #expect(notified == 2)
    }
}
