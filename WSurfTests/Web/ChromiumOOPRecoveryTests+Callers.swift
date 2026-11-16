// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import CefKit
@testable import WSurf

/// The third group of `ChromiumOOPRecoveryTests` (delta review of #130): which callers count as a person's action while the service
/// is given up. A window of a whole app runs on a connection that has no service and is in a crash loop; a caller that is not a
/// person's leaves the loop alone (no hello, the state still `.crashLooping`), one that is gives it up and asks for the service.
extension ChromiumOOPRecoveryTests {
    @MainActor
    struct Callers {
        let connection: ChromiumRemote
        let app: BrowserApplication
        let profile: Profile
        let window: AppCoordinator
        let hellos: Int

        /// Nothing asked for the service since the loop began, also not a moment later (the engine switch of a tab and its load are
        /// asynchronous).
        func loopIsUntouched() async -> Bool {
            try? await Task.sleep(for: .seconds(1))
            return connection.isGivenUp && connection.helloCount == hellos
        }
        /// A person's action gave the loop up and asked for the service (`userReload`, then a hello). A connection with no service
        /// fails that hello soon after, so the count is read, not the state.
        func loopWasEnded() async -> Bool {
            await waitUntil(timeout: .seconds(10)) { connection.helloCount > hellos }
        }
        /// The tab has its Chromium page: its site is set to Chromium, so what the test is about is the service.
        func hasChromiumPage(_ tab: BrowserTab) async -> Bool {
            await waitUntil(timeout: .seconds(10)) { tab.page.chromium != nil }
        }
    }

