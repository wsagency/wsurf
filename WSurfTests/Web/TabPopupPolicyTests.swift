// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
/// What one tab is under, and what it remembers being refused. The policy is
/// read on every pop-up, so it follows the page rather than the window.
@Suite(.serialized)
struct TabPopupPolicyTests {
    private func store() -> SitePermissions {
        SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appending(path: "TabPopupPolicyTests-\(UUID().uuidString).json")
        )
    }

    private func withPopupsBlocked(_ blocked: Bool, settings: BrowserSettings, _ body: () -> Void) {
        let previous = settings.blocksPopups
        settings.blocksPopups = blocked
        defer { settings.blocksPopups = previous }
        body()
    }

    @Test func aTabOnNoWebsiteIsUnderTheSetting() {
        let settings = BrowserSettings()
        let policy = TabPopupPolicy(store: store(), settings: settings)

        withPopupsBlocked(true, settings: settings) { #expect(policy.effective == .blockAndNotify) }
        withPopupsBlocked(false, settings: settings) { #expect(policy.effective == .allow) }
    }

    @Test func aWebsiteWithItsOwnAnswerIsNotUnderTheSetting() {
        let settings = BrowserSettings()
        let permissions = store()
        permissions.setPopups(.allow, for: "https://example.com")
        let policy = TabPopupPolicy(store: permissions, settings: settings)
        _ = policy.pageChanged(url: URL(string: "https://example.com/page"))

        withPopupsBlocked(true, settings: settings) { #expect(policy.effective == .allow) }
    }

    @Test func aTabTakesTheOriginOfThePageItIsOn() {
        let policy = TabPopupPolicy(store: store(), settings: BrowserSettings())

        #expect(policy.pageChanged(url: URL(string: "https://example.com/one")))
        #expect(policy.origin == "https://example.com")
        #expect(
            !policy.pageChanged(url: URL(string: "https://example.com/two")),
            "another page of the same website is the same website"
        )
        #expect(policy.pageChanged(url: URL(string: "https://other.example.com/")))
        #expect(policy.origin == "https://other.example.com")
    }

    @Test func aPageOfTheBrowsersOwnIsNoWebsite() {
        let policy = TabPopupPolicy(store: store(), settings: BrowserSettings())

        #expect(policy.pageChanged(url: URL(string: "https://example.com/")))
        #expect(policy.pageChanged(url: SystemPages.start))
        #expect(policy.origin.isEmpty)
    }

    @Test func onlyABlockWorthTellingAboutIsRemembered() {
        let settings = BrowserSettings()
        let permissions = store()
        let policy = TabPopupPolicy(store: permissions, settings: settings)
        _ = policy.pageChanged(url: URL(string: "https://example.com/one"))
        let wanted = URL(string: "https://example.com/popup")

        withPopupsBlocked(true, settings: settings) {
            policy.note(wanted)
            #expect(policy.blocked == wanted)
        }

        policy.clear()
        #expect(policy.blocked == nil)

        permissions.setPopups(.block, for: "https://example.com")
        withPopupsBlocked(true, settings: settings) {
            policy.note(wanted)
            #expect(policy.blocked == nil, "a silent block has nothing to report")
        }

        permissions.setPopups(.allow, for: "https://example.com")
        withPopupsBlocked(true, settings: settings) {
            policy.note(wanted)
            #expect(policy.blocked == nil)
        }
    }

    @Test func leavingTheWebsiteForgetsWhatItWasRefused() {
        let settings = BrowserSettings()
        let policy = TabPopupPolicy(store: store(), settings: settings)
        _ = policy.pageChanged(url: URL(string: "https://example.com/one"))

        withPopupsBlocked(true, settings: settings) {
            policy.note(URL(string: "https://example.com/popup"))
            #expect(policy.blocked != nil)
            _ = policy.pageChanged(url: URL(string: "https://other.example.com/"))
            #expect(policy.blocked == nil)
        }
    }
}
