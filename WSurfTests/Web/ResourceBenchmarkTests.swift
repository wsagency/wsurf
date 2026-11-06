// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

// What the app costs while it does nothing, and what it keeps: the sidebar at rest, the idle process family, memory per tab and
// per window, a critical-pressure discard, a large session restored to its front page, and a short soak.
//
// Reported, never budgeted: every case prints `WSURF-BENCH` lines (the process-wide numbers are not stable enough for a budget).
// Not in any plan and not named `*PerformanceTests`: the suite is in `Tools/serial-parts.json` `skippedSuites`, and each case is
// gated on `WSURF_PERF_BENCH=1` (`R7` also on `WSURF_PERF_SOAK=1`), so a developer's Cmd-U never runs it. WebKit only: Chromium
// is `ChromiumResourceBenchmarkTests`. Run with `-default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 900`.
//
// The numbers of the "resting sidebar" case are the main-thread CPU of the test host (`CLOCK_THREAD_CPUTIME_ID`); the idle,
// memory and soak cases read `proc_pid_rusage` of the host, its children and the WebKit processes it is responsible for.
private let benchEnabled = ProcessInfo.processInfo.environment["WSURF_PERF_BENCH"] == "1"
private let soakEnabled = benchEnabled && ProcessInfo.processInfo.environment["WSURF_PERF_SOAK"] == "1"

@MainActor
@Suite(.serialized)
struct ResourceBenchmarkTests {
    // MARK: - R1: the sidebar at rest

    /// Shapes of the 300-row list: `flat` loose rows only, `folders` 10 open folders of 20, `pins` 20 pinned rows, `splits` 10
    /// splits of 2 rows, `all` the three at once. 8 loaded WebKit pages sit after the rows. In a real window (not ordered in), at
    /// rest: main-thread CPU per 400 ms and the document height of the largest scroll view, which keeps changing while the
    /// sidebar's lazy stack re-estimates itself (0.1.22 audit); then 10 switches among the loaded pages.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)), arguments: ["flat", "folders", "pins", "splits", "all"])
    func restingSidebarCPU(shape: String) async throws {
        try await ResourceRig.with(name: "Resting sidebar \(shape)") { rig in
            let coordinator = rig.newWindow()
            let browser = coordinator.browser
            let rows = (0..<300).map { PerfProbe.addBackgroundTab(to: browser, address: "https://fixture-\($0).example/") }
            let viewsBefore = TabWebView.liveInstances.allObjects.count
            if shape == "folders" || shape == "all" {
                for index in 0..<10 {
                    browser.createFolder(named: "Folder \(index)", containing: Array(rows[index * 20..<(index + 1) * 20]))
                }
            }
            if shape == "pins" || shape == "all" {
                for tab in rows[200..<220] {
                    browser.pin(tab)
                }
            }
            if shape == "splits" || shape == "all" {
                for index in 0..<10 {
                    browser.split(rows[220 + 2 * index], with: rows[221 + 2 * index], axis: .sideBySide)
                }
            }
            let viewsAfterShape = TabWebView.liveInstances.allObjects.count
            var loaded: [BrowserTab] = []
            for index in 0..<8 {
                let tab = browser.newTab()
                loaded.append(tab)
                rig.track(tab)
                tab.loadHTML(Self.page(index), baseURL: URL(string: "https://audit-\(index).example/"))
                Self.draw(coordinator)
                #expect(PerfProbe.spin { !tab.hasNoPageYet && !tab.isLoading }, "page \(index) loaded")
            }
            browser.activate(loaded[7])
            Self.draw(coordinator)

            PerfProbe.idle(2)
            let host = getpid()
            let usage0 = PerfProbe.usage(of: host)
            let wall0 = ContinuousClock.now
            var rest: [Double] = []
            var heights: [Double] = []
            for _ in 0..<5 {
                let cpu0 = PerfProbe.mainCPUms()
                PerfProbe.idle(0.4)
                rest.append(PerfProbe.mainCPUms() - cpu0)
                heights.append(Self.largestDocumentHeight(in: coordinator))
            }
            let seconds = PerfProbe.ms(ContinuousClock.now - wall0) / 1_000
            let hostCPUPercent = (PerfProbe.usage(of: host).map { $0.cpuSeconds } ?? 0) - (usage0?.cpuSeconds ?? 0)
            let varies = (heights.max() ?? 0) - (heights.min() ?? 0)
            PerfProbe.report(
                "R1-rest shape=\(shape)",
                PerfProbe.summary(rest) + String(
                    format: " restShareOfCorePct=%.1f hostCpuPct=%.1f docHeights=%@ docHeightRange=%.2f tabs=%d liveViewsBefore=%d liveViewsAfterShape=%d",
                    (rest.reduce(0, +) / 2_000) * 100, hostCPUPercent / seconds * 100,
                    heights.map { String(format: "%.1f", $0) }.joined(separator: ","), varies,
                    browser.tabs.count, viewsBefore, viewsAfterShape
                )
            )

            var wall: [Double] = []
            var cpu: [Double] = []
            var after: [Double] = []
            let clock = ContinuousClock()
            for step in 0..<10 {
                let tab = loaded[step % 8]
                guard tab !== browser.activeTab else { continue }
                let cpu0 = PerfProbe.mainCPUms()
                let started = clock.now
                browser.activate(tab)
                _ = PerfProbe.spin(timeout: 5) { tab.page.nativeView.window != nil }
                Self.draw(coordinator)
                wall.append(PerfProbe.ms(clock.now - started))
                let cpu1 = PerfProbe.mainCPUms()
                cpu.append(cpu1 - cpu0)
                PerfProbe.idle(0.4)
                after.append(PerfProbe.mainCPUms() - cpu1)
            }
            PerfProbe.report("R1-switch shape=\(shape)", "wall: " + PerfProbe.summary(wall))
            PerfProbe.report("R1-switch shape=\(shape)", "mainCpu: " + PerfProbe.summary(cpu))
            PerfProbe.report("R1-switch shape=\(shape)", "after400msCpu: " + PerfProbe.summary(after))
        }
    }

