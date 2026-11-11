// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A Passwords window with a stand-in for its content, over a profile catalog of its own: showing the real content would build the
/// credentials page, which opens a vault.
@MainActor
final class PasswordsWindowRig {
    private final class Built {
        var profileIDs: [UUID] = []
    }

    let file: URL
    let catalog: ProfileStore
    /// The selection the window follows: like a browser window's own, over the shared catalog.
    let selection: ProfileStore
    let controller: PasswordsWindow
    private let built: Built

    init() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        self.file = file
        let catalog = ProfileStore(file: file)
        let selection = ProfileStore.selection(profile: .original(), catalog: catalog)
        let built = Built()
        self.built = built
        self.catalog = catalog
        self.selection = selection
        controller = PasswordsWindow(profiles: selection, autosaveName: nil) { profile in
            built.profileIDs.append(profile.id)
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            return controller
        }
    }

    /// The profile of every content the window built, in order.
    var builtProfileIDs: [UUID] {
        built.profileIDs
    }

    /// How many Passwords windows are showing, whichever rig made them.
    static var openWindowCount: Int {
        NSApp.windows.filter { PasswordsWindow.isPasswordsWindow($0) && $0.isVisible }.count
    }

    func tearDown() {
        controller.window?.close()
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
@Suite(.serialized)
struct PasswordsWindowTests {
    @Test func showingTwiceGivesOneWindow() throws {
        let rig = PasswordsWindowRig()
        defer { rig.tearDown() }

        rig.controller.show()
        let first = try #require(rig.controller.window)
        rig.controller.show()

        #expect(rig.controller.window === first)
        #expect(PasswordsWindowRig.openWindowCount == 1)
        #expect(rig.builtProfileIDs.count == 1, "a second show keeps the content, so an open editor is not dropped")
        #expect(first.title == "Passwords")
    }

    @Test func closingDropsTheContentAndTheNextShowBuildsANewOne() throws {
        let rig = PasswordsWindowRig()
        defer { rig.tearDown() }
        rig.controller.show()
        let window = try #require(rig.controller.window)
        #expect(window.contentViewController != nil)

        window.close()

        #expect(window.contentViewController == nil, "the page's unlocked session goes with its content")
        #expect(rig.controller.boundProfileID == nil)
        rig.controller.show()
        #expect(rig.controller.window === window)
        #expect(window.contentViewController != nil)
        #expect(rig.builtProfileIDs.count == 2)
    }

    @Test func theWindowIsNotRestorableAndStaysOnItsOwnSpace() throws {
        let rig = PasswordsWindowRig()
        defer { rig.tearDown() }
        rig.controller.show()
        let window = try #require(rig.controller.window)

        #expect(!window.isRestorable)
        #expect(window.level == .normal)
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!window.collectionBehavior.contains(.stationary))
        #expect(!window.isReleasedWhenClosed)
        #expect(window.contentMinSize == PasswordsWindow.minimumContentSize)
        #expect(!window.isExcludedFromWindowsMenu)
        #expect(PasswordsWindow.frameAutosaveName == "WSurfPasswordsWindow")
    }

    @Test func showingCreatesNoBrowserWindow() {
        let rig = PasswordsWindowRig()
        defer { rig.tearDown() }
        let app = BrowserApplication.shared
        let before = app.windows.count

        rig.controller.show()

        #expect(app.windows.count == before)
    }

    @Test func aPrivateProfileBindsToTheOneToReturnTo() throws {
        let rig = PasswordsWindowRig()
        defer { rig.tearDown() }
        let work = rig.catalog.add(name: "Work")
        rig.selection.markCurrent(work)
        rig.selection.markCurrent(.privateBrowsing())
        #expect(rig.selection.isPrivate)

        rig.controller.show()

        #expect(rig.controller.profile.id == work.id)
        #expect(rig.builtProfileIDs == [work.id])
    }

    @Test func aProfileSwitchRebindsTheContentOfTheOpenWindow() throws {
        let rig = PasswordsWindowRig()
        defer { rig.tearDown() }
        let work = rig.catalog.add(name: "Work")
        rig.selection.markCurrent(work)
        rig.controller.show()
        let window = try #require(rig.controller.window)

        rig.selection.markCurrent(.original())
        rig.controller.show()

        #expect(rig.controller.window === window)
        #expect(rig.builtProfileIDs == [work.id, Profile.original().id])
    }
}
