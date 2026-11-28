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

    private func sharedRecords(_ kind: SharedSpaceItem.Kind, in cloud: FakeSyncCloud) -> [SharedSpaceItem] {
        (cloud.records(in: SharedCatalogCategory.spaces.zone) ?? [])
            .compactMap(SharedSpaceItem.init(record:))
            .filter { $0.kind == kind && !$0.removed }
    }

    @Test func windowLocalAgentTabsPublishOnlyAfterFilingAndCleanupPreservesLegacyCloudRows() async throws {
        let cloud = FakeSyncCloud()
        let mac = Mac(cloud)
        defer { mac.finish() }
        let window = mac.addWindow()
        let space = try #require(mac.store.spaces.first)
        try await mac.host.share(space, in: mac.profile)

        let alreadyShared = window.addPage("https://published-agent.example.test/")
        window.scheduleSave()
        try await mac.sync()
        #expect(mac.host.sharesRow(alreadyShared.id, in: window))
        #expect(alreadyShared.spaceTabID == nil, "Cloud publishes these rows without profile Space-tab links")
        let session = MCPBrowserSession(browser: window, available: { true })
        defer { session.revoke() }
        alreadyShared.staysInItsWindow = true
        session.attributeAgentTab(alreadyShared)
        let disposable = window.addPage("https://disposable-agent.example.test/")
        disposable.staysInItsWindow = true
        session.attributeAgentTab(disposable)

        window.closeAgentTabs(openedBy: session.id)
        #expect(!alreadyShared.isClosed)
        #expect(disposable.isClosed)
        try await mac.sync()
        #expect(sharedTabs(in: cloud).contains { $0.url == alreadyShared.urlString })

        let local = window.addPage("https://local-agent.example.test/")
        local.staysInItsWindow = true
        let localID = local.id
        let address = local.urlString
        try await mac.sync()
        #expect(!sharedTabs(in: cloud).contains { $0.url == address })
        mac.removeWindow(window)

        let restored = mac.restoreWindow(window.windowID, sharesSpaceTabs: false)
        let reopened = try #require(restored.tab(id: localID))
        #expect(reopened.staysInItsWindow)
        #expect(reopened.mcpAgentTabOrigin == nil)
        try await mac.sync()
        #expect(!sharedTabs(in: cloud).contains { $0.url == address })

        restored.createFolder(named: "Filed", containing: [reopened])
        #expect(!reopened.staysInItsWindow)
        try await mac.sync()
        #expect(sharedTabs(in: cloud).contains { $0.url == address })
    }

    /// Two Macs with two windows each share two Spaces. A move between them, a folder and a close each reach both windows.
    @Test func remoteMovesFoldersAndClosesReachEveryWindowThatSharesSpaceTabs() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio", sharesSpaceTabs: true)
        let air = Mac(cloud, name: "Air", sharesSpaceTabs: true)
        defer { studio.finish(); air.finish() }
        let home = try #require(studio.store.spaces.first)
        let work = studio.store.add(name: "Work")
        let studioSecond = studio.addWindow()
        for window in studio.windows {
            window.adoptSpaces(studio.store.spaces.map(\.id))
        }
        let page = studio.browser.addPage("https://moving.example.test/")
        let inner = studioSecond.addPage("https://in-folder.example.test/")
        studioSecond.scheduleSave()
        let folder = studioSecond.createFolder(named: "Reading", containing: [inner])
        studio.browser.scheduleSave()
        #expect(studio.browser.folder(id: folder.id)?.name == "Reading")
        try await studio.host.share(home, in: studio.profile)
        try await studio.host.share(work, in: studio.profile)
        try await studio.sync()
        #expect(sharedRecords(.folder, in: cloud).count == 1)
        #expect(sharedTabs(in: cloud).count == 2)

        try await air.host.enable(.spaces, for: air.profile)
        let airSecond = air.addWindow()
        for remote in air.host.availableSpaces(for: air.profile) {
            try await air.host.join(remote, in: air.profile)
        }
        try await air.sync()
        let joinedWork = try #require(air.host.links[air.profile.id]?.spaces.first { $0.value == studio.host.links[studio.profile.id]?.spaces[work.id] }?.key)
        for window in [air.browser, airSecond] {
            let copy = try #require(pages(at: inner.urlString, in: window).first)
            #expect(window.folder(containing: copy)?.name == "Reading")
            #expect(window.folders.filter { $0.name == "Reading" }.count == 1)
            #expect(pages(at: page.urlString, in: window).count == 1)
        }

        // A move to the other Space on the Studio moves the row in both of the Air's windows.
        studio.browser.move([.tab(page.id)], toSpace: work.id)
        try await studio.sync()
        try await air.sync()
        for window in [air.browser, airSecond] {
            #expect(pages(at: page.urlString, in: window).map(\.spaceID) == [joinedWork])
        }

        // A close in the Studio's second window closes the row in both of the Air's windows.
        let closing = try #require(pages(at: page.urlString, in: studioSecond).first)
        studioSecond.close(closing)
        try await studio.sync()
        try await air.sync()
        for window in [air.browser, airSecond] {
            #expect(pages(at: page.urlString, in: window).isEmpty)
        }
        try await air.sync()
        #expect(sharedTabs(in: cloud).count == 1)
        #expect(sharedRecords(.folder, in: cloud).count == 1)
    }

    enum RemotePinChange: String, CaseIterable, Sendable {
        case deleteInOneWindow, deleteInTwoWindows, unpinInTwoWindows, closeInSecondWindow
    }

    /// A pin removed on another Mac leaves no page behind; one unpinned there is one shared Space tab in every window here.
    @Test(arguments: RemotePinChange.allCases)
    func aPinRemovedOnAnotherMacLeavesEveryWindowConsistent(change: RemotePinChange) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio", sharesSpaceTabs: true)
        let air = Mac(cloud, name: "Air", sharesSpaceTabs: true)
        defer { studio.finish(); air.finish() }
        let address = "https://remote-pin.example.test/"
        let pin = studio.browser.pinned(address)
        let pinID = try #require(pin.pinID)
        _ = try await studio.host.publishProfile(studio.profile)
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.profiles, for: air.profile)
        try await air.host.joinProfile(try #require(air.host.available(.profiles, for: air.profile).first), in: air.profile)
        // The Space too: an unpinned tab joins the shared Space it is in, which a profile alone does not bring.
        try await air.host.enable(.spaces, for: air.profile)
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)
        try await air.sync()
        var windows = [air.browser]
        if change != .deleteInOneWindow {
            windows.append(air.addWindow())
        }
        for window in windows {
            #expect(window.page(for: pinID) != nil)
        }

        switch change {
        case .unpinInTwoWindows:
            studio.browser.unpin(pin)
        case .closeInSecondWindow:
            // Closed on this Mac, in the window iCloud does not follow, while the other window's page holds a live slot.
            let owner = try #require(air.host.spaceTabsOwner(of: air.profile))
            let other = try #require(windows.first { $0 !== owner })
            other.close([.tab(try #require(other.page(for: pinID)).id)])
            for window in windows {
                window.scheduleSave()
            }
            try await air.sync()
        case .deleteInOneWindow, .deleteInTwoWindows:
            studio.browser.close([.tab(pin.id)])
        }
        try await studio.sync()
        try await air.sync()
        try await studio.sync()
        try await air.sync()

        #expect(!air.browser.pinStore.pins.contains { $0.id == pinID })
        let links = Set(windows.flatMap { window in window.tabs.filter { $0.urlString == address }.map(\.spaceTabID) })
        for window in windows {
            let pages = window.tabs.filter { $0.urlString == address }
            #expect(window.pendingPinDemotions.isEmpty)
            #expect(pages.allSatisfy { $0.pinID == nil && $0.pinnedURL == nil })
            if change == .unpinInTwoWindows {
                #expect(pages.count == 1 && pages.first?.spaceTabID != nil)
            } else {
                #expect(pages.isEmpty)
            }
        }
        if change == .closeInSecondWindow {
            #expect(sharedTabs(in: cloud).filter { $0.url == address }.isEmpty)
            #expect(air.browser.pinStore.spaceRows.allSatisfy { $0.url != address })
        }
        if change == .unpinInTwoWindows {
            #expect(links.count == 1)
            #expect(sharedTabs(in: cloud).filter { $0.url == address }.count == 1)
        }
    }

    /// A shared tab pinned in the window iCloud follows keeps its slot. Closing the pin in the other window must close it
    /// everywhere, not bring it back as a shared Space tab from that slot.
    @Test func closingAPinMadeFromASharedTabInAnotherWindowClosesItEverywhere() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio", sharesSpaceTabs: true)
        defer { studio.finish() }
        let address = "https://pinned-from-shared.example.test/"
        let second = studio.addWindow()
        studio.browser.addPage(address)
        studio.browser.scheduleSave()
        _ = try await studio.host.publishProfile(studio.profile)
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        let owner = try #require(studio.host.spaceTabsOwner(of: studio.profile))
        let other = owner === studio.browser ? second : studio.browser
        let ownerPage = try #require(owner.tabs.first { $0.urlString == address })
        owner.pin(ownerPage)
        let pinID = try #require(ownerPage.pinID)
        try await studio.sync()
        #expect(studio.host.links[studio.profile.id]?.slots[ownerPage.id]?.pinID == pinID)

        let otherPin = try #require(other.page(for: pinID))
        other.close([.tab(otherPin.id)])
        for window in [studio.browser, second] {
            window.scheduleSave()
        }
        try await studio.sync()

        for window in [studio.browser, second] {
            #expect(window.tabs.filter { $0.urlString == address }.isEmpty)
            #expect(window.pendingPinDemotions.isEmpty)
        }
        #expect(studio.browser.pinStore.spaceRows.allSatisfy { $0.url != address })
        #expect(sharedTabs(in: cloud).filter { $0.url == address }.isEmpty)
    }

    /// The page goes to a micro window from a window that is not the one iCloud follows, and back. Nothing is uploaded again.
    @Test func aMicroWindowRoundTripFromAnotherWindowKeepsTheSharedRow() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio", sharesSpaceTabs: true)
        defer { studio.finish() }
        let home = try #require(studio.store.spaces.first)
        let studioSecond = studio.addWindow()
        let page = studio.browser.addPage("https://round-trip.example.test/")
        studio.browser.scheduleSave()
        try await studio.host.share(home, in: studio.profile)
        try await studio.sync()
        let record = try #require(sharedTabs(in: cloud).first)
        let owner = try #require(studio.host.spaceTabsOwner(of: studio.profile))
        let window = owner === studio.browser ? studioSecond : studio.browser
        let tab = try #require(pages(at: page.urlString, in: window).first)

        let micro = BrowserModel(context: window.context, windowID: UUID(), database: window.database)
        micro.windowKind = .micro
        let row = window.insertMicroPlaceholder(for: tab)
        try #require(micro.adoptTab(tab, from: window, activate: true))
        #expect(!micro.sharesSpaceTabs)
        try await studio.sync()
        #expect(sharedTabs(in: cloud).map(\.id) == [record.id])
        #expect(owner.tabs.filter { $0.spaceTabID == row.spaceTabID }.count == 1)

        try #require(window.adoptTab(tab, from: micro, activate: true))
        window.settle(tab, into: row)
        window.scheduleSave()
        try await studio.sync()
        #expect(sharedTabs(in: cloud).map(\.id) == [record.id])
        for model in [studio.browser, studioSecond] {
            #expect(pages(at: page.urlString, in: model).count == 1)
        }
        #expect(window.tab(id: tab.id) === tab && tab.spaceTabID != nil)
        micro.closeAllTabs(saving: false)
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