    // MARK: - R2: the idle process family

    /// 20 s with the window ordered in and nothing happening, per process of the family: CPU as a share of one core, idle
    /// wakeups per second, billed energy and footprint. `/page` animates a canvas, `/still` does not.
    @Test(
        .enabled(if: benchEnabled), .timeLimit(.minutes(5)),
        arguments: ["startPage", "threeStaticPages", "animatedFront", "animatedBackground"]
    )
    func idleFamily(state: String) async throws {
        try await LiveWindowRig.with(engine: .webKit) { rig in
            var animated: BrowserTab?
            switch state {
            case "threeStaticPages":
                for _ in 0..<3 { _ = try await rig.open("/still") }
            case "animatedFront":
                animated = try await rig.open("/page")
            case "animatedBackground":
                animated = try await rig.open("/page", grace: .zero)
                _ = try await rig.open("/still")
            default:
                break
            }
            try await Task.sleep(for: .seconds(3))
            if let animated {
                let visibility = await rig.state(of: animated) ?? "?"
                let framesPerSecond = await rig.framesInASecond(of: animated)
                PerfProbe.report("R2-state state=\(state)", "animatedTabVisibility=\(visibility) animatedTabFramesPerSecond=\(framesPerSecond)")
            }
            await ResourceProbe.idleTable("R2-idle state=\(state)", seconds: 20)
        }
    }

