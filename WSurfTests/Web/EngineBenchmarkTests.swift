// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

// What a person waits for on a page in Chromium, and between the two engines: the first Chromium tab of a session, a switch among
// loaded tabs, a new tab to its first paint, Find, closing tabs and changing a tab's engine. Reported, not budgeted: CEF in the test
// host breaks `XCTMemoryMetric` for every XCTest case after it (see `ChromiumLoadBenchmarkTests`), so these are Swift Testing cases
// that read manual clocks only (`ContinuousClock` and the main thread's CPU time), and the suite is in `Tools/serial-parts.json`
// `skippedSuites`: ci-local never runs it.
//
// Every case is off unless `WSURF_PERF_BENCH=1` is set (`TEST_RUNNER_WSURF_PERF_BENCH=1` for `xcodebuild`), so a developer's Cmd-U
// never starts CEF for it. Each prints `WSURF-ENGINE-BENCH` lines. CEF cannot be started twice in one process, so the first-start case
// needs a fresh host per sample: run it alone, once per sample. A page loads in Chromium only when its window is ordered in, which
// `LiveWindowRig` does (without activating the app).
private nonisolated let benchEnabled = ProcessInfo.processInfo.environment["WSURF_PERF_BENCH"] == "1"

@MainActor
@Suite(.serialized, .boundedWebViews)
struct EngineBenchmarkTests {
    /// Small distinct pages, and a 200 KB article, on top of the rig's `/page` (animated) and `/still`.
    private static var routes: [String: HTTPFixtureServer.Response] {
        var routes: [String: HTTPFixtureServer.Response] = ["/article": .html(ReaderFixtures.longArticle(bytes: 200_000))]
        for index in 0..<16 {
            let rows = (0..<20).map { "<p>Paragraph \($0) of plain page \(index): some text to paint on the first frame.</p>" }.joined()
            routes["/p\(index)"] = .html(
                "<!doctype html><html><head><title>Plain \(index)</title></head><body><h1>Plain page \(index)</h1>\(rows)</body></html>")
        }
        return routes
    }

    private static let clock = ContinuousClock()

    private static func report(_ name: String, _ fields: String) {
        print("WSURF-ENGINE-BENCH case=\(name) \(fields)")
    }

    private static func loadAverage() -> String {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return String(format: "load1=%.2f load5=%.2f", load[0], load[1])
    }

