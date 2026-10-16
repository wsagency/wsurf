// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// A tab opened in the background is new until it first comes on screen. The flag lives on the tab and in memory
/// only: after a restart nothing is new.
@MainActor
struct TabUnseenTests {
    private func makeModel() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    @Test func aBackgroundTabStartsUnseen() {
        let model = makeModel()
        let current = model.newTab()
        let background = model.newTab(activate: false)

        #expect(background.isUnseen)
        #expect(!current.isUnseen)
        #expect(model.activeTab === current)
    }

    @Test func aForegroundTabIsNeverUnseen() {
        let model = makeModel()
        _ = model.newTab()
        let foreground = model.newTab()

        #expect(!foreground.isUnseen)
    }

    /// Without an active tab the first tab is the one on screen, and a tab opened there is shown at once.
    @Test func aTabOpenedWithNothingActiveIsSeen() {
        let model = makeModel()
        let only = model.newTab(activate: false)

        #expect(model.activeTab === only)
        #expect(!only.isUnseen)
    }

    @Test func activatingClearsIt() {
        let model = makeModel()
        let current = model.newTab()
        let background = model.newTab(activate: false)
        let other = model.newTab(activate: false)

        model.activate(background)

        #expect(!background.isUnseen)
        #expect(other.isUnseen, "only the tab that came on screen is cleared")

        model.activate(current)
        #expect(!background.isUnseen, "leaving a tab does not make it new again")
    }

    /// A pane beside the focused tab is on screen too, even though it was never activated.
    @Test func aSplitPaneOnScreenClearsIt() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab(activate: false)
        #expect(right.isUnseen)

        model.activate(left)
        model.split(left, with: right, axis: .sideBySide)

        #expect(model.activeSplit?.contains(right.id) == true)
        #expect(!right.isUnseen)
    }

    @Test func aSplitOfOtherTabsLeavesAnUnseenTabNew() {
        let model = makeModel()
        let left = model.newTab()
        let right = model.newTab()
        let background = model.newTab(activate: false)
        model.split(left, with: right, axis: .sideBySide)
        model.activate(left)

        #expect(background.isUnseen)
    }

    @Test func aRestoredSessionHasNoUnseenTabs() {
        let database = AppDatabase.temporary()
        let first = BrowserModel(database: database)
        _ = first.newTab()
        let background = first.newTab(activate: false)
        #expect(background.isUnseen)
        first.saveBlocking()

        let reopened = BrowserModel(database: database)
        reopened.restoreSession()

        #expect(reopened.tabs.count == first.tabs.count)
        #expect(reopened.tabs.allSatisfy { !$0.isUnseen })
    }

    @Test(.boundedWebViews) func importedBookmarksAreNotUnseen() {
        let model = makeModel()
        let folder = model.importBookmarksFolder(named: "Imported", entries: [
            .init(url: "https://example.com/", title: "Example", date: .distantPast),
            .init(url: "https://docs.example.com/", title: "Docs", date: .distantPast),
        ])

        let imported = folder.map { model.tabs(in: $0) } ?? []
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { !$0.isUnseen })
    }

    /// Stage mode opens its sites in the background, so it has to say which of them stay new.
    @Test func everyStagedNewTabIsAStagedSite() {
        let staged = Set(
            (StageSet.pinned + StageSet.loose + StageSet.reading.sites + StageSet.shipping.sites).map(\.address)
        )

        #expect(!StageSet.unseen.isEmpty)
        #expect(StageSet.unseen.isSubset(of: staged))
        #expect(!StageSet.unseen.contains(StageSet.opening.address), "the opening tab is the one on screen")
    }
}