    // MARK: - R3: memory per WebKit tab

    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func memoryPerWebKitTab() async throws {
        try await LiveWindowRig.with(engine: .webKit, routes: Self.plainRoutes) { rig in
            let browser = rig.browser
            var stages: [ResourceProbe.Stage] = []
            func record(_ label: String) {
                let stage = ResourceProbe.stage(label)
                stages.append(stage)
                stage.report("R3-memory")
            }
            record("0-tabs")
            var tabs: [BrowserTab] = []
            for index in 0..<10 {
                tabs.append(try await rig.open("/plain/\(index)"))
                if [0, 4, 9].contains(index) {
                    try await Task.sleep(for: .seconds(2))
                    record("\(index + 1)-tabs")
                }
            }
            for tab in tabs {
                browser.close(tab)
            }
            for tab in tabs {
                await tab.waitForRetirement()
            }
            try await Task.sleep(for: .seconds(10))
            record("closed+10s")
            try await Task.sleep(for: .seconds(20))
            record("closed+30s")
            var again: [BrowserTab] = []
            for index in 10..<20 { again.append(try await rig.open("/plain/\(index)")) }
            try await Task.sleep(for: .seconds(2))
            record("reopened-10")
            let discarded = browser.discardBackgroundTabs(keepingRecent: 0)
            try await Task.sleep(for: .seconds(10))
            record("discarded(\(discarded))+10s")
            if let first = stages.first, stages.count > 3 {
                let ten = stages[3]
                PerfProbe.report(
                    "R3-perTab",
                    String(
                        format: "familyMBPerTab=%.1f hostMBPerTab=%.1f webContentMBPerTab=%.1f webContentCountAt10=%d",
                        (ten.total - first.total) / 10, (ten.host - first.host) / 10,
                        (ten.webContent - first.webContent) / 10, ten.webContentCount
                    )
                )
            }
        }
    }

    // MARK: - R4: memory per window

    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func memoryPerWindow() async throws {
        try await ResourceRig.with(name: "Memory per window") { rig in
            var stages = [ResourceProbe.Stage]()
            func record(_ label: String) {
                let stage = ResourceProbe.stage(label)
                stages.append(stage)
                stage.report("R4-memory")
            }
            record("0-windows")
            var windows: [AppCoordinator] = []
            for index in 1...3 {
                let coordinator = rig.newWindow()
                windows.append(coordinator)
                Self.draw(coordinator)
                PerfProbe.idle(1)
                record("\(index)-windows")
            }
            for coordinator in windows {
                rig.close(coordinator)
            }
            try await Task.sleep(for: .seconds(10))
            record("closed+10s")
            if stages.count == 5 {
                PerfProbe.report(
                    "R4-perWindow",
                    String(
                        format: "familyMBPerWindow=%.1f hostMBPerWindow=%.1f returnedFamilyMB=%.1f returnedHostMB=%.1f",
                        (stages[3].total - stages[0].total) / 3, (stages[3].host - stages[0].host) / 3,
                        stages[3].total - stages[4].total, stages[3].host - stages[4].host
                    )
                )
            }
        }
    }

    // MARK: - R5: critical memory pressure

    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func criticalPressureDiscard() async throws {
        try await LiveWindowRig.with(engine: .webKit, routes: Self.plainRoutes) { rig in
            let browser = rig.browser
            for index in 0..<20 { _ = try await rig.open("/plain/\(index)") }
            try await Task.sleep(for: .seconds(3))
            let materialisedBefore = browser.tabs.filter(\.isMaterialised).count
            let viewsBefore = TabWebView.liveInstances.allObjects.count
            ResourceProbe.stage("before").report("R5-memory")
            let clock = ContinuousClock()
            let started = clock.now
            browser.relieveMemoryPressure(.critical)
            let callMs = PerfProbe.ms(clock.now - started)
            let materialisedAfter = browser.tabs.filter(\.isMaterialised).count
            PerfProbe.report(
                "R5-call",
                String(
                    format: "callMs=%.2f tabs=%d materialisedBefore=%d materialisedAfter=%d unloaded=%d liveViewsBefore=%d liveViewsAfter=%d",
                    callMs, browser.tabs.count, materialisedBefore, materialisedAfter, materialisedBefore - materialisedAfter,
                    viewsBefore, TabWebView.liveInstances.allObjects.count
                )
            )
            try await Task.sleep(for: .seconds(5))
            ResourceProbe.stage("+5s").report("R5-memory")
            try await Task.sleep(for: .seconds(10))
            ResourceProbe.stage("+15s").report("R5-memory")
        }
    }

