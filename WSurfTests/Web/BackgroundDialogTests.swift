// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A dialog from a tab the person is not looking at waits for that tab: no sheet covers the tab in front, the page stays
/// blocked, and the sheet comes up on the tab's own window when it is brought to the front. A tab that closes or leaves its page
/// meanwhile has the dialog answered as cancelled. The window is the one the app builds (content area, parking shelf and
/// sidebar), on each engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct BackgroundDialogTests {
    /// Opens a confirm in `tab`'s page. The page writes the answer to its body and sends it to `/answer`, which still arrives
    /// when the page is leaving. Nothing waits for the script: Chromium checks the page after it runs, which the open confirm
    /// blocks.
    private func askToConfirm(in tab: BrowserTab) {
        tab.page.evaluateJavaScript("""
            setTimeout(() => {
              const answer = confirm('Keep going?');
              document.body.dataset.answer = String(answer);
              navigator.sendBeacon('/answer?v=' + answer);
            }, 0);
            true
            """)
    }

    private func answer(in tab: BrowserTab) async -> String? {
        (try? await tab.page.evaluateJavaScript("document.body.dataset.answer || ''")) as? String
    }

    /// Waits until WSurf has the dialog: it waits for its tab, or (where the tab's place is ignored) a sheet is up.
    private func dialogArrives(in tab: BrowserTab, _ rig: LiveWindowRig) async -> Bool {
        await waitUntil { tab.dialogs.waitsToBeShown || rig.window.attachedSheet != nil }
    }

    /// A failed case can leave a sheet up; the window must not close under it.
    private func endSheet(in rig: LiveWindowRig) {
        if let sheet = rig.window.attachedSheet {
            rig.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aBackgroundTabsConfirmWaitsUntilTheTabIsInFront(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            defer { endSheet(in: rig) }
            let background = try await rig.open("/still")
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            askToConfirm(in: background)
            try #require(await dialogArrives(in: background, rig))
            #expect(rig.window.attachedSheet == nil, "\(engine): no sheet covers the tab in front")

            rig.browser.activate(background)
            #expect(await waitUntil { rig.window.attachedSheet != nil }, "\(engine): the sheet comes up once its tab is in front")
            let sheet = try #require(rig.window.attachedSheet)
            rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            #expect(await waitUntil { await answer(in: background) == "true" }, "\(engine): the person's OK reached the page")
            #expect(!background.dialogs.waitsToBeShown)
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func closingABackgroundTabAnswersItsWaitingDialog(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            defer { endSheet(in: rig) }
            let background = try await rig.open("/still")
            let front = try await rig.open("/still")
            askToConfirm(in: background)
            try #require(await dialogArrives(in: background, rig))
            #expect(rig.window.attachedSheet == nil, "\(engine): no sheet covers the tab in front")

            rig.browser.close(background)
            #expect(!background.dialogs.waitsToBeShown, "\(engine): the waiting dialog is answered as cancelled")
            await background.waitForRetirement()
            #expect(rig.window.attachedSheet == nil, "\(engine): and never shown")
            #expect(rig.browser.activeTab === front)
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func navigatingAwayAnswersAWaitingDialogAsCancelled(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            defer { endSheet(in: rig) }
            let background = try await rig.open("/still")
            _ = try await rig.open("/still")
            askToConfirm(in: background)
            try #require(await dialogArrives(in: background, rig))
            #expect(rig.window.attachedSheet == nil, "\(engine): no sheet covers the tab in front")

            let next = try rig.server.url("/page")
            _ = background.load(next)
            #expect(
                await waitUntil(timeout: .seconds(60)) { background.page.url == next && !background.page.isLoading },
                "\(engine): the navigation goes on"
            )
            #expect(rig.server.lastRequestHead(for: "/answer")?.contains("v=false") == true, "\(engine): the page was told Cancel")
            #expect(!background.dialogs.waitsToBeShown)

            rig.browser.activate(background)
            #expect(await waitUntil { background.page.window === rig.window && !background.page.isParked })
            #expect(await rig.marker(of: background) == "loaded", "\(engine): the new page answers")
            #expect(rig.window.attachedSheet == nil, "\(engine): nothing asks about the page that is gone")
        }
    }

    /// A favorite kept alive behind the tab in front is in the window, though not shown: its dialog waits like any other tab's.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aKeptAliveFavoritesDialogDoesNotCoverTheTabInFront(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            defer { endSheet(in: rig) }
            let favorite = try await rig.open("/still")
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front && favorite.page.window === rig.window)
            askToConfirm(in: favorite)
            try #require(await dialogArrives(in: favorite, rig))
            #expect(rig.window.attachedSheet == nil, "\(engine): no sheet covers the tab in front")

            rig.browser.activate(favorite)
            #expect(await waitUntil { rig.window.attachedSheet != nil }, "\(engine): the sheet comes up once the favorite is in front")
            let sheet = try #require(rig.window.attachedSheet)
            rig.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            #expect(await waitUntil { await answer(in: favorite) == "false" }, "\(engine): the person's Cancel reached the page")
        }
    }

    /// A page that asks before it unloads, as a page with unsaved work does. Chromium asks only a page that has had user
    /// activation, so it gets a real click while it is in front.
    private func guardUnload(_ tab: BrowserTab) async throws {
        _ = try await tab.page.evaluateJavaScript("window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; }; true")
        let chromium = try #require(tab.page.chromium)
        for type in ["mousePressed", "mouseReleased"] {
            _ = try await chromium.command("Input.dispatchMouseEvent", params: ["type": type, "x": 5, "y": 5, "button": "left", "clickCount": 1])
        }
        try #require(try await tab.page.evaluateJavaScript("navigator.userActivation.hasBeenActive") as? Bool == true)
    }

    /// Chromium asks before such a page reloads. For a tab in the background the question waits, and the reload with it, until
    /// the tab is in front. Closing such a tab asks nothing: the browser is closed without a prompt.
    @Test(.timeLimit(.minutes(2)))
    func aBackgroundChromiumTabAsksBeforeReloadingOnceInFrontAndClosesWithoutAsking() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            defer { endSheet(in: rig) }
            let closing = try await rig.open("/page")
            try await guardUnload(closing)
            let guarded = try await rig.open("/page")
            try await guardUnload(guarded)
            _ = try await guarded.page.evaluateJavaScript("window.__marker = 'before'; true")
            _ = try await rig.open("/still")

            rig.browser.close(closing)
            await closing.waitForRetirement()
            #expect(rig.window.attachedSheet == nil && !closing.dialogs.waitsToBeShown, "closing asks nothing")

            guarded.reload()
            try #require(await dialogArrives(in: guarded, rig))
            #expect(rig.window.attachedSheet == nil, "no sheet covers the tab in front")

            rig.browser.activate(guarded)
            #expect(await waitUntil { rig.window.attachedSheet != nil }, "the question comes up once the tab is in front")
            let sheet = try #require(rig.window.attachedSheet)
            rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            #expect(await waitUntil { await rig.marker(of: guarded) == "loaded" }, "Reload goes on once the person agrees")
        }
    }
}
