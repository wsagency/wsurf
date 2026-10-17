// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// A fresh profile for each test, so no test reaches the default profile's store, which the whole test process shares.
@MainActor
private final class PinFixture {
    let profile = Profile(id: UUID(), name: "Pin fixture", symbol: "pin", color: .gray)
    let context: BrowserProfileContext
    private(set) var windows: [BrowserModel] = []
    private var closedTabs: [BrowserTab] = []

    init() {
        context = BrowserProfileContext.shared(for: profile)
    }

    /// A window of the profile, ready as the app prepares a new one.
    func window(id: UUID = UUID()) -> BrowserModel {
        let model = BrowserModel(context: context, windowID: id)
        model.attachProfilePins()
        windows.append(model)
        return model
    }

    /// The window as the app brings it back from its saved session.
    func reopen(_ closed: BrowserModel) -> BrowserModel {
        let model = BrowserModel(context: context, windowID: closed.windowID)
        model.restoreSession()
        windows.append(model)
        return model
    }

    /// Closes a window the way the user does.
    func close(_ window: BrowserModel) {
        closedTabs += window.tabs
        window.markSessionClosed()
        window.closeAllTabs(saving: false)
    }

    var pins: [ProfilePin] {
        ProfilePinStore.store(for: context.database).pins
    }

    func storedPins() throws -> [ProfilePin] {
        ProfilePin.depthFirst(try context.database.writer.read { try ProfilePin.fetchAll($0) })
    }

    /// Every attached window already shows exactly the stored set, so it has nothing left to publish.
    func expectConverged(sourceLocation: SourceLocation = #_sourceLocation) {
        for window in windows where window.attachedPinStore != nil {
            var next = window.profilePinProjection(previous: pins)
            ProfilePin.assignOrderKeys(&next, previous: pins)
            #expect(next == pins, sourceLocation: sourceLocation)
        }
    }

    func tearDown() async {
        let tabs = closedTabs + windows.flatMap(\.tabs)
        for window in windows {
            window.closeAllTabs(saving: false)
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        await context.sitePermissions.waitForPendingSave()
        BrowserProfileContext.forget(profile.id)
        ProfileSettingsStore.forget(profile.id)
        try? FileManager.default.removeItem(at: profile.supportDirectory)
        try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
    }
}

private func withPins(_ body: (PinFixture) async throws -> Void) async throws {
    let fixture = PinFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.tearDown()
        throw error
    }
    await fixture.tearDown()
}

@MainActor
@Suite(.serialized)
struct ProfilePinTests {
    /// A pin, a Favorite and a pinned folder holding a bookmarked page, a plain page and a folder with a page.
    private func populate(_ window: BrowserModel) {
        window.pinned("https://a.example/")
        window.addFavorite(window.addPage("https://fav.example/"))
        let work = window.createFolder(named: "Work")
        window.pin(work)
        let bookmarked = window.pinned("https://work.example/d")
        window.move([.tab(bookmarked.id)], into: work, settlingPins: false)
        window.move([.tab(window.addPage("https://work.example/e").id)], into: work, settlingPins: false)
        let nested = window.createFolder(named: "Nested")
        window.move([.folder(nested.id)], into: work, settlingPins: false)
        window.move([.tab(window.addPage("https://work.example/f").id)], into: nested, settlingPins: false)
    }

    private static let populated = """
        https://a.example/ ★https://fav.example/ \
        Work[https://work.example/d https://work.example/e Nested[https://work.example/f]]
        """

    @Test(.boundedWebViews) func pinsSurviveClosingEveryWindow() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            populate(first)
            #expect(first.pinOutline == Self.populated)
            #expect(second.pinOutline == Self.populated)
            let folderIDs = Set(first.folders.map(\.id))
            let before = try fixture.storedPins()
            #expect(before.count == 7)

            fixture.close(first)
            fixture.close(second)
            let after = try fixture.storedPins()
            #expect(after == before)

