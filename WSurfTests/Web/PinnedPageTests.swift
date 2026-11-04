// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation
import Testing

@testable import WSurf

/// Everything above the pin line is pinned, and every pinned tab remembers its pinned page: wandering away keeps it
/// pinned and in its place, unloading brings it back, and Update Pinned URL moves the page it returns to.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PinnedPageTests {
    private func model() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    /// A loaded tab showing `address`, set by hand so nothing navigates.
    private func page(_ address: String, in model: BrowserModel, activate: Bool = false) -> BrowserTab {
        let tab = model.newTab(activate: activate)
        tab.urlString = address
        tab.pageTitle = address
        return tab
    }

    /// A pinned folder holding `Inner`, an ordinary folder.
    private func pinnedFolder(in model: BrowserModel) -> (outer: TabFolder, inner: TabFolder) {
        let outer = model.createFolder(named: "Work")
        model.pin(outer)
        let inner = model.createFolder(named: "Inner")
        model.move([.folder(inner.id)], into: outer)
        return (outer, inner)
    }

    // MARK: - The pin line

    @Test func everyTabAboveTheLineIsPinnedAndClosingItUnloads() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, inner) = pinnedFolder(in: model)
        let pin = page("https://pin.test/", in: model)
        model.pin(pin)
        let filed = page("https://filed.test/", in: model)
        model.move([.tab(filed.id)], into: outer)
        let dropped = page("https://dropped.test/", in: model)
        let drag = SidebarDrag(
            items: [.tab(dropped.id)], lead: .tab(dropped.id), origin: .zero,
            tree: model.sidebarTree, keepsSection: true, wasKept: false
        )
        model.move(drag.items, into: inner, settlingPins: false)
        drag.settlePins(model.isPinned(.folder(inner.id)), in: model)
        let loose = page("https://loose.test/", in: model)

        for tab in [pin, filed, dropped] {
            #expect(model.isPinned(.tab(tab.id)), "\(tab.urlString) sits above the line")
            #expect(tab.isPinnedForProfile, "\(tab.urlString) is pinned")
            #expect(tab.pinnedURL?.absoluteString == tab.urlString, "\(tab.urlString) has its pinned page")
            #expect(SidebarTabAction.resolve(isPinned: tab.isPinnedForProfile, isDeferred: false, command: false) == .unload)
        }
        #expect(!model.isPinned(.tab(loose.id)) && !loose.isPinnedForProfile)
        #expect(SidebarTabAction.resolve(isPinned: loose.isPinnedForProfile, isDeferred: false, command: false) == .close)
    }

    @Test func aPinFiledInAPinnedFolderKeepsItsPinnedPage() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, _) = pinnedFolder(in: model)
        let pin = page("https://pin.test/home", in: model)
        model.pin(pin)
        pin.urlString = "https://pin.test/elsewhere"

        model.move([.tab(pin.id)], into: outer)

        #expect(pin.pinnedURL?.absoluteString == "https://pin.test/home")
        #expect(pin.isAwayFromPin)
    }

    @Test func aLinkFromAPinnedFolderPageOpensUnderTheLine() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, _) = pinnedFolder(in: model)
        let filed = page("https://filed.test/", in: model)
        model.move([.tab(filed.id)], into: outer)
        let loose = page("https://loose.test/", in: model)

        let opened = model.newTab(after: filed)

        #expect(model.folder(containing: opened) == nil)
        #expect(model.rows(in: nil) == [.folder(outer.id), .tab(opened.id), .tab(loose.id)])
        #expect(!opened.isPinnedForProfile)
    }

    @Test func unpinningAFolderUnpinsItsPagesAndTheyCanBeClosed() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, inner) = pinnedFolder(in: model)
        let filed = page("https://filed.test/", in: model)
        model.move([.tab(filed.id)], into: inner)
        #expect(filed.isPinnedForProfile)

        model.unpin(outer)

        #expect(!filed.isPinnedForProfile && filed.pinnedURL == nil)
    }

    // MARK: - Migration

    @Test func aPinnedFolderPageWithoutAPinnedPageTakesItsCurrentPageOnce() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, _) = pinnedFolder(in: model)
        let filed = page("https://filed.test/start", in: model)
        // As 0.1.10 left it: a page in a pinned folder with no pinned page of its own.
        model.move([.tab(filed.id)], into: outer, settlingPins: false)
        filed.urlString = "https://filed.test/now"
        #expect(filed.pinnedURL == nil)

        model.attachProfilePins()

        #expect(filed.pinnedURL?.absoluteString == "https://filed.test/now")
        #expect(filed.pinnedTitle == filed.title)
        let row = model.pinStore.pins.first { $0.id == filed.pinID }
        #expect(row?.pinnedURL?.absoluteString == "https://filed.test/now", "the profile keeps it for every window")

        filed.urlString = "https://filed.test/later"
        model.settlePinnedPages()
        #expect(filed.pinnedURL?.absoluteString == "https://filed.test/now", "only once")
    }

    // MARK: - Navigating

    @Test func navigatingInAPinnedTabKeepsItPinnedAndInPlace() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, _) = pinnedFolder(in: model)
        let pin = page("https://pin.test/", in: model)
        model.pin(pin)
        let filed = page("https://filed.test/", in: model)
        model.move([.tab(filed.id)], into: outer)
        page("https://loose.test/", in: model)
        let root = model.rows(in: nil)
        let held = model.rows(in: outer)

        // Same site, another site: both only change the address the tab shows.
        pin.urlString = "https://pin.test/inbox"
        filed.urlString = "https://elsewhere.test/"
        model.scheduleSave()

        #expect(model.rows(in: nil) == root)
        #expect(model.rows(in: outer) == held)
        for tab in [pin, filed] {
            #expect(tab.isPinnedForProfile)
            #expect(tab.isAwayFromPin, "\(tab.urlString) shows it has left its pinned page")
        }
        #expect(pin.pinnedURL?.absoluteString == "https://pin.test/")
        #expect(filed.pinnedURL?.absoluteString == "https://filed.test/")
    }

    // MARK: - Unloading

    @Test(arguments: [false, true])
    func unloadingAPinnedTabBringsBackItsPinnedPage(bySleeping: Bool) {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        page("https://other.test/", in: model, activate: true)
        let pin = page("https://pin.test/home", in: model)
        model.pin(pin)
        pin.realizeDeferredSession()
        pin.urlString = "https://away.test/deep"
        pin.pageTitle = "Away"
        #expect(pin.isMaterialised)

        if bySleeping {
            #expect(model.discardBackgroundTabs() == 1)
        } else {
            #expect(model.unload(pin))
        }

        #expect(pin.isDeferred && !pin.isMaterialised)
        #expect(pin.urlString == "https://pin.test/home")
        #expect(pin.pageTitle == "https://pin.test/home")
        #expect(pin.sessionState == nil, "the history made away from the pinned page is not restored")
        #expect(pin.pinnedURL?.absoluteString == "https://pin.test/home")
        #expect(!pin.isAwayFromPin)

        model.activate(pin)
        #expect(pin.urlString == "https://pin.test/home")
    }

    /// A pinned new tab keeps the Start page: unloading it away, or Back to Pinned Page, brings back the Start page.
    @Test func aPinnedNewTabComesBackOnTheStartPage() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        page("https://other.test/", in: model, activate: true)
        let (outer, _) = pinnedFolder(in: model)
        let fresh = model.newTab(activate: false)
        model.pin(fresh)
        let filed = model.newTab(activate: false)
        model.move([.tab(filed.id)], into: outer)

        for tab in [fresh, filed] {
            #expect(tab.pinnedURL == SystemPages.start)
            #expect(tab.isShowingPin && !tab.isAwayFromPin)
        }

        fresh.urlString = "https://away.test/"
        #expect(fresh.isAwayFromPin && !fresh.isShowingPin)
        #expect(model.unload(fresh))
        #expect(fresh.isDeferred)
        #expect(fresh.urlString == SystemPages.start.absoluteString)
        #expect(fresh.pageTitle == SystemPages.startTitle)
        #expect(fresh.isShowingPin && !fresh.isAwayFromPin)
        model.activate(fresh)
        #expect(fresh.urlString == SystemPages.start.absoluteString)

        filed.urlString = "https://away.test/"
        model.returnToPin(filed)
        #expect(filed.urlString == SystemPages.start.absoluteString)
        #expect(filed.isShowingPin && !filed.isAwayFromPin)
    }

    @Test func unloadingAnOrdinaryTabKeepsItsPage() {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        page("https://other.test/", in: model, activate: true)
        let loose = page("https://loose.test/deep", in: model)

        #expect(model.unload(loose))

        #expect(loose.urlString == "https://loose.test/deep")
    }

    // MARK: - Update Pinned URL

    @Test(arguments: [false, true])
    func updatingThePinnedURLIsOneUndoStepAndKeepsThePlace(inFolder: Bool) {
        let model = model()
        defer { model.closeAllTabs(saving: false) }
        let (outer, _) = pinnedFolder(in: model)
        let tab = page("https://pin.test/home", in: model)
        if inFolder {
            model.move([.tab(tab.id)], into: outer)
        } else {
            model.pin(tab)
        }
        page("https://loose.test/", in: model)
        tab.urlString = "https://pin.test/inbox"
        tab.pageTitle = "Inbox"
        let root = model.rows(in: nil)
        let held = model.rows(in: outer)
        model.sidebarUndoManager.removeAllActions()

        model.pin(tab)

        #expect(tab.pinnedURL?.absoluteString == "https://pin.test/inbox")
        #expect(tab.pinnedTitle == "Inbox")
        #expect(!tab.isAwayFromPin)
        #expect(model.rows(in: nil) == root)
        #expect(model.rows(in: outer) == held)
        #expect(model.sidebarUndoManager.undoActionName == "Update Pinned URL")

        model.sidebarUndoManager.undo()
        #expect(tab.pinnedURL?.absoluteString == "https://pin.test/home")
        #expect(tab.isAwayFromPin)
        #expect(!model.sidebarUndoManager.canUndo, "one step")

        model.sidebarUndoManager.redo()
        #expect(tab.pinnedURL?.absoluteString == "https://pin.test/inbox")
    }

    // MARK: - Persistence

    @Test func theUpdatedPinnedPageReachesTheProfileAndSurvivesARestart() {
        let database = AppDatabase.temporary()
        let windowID = UUID()
        let first = BrowserModel(windowID: windowID, database: database)
        first.attachProfilePins()
        let (outer, _) = pinnedFolder(in: first)
        let filed = page("https://filed.test/", in: first)
        first.move([.tab(filed.id)], into: outer)
        filed.urlString = "https://filed.test/updated"
        first.pin(filed)

        let other = BrowserModel(windowID: UUID(), database: database)
        other.attachProfilePins()
        let copy = other.page(for: filed.pinID)
        #expect(copy !== filed)
        #expect(copy?.pinnedURL?.absoluteString == "https://filed.test/updated")
        other.closeAllTabs(saving: false)

        first.saveBlocking()
        first.markSessionClosed()
        first.closeAllTabs(saving: false)
        let back = BrowserModel(windowID: windowID, database: database)
        back.restoreSession()
        defer { back.closeAllTabs(saving: false) }
        #expect(back.tab(id: filed.id)?.pinnedURL?.absoluteString == "https://filed.test/updated")
        #expect(back.tab(id: filed.id).map { back.isPinned(.tab($0.id)) } == true)
    }
}