    /// A window of a profile whose site `address` is set to Chromium, in a crash loop of a connection of its own.
    func withCrashLoopedWindow(_ body: (Callers) async throws -> Void) async throws {
        let connection = makeConnection()
        ChromiumPage.testConnection = connection
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Recovery callers")
        let app = BrowserApplication(
            defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter(), ownsSession: true)
        let window = app.newWindow(profile: profile, show: false)
        window.context.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: Self.address))
        let old = RealTab(connection, withBrowser: true)
        var failure: (any Error)?
        do {
            crashLoop(connection, with: [old])
            #expect(connection.state == .crashLooping)
            try await body(Callers(connection: connection, app: app, profile: profile, window: window, hellos: connection.helloCount))
        } catch {
            failure = error
        }
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        ChromiumPage.testConnection = nil
        connection.disconnect()
        await old.end()
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    /// D1: an extension's `windows.create` is not a person's action. Run on a timer it would otherwise relaunch the service every
    /// launchd throttle.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func anExtensionWindowOpenedDuringACrashLoopDoesNotEndIt() async throws {
        try await withCrashLoopedWindow { rig in
            _ = rig.app.openExtensionWindow(
                for: rig.window.extensions, profile: rig.profile, privately: false, focused: false, urls: [Self.address], tabs: [])
            let opened = try #require(rig.app.windows.last { $0 !== rig.window })
            let tab = try #require(opened.browser.tabs.first { $0.urlString == Self.address.absoluteString })
            #expect(await rig.hasChromiumPage(tab))
            #expect(await rig.loopIsUntouched(), "an extension's window does not end the loop (state \(rig.connection.state))")
            tab.reload(byPerson: true)
            #expect(await rig.loopWasEnded(), "the person's Reload in it does")
        }
    }

    /// S2: a URL from another app (`open https://…`, Handoff) may be a script's, so it does not end the loop; the tab keeps the
    /// address and the person's Reload loads it.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aUrlFromAnotherAppDuringACrashLoopDoesNotEndItAndItsTabReloads() async throws {
        try await withCrashLoopedWindow { rig in
            rig.window.openFromAnotherApp([Self.address])
            let tab = try #require(rig.window.browser.tabs.first { $0.urlString == Self.address.absoluteString })
            #expect(await rig.hasChromiumPage(tab))
            #expect(await rig.loopIsUntouched(), "a URL from another app does not end the loop (state \(rig.connection.state))")
            tab.reload(byPerson: true)
            #expect(await rig.loopWasEnded(), "a Reload of the tab does")
        }
    }

    /// The same URL typed into a new tab, as a control: the person's own `openNewTab` ends the loop.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aTabThePersonOpensDuringACrashLoopEndsIt() async throws {
        try await withCrashLoopedWindow { rig in
            rig.window.openNewTab(url: Self.address)
            #expect(await rig.loopWasEnded())
        }
    }

    /// S3: a page's own `window.open` (no click behind it) is never a person's action; a click's tab is.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aScriptsPopUpDuringACrashLoopDoesNotEndItButAClickedLinkDoes() async throws {
        try await withCrashLoopedWindow { rig in
            let opener = URL(string: "https://opener.example/")!
            let tab = try #require(rig.window.browser.activeTab)
            rig.window.browser.sitePermissions.setPopups(.allow, for: SitePermissions.origin(for: opener))
            tab.popups.pageChanged(url: opener)
            tab.openChromiumWindow(Self.address, userGesture: false, sourceURL: opener, sourceFrame: nil)
            let popped = try #require(rig.window.browser.tabs.first { $0.urlString == Self.address.absoluteString })
            #expect(await rig.hasChromiumPage(popped))
            #expect(await rig.loopIsUntouched(), "a script's pop-up does not end the loop (state \(rig.connection.state))")
            tab.openChromiumWindow(Self.address, userGesture: true, sourceURL: opener, sourceFrame: nil, click: .backgroundTab)
            #expect(await rig.loopWasEnded(), "a click on a link does")
        }
    }

    /// S1: Duplicate Tab and Reopen Closed Tab bring a page back through the deferred restore, and are a person's.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func duplicatingATabDuringACrashLoopEndsIt() async throws {
        try await withCrashLoopedWindow { rig in
            let tab = rig.window.browser.newTab(url: Self.address)
            #expect(await rig.hasChromiumPage(tab))
            #expect(await rig.loopIsUntouched(), "the tab itself is not a person's (state \(rig.connection.state))")
            rig.window.browser.duplicate(tab)
            #expect(await rig.loopWasEnded())
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func reopeningAClosedTabDuringACrashLoopEndsIt() async throws {
        try await withCrashLoopedWindow { rig in
            let tab = rig.window.browser.newTab(url: Self.address)
            #expect(await rig.hasChromiumPage(tab))
            #expect(await rig.loopIsUntouched())
            rig.window.browser.close(tab)
            #expect(await rig.loopIsUntouched(), "closing a tab asks for nothing")
            rig.window.browser.reopenLastClosedTab()
            #expect(await rig.loopWasEnded())
        }
    }

    /// Showing a deferred tab is not a person's action by itself (a session restore shows tabs too); Load Tab says it is.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aDeferredTabShownDuringACrashLoopEndsItOnlyWhenThePersonLoadedIt() async throws {
        try await withCrashLoopedWindow { rig in
            let restored = rig.window.browser.makeTab(for: Self.address, restoring: true)
            let loaded = rig.window.browser.makeTab(for: Self.address, restoring: true)
            restored.deferRestore(state: nil, url: Self.address)
            loaded.deferRestore(state: nil, url: Self.address)
            restored.realizeDeferredSession()
            #expect(await rig.hasChromiumPage(restored))
            #expect(await rig.loopIsUntouched(), "a restored tab does not end the loop (state \(rig.connection.state))")
            loaded.deferredLoadByPerson = true
            loaded.realizeDeferredSession()
            #expect(await rig.hasChromiumPage(loaded))
            #expect(await rig.loopWasEnded(), "Load Tab does")
            // Not in the window's tabs, so not closed with it: let go of them before the connection ends.
            for tab in [restored, loaded] {
                tab.detach()
                await tab.waitForRetirement()
            }
        }
    }

    /// S5: an error document that was loading when the service went away must not turn the person's next failed load into an alert.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aGivenUpServiceLeavesNoErrorDocumentFlagBehind() async {
        let connection = makeConnection()
        let tab = RealTab(connection, withBrowser: true)
        crashLoop(connection, with: [tab])
        #expect(connection.isGivenUp)
        tab.tab.isLoadingErrorPage = true
        tab.tab.navigationFailed(nil, error: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: Self.address]))
        #expect(!tab.tab.isLoadingErrorPage, "the flag of the vanished error document is cleared")
        connection.disconnect()
        await tab.end()
    }
}
