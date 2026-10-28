// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A loaded favorite stays alive behind the tab in front, as a background tab does, and it is not shown: the engines report its
/// page hidden and it runs no animation frames. What plays sound keeps playing. The window is the one the app builds (content
/// area and parking shelf) with the real sidebar, on each engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct KeptAliveFavoritesTests {
    /// Counts animation frames on a canvas, which the engine runs only while it counts the page visible. `playSong()` starts a
    /// player the way a page does when it has something to say. Its element is told to play a file the server never sends, so
    /// `paused` is false, nothing is decoded and nothing is heard: a page that plays for real in the test host leaves WebKit's GPU
    /// process unresponsive for the cases after it. The element is made on demand because a file that never arrives would keep
    /// WebKit's page loading.
    private static let page = """
        <!doctype html><title>Page</title><canvas id="c" width="300" height="200"></canvas>
        <script>
        window.__marker = 'loaded';
        window.__frames = 0;
        const context = document.getElementById('c').getContext('2d');
        function frame(time) {
          window.__frames++;
          context.fillStyle = 'hsl(' + (time / 10 % 360) + ',60%,50%)';
          context.fillRect(0, 0, 300, 200);
          requestAnimationFrame(frame);
        }
        requestAnimationFrame(frame);
        let song = null;
        window.playSong = () => {
          song = document.createElement('audio');
          song.src = '/never';
          document.body.append(song);
          const play = () => {
            if (song.paused) {
              const attempt = song.play();
              if (attempt) { attempt.catch(() => {}); }
            }
          };
          play();
          setInterval(play, 100);
        };
        window.songIsPlaying = () => song !== null && !song.paused;
        </script>
        """

    private struct Rig {
        let app: BrowserApplication
        let coordinator: AppCoordinator
        let window: NSWindow
        let server: HTTPFixtureServer
        let engine: BrowserEngine

        var browser: BrowserModel {
            coordinator.browser
        }

        /// A tab on `path` that is in front once its page has loaded. A covered window must not decide what the pages report, so
        /// WebKit pages ignore it (Chromium does for every page).
        func open(_ path: String) async throws -> BrowserTab {
            let url = try server.url(path)
            let tab = browser.newTab(url: url, engine: engine)
            tab.page.ignoresWindowOcclusion = true
            try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading })
            try #require(await waitUntil { tab.page.window === window })
            return tab
        }

        func state(of tab: BrowserTab) async -> String? {
            (try? await tab.page.evaluateJavaScript("document.visibilityState")) as? String
        }

        func frames(of tab: BrowserTab) async -> Double {
            (try? await tab.page.evaluateJavaScript("window.__frames")) as? Double ?? -1
        }

        func marker(of tab: BrowserTab) async -> String? {
            (try? await tab.page.evaluateJavaScript("window.__marker")) as? String
        }

        func isAnimating(_ tab: BrowserTab) async -> Bool {
            let first = await frames(of: tab)
            try? await Task.sleep(for: .milliseconds(300))
            let second = await frames(of: tab)
            let visibility = await state(of: tab)
            return first >= 0 && second > first && visibility == "visible"
        }

        /// Frames the page ran in a second, once it has been hidden for a moment.
        func framesInASecond(of tab: BrowserTab) async -> Double {
            try? await Task.sleep(for: .milliseconds(500))
            let first = await frames(of: tab)
            try? await Task.sleep(for: .seconds(1))
            return await frames(of: tab) - first
        }

        /// The page starts a player, as a person's click on it would make it do.
        func startPlaying(_ tab: BrowserTab) async throws {
            _ = try await tab.page.evaluateJavaScript("window.playSong(); true", in: nil, contentWorld: .page, userGesture: true)
        }

        func isPlaying(_ tab: BrowserTab) async -> Bool? {
            (try? await tab.page.evaluateJavaScript("window.songIsPlaying()")) as? Bool
        }
    }

    private func withWindow(engine: BrowserEngine, _ body: @MainActor (Rig) async throws -> Void) async throws {
        let never = ResponseGate()
        let server = try await HTTPFixtureServer.start(routes: [
            "/page": .html(Self.page),
            "/never": .html("", gate: never),
            "/still": .html("<!doctype html><title>Still</title><p>Nothing moves here.</p>"),
        ])
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Kept alive favorites")
        let context = BrowserProfileContext.shared(for: profile)
        let origin = SitePermissions.origin(for: try server.url("/page"))
        context.sitePermissions.setEngine(engine, for: origin)
        context.sitePermissions.setAutoplay(.allow, for: origin)
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let coordinator = app.newWindow(profile: profile, show: false)
        coordinator.showBrowser(activate: false)
        var failure: (any Error)?
        do {
            let window = try #require(coordinator.nativeWindow)
            window.orderFrontRegardless()
            try await body(Rig(app: app, coordinator: coordinator, window: window, server: server, engine: engine))
        } catch {
            failure = error
        }
        let tabs = coordinator.browser.tabs
        for window in app.windows {
            window.closeWindow()
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        withExtendedLifetime((server, never)) {}
        if let failure {
            throw failure
        }
    }

    /// Whether `image` shows anything but white and nothing: a snapshot of a page that did not paint is one or the other.
    private func hasContent(_ image: NSImage) -> Bool {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return false }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9 {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Hidden

    /// The favorite is loaded and stays so (no reload when it comes back), but while another tab is in front its page is hidden
    /// and its frame counter stands still. In front it animates, and the tab in front is visible, so a hidden favorite is not an
    /// unshown window.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteBehindAnotherTabIsHiddenAndStopsAnimating(engine: BrowserEngine) async throws {
        try await withWindow(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            rig.browser.activate(favorite)
            try #require(await waitUntil { await rig.isAnimating(favorite) }, "in front the favorite is visible and animates")

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            #expect(await waitUntil { await rig.state(of: front) == "visible" }, "the tab in front is visible")
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(hidden, "\(engine): the favorite behind it reports \(reported)")
            let ran = await rig.framesInASecond(of: favorite)
            #expect(ran >= 0 && ran <= 2, "\(engine): the hidden favorite ran \(ran) frames in a second")

            #expect(favorite.isMaterialised && !favorite.isDeferred, "it stays loaded")
            #expect(favorite.page.window != nil, "and in its window")
            #expect(await rig.marker(of: favorite) == "loaded")

            rig.browser.activate(favorite)
            #expect(await waitUntil { await rig.isAnimating(favorite) }, "\(engine): back in front it is visible and animates again")
            #expect(await rig.marker(of: favorite) == "loaded", "it did not reload")
        }
    }

    /// A favorite that opens behind the tab in front (the way every favorite does at launch) loads without being shown, and is
    /// hidden while it does.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteThatOpensBehindTheTabInFrontLoadsHidden(engine: BrowserEngine) async throws {
        try await withWindow(engine: engine) { rig in
            let front = try await rig.open("/still")
            let url = try rig.server.url("/page")
            let favorite = rig.browser.newTab(url: url, activate: false, engine: engine)
            favorite.page.ignoresWindowOcclusion = true
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            try #require(rig.browser.activeTab === front)

            #expect(
                await waitUntil(timeout: .seconds(60)) { favorite.page.url == url && !favorite.page.isLoading },
                "\(engine): the favorite loads without being shown"
            )
            #expect(await waitUntil { favorite.page.window === rig.window }, "in the window, where Chromium needs it")
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(hidden, "\(engine): it reports \(reported)")
            let ran = await rig.framesInASecond(of: favorite)
            #expect(ran >= 0 && ran <= 2, "\(engine): it ran \(ran) frames in a second")

            rig.browser.activate(favorite)
            #expect(await waitUntil { await rig.isAnimating(favorite) }, "\(engine): shown, it animates")
            #expect(await rig.marker(of: favorite) == "loaded", "it did not reload")
        }
    }

    /// The preview in the sidebar comes from a snapshot of the page, which has to work on a page that is hidden: one is taken as
    /// the tab leaves the front, and one when the pointer rests on its row.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aHiddenFavoriteStillGivesItsPreview(engine: BrowserEngine) async throws {
        try await withWindow(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            rig.browser.addFavorite(favorite)
            rig.browser.activate(favorite)
            try #require(await waitUntil { await rig.isAnimating(favorite) })

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" })
            #expect(await waitUntil(timeout: .seconds(15)) { favorite.preview != nil }, "\(engine): the preview taken as it left the front")

            let earlier = favorite.preview
            favorite.refreshPreview()
            #expect(await waitUntil(timeout: .seconds(15)) { favorite.preview !== earlier }, "\(engine): a new preview of the hidden page")
            let image = try #require(favorite.preview)
            #expect(hasContent(image), "\(engine): the preview of the hidden page is not blank")
        }
    }

    // MARK: - Playing

    /// A favorite that plays keeps playing behind the tab in front, loaded and in its window, and stays in the list of tabs that
    /// are heard.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteThatPlaysAudioKeepsPlayingBehindAnotherTab(engine: BrowserEngine) async throws {
        try await withWindow(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            try await rig.startPlaying(favorite)
            try #require(await waitUntil { favorite.isPlayingAudio }, "the page plays")
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try await Task.sleep(for: .seconds(2))

            #expect(favorite.isPlayingAudio, "\(engine): the favorite is still heard")
            #expect(rig.app.audibleTabs(for: rig.coordinator).contains { $0.tab === favorite })
            #expect(await rig.isPlaying(favorite) == true, "\(engine): its player was not paused")
            #expect(favorite.isMaterialised && !favorite.isDeferred)
            #expect(favorite.page.window != nil)
            #expect(await rig.marker(of: favorite) == "loaded", "it did not reload")
        }
    }

    /// A hidden favorite that starts to play is shown to the engine again, so what it plays is not cut short by being hidden.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aHiddenFavoriteThatStartsPlayingIsNoLongerHidden(engine: BrowserEngine) async throws {
        try await withWindow(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            rig.browser.addFavorite(favorite)
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" })

            try await rig.startPlaying(favorite)
            #expect(await waitUntil { favorite.isPlayingAudio }, "\(engine): the page plays")
            let shown = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "visible" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(shown, "\(engine): the favorite that plays reports \(reported)")
            try await Task.sleep(for: .seconds(1))
            #expect(await rig.isPlaying(favorite) == true, "\(engine): its player was not paused")
            #expect(favorite.isPlayingAudio)
        }
    }
}
