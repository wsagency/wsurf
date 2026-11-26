// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

/// Windows that share Space tabs show each shared row once per window and upload it once per Mac.
extension SharedSpacesTests {
    private func sharedTabs(in cloud: FakeSyncCloud) -> [SharedSpaceItem] {
        (cloud.records(in: SharedCatalogCategory.spaces.zone) ?? [])
            .compactMap(SharedSpaceItem.init(record:))
            .filter { $0.kind == .tab && !$0.removed }
    }

    private func pages(at address: String, in window: BrowserModel) -> [BrowserTab] {
        window.tabs.filter { $0.urlString == address }
    }

    /// The first launch after the update: each window's own shared tabs become every window's, and iCloud keeps one record
    /// for each, even though the second window restores before the app lists it.
    @Test func windowsThatStartSharingSpaceTabsKeepOneCloudRecordPerTab() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio")
        defer { studio.finish() }
        let home = try #require(studio.store.spaces.first)
        let second = studio.addWindow()
        let mine = studio.browser.addPage("https://first-window.example.test/")
        let theirs = second.addPage("https://second-window.example.test/")
        try await studio.host.share(home, in: studio.profile)
        try await studio.sync()
        #expect(sharedTabs(in: cloud).count == 2)

        studio.removeWindow(second)
        studio.browser.sharesSpaceTabsOverride = true
        studio.browser.attachSpaceRows()
        let restored = studio.restoreWindow(second.windowID, sharesSpaceTabs: true)
        try await studio.sync()
        studio.browser.scheduleSave()
        restored.scheduleSave()
        try await studio.sync()

        #expect(sharedTabs(in: cloud).count == 2)
        for window in [studio.browser, restored] {
            #expect(pages(at: mine.urlString, in: window).count == 1)
            #expect(pages(at: theirs.urlString, in: window).count == 1)
        }

        // The window iCloud follows can close; the other one takes its rows over without uploading them again.
        let owner = try #require(studio.host.spaceTabsOwner(of: studio.profile))
        let other = owner === studio.browser ? restored : studio.browser
        if owner !== studio.browser {
            studio.removeWindow(owner)
        } else {
            owner.markSessionClosed()
        }
        let page = try #require(pages(at: mine.urlString, in: other).first)
        other.renameTab(page, to: "After the owner closed")
        try await studio.sync()
        #expect(sharedTabs(in: cloud).count == 2)
        #expect(sharedTabs(in: cloud).first { $0.url == mine.urlString }?.customTitle == "After the owner closed")
    }

    @Test func twoWindowsThatShareSpaceTabsUploadEachTabOnceAndFollowRemoteChanges() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio", sharesSpaceTabs: true)
        let air = Mac(cloud, name: "Air", sharesSpaceTabs: true)
        defer { studio.finish(); air.finish() }

        let home = try #require(studio.store.spaces.first)
        let studioSecond = studio.addWindow()
        let page = studio.browser.addPage("https://one.example.test/")
        studio.browser.scheduleSave()
        let studioCopy = try #require(studioSecond.tabs.first { $0.spaceTabID == page.spaceTabID })
        try await studio.host.share(home, in: studio.profile)
        try await studio.sync()
        // Edits in the second window go through the window iCloud follows, never as a copy of their own.
        let added = studioSecond.addPage("https://two.example.test/")
        studioSecond.scheduleSave()
        studioSecond.renameTab(studioCopy, to: "Renamed in the second window")
        try await studio.sync()
        #expect(sharedTabs(in: cloud).compactMap(\.url).sorted() == ["https://one.example.test/", "https://two.example.test/"])
        #expect(sharedTabs(in: cloud).first { $0.url == page.urlString }?.customTitle == "Renamed in the second window")

        try await air.host.enable(.spaces, for: air.profile)
        let airSecond = air.addWindow()
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)
        try await air.sync()
        for window in [air.browser, airSecond] {
            #expect(pages(at: page.urlString, in: window).count == 1)
            #expect(pages(at: added.urlString, in: window).count == 1)
            #expect(pages(at: page.urlString, in: window).first?.customTitle == "Renamed in the second window")
        }
        try await air.sync()
        #expect(sharedTabs(in: cloud).count == 2)

        // A close in the second window of one Mac closes the tab in both windows of the other.
        studioSecond.close(try #require(studioSecond.tabs.first { $0.spaceTabID == added.spaceTabID }))
        #expect(studio.browser.tab(id: added.id) == nil)
        try await studio.sync()
        try await air.sync()
        #expect(sharedTabs(in: cloud).compactMap(\.url) == ["https://one.example.test/"])
        for window in [air.browser, airSecond] {
            #expect(pages(at: added.urlString, in: window).isEmpty)
            #expect(pages(at: page.urlString, in: window).count == 1)
        }

        // A remote rename reaches both windows once.
        studio.browser.renameTab(page, to: "Renamed on the Studio")
        try await studio.sync()
        try await air.sync()
        for window in [air.browser, airSecond] {
            #expect(pages(at: page.urlString, in: window).map(\.customTitle) == ["Renamed on the Studio"])
        }
        try await air.sync()
        #expect(sharedTabs(in: cloud).count == 1)
    }
}
