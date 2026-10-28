// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    let app: BrowserApplication
    let coordinator: AppCoordinator
    let window: NSWindow
    let server: HTTPFixtureServer
    let engine: BrowserEngine

    var browser: BrowserModel {
        coordinator.browser
    }

    /// Runs `body` in a window of a profile of its own, whose pages open on `engine` and may start sound, and closes it after.
    static func with(engine: BrowserEngine, _ body: @MainActor (LiveWindowRig) async throws -> Void) async throws {
        let never = ResponseGate()
        let server = try await HTTPFixtureServer.start(routes: [
            "/page": .html(page),
            "/never": .html("", gate: never),
            "/still": .html("<!doctype html><title>Still</title><p>Nothing moves here.</p>"),
        ])
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Live window")
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
        catalog.markCurrent(previous)
        withExtendedLifetime((server, never)) {}
        if let failure {
            throw failure
        }
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