    private static func draw(_ rig: LiveWindowRig) {
        if let view = rig.window.contentView {
            PerfProbe.draw(view)
        }
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// A tab on `path` in `engine`, in front, once its page has loaded; with the milliseconds of the `newTab` call and of the wait.
    private static func open(
        _ rig: LiveWindowRig, _ path: String, engine: BrowserEngine, grace: Duration = .seconds(10)
    ) async throws -> (tab: BrowserTab, callMs: Double, loadMs: Double) {
        let url = try rig.server.url(path)
        let began = clock.now
        let tab = rig.browser.newTab(url: url, engine: engine)
        let called = clock.now
        tab.backgroundHidingGrace = grace
        tab.page.ignoresWindowOcclusion = true
        try #require(await waitUntil(timeout: .seconds(60), tick: .milliseconds(5)) { tab.page.url == url && !tab.page.isLoading })
        let loaded = clock.now
        try #require(await waitUntil { tab.page.window === rig.window })
        return (tab, PerfProbe.ms(called - began), PerfProbe.ms(loaded - began))
    }

    /// First contentful paint of a `PageDriver.readPerformance` reply, or -1.
    private static func firstContentfulPaint(of tab: BrowserTab) async -> Double {
        let reply = await PageDriver.readPerformance(in: tab.page)
        guard let start = reply.firstIndex(of: "{"),
            let object = try? JSONSerialization.jsonObject(with: Data(reply[start...].prefix { $0 != "\n" }.utf8)) as? [String: Any],
            let paint = object["paint"] as? [String: Any], let value = paint["firstContentfulPaintMs"] as? NSNumber
        else { return -1 }
        return value.doubleValue
    }

    /// Switches to each of `tabs` in turn, `rounds` times, drawing after each; returns wall and main CPU of the switch and the main
    /// thread's CPU in the 400 ms after it.
    private static func switching(
        _ rig: LiveWindowRig, order: [BrowserTab], rounds: Int
    ) async throws -> (wall: [Double], cpu: [Double], after: [Double]) {
        var wall: [Double] = []
        var cpu: [Double] = []
        var after: [Double] = []
        for _ in 0..<rounds {
            for tab in order {
                let before = PerfProbe.mainCPUms()
                let began = clock.now
                rig.browser.activate(tab)
                draw(rig)
                wall.append(PerfProbe.ms(clock.now - began))
                let switched = PerfProbe.mainCPUms()
                cpu.append(switched - before)
                try await Task.sleep(for: .milliseconds(400))
                after.append(PerfProbe.mainCPUms() - switched)
            }
        }
        return (wall, cpu, after)
    }

    // MARK: - E1

    /// The first Chromium use of the host: the call, the CEF start-up on the main thread, the page loaded. The longest gap between
    /// two ticks of a 2 ms main-run-loop timer is the longest the window froze.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func startingChromiumForTheFirstTab() async throws {
        guard !ChromiumRuntime.shared.isInitialized else {
            Self.report("E1-first-chromium-tab", "skipped=CEF-was-already-initialised-in-this-host")
            return
        }
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            #expect(!ChromiumRuntime.shared.isInitialized, "opening the window did not start CEF")
            let load = Self.loadAverage()
            let watch = HitchWatch()
            let cpuBefore = PerfProbe.mainCPUms()
            watch.start()
            let opened = try await Self.open(rig, "/p0", engine: .chromium)
            watch.stop()
            let gaps = watch.gaps.sorted(by: >)
            Self.report(
                "E1-first-chromium-tab",
                String(
                    format: "n=1 newTabToLoadedMs=%.1f newTabCallMs=%.1f longestMainGapMs=%.1f secondGapMs=%.1f mainCpuMs=%.1f %@ loadAfter=%@",
                    opened.loadMs, opened.callMs, watch.longestMs, gaps.count > 1 ? gaps[1] : 0, PerfProbe.mainCPUms() - cpuBefore, load,
                    Self.loadAverage())
            )
        }
    }

    // MARK: - E2

    /// Three rounds of switches among four loaded Chromium tabs, drawn after each.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func switchingLoadedChromiumTabs() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            var tabs: [BrowserTab] = []
            for index in 0..<4 {
                tabs.append(try await Self.open(rig, "/p\(index)", engine: .chromium).tab)
            }
            Self.draw(rig)
            let result = try await Self.switching(rig, order: tabs, rounds: 3)
            Self.report("E2-switch-chromium-wall", PerfProbe.summary(result.wall))
            Self.report("E2-switch-chromium-mainCpu", PerfProbe.summary(result.cpu))
            Self.report("E2-switch-chromium-after400msCpu", PerfProbe.summary(result.after) + " " + Self.loadAverage())
        }
    }

    // MARK: - E3

    /// Two WebKit and two Chromium tabs, switched in turn, so every second switch changes engine.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func switchingBetweenWebKitAndChromiumTabs() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            let webKit = [
                try await Self.open(rig, "/p4", engine: .webKit).tab,
                try await Self.open(rig, "/p5", engine: .webKit).tab,
            ]
            let chromium = [
                try await Self.open(rig, "/p6", engine: .chromium).tab,
                try await Self.open(rig, "/p7", engine: .chromium).tab,
            ]
            Self.draw(rig)
            let toChromium = try await Self.switching(rig, order: [webKit[0], chromium[0], webKit[1], chromium[1]], rounds: 3)
            // The order above alternates engines; its even places are the switches to WebKit and its odd places to Chromium.
            func split(_ values: [Double], odd: Bool) -> [Double] {
                values.enumerated().filter { ($0.offset % 2 == 1) == odd }.map(\.element)
            }
            for (label, odd) in [("toWebKit", false), ("toChromium", true)] {
                Self.report("E3-switch-\(label)-wall", PerfProbe.summary(split(toChromium.wall, odd: odd)))
                Self.report("E3-switch-\(label)-mainCpu", PerfProbe.summary(split(toChromium.cpu, odd: odd)))
                Self.report("E3-switch-\(label)-after400msCpu", PerfProbe.summary(split(toChromium.after, odd: odd)))
            }
        }
    }

    // MARK: - E4

    /// Five new Chromium tabs, CEF already running: the call to the page loaded, and its first contentful paint.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func openingANewChromiumTabToFirstPaint() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            let warm = try await Self.open(rig, "/p15", engine: .chromium).tab
            rig.browser.close(warm)
            await warm.waitForRetirement()
            var loads: [Double] = []
            var calls: [Double] = []
            var paints: [Double] = []
            for index in 0..<5 {
                let opened = try await Self.open(rig, "/p\(index + 8)", engine: .chromium)
                loads.append(opened.loadMs)
                calls.append(opened.callMs)
                paints.append(await Self.firstContentfulPaint(of: opened.tab))
                rig.browser.close(opened.tab)
                await opened.tab.waitForRetirement()
            }
            Self.report("E4-new-chromium-tab-to-load", PerfProbe.summary(loads) + " newTabCallMedianMs=\(String(format: "%.2f", Self.median(calls)))")
            Self.report("E4-new-chromium-tab-fcp", PerfProbe.summary(paints) + " note=page-relative-ms")
        }
    }

    // MARK: - E5

    /// Find in a 200 KB Chromium page, as `WebPagePerformanceTests.testFindingInALongPage` does in WebKit: open, count, ten steps.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func findingInAChromiumPage() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            let tab = try await Self.open(rig, "/article", engine: .chromium).tab
            var counted: [Double] = []
            var steps: [Double] = []
            var matches = 0
            for _ in 0..<3 {
                let began = Self.clock.now
                tab.find.open()
                tab.find.query = "harbour"
                tab.find.queryDidChange()
                let counting = await waitUntil(timeout: .seconds(30), tick: .milliseconds(5)) {
                    tab.find.totalMatches > 0 && tab.find.currentMatch > 0
                }
                #expect(counting, "matches counted")
                counted.append(PerfProbe.ms(Self.clock.now - began))
                for _ in 0..<10 {
                    let current = tab.find.currentMatch
                    let step = Self.clock.now
                    tab.find.find()
                    _ = await waitUntil(timeout: .seconds(10), tick: .milliseconds(5)) { tab.find.currentMatch != current }
                    steps.append(PerfProbe.ms(Self.clock.now - step))
                }
                matches = tab.find.totalMatches
                tab.find.close()
            }
            Self.report("E5-find-open-and-count", PerfProbe.summary(counted) + " matches=\(matches)")
            Self.report("E5-find-step", PerfProbe.summary(steps))
        }
    }

    // MARK: - E6

    /// Four loaded Chromium tabs closed one by one: the `close` call, and the time until the retirement returns (CEF's close
    /// confirmation, bounded at five seconds). A tab at the bound is reported.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func closingChromiumTabs() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            var tabs: [BrowserTab] = []
            for index in 0..<4 {
                tabs.append(try await Self.open(rig, "/p\(index)", engine: .chromium).tab)
            }
            Self.draw(rig)
            var calls: [Double] = []
            var retired: [Double] = []
            for tab in tabs.reversed() {
                let began = Self.clock.now
                rig.browser.close(tab)
                calls.append(PerfProbe.ms(Self.clock.now - began))
                await tab.waitForRetirement()
                retired.append(PerfProbe.ms(Self.clock.now - began))
                Self.draw(rig)
            }
            let atBound = retired.filter { $0 >= 4_900 }.count
            Self.report("E6-close-chromium-call", PerfProbe.summary(calls))
            Self.report("E6-close-chromium-retired", PerfProbe.summary(retired) + " tabsAtFiveSecondBound=\(atBound)")
        }
    }

    // MARK: - E7

    /// A loaded WebKit tab moved to Chromium and back: the engine switch, which reloads the address, until the page has loaded.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func switchingATabsEngine() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: Self.routes) { rig in
            let url = try rig.server.url("/p0")
            let tab = try await Self.open(rig, "/p0", engine: .webKit).tab
            var toChromium: [Double] = []
            var toWebKit: [Double] = []
            for _ in 0..<3 {
                for target in [BrowserEngine.chromium, .webKit] {
                    let began = Self.clock.now
                    let switched = await tab.switchEngine(to: target)
                    #expect(switched, "the engine changed to \(target)")
                    let loaded = await waitUntil(timeout: .seconds(60), tick: .milliseconds(5)) {
                        tab.page.url == url && !tab.page.isLoading && (tab.page.chromium != nil) == (target == .chromium)
                    }
                    #expect(loaded, "the page loaded again in \(target)")
                    Self.draw(rig)
                    let elapsed = PerfProbe.ms(Self.clock.now - began)
                    if target == .chromium {
                        toChromium.append(elapsed)
                    } else {
                        toWebKit.append(elapsed)
                    }
                }
            }
            Self.report("E7-engine-switch-toChromium", PerfProbe.summary(toChromium) + " note=first-sample-starts-CEF-if-cold")
            Self.report("E7-engine-switch-toWebKit", PerfProbe.summary(toWebKit))
        }
    }
}