    // MARK: - R6: restoring a large session to its front page

    /// A saved window of 300 rows in 10 folders whose front tab is a page on the fixture server, restored the way a launch does
    /// (`beginLaunchRestore`, then a draw), three times. Then: until the front page has loaded, and its first contentful paint.
    @Test(.enabled(if: benchEnabled), .timeLimit(.minutes(5)))
    func restoringALargeSessionToTheFrontPage() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/plain/0": .html(Self.plainPage(0))])
        let frontURL = try server.url("/plain/0")
        try await ResourceRig.with(name: "Large session") { rig in
            let context = BrowserProfileContext.shared(for: rig.profile)
            let model = BrowserModel(context: context, windowID: UUID())
            let pages = (0..<300).map { model.addPage("https://fixture-\($0).example/") }
            for index in 0..<10 {
                model.createFolder(named: "Folder \(index)", containing: Array(pages[index * 30..<(index + 1) * 30]))
            }
            let front = model.addPage(frontURL.absoluteString)
            model.activeTabID = front.id
            model.saveBlocking()
            model.cancelPendingSave()
            var restoreMs: [Double] = []
            var loadMs: [Double] = []
            var fcp: [Double] = []
            var rowsRestored: [Int] = []
            let clock = ContinuousClock()
            for pass in 0..<4 {
                let started = clock.now
                _ = rig.app.beginLaunchRestore(of: [rig.profile], lastWindowID: model.windowID, launchProfileID: nil, show: false)
                guard let coordinator = rig.app.windows.last else {
                    Issue.record("pass \(pass): no window was restored")
                    break
                }
                rig.adopt(coordinator)
                Self.draw(coordinator)
                let restored = PerfProbe.ms(clock.now - started)
                coordinator.showBrowser(activate: false)
                coordinator.nativeWindow?.orderFrontRegardless()
                guard let tab = coordinator.browser.activeTab, tab.urlString == frontURL.absoluteString else {
                    Issue.record("pass \(pass): the front tab is not the saved page")
                    rig.closeForRestart(coordinator)
                    continue
                }
                rig.track(tab)
                tab.page.ignoresWindowOcclusion = true
                let loaded = PerfProbe.spin(timeout: 60) { tab.page.url == frontURL && !tab.hasNoPageYet && !tab.isLoading }
                let toLoad = PerfProbe.ms(clock.now - started)
                let report = await PageDriver.readPerformance(in: tab.page)
                if pass > 0 {
                    restoreMs.append(restored)
                    rowsRestored.append(coordinator.browser.tabs.count)
                    if loaded {
                        loadMs.append(toLoad)
                    }
                    if let paint = Self.firstContentfulPaint(in: report) {
                        fcp.append(paint)
                    }
                }
                rig.closeForRestart(coordinator)
                try await Task.sleep(for: .milliseconds(300))
            }
            PerfProbe.report("R6-restore", "restoreAndFirstDrawMs: " + PerfProbe.summary(restoreMs) + " rows=\(rowsRestored)")
            PerfProbe.report("R6-restore", "toFrontPageLoadedMs: " + PerfProbe.summary(loadMs))
            PerfProbe.report("R6-restore", "firstContentfulPaintMs(engine-relative): " + PerfProbe.summary(fcp))
        }
        withExtendedLifetime(server) {}
    }

    // MARK: - R7: a short soak

    /// Three minutes: a tab is opened every 2 s (20 fixture pages in turn), one of the last 8 is activated every second, and the
    /// oldest is closed whenever more than 10 are live. Footprints every 30 s, then everything closed and one more at +10 s.
    @Test(.enabled(if: soakEnabled), .timeLimit(.minutes(5)))
    func longSessionGrowth() async throws {
        try await LiveWindowRig.with(engine: .webKit, routes: Self.plainRoutes) { rig in
            let browser = rig.browser
            let clock = ContinuousClock()
            let began = clock.now
            var live: [BrowserTab] = []
            var closed: [WeakTab] = []
            var series: [(minutes: Double, host: Double, family: Double)] = []
            func record(_ label: String) {
                let stage = ResourceProbe.stage(label)
                let minutes = PerfProbe.ms(clock.now - began) / 60_000
                series.append((minutes, stage.host, stage.total))
                PerfProbe.report(
                    "R7-soak",
                    String(
                        format: "at=%@ minutes=%.2f hostMB=%.1f familyMB=%.1f procs=%d liveWebViews=%d tabs=%d",
                        label, minutes, stage.host, stage.total, stage.count,
                        TabWebView.liveInstances.allObjects.count, browser.tabs.count
                    )
                )
            }
            record("start")
            var opened = 0
            for tick in 1...180 {
                if tick % 2 == 1 {
                    live.append(try await rig.open("/plain/\(opened % 20)"))
                    opened += 1
                }
                while live.count > 10 {
                    let oldest = live.removeFirst()
                    closed.append(WeakTab(oldest))
                    browser.close(oldest)
                }
                let recent = live.suffix(8)
                if let tab = recent.dropFirst(tick % max(recent.count, 1)).first ?? recent.first {
                    browser.activate(tab)
                }
                if tick % 30 == 0 { record("t\(tick)s") }
                let next = began + .seconds(tick)
                if clock.now < next {
                    try await Task.sleep(until: next, clock: clock)
                }
            }
            for tab in live {
                closed.append(WeakTab(tab))
                browser.close(tab)
            }
            live.removeAll()
            try await Task.sleep(for: .seconds(10))
            record("closedAll+10s")
            let alive = closed.filter { $0.tab != nil }.count
            let slopeSeries = series.filter { $0.minutes > 0.1 && $0.minutes < 3.1 }
            PerfProbe.report(
                "R7-slope",
                String(
                    format: "hostMBPerMin=%.2f familyMBPerMin=%.2f opened=%d closedTabsProbed=%d closedTabsStillAlive=%d liveWebViewsAtEnd=%d tabsAtEnd=%d",
                    ResourceProbe.slope(slopeSeries.map { ($0.minutes, $0.host) }),
                    ResourceProbe.slope(slopeSeries.map { ($0.minutes, $0.family) }),
                    opened, closed.count, alive, TabWebView.liveInstances.allObjects.count, browser.tabs.count
                )
            )
        }
    }

    // MARK: - Helpers

    private final class WeakTab {
        weak var tab: BrowserTab?
        init(_ tab: BrowserTab) {
            self.tab = tab
        }
    }

    private static func plainPage(_ index: Int) -> String {
        "<!doctype html><title>Plain \(index)</title>"
            + (0..<200).map { "<p>Paragraph \($0) of page \(index) with <a href='#\($0)'>a link</a> and some text.</p>" }.joined()
    }

    private static var plainRoutes: [String: HTTPFixtureServer.Response] {
        Dictionary(uniqueKeysWithValues: (0..<30).map { ("/plain/\($0)", HTTPFixtureServer.Response.html(plainPage($0))) })
    }

    private static func page(_ index: Int) -> String {
        let rows = (0..<200).map { "<p>Paragraph \($0) of page \(index) with <a href='#\($0)'>a link</a> and some text.</p>" }.joined()
        return """
            <!doctype html><html><head><title>Page \(index)</title></head><body>
            <form><input type=email name=email autocomplete=username><input type=password name=password></form>
            \(rows)</body></html>
            """
    }

    private static func draw(_ coordinator: AppCoordinator) {
        if let view = coordinator.nativeWindow?.contentView {
            PerfProbe.draw(view)
        }
    }

    /// The height of the tallest scroll view's document: the sidebar list. It changes between passes while the lazy stack is
    /// still settling.
    private static func largestDocumentHeight(in coordinator: AppCoordinator) -> Double {
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrolls($0) }
        }
        guard let content = coordinator.nativeWindow?.contentView else { return -1 }
        return Double(scrolls(content).map { $0.documentView?.frame.height ?? 0 }.max() ?? -1)
    }

    /// `firstContentfulPaintMs` of the "PERFORMANCE:\n{json}" report of `PageDriver.readPerformance`.
    private static func firstContentfulPaint(in report: String) -> Double? {
        guard let newline = report.firstIndex(of: "\n"),
              let json = try? JSONSerialization.jsonObject(with: Data(report[report.index(after: newline)...].utf8)) as? [String: Any],
              let paint = json["paint"] as? [String: Any]
        else { return nil }
        return (paint["firstContentfulPaintMs"] as? NSNumber)?.doubleValue
    }
}