            let third = fixture.window()
            #expect(third.pinOutline == Self.populated)
            #expect(Set(third.folders.map(\.id)) == folderIDs)
            #expect(third.favorites.map(\.urlString) == ["https://fav.example/"])
            fixture.expectConverged()
        }
    }

    @Test(.boundedWebViews) func aNewWindowShowsTheProfilesPinsFoldersAndFavorites() async throws {
        try await withPins { fixture in
            populate(fixture.window())
            let fresh = fixture.window()
            #expect(fresh.activeTabID == nil)
            // The app opens a tab of the window's own once the pins are in place.
            let own = fresh.newTab()

            #expect(fresh.pinOutline == Self.populated)
            #expect(fresh.activeTabID == own.id)
            #expect(fresh.sidebarItems.last == .tab(own.id))
            let copies = fresh.tabs.filter { $0 !== own && !$0.isFavorite }
            #expect(copies.count == 4)
            #expect(copies.allSatisfy { $0.isDeferred && !$0.isMaterialised })
            fixture.expectConverged()
        }
    }

    @Test func pinningInOneWindowShowsInTheOtherWithoutSharingThePage() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let page = first.pinned("https://one.example/")
            let copy = try #require(second.page(for: page.pinID))

            #expect(copy !== page && copy.id != page.id)
            #expect(copy.pinnedURL == page.pinnedURL)
            #expect(copy.isDeferred && !copy.isMaterialised)
            #expect(second.tabs.count == 1)

            // Where one window's page goes does not change the pin, and so does not reach the other window.
            let before = fixture.pins
            copy.urlString = "https://one.example/next"
            second.scheduleSave()
            #expect(page.urlString == "https://one.example/")
            #expect(fixture.pins == before)
            fixture.expectConverged()
        }
    }

    @Test(.boundedWebViews) func eachWindowKeepsItsOwnPageForTheSamePin() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let page = first.pinned("https://one.example/")
            let copy = try #require(second.page(for: page.pinID))
            let loose = second.addPage("https://loose.example/")
            second.activate(loose)
            copy.urlString = "https://one.example/next"
            second.saveBlocking()
            fixture.close(second)

            let restored = fixture.reopen(second)
            let comeBack = try #require(restored.page(for: page.pinID))
            #expect(comeBack.urlString == "https://one.example/next")
            #expect(comeBack.id == copy.id)
            #expect(restored.page(at: "https://loose.example/") != nil)
            #expect(restored.tabs.count == 2)
            #expect(page.urlString == "https://one.example/")
            let brandNew = fixture.window()
            #expect(brandNew.page(for: page.pinID)?.urlString == "https://one.example/")
            fixture.expectConverged()
        }
    }

    @Test(.boundedWebViews) func removingAPinElsewhereKeepsALoadedCopyAsAnOrdinaryTab() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let third = fixture.window()
            first.pinned("https://keep.example/")
            let doomed = first.pinned("https://gone.example/")
            let open = try #require(second.page(for: doomed.pinID))
            open.realizeDeferredSession()
            #expect(open.isMaterialised && !open.isDeferred)

            first.close([.tab(doomed.id)])

            #expect(second.tab(id: open.id) === open)
            #expect(open.pinID == nil && open.pinnedURL == nil && !open.isFavorite)
            let kept = try #require(second.page(at: "https://keep.example/"))
            #expect(second.sidebarItems == [.tab(kept.id), .tab(open.id)])
            #expect(third.tabs.map(\.urlString) == ["https://keep.example/"])
            #expect(first.tabs.map(\.urlString) == ["https://keep.example/"])
            fixture.expectConverged()
        }
    }

    @Test(.boundedWebViews) func unloadingAPinLeavesOtherWindowsAlone() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let page = first.pinned("https://one.example/")
            let copy = try #require(second.page(for: page.pinID))
            page.realizeDeferredSession()
            copy.realizeDeferredSession()
            let before = fixture.pins

            #expect(first.unload(page))

            #expect(page.isDeferred)
            #expect(copy.isMaterialised && !copy.isDeferred)
            #expect(fixture.pins == before)
            fixture.expectConverged()
        }
    }

    @Test func undoingRemoveTabRestoresThePinInEveryWindow() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let page = first.pinned("https://one.example/")
            first.pinned("https://two.example/")
            let pinID = page.pinID

            first.close([.tab(page.id)])
            #expect(first.pinOutline == "https://two.example/")
            #expect(second.pinOutline == "https://two.example/")

            first.sidebarUndoManager.undo()
            #expect(first.pinOutline == "https://one.example/ https://two.example/")
            #expect(second.pinOutline == "https://one.example/ https://two.example/")
            #expect(second.page(for: pinID) != nil)
            fixture.expectConverged()
        }
    }

    @Test func renamingAndReorderingPinsReachEveryWindow() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let one = first.pinned("https://one.example/")
            let two = first.pinned("https://two.example/")
            let work = first.createFolder(named: "Work")
            first.pin(work)
            first.move([.tab(first.addPage("https://work.example/").id)], into: work, settlingPins: false)

            first.renameTab(one, to: "Uno")
            first.renameFolder(work, to: "Job")
            first.setFolderColor(.red, for: work)
            work.isExpanded = false
            first.scheduleSave()
            first.move([.tab(two.id)], into: nil, before: .tab(one.id))

            #expect(first.pinOutline == "https://two.example/ https://one.example/ Job[https://work.example/]")
            #expect(second.pinOutline == first.pinOutline)
            #expect(second.page(for: one.pinID)?.customTitle == "Uno")
            let job = try #require(second.folder(id: work.id))
            #expect(job.name == "Job" && job.color == .red && !job.isExpanded)

            // Unpinning the folder in one window removes it from the others.
            second.unpin(job)
            #expect(first.folder(id: work.id) == nil)
            #expect(first.pinOutline == "https://two.example/ https://one.example/")
            #expect(second.folder(id: work.id) != nil)
            fixture.expectConverged()
        }
    }

    @Test(.boundedWebViews) func favoritesStripMatchesInEveryWindow() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let one = first.addPage("https://one.example/")
            let two = first.addPage("https://two.example/")
            first.addFavorite(one)
            first.addFavorite(two)

            #expect(first.favorites.map(\.urlString) == ["https://one.example/", "https://two.example/"])
            #expect(second.favorites.map(\.urlString) == first.favorites.map(\.urlString))
            // Every window loads its Favorites, as a restored window does.
            #expect(second.favorites.allSatisfy { !$0.isDeferred })

            first.removeFavorite(one)
            #expect(second.favorites.map(\.urlString) == ["https://two.example/"])
            #expect(second.page(for: one.pinID)?.pinnedURL != nil)
            fixture.expectConverged()
        }
    }

    @Test func pinningAFolderChildKeepsItsPageInOtherWindows() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let work = first.createFolder(named: "Work")
            first.pin(work)
            let child = first.addPage("https://work.example/")
            first.move([.tab(child.id)], into: work, settlingPins: false)
            let copy = try #require(second.page(for: child.pinID))
            #expect(child.pinnedURL == nil)

            first.pinAtTop([.tab(child.id)])

            #expect(second.page(for: child.pinID) === copy)
            #expect(copy.pinnedURL != nil)
            #expect(second.pinOutline == "Work[] https://work.example/")
            fixture.expectConverged()
        }
    }

    @Test func keptItemsOfAnUnattachedWindowJoinTheProfileWhenItAttaches() async throws {
        try await withPins { fixture in
            let old = BrowserModel(context: fixture.context, windowID: UUID())
            old.pinned("https://one.example/")
            let work = old.createFolder(named: "Work")
            old.pin(work)
            old.move([.tab(old.addPage("https://work.example/").id)], into: work, settlingPins: false)
            old.saveBlocking()
            let empty = try fixture.storedPins()
            #expect(empty.isEmpty)

            let restored = fixture.reopen(old)
            let adopted = try fixture.storedPins()
            #expect(adopted.count == 3)
            let other = fixture.window()
            #expect(other.pinOutline == "https://one.example/ Work[https://work.example/]")
            #expect(restored.pinOutline == other.pinOutline)
            fixture.expectConverged()
        }
    }

    @Test(.boundedWebViews) func closingAWindowNeverRemovesProfilePins() async throws {
        try await withPins { fixture in
            let first = fixture.window()
            let second = fixture.window()
            let third = fixture.window()
            populate(first)
            let pins = fixture.pins
            #expect(pins.count == 7)

            // The user closes a window.
            fixture.close(second)
            second.scheduleSave()
            #expect(fixture.pins == pins)

            // A quit empties every window without recording any as closed.
            third.closeAllTabs(saving: false)
            third.scheduleSave()
            #expect(fixture.pins == pins)

            // A window that switches profile stops sharing this one's pins.
            first.adopt(database: .temporary(), sitePermissions: fixture.context.sitePermissions)
            first.scheduleSave()
            let afterSwitch = try fixture.storedPins()
            #expect(afterSwitch == pins)

            first.closeAllTabs(saving: false)
            let afterClose = try fixture.storedPins()
            #expect(afterClose == pins)
            #expect(fixture.window().pinOutline == Self.populated)
        }
    }

    @Test(.boundedWebViews) func aRestartPreservesProfileFolderIDsAndOrder() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfilePins-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var written: [ProfilePin] = []
        do {
            let database = AppDatabase(at: file)
            let window = BrowserModel(windowID: UUID(), database: database)
            window.attachProfilePins()
            populate(window)
            window.pinned("https://z.example/")
            written = window.pinStore.pins
            let tabs = window.tabs
            window.markSessionClosed()
            window.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
        }
        #expect(written.count == 8)

        let reopened = AppDatabase(at: file)
        let fresh = BrowserModel(windowID: UUID(), database: reopened)
        fresh.attachProfilePins()
        #expect(fresh.pinStore.pins == written)
        #expect(fresh.pinOutline == Self.populated + " https://z.example/")
        let folderIDs: Set<UUID> = Set(written.filter { $0.kind == .folder }.map { $0.id })
        #expect(Set(fresh.folders.map { $0.id }) == folderIDs)
        let tabs = fresh.tabs
        fresh.closeAllTabs(saving: false)
        for tab in tabs {
            await tab.waitForRetirement()
        }
    }

    @Test func privateWindowsNeitherSeeNorChangeProfilePins() async throws {
        try await withPins { fixture in
            let regular = fixture.window()
            regular.pinned("https://one.example/")
            let pins = fixture.pins
            let rows = try fixture.storedPins()

            let privateContext = BrowserProfileContext.shared(for: .privateBrowsing())
            let secret = BrowserModel(context: privateContext, windowID: UUID())
            secret.attachProfilePins()
            #expect(secret.tabs.isEmpty)
            secret.pinned("https://secret.example/")
            #expect(secret.pinOutline == "https://secret.example/")
            #expect(regular.pinOutline == "https://one.example/")
            #expect(fixture.pins == pins)
            let unchanged = try fixture.storedPins()
            #expect(unchanged == rows)

            // A regular window that turns private leaves the profile's pins alone as well.
            let turning = fixture.window()
            turning.adopt(
                database: .temporary(), sitePermissions: privateContext.sitePermissions, privately: true
            )
            turning.pinned("https://also-secret.example/")
            let afterTurning = try fixture.storedPins()
            #expect(afterTurning == rows)
            #expect(regular.pinOutline == "https://one.example/")

            secret.closeAllTabs(saving: false)
            await privateContext.endPrivateSession()
            await turning.context.endPrivateSession()
        }
    }
}
