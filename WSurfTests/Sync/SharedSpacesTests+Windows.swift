// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    enum ClosedWindow {
        case neither, folder, page
    }

    @Test(arguments: [ClosedWindow.neither, .folder, .page])
    func aRemoteFolderMoveFollowsTheFolderAcrossWindows(closed: ClosedWindow) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }

        let home = try #require(studio.store.spaces.first)
        let page = studio.browser.addPage("https://moved.example.test/")
        let folder = studio.browser.createFolder(named: "Reading")
        try await studio.host.share(home, in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)

        let folderWindow = air.browser
        let pageWindow = air.addWindow()
        let copy = try #require(folderWindow.page(at: page.urlString))
        let joined = try #require(copy.spaceID)
        pageWindow.switchSpace(to: joined)
        try #require(pageWindow.adoptTab(copy, from: folderWindow, activate: false))
        let keepFolder = folderWindow.addPage("file:///local/folder-window")
        let keepPage = pageWindow.addPage("file:///local/page-window")
        folderWindow.activeTabID = keepFolder.id
        pageWindow.activeTabID = keepPage.id
        try await air.sync()
        try await studio.sync()

        let sleeping: BrowserModel? = switch closed {
        case .neither:
            nil
        case .folder:
            folderWindow
        case .page:
            pageWindow
        }
        sleeping?.markSessionClosed()
        sleeping?.closeAllTabs(saving: false)
        studio.browser.move(page, to: folder)
        try await studio.sync()
        try await air.sync()
        if closed == .folder {
            try #require(pageWindow.tab(id: copy.id) === copy)
            pageWindow.renameTab(copy, to: "Edited while waiting")
        }
        // An ordinary save captures the rows visible on this Mac while the other window is closed.
        for window in air.windows where window.sessionClosedAt == nil {
            window.scheduleSave()
        }
        try await air.sync()
        try await studio.sync()
        #expect(studio.browser.folder(containing: page)?.id == folder.id)
        if closed == .folder {
            #expect(page.customTitle == "Edited while waiting")
        }

        sleeping?.restoreSession()
        let moved = try #require(folderWindow.tab(id: copy.id))
        if closed != .page {
            #expect(moved === copy)
        }
        #expect(folderWindow.folder(containing: moved)?.name == "Reading")
        #expect(pageWindow.tab(id: copy.id) == nil)
        #expect(folderWindow.activeTabID == keepFolder.id && pageWindow.activeTabID == keepPage.id)
        #expect(folderWindow.tab(id: keepFolder.id)?.urlString == keepFolder.urlString)
        #expect(pageWindow.tab(id: keepPage.id)?.urlString == keepPage.urlString)
        for window in air.windows {
            window.scheduleSave()
        }
        try await air.sync()
        try await studio.sync()
        #expect(studio.browser.folder(containing: page)?.id == folder.id)
    }

    @Test func aNewChildWaitsForItsClosedFolderWindow() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let folder = studio.browser.createFolder(named: "Reading")
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)
        let other = air.addWindow()
        air.browser.markSessionClosed()
        air.browser.closeAllTabs(saving: false)
        let page = studio.browser.addPage("https://new-child.example.test/")
        studio.browser.move(page, to: folder)
        try await studio.sync()
        try await air.sync()
        #expect(other.page(at: page.urlString) == nil)
        air.browser.restoreSession()
        let received = try #require(air.browser.page(at: page.urlString))
        #expect(air.browser.folder(containing: received)?.name == "Reading")
        #expect(other.page(at: page.urlString) == nil)
    }

    @Test func gatheringKeepsTheRemoteParentWhileItsWindowIsClosed() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let space = try #require(air.store.spaces.first)
        let source = air.addWindow()
        let sleeping = air.addWindow()
        let held = source.createFolder(named: "Held")
        let newParent = sleeping.createFolder(named: "New parent")
        let page = source.addPage("https://waiting-to-move.example.test/")
        source.move(page, to: held)
        let kept = air.browser.addPage("https://stays-put.example.test/")
        try await air.host.share(space, in: air.profile)
        try await air.sync()
        try await studio.host.enable(.spaces, for: studio.profile)
        try await studio.host.join(try #require(studio.host.availableSpaces(for: studio.profile).first), in: studio.profile)
        let remote = try #require(studio.browser.page(at: page.urlString))
        let remoteParent = try #require(studio.browser.folders.first { $0.name == newParent.name })
        sleeping.markSessionClosed()
        sleeping.closeAllTabs(saving: false)
        studio.browser.move(remote, to: remoteParent)
        try await studio.sync()
        try await air.sync()
        #expect(source.folder(containing: page) === held)
        let entry = SpaceEntry(space: space, profile: air.profile)
        let originalOrder = air.host.links[air.profile.id]?.slots[kept.id]?.last?.order
        try air.host.gatherSharedRoots([.folder(held.id)], in: entry, from: source, into: air.browser)
        #expect(air.browser.folder(containing: page) === held)
        air.browser.scheduleSave()
        try await air.sync()
        try await studio.sync()
        #expect(air.host.links[air.profile.id]?.slots[kept.id]?.last?.order == originalOrder)
        #expect(studio.browser.folder(containing: remote) === remoteParent)
    }

    @Test func aRemoteMoveKeepsTheFolderAndItsDeviceOnlyContentsTogether() async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud)
        let air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let home = try #require(air.store.spaces.first)
        let other = air.addWindow()
        let target = air.browser.createFolder(named: "Target")
        let subfolder = other.createFolder(named: "Local grouping")
        let shared = other.addPage("https://inside.example.test/")
        let deviceOnly = other.addPage("file:///local/in-folder")
        other.move([.tab(shared.id), .tab(deviceOnly.id)], into: subfolder)
        let child = other.createFolder(named: "Child", containing: [SidebarItem.folder(subfolder.id)])
        let selectedHere = air.browser.addPage("file:///local/stays-here")
        let selectedThere = other.addPage("file:///local/stays-there")
        air.browser.activeTabID = selectedHere.id
        other.activeTabID = selectedThere.id
        try await air.host.share(home, in: air.profile)
        try await air.sync()
        try await studio.host.enable(.spaces, for: studio.profile)
        try await studio.host.join(try #require(studio.host.availableSpaces(for: studio.profile).first), in: studio.profile)
        let move = try #require(studio.browser.folders.first { $0.name == "Child" })
        let into = try #require(studio.browser.folders.first { $0.name == "Target" })
        studio.browser.move([.folder(move.id)], into: into)
        try await studio.sync()
        try await air.sync()

        #expect(air.browser.folder(id: child.id) === child && other.folder(id: child.id) == nil)
        #expect(air.browser.reconciledTree().parent(of: .folder(child.id)) == target.id)
        #expect(air.browser.reconciledTree().parent(of: .folder(subfolder.id)) == child.id)
        #expect(air.browser.tab(id: shared.id) === shared && air.browser.tab(id: deviceOnly.id) === deviceOnly)
        #expect(air.browser.folder(containing: deviceOnly)?.id == subfolder.id)
        #expect(air.browser.activeTabID == selectedHere.id && other.activeTabID == selectedThere.id)
        air.browser.scheduleSave()
        other.scheduleSave()
        try await air.sync()
        try await studio.sync()
        #expect(studio.browser.reconciledTree().parent(of: .folder(move.id)) == into.id)
        #expect(studio.browser.page(at: deviceOnly.urlString) == nil)
    }

    @Test func simultaneousFolderMovesKeepEachBranchWithItsNewParent() async throws {
        let cloud = FakeSyncCloud()
        let air = Mac(cloud)
        let studio = Mac(cloud)
        defer { air.finish(); studio.finish() }
        let other = air.addWindow()
        let separate = air.browser.createFolder(named: "Separate")
        let leaf = air.browser.createFolder(named: "Leaf")
        let group = air.browser.createFolder(named: "Group", containing: [SidebarItem.folder(leaf.id)])
        let inside = other.createFolder(named: "Inside")
        _ = other.createFolder(named: "Outside", containing: [SidebarItem.folder(inside.id)])
        try await air.host.share(try #require(air.store.spaces.first), in: air.profile)
        try await air.sync()
        try await studio.host.enable(.spaces, for: studio.profile)
        try await studio.host.join(try #require(studio.host.availableSpaces(for: studio.profile).first), in: studio.profile)
        func onStudio(_ name: String) throws -> TabFolder {
            try #require(studio.browser.folders.first { $0.name == name })
        }
        let moving = try onStudio("Group")
        let detaching = try onStudio("Leaf")
        studio.browser.move([.folder(detaching.id)], into: try onStudio("Separate"))
        studio.browser.move([.folder(moving.id)], into: try onStudio("Inside"))
        try await studio.sync()
        try await air.sync()
        #expect(air.browser.folder(id: leaf.id) === leaf)
        #expect(air.browser.reconciledTree().parent(of: .folder(leaf.id)) == separate.id)
        #expect(other.folder(id: group.id) === group)
        #expect(other.reconciledTree().parent(of: .folder(group.id)) == inside.id)
    }
}
