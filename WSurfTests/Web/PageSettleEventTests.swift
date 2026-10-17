// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Waits that ask the page once and let it answer, instead of sampling it on an interval.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageSettleEventTests {
    private final class Hosts {
        var windows: [NSWindow] = []

        func append(_ window: NSWindow) {
            windows.append(window)
        }

        func closeAll() {
            for window in windows {
                window.contentView = nil
                window.close()
            }
            windows = []
        }
    }

    private let hosts = Hosts()

    /// A page on a loopback server, hosted in a window: a page nobody shows has its timers throttled.
    private func page(_ body: String, routes: [String: HTTPFixtureServer.Response] = [:]) async throws -> (BrowserPage, HTTPFixtureServer) {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><body>\(body)</body>")].merging(routes) { $1 })
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = BrowserPage(
            webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration),
            context: BrowserProfileContext(profile: .privateBrowsing()))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        hosts.append(window)
        view.load(URLRequest(url: try server.url()))
        try #require(await waitUntil { view.url == (try? server.url()) && !view.isLoading })
        return (view, server)
    }

    private func milliseconds(_ duration: Duration) -> Int {
        PageSettle.milliseconds(duration)
    }

    @Test func settleResolvesOnQuietWithoutPolling() async throws {
        let (view, server) = try await page("<p>Static</p>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let evaluations = view.evaluations, asyncCalls = view.asyncCalls
        let clock = ContinuousClock()
        let start = clock.now
        await PageSettle.untilQuiet(view)
        #expect(view.asyncCalls - asyncCalls == 1, "one question to the page")
        #expect(view.evaluations - evaluations == 0, "and no sampling")
        #expect(start.duration(to: clock.now) < .seconds(2), "a static page is quiet at once, not at the ceiling")

        // The sampling path stays as the fallback and as the choice of an injected clock.
        let sampled = view.evaluations
        await PageSettle.$strategy.withValue(.polling) { await PageSettle.untilQuiet(view) }
        #expect(view.evaluations - sampled >= 2)
    }

    @Test func aBusyPageEndsAtItsCeilingInOneCall() async throws {
        let (view, server) = try await page(
            "<p id=t></p><script>window.ticks = 0; setInterval(() => { window.ticks += 1; document.getElementById('t').textContent = performance.now(); }, 10)</script>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let asyncCalls = view.asyncCalls
        let clock = ContinuousClock()
        let start = clock.now
        await PageSettle.untilQuiet(view, ceiling: .milliseconds(400))
        let elapsed = milliseconds(start.duration(to: clock.now))
        let counted = try await view.evaluateJavaScript("window.ticks") as? Int
        let ticks = try #require(counted)
        #expect(elapsed < 3_000, "\(elapsed) ms")
        #expect(view.asyncCalls - asyncCalls == 1)
        // A page that kept changing through the whole wait (a tick every 10 ms or so) is never quiet, so the wait lasts to its
        // ceiling. A page whose timers the system slowed down was quiet, and may be answered early.
        if ticks >= 30 {
            #expect(elapsed >= 350, "\(ticks) changes in \(elapsed) ms")
        }
    }

    @Test func aBurstOfChangesDelaysTheAnswerUntilItEnds() async throws {
        let (view, server) = try await page("""
            <script>
              window.appended = 0;
              const timer = setInterval(() => {
                document.body.append('x'); window.appended += 1; window.lastChange = performance.now();
                if (window.appended === 6) clearInterval(timer);
              }, 60);
            </script>
            """)
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        await PageSettle.untilQuiet(view, ceiling: .seconds(5))
        #expect(try await view.evaluateJavaScript("window.appended") as? Int == 6, "the wait lasted through the burst")
        let since = try #require(try await view.evaluateJavaScript("performance.now() - window.lastChange") as? Double)
        #expect(since >= 100, "and ended only after the page had been quiet for its window: \(since) ms")
    }

    @Test func theHighlightRingDoesNotKeepThePageFromSettling() async throws {
        let (view, server) = try await page("<button style='width:120px;height:40px'>Target</button>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        _ = await PageDriver.readRenderedPage(view)
        await PageDriver.announce(ref: 1, in: view, pause: false)
        #expect(try await view.evaluateJavaScript("!!document.querySelector('.__wsurf-ring')") as? Bool == true)
        let clock = ContinuousClock()
        let start = clock.now
        await PageSettle.untilQuiet(view, ceiling: .seconds(2))
        #expect(milliseconds(start.duration(to: clock.now)) < 1_000, "the ring's own changes are not the page's")
    }

    @Test func aNavigationTheClickStartedIsFollowedToItsEnd() async throws {
        let (view, server) = try await page(
            "<a href='/next'>Next</a>", routes: ["/next": .html("<!doctype html><title>Next</title><p>Arrived</p>")])
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        _ = try await view.evaluateJavaScript("document.querySelector('a').click(); 0")
        await PageSettle.$limits.withValue(.init(grace: .zero)) { await PageSettle.afterInteraction(view) }
        #expect(view.url?.path == "/next" && !view.isLoading, "\(String(describing: view.url)) loading \(view.isLoading)")
    }

    @Test func theMeterCountsTheTimeSpentWaiting() async throws {
        let (view, server) = try await page("<p>Static</p>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let meter = PageSettle.Meter()
        await PageSettle.$meter.withValue(meter) { await PageSettle.untilQuiet(view) }
        #expect(meter.elapsed > .milliseconds(50) && meter.elapsed < .seconds(2), "\(meter.elapsed)")
    }

    // MARK: waitForPage

    @Test func waitForPageUsesOneScriptCall() async throws {
        let (view, server) = try await page("<p id=out>Loading</p><script>setTimeout(() => { document.getElementById('out').textContent = 'Ready now'; }, 250)</script>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let asyncCalls = view.asyncCalls
        let output = await PageDriver.waitForPage(condition: "text", value: "Ready now", timeout: 5, in: view)
        #expect(output.hasPrefix("Condition met."), "\(output.prefix(120))")
        #expect(output.contains("observationID: "), "the wait returns a fresh observation")
        #expect(view.asyncCalls - asyncCalls == 1, "the page watched for the text itself")
    }

    @Test func waitForPageTimesOutAfterOneChunk() async throws {
        let (view, server) = try await page("<p>Nothing changes</p>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let asyncCalls = view.asyncCalls
        let clock = ContinuousClock()
        let start = clock.now
        let output = await PageDriver.waitForPage(condition: "text", value: "Never shown", timeout: 1, in: view)
        #expect(output.hasPrefix("Timed out waiting for text."), "\(output.prefix(120))")
        #expect(milliseconds(start.duration(to: clock.now)) >= 900)
        #expect(view.asyncCalls - asyncCalls == 1)
    }

    @Test func waitForPageSeesAChangeThatNoMutationAnnounces() async throws {
        let (view, server) = try await page("<p>Page</p><script>setTimeout(() => history.pushState({}, '', '/pushed'), 200)</script>")
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let output = await PageDriver.waitForPage(condition: "url", value: "/pushed", timeout: 5, in: view)
        #expect(output.hasPrefix("Condition met."), "\(output.prefix(120))")
    }

    @Test func anElementWaitEndsAsStaleWhenThePageNavigates() async throws {
        let (view, server) = try await page(
            "<button id=later disabled>Later</button><script>setTimeout(() => { location.href = '/next'; }, 300)</script>",
            routes: ["/next": .html("<!doctype html><button id=later>Later</button>")])
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let output = await PageDriver.waitForPage(condition: "elementEnabled", value: "#later", timeout: 5, in: view)
        #expect(output == PageDriver.staleMessage, "\(output.prefix(120))")
    }

    @Test func aTextWaitContinuesOnThePageThatArrives() async throws {
        let (view, server) = try await page(
            "<p>Old page</p><script>setTimeout(() => { location.href = '/next'; }, 200)</script>",
            routes: ["/next": .html("<!doctype html><p>Welcome back</p>")])
        defer {
            hosts.closeAll()
            withExtendedLifetime(server) {}
        }
        let output = await PageDriver.waitForPage(condition: "text", value: "Welcome back", timeout: 8, in: view)
        #expect(output.hasPrefix("Condition met."), "\(output.prefix(120))")
    }
}