/// Process-family accounting shared by the resource suites.
@MainActor
enum ResourceProbe {
    struct Stage {
        var label: String
        var host = 0.0
        var webContent = 0.0
        var webContentCount = 0
        var gpu = 0.0
        var networking = 0.0
        var other = 0.0
        var otherCount = 0
        var total = 0.0
        var count = 0
        var hostWakeups: UInt64 = 0

        func report(_ name: String) {
            PerfProbe.report(
                "\(name) step=\(label)",
                String(
                    format: "hostMB=%.1f webContentCount=%d webContentMB=%.1f gpuMB=%.1f networkingMB=%.1f otherCount=%d otherMB=%.1f totalMB=%.1f procs=%d",
                    host, webContentCount, webContent, gpu, networking, otherCount, other, total, count
                )
            )
        }
    }

    static func stage(_ label: String) -> Stage {
        let megabyte = 1_048_576.0
        var stage = Stage(label: label)
        for member in PerfProbe.family() {
            guard let usage = PerfProbe.usage(of: member.pid) else { continue }
            let size = Double(usage.footprint) / megabyte
            stage.total += size
            stage.count += 1
            if member.pid == getpid() {
                stage.host = size
                stage.hostWakeups = usage.wakeups
            } else if member.name.contains("WebContent") {
                stage.webContent += size
                stage.webContentCount += 1
            } else if member.name.contains("GPU") {
                stage.gpu += size
            } else if member.name.contains("Networking") {
                stage.networking += size
            } else {
                stage.other += size
                stage.otherCount += 1
            }
        }
        return stage
    }

