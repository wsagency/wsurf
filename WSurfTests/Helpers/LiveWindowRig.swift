// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The window the app builds (content area, sidebar and parking shelf) on one engine, with a page that counts animation frames,
/// which an engine runs only while it counts the page visible, and a page that does not move. For the cases that watch what a tab
/// reports once it is no longer in front.
@MainActor
struct LiveWindowRig {
    /// Counts animation frames on a canvas. `playSong()` starts a player the way a page does when it has something to say. Its
    /// element is told to play a file the server never sends, so `paused` is false, nothing is decoded and nothing is heard: a
    /// page that plays for real in the test host leaves WebKit's GPU process unresponsive for the cases after it. The element is
    /// made on demand because a file that never arrives would keep WebKit's page loading.
    static let page = """
        <!doctype html><title>Page</title><canvas id="c" width="300" height="200"></canvas>
        <script>
        window.__marker = 'loaded';
        window.__frames = 0;
        // willReadFrequently keeps the canvas in plain memory: a GPU-less CI VM cannot allocate the IOSurface an accelerated
        // canvas draws into, and its snapshots come out blank.
        const context = document.getElementById('c').getContext('2d', { willReadFrequently: true });
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

    let app: BrowserApplication
    let coordinator: AppCoordinator
    let window: NSWindow
    let server: HTTPFixtureServer
    let engine: BrowserEngine

    var browser: BrowserModel {
        coordinator.browser
    }

    /// The WebKit store of every rig's profile, emptied after each rig. A store per rig would cost the test host's Networking
    /// process one of the about 180 persistent stores it can ever serve (`Profile.dataStoreForTesting`), and the cases that run
    /// after the last one cannot open a database.
    private static let dataStore = WKWebsiteDataStore(forIdentifier: UUID())

    /// Gives `profile` the one shared store instead of a persistent store of its own, for the helpers that open a page in a profile per
    /// case. Call it before the profile's `BrowserProfileContext` exists, and `releaseSharedDataStore` once the case is over.
    static func useSharedDataStore(for profile: Profile) {
        Profile.dataStoreForTesting[profile.id] = dataStore
    }

    /// Takes `profile` off the shared store and empties it for the next case.
    static func releaseSharedDataStore(for profile: Profile) async {
        Profile.dataStoreForTesting[profile.id] = nil
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Runs `body` in a window of a profile of its own, whose pages open on `engine` and may start sound, and closes it after.
    /// `routes` adds pages of the case's own to the server.
    static func with(
        engine: BrowserEngine,
        routes: [String: HTTPFixtureServer.Response] = [:],
        _ body: @MainActor (LiveWindowRig) async throws -> Void
    ) async throws {
        let never = ResponseGate()
        let server = try await HTTPFixtureServer.start(routes: routes.merging([
            "/page": .html(page),
            "/never": .html("", gate: never),
            "/still": .html("<!doctype html><title>Still</title><p>Nothing moves here.</p>"),
        ]) { _, fixed in fixed })
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Live window")
        useSharedDataStore(for: profile)
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
            try await body(LiveWindowRig(app: app, coordinator: coordinator, window: window, server: server, engine: engine))
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
        await releaseSharedDataStore(for: profile)
        catalog.markCurrent(previous)
        withExtendedLifetime((server, never)) {}
        if let failure {
            throw failure
        }
    }

    /// A tab on `path` that is in front once its page has loaded. A covered window must not decide what the pages report, so
    /// WebKit pages ignore it (Chromium does for every page). The tab hides its page at once when it leaves the front, unless it
    /// is given a wait, which `clock` times.
    func open(_ path: String, grace: Duration = .zero, clock: (any Clock<Duration>)? = nil) async throws -> BrowserTab {
        let url = try server.url(path)
        let tab = browser.newTab(url: url, engine: engine)
        tab.backgroundHidingGrace = grace
        if let clock {
            tab.backgroundClock = clock
        }
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

    /// Writes a value into the page that nothing in the page sets, and returns it. `__marker` cannot say "the page did not reload",
    /// because the page sets it again on every load; this value is gone after a reload, so a test that stamps a tab once, after its
    /// first load, and reads the stamp back later has seen the same document the whole time.
    func stamp(_ tab: BrowserTab) async throws -> String {
        let value = UUID().uuidString
        _ = try await tab.page.evaluateJavaScript("window.__stamp = '\(value)'; true")
        return value
    }

    /// Whether the page still holds `stamp` (see `stamp(_:)`): it is the same document as when it was written.
    func stampSurvived(_ tab: BrowserTab, _ stamp: String) async -> Bool {
        (try? await tab.page.evaluateJavaScript("window.__stamp")) as? String == stamp
    }

    /// Whether the page runs animation frames and is visible. It takes one sample of the counter and then polls it, so a page that
    /// animates answers within a tick or two instead of after a fixed wait; a page that does not is given the same 300 ms as before.
    func isAnimating(_ tab: BrowserTab) async -> Bool {
        let first = await frames(of: tab)
        guard first >= 0 else { return false }
        let deadline = ContinuousClock.now + .milliseconds(300)
        repeat {
            try? await Task.sleep(for: .milliseconds(20))
            if await frames(of: tab) > first {
                return await state(of: tab) == "visible"
            }
        } while ContinuousClock.now < deadline
        return false
    }

    /// Frames the page ran in a second after a 100 ms lead. For a page that animates in front; a hidden page is measured with
    /// `frames(of:whileFramesOf:)`, because an engine draws a page for a moment after it reports `hidden`.
    func framesInASecond(of tab: BrowserTab) async -> Double {
        try? await Task.sleep(for: .milliseconds(100))
        let first = await frames(of: tab)
        try? await Task.sleep(for: .seconds(1))
        return await frames(of: tab) - first
    }

    /// Frames `tab`, a page the engine reports hidden, ran while `reference`, a visible page of this rig's counting page, ran `count`
    /// of its own. A page that is hidden stays near zero however long that took, and the visible one is the control that proves the
    /// engine was drawing: the answer does not depend on how long a second is on this machine. The count starts once a stretch of
    /// ten frames of `reference` has passed with none of `tab`'s, because an engine reports `hidden` to the page a little before it
    /// stops drawing it (Chromium ran 7 frames in the first 20 of a page that had just loaded behind another tab), and a page that
    /// never goes quiet still fails: its frames are counted in the last window. Nil when `reference` did not draw.
    func frames(of tab: BrowserTab, whileFramesOf reference: BrowserTab, run count: Double = 20) async -> Double? {
        var windows: [Double] = []
        for _ in 0..<5 {
            guard let ran = await framesCounted(of: tab, whileFramesOf: reference, run: 10) else { return nil }
            windows.append(ran)
            if ran == 0 {
                break
            }
        }
        guard let ran = await framesCounted(of: tab, whileFramesOf: reference, run: count) else { return nil }
        print("hidden page frames per 10 of the front's, until quiet: \(windows), then \(ran) per \(Int(count))")
        return ran
    }

    private func framesCounted(of tab: BrowserTab, whileFramesOf reference: BrowserTab, run count: Double) async -> Double? {
        let before = await frames(of: tab)
        let referenceBefore = await frames(of: reference)
        guard before >= 0, referenceBefore >= 0 else { return nil }
        let drew = await waitUntil(timeout: .seconds(10)) { await frames(of: reference) >= referenceBefore + count }
        guard drew else { return nil }
        return await frames(of: tab) - before
    }

    /// The page starts a player, as a person's click on it would make it do.
    func startPlaying(_ tab: BrowserTab) async throws {
        _ = try await tab.page.evaluateJavaScript("window.playSong(); true", in: nil, contentWorld: .page, userGesture: true)
    }

    func isPlaying(_ tab: BrowserTab) async -> Bool? {
        (try? await tab.page.evaluateJavaScript("window.songIsPlaying()")) as? Bool
    }

    /// Whether `image` shows anything but white and nothing: a snapshot of a page that did not paint is one or the other.
    static func hasContent(_ image: NSImage) -> Bool {
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
}
