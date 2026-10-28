// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What makes a tab's page hidden once it is no longer in front, and what keeps it as it was.
@MainActor
@Suite(.boundedWebViews)
struct BackgroundHidingPolicyTests {
    private func makeModel() -> BrowserModel {
        BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundHiding-\(UUID().uuidString).json")
            )
        )
    }

    @Test func aTabWithNothingGoingOnHidesInTheBackground() {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        #expect(tab.hidesInBackground)
        #expect(tab.page.hidesWhileParked, "its page is told")
    }

    /// Each reason on its own, on a tab with nothing else going on: the tab is not hidden while it holds, and is when it ends.
    @Test(arguments: BackgroundTabHidingTests.Reason.allCases)
    func whatTheTabIsDoingKeepsItShown(reason: BackgroundTabHidingTests.Reason) {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        reason.apply(true, to: tab, in: model)
        #expect(!tab.hidesInBackground, "\(reason)")
        reason.apply(false, to: tab, in: model)
        #expect(tab.hidesInBackground, "\(reason) ended")
    }

    @Test func aPrivateTabIsNeverHidden() {
        let model = makeModel()
        model.adopt(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundHiding-\(UUID().uuidString).json")
            ),
            privately: true
        )
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        #expect(tab.isPrivate)
        #expect(!tab.hidesInBackground)
    }

    /// The page hears of a change while it waits, with no help from whoever changed it.
    @Test func theTabsPageFollowsWhatTheTabDoes() async {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        let page = tab.page
        #expect(page.hidesWhileParked)

        tab.isPlayingAudio = true
        #expect(await waitUntil { !page.hidesWhileParked }, "a tab that plays is shown")
        tab.isPlayingAudio = false
        #expect(await waitUntil { page.hidesWhileParked }, "and hides again when it stops")
    }
}