    /// Least-squares slope of `points` (x, y).
    static func slope(_ points: [(Double, Double)]) -> Double {
        let n = Double(points.count)
        guard n >= 2 else { return 0 }
        let sx = points.reduce(0) { $0 + $1.0 }, sy = points.reduce(0) { $0 + $1.1 }
        let sxy = points.reduce(0) { $0 + $1.0 * $1.1 }, sxx = points.reduce(0) { $0 + $1.0 * $1.0 }
        let denominator = n * sxx - sx * sx
        return denominator == 0 ? 0 : (n * sxy - sx * sy) / denominator
    }

    /// Sits idle for `seconds` (the run loop sleeps; nothing is driven) and prints, per process of the family, its CPU as a share
    /// of one core, idle wakeups per second, billed energy per second and footprint, then the family's sum.
    static func idleTable(_ name: String, seconds: Double, prefix: String = "WSURF-BENCH") async {
        let members = PerfProbe.family()
        var before: [pid_t: PerfProbe.ProcessUsage] = [:]
        for member in members {
            if let usage = PerfProbe.usage(of: member.pid) {
                before[member.pid] = usage
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        try? await Task.sleep(for: .seconds(seconds))
        let elapsed = PerfProbe.ms(clock.now - started) / 1_000
        var sumCPU = 0.0, sumWakeups = 0.0, sumEnergy = 0.0, sumMB = 0.0
        for member in members {
            guard let first = before[member.pid], let last = PerfProbe.usage(of: member.pid) else { continue }
            let cpu = (last.cpuSeconds - first.cpuSeconds) / elapsed * 100
            let wakeups = Double(last.wakeups &- first.wakeups) / elapsed
            let energy = Double(last.billedEnergy &- first.billedEnergy) / 1e6 / elapsed
            let megabytes = Double(last.footprint) / 1_048_576
            sumCPU += cpu
            sumWakeups += wakeups
            sumEnergy += energy
            sumMB += megabytes
            print(String(
                format: "%@ case=%@ proc=%@ pid=%d cpuPct=%.2f wakeupsPerSec=%.1f energyMjPerSec=%.2f footprintMB=%.1f seconds=%.1f",
                prefix, name, member.name.replacingOccurrences(of: " ", with: "_"), member.pid, cpu, wakeups, energy, megabytes, elapsed
            ))
        }
        print(String(
            format: "%@ case=%@ proc=FAMILY-TOTAL cpuPct=%.2f wakeupsPerSec=%.1f energyMjPerSec=%.2f footprintMB=%.1f procs=%d seconds=%.1f",
            prefix, name, sumCPU, sumWakeups, sumEnergy, sumMB, members.count, elapsed
        ))
    }
}

/// A profile of its own, with the shared WebKit store and onboarding marked done, and an app whose windows are not ordered in.
@MainActor
final class ResourceRig {
    let app: BrowserApplication
    let notifications = NotificationCenter()
    let profile: Profile
    private let catalog = ProfileStore.shared
    private let previous: Profile
    private let onboarding: Any?
    private var coordinators: [AppCoordinator] = []
    private var tabs: [BrowserTab] = []

    private init(name: String) {
        let defaults = StageMode.defaults
        onboarding = defaults.object(forKey: "onboarding.completed")
        defaults.set(true, forKey: "onboarding.completed")
        previous = catalog.current
        profile = catalog.add(name: name)
        LiveWindowRig.useSharedDataStore(for: profile)
        app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: notifications)
    }

    static func with(name: String, _ body: @MainActor (ResourceRig) async throws -> Void) async throws {
        let rig = ResourceRig(name: name)
        var failure: (any Error)?
        do {
            try await body(rig)
        } catch {
            failure = error
        }
        await rig.finish()
        if let failure {
            throw failure
        }
    }

    func newWindow() -> AppCoordinator {
        let coordinator = app.newWindow(profile: profile, show: false)
        coordinators.append(coordinator)
        return coordinator
    }

    func adopt(_ coordinator: AppCoordinator) {
        coordinators.append(coordinator)
    }

    func track(_ tab: BrowserTab) {
        tabs.append(tab)
    }

    /// Closes a window the way `LaunchPerformanceTests` does after a pass: the window and its SwiftUI graph go now.
    func close(_ coordinator: AppCoordinator) {
        coordinator.browser.cancelPendingSave()
        coordinator.nativeWindow?.contentView = nil
        coordinator.nativeWindow?.close()
        coordinator.releaseWindowHost()
        coordinator.application = nil
        coordinator.windowDidClose()
        coordinators.removeAll { $0 === coordinator }
    }

    /// The same, after a terminate notification, so the window stays saved as open for the next pass.
    func closeForRestart(_ coordinator: AppCoordinator) {
        notifications.post(name: NSApplication.willTerminateNotification, object: nil)
        for tab in coordinator.browser.tabs where tab.isMaterialised {
            tabs.append(tab)
        }
        close(coordinator)
    }

    private func finish() async {
        for coordinator in coordinators {
            close(coordinator)
        }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        await catalog.remove(profile)
        await LiveWindowRig.releaseSharedDataStore(for: profile)
        catalog.markCurrent(previous)
        StageMode.defaults.set(onboarding, forKey: "onboarding.completed")
    }
}
