// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CoreText
import Foundation
import XCTest

@testable import WSurf

/// What a person waits for on a page, in the window the app builds: a new tab to its first paint, a switch among loaded pages with a
/// crowded sidebar, Find, zoom, Reader and a PDF. WebKit only, and clock only: a live page's footprint swings more than a budget
/// can hold (`BrowserPerformanceTests.testSwitchingLoadedTabsInAWindow` is the precedent), and Chromium pages never run here (CEF in
/// this host breaks the memory metric of every case after it; `EngineBenchmarkTests` is their home). Each case prints a
/// `WSURF-BENCH` line with the per-operation figures the budget cannot show.
///
/// The window is the app's own (`BrowserApplication.newWindow`), in a profile of its own on the shared test data store, with
/// onboarding marked done in this host's defaults. The pages come from a loopback `HTTPFixtureServer`.
nonisolated final class WebPagePerformanceTests: XCTestCase, @unchecked Sendable {
    // MARK: - Fixtures

    @MainActor
    private final class Flag {
        var done = false
    }

    @MainActor
    private final class Box<Value> {
        var value: Value?
    }

    /// A small page, distinct for every `index`, with text to paint.
    private nonisolated static func plain(_ index: String) -> String {
        let rows = (0..<20).map { "<p>Paragraph \($0) of plain page \(index): some text to paint on the first frame.</p>" }.joined()
        return "<!doctype html><html><head><title>Plain \(index)</title></head><body><h1>Plain page \(index)</h1>\(rows)</body></html>"
    }

    /// Twenty pages of forty lines of text, drawn into a PDF context in memory.
    private nonisolated static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for page in 0..<pages {
            context.beginPDFPage(nil)
            for line in 0..<40 {
                let text = NSAttributedString(
                    string: "Page \(page + 1), line \(line + 1): the tide clock kept every ferry on time for nine decades.",
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                context.textPosition = CGPoint(x: 54, y: 740 - CGFloat(line) * 17)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The app's window in a profile of its own, and the server behind its pages. `shown` orders the window in without activating
    /// the app, for the case that needs paint timing.
    @MainActor
    private final class Rig {
        let server: HTTPFixtureServer
        let base: URL
        let catalog = ProfileStore.shared
        let previous: Profile
        let profile: Profile
        let app: BrowserApplication
        let coordinator: AppCoordinator
        var tabs: [BrowserTab] = []
        private let onboardingWas: Any?

        var browser: BrowserModel {
            coordinator.browser
        }

        init?(shown: Bool) {
            let started = Box<HTTPFixtureServer>()
            let flag = Flag()
            let article = ReaderFixtures.longArticle(bytes: 200_000)
            let pdf = WebPagePerformanceTests.pdf(pages: 20)
            Task {
                started.value = try? await HTTPFixtureServer.start(
                    routes: ["/article": .html(article), "/doc.pdf": .bytes(pdf, contentType: "application/pdf")],
                    respond: { request in
                        request.path.hasPrefix("/plain/")
                            ? .html(WebPagePerformanceTests.plain(String(request.path.dropFirst("/plain/".count)))) : nil
                    }
                )
                flag.done = true
            }
            guard PerfProbe.spin(timeout: 30, until: { flag.done }), let server = started.value,
                let base = try? server.url("/")
            else {
                XCTFail("The fixture server did not start.")
                return nil
            }
            self.server = server
            self.base = base
            onboardingWas = StageMode.defaults.object(forKey: "onboarding.completed")
            StageMode.defaults.set(true, forKey: "onboarding.completed")
            previous = catalog.current
            profile = catalog.add(name: "Web page performance")
            LiveWindowRig.useSharedDataStore(for: profile)
            app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
            coordinator = app.newWindow(profile: profile, show: false)
            if shown {
                coordinator.showBrowser(activate: false)
                coordinator.nativeWindow?.orderFrontRegardless()
            }
        }

        func url(_ path: String) -> URL {
            URL(string: String(base.absoluteString.dropLast()) + path) ?? base
        }

        func draw() {
            if let view = coordinator.nativeWindow?.contentView {
                PerfProbe.draw(view)
            }
        }

        /// Runs `work` to its end from this synchronous test, spinning the run loop its main-actor steps need.
        func run(timeout: TimeInterval = 120, _ work: @escaping @MainActor () async -> Void) {
            let flag = Flag()
            Task {
                await work()
                flag.done = true
            }
            XCTAssertTrue(PerfProbe.spin(timeout: timeout, until: { flag.done }), "The async step finished.")
        }

        /// A tab on `path` in front, once its page has loaded. Pages ignore the window being covered.
        @discardableResult
        func open(_ path: String) -> BrowserTab {
            let target = url(path)
            let tab = browser.newTab(url: target)
            tabs.append(tab)
            tab.page.ignoresWindowOcclusion = true
            XCTAssertTrue(PerfProbe.spin { tab.page.url == target && !tab.page.isLoading }, "\(path) loaded")
            draw()
            return tab
        }

        /// A tab on a page of its own that never touches the network.
        func loadedTab(_ index: Int) -> BrowserTab {
            let tab = browser.newTab()
            tabs.append(tab)
            tab.loadHTML(
                "<!doctype html><title>Page \(index)</title>" + String(repeating: "<p>Paragraph of page \(index).</p>", count: 200),
                baseURL: URL(string: "https://switch-\(index).example/")
            )
            draw()
            XCTAssertTrue(PerfProbe.spin { !tab.hasNoPageYet && !tab.isLoading }, "page \(index) loaded")
            return tab
        }

        /// Closes the window and every tab it opened, and removes the profile, as `testSwitchingLoadedTabsInAWindow` does.
        func tearDown() {
            let all = tabs + browser.tabs
            coordinator.closeWindow()
            coordinator.releaseWindowHost()
            run {
                for tab in all {
                    await tab.waitForRetirement()
                }
                await self.catalog.remove(self.profile)
                await LiveWindowRig.releaseSharedDataStore(for: self.profile)
                self.catalog.markCurrent(self.previous)
            }
            StageMode.defaults.set(onboardingWas, forKey: "onboarding.completed")
            withExtendedLifetime((app, server)) {}
        }
    }

    private static let clock = ContinuousClock()

    // MARK: - P1

    /// Five new tabs on a page of the loopback server, each timed from the call to the page loaded in a window that is ordered in
    /// (so it paints). The first contentful paint is read after the measured pass, with the page performance script the agent uses.
    func testOpeningANewTabToFirstPaint() {
        MainActor.assumeIsolated {
            guard let rig = Rig(shown: true) else { return }
            var index = 0
            var wall: [Double] = []
            var call: [Double] = []
            var paint: [Double] = []
            let options = XCTMeasureOptions.budgeted
            options.invocationOptions = [.manuallyStart, .manuallyStop]
            measure(metrics: [XCTClockMetric()], options: options) {
                index += 1
                let target = rig.url("/plain/\(index)")
                startMeasuring()
                let began = Self.clock.now
                let tab = rig.browser.newTab(url: target)
                call.append(PerfProbe.ms(Self.clock.now - began))
                rig.tabs.append(tab)
                tab.page.ignoresWindowOcclusion = true
                XCTAssertTrue(PerfProbe.spin { tab.page.url == target && !tab.page.isLoading }, "plain page \(index) loaded")
                wall.append(PerfProbe.ms(Self.clock.now - began))
                stopMeasuring()
                let report = Box<String>()
                rig.run { report.value = await PageDriver.readPerformance(in: tab.page) }
                paint.append(Self.firstContentfulPaint(in: report.value ?? ""))
                rig.browser.close(tab)
                rig.run { await tab.waitForRetirement() }
            }
            PerfProbe.report("P1-new-tab-to-load", PerfProbe.summary(wall) + " newTabCallMedianMs=\(String(format: "%.2f", Self.median(call)))")
            PerfProbe.report("P1-new-tab-fcp", PerfProbe.summary(paint) + " note=page-relative-ms-first-contentful-paint")
            rig.tearDown()
        }
    }

    private nonisolated static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    /// `paint.firstContentfulPaintMs` of a `PageDriver.readPerformance` reply, or -1.
    private nonisolated static func firstContentfulPaint(in reply: String) -> Double {
        guard let start = reply.firstIndex(of: "{"),
            let object = try? JSONSerialization.jsonObject(with: Data(reply[start...].prefix { $0 != "\n" }.utf8)) as? [String: Any],
            let paint = object["paint"] as? [String: Any], let value = paint["firstContentfulPaintMs"] as? NSNumber
        else { return -1 }
        return value.doubleValue
    }

    // MARK: - P2

    /// Sixteen switches among eight loaded pages in a window whose sidebar holds 300 rows in 10 folders: the shape the 0.1.22 audit
    /// found settling at rest. The clock holds the activations and their frames. Unmeasured, before and after: the main thread's CPU
    /// at rest and the sidebar's document height (a height that keeps changing is the settle loop), and the CPU of the 400 ms after
    /// each switch.
    func testSwitchingLoadedTabsInACrowdedWindowWithFolders() {
        MainActor.assumeIsolated {
            guard let rig = Rig(shown: false) else { return }
            let browser = rig.browser
            let rows = (0..<300).map { browser.addPage("https://fixture-\($0).example/") }
            for folder in 0..<10 {
                browser.createFolder(named: "Folder \(folder)", containing: Array(rows[folder * 30..<(folder + 1) * 30]))
            }
            let tabs = (0..<8).map { rig.loadedTab($0) }
            rig.draw()
            PerfProbe.idle(2)
            var rest: [Double] = []
            var heights: [CGFloat] = []
            for _ in 0..<5 {
                let before = PerfProbe.mainCPUms()
                PerfProbe.idle(0.4)
                rest.append(PerfProbe.mainCPUms() - before)
                heights.append(Self.tallestScrollDocument(in: rig.coordinator.nativeWindow?.contentView))
            }
            PerfProbe.report("P2-rest", PerfProbe.summary(rest) + " restDocHeights=\(heights.map { String(format: "%.1f", $0) })")
            var wall: [Double] = []
            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                for _ in 0..<2 {
                    for tab in tabs {
                        let began = Self.clock.now
                        browser.activate(tab)
                        rig.draw()
                        wall.append(PerfProbe.ms(Self.clock.now - began))
                    }
                }
            }
            var cpu: [Double] = []
            var after: [Double] = []
            for _ in 0..<2 {
                for tab in tabs {
                    let before = PerfProbe.mainCPUms()
                    browser.activate(tab)
                    rig.draw()
                    let switched = PerfProbe.mainCPUms()
                    cpu.append(switched - before)
                    PerfProbe.idle(0.4)
                    after.append(PerfProbe.mainCPUms() - switched)
                }
            }
            PerfProbe.report("P2-switch-wall", PerfProbe.summary(wall))
            PerfProbe.report("P2-switch-mainCpu", PerfProbe.summary(cpu))
            PerfProbe.report("P2-after400msCpu", PerfProbe.summary(after))
            rig.tearDown()
        }
    }

    @MainActor
    private static func tallestScrollDocument(in view: NSView?) -> CGFloat {
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrolls($0) }
        }
        guard let view else { return -1 }
        return scrolls(view).map { $0.documentView?.frame.height ?? 0 }.max() ?? -1
    }

    // MARK: - P3

    /// Find in a 200 KB page: open the bar, type a word that occurs in every paragraph, wait for the count, then ten steps to the
    /// next match, each waited for.
    func testFindingInALongPage() {
        MainActor.assumeIsolated {
            guard let rig = Rig(shown: false) else { return }
            let tab = rig.open("/article")
            var steps: [Double] = []
            var counted: [Double] = []
            var matches = 0
            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                let began = Self.clock.now
                tab.find.open()
                tab.find.query = "harbour"
                tab.find.queryDidChange()
                XCTAssertTrue(PerfProbe.spin(timeout: 30) { tab.find.totalMatches > 0 && tab.find.currentMatch > 0 }, "matches counted")
                counted.append(PerfProbe.ms(Self.clock.now - began))
                for _ in 0..<10 {
                    let current = tab.find.currentMatch
                    let step = Self.clock.now
                    tab.find.find()
                    _ = PerfProbe.spin(timeout: 10) { tab.find.currentMatch != current }
                    steps.append(PerfProbe.ms(Self.clock.now - step))
                }
                matches = tab.find.totalMatches
                tab.find.close()
            }
            PerfProbe.report("P3-find-open-and-count", PerfProbe.summary(counted) + " matches=\(matches)")
            PerfProbe.report("P3-find-step", PerfProbe.summary(steps))
            rig.tearDown()
        }
    }

    // MARK: - P4

    /// Six zoom steps on a 200 KB page, each followed by a frame and a round trip to the page, so the engine has applied it; then
    /// back to 100%.
    func testZoomingALongPage() {
        MainActor.assumeIsolated {
            guard let rig = Rig(shown: false) else { return }
            let tab = rig.open("/article")
            var steps: [Double] = []
            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                for _ in 0..<6 {
                    let began = Self.clock.now
                    tab.zoomIn()
                    rig.draw()
                    rig.run { _ = try? await tab.page.evaluateJavaScript("1") }
                    steps.append(PerfProbe.ms(Self.clock.now - began))
                }
                tab.resetZoom()
                rig.draw()
                rig.run { _ = try? await tab.page.evaluateJavaScript("1") }
            }
            PerfProbe.report("P4-zoom-step", PerfProbe.summary(steps))
            rig.tearDown()
        }
    }

    // MARK: - P5

    /// Reader for a 200 KB article: open it and draw its view, then close it and draw the page again.
    func testShowingReaderForALongArticle() {
        MainActor.assumeIsolated {
            guard let rig = Rig(shown: false) else { return }
            let tab = rig.open("/article")
            var opened: [Double] = []
            var closed: [Double] = []
            var shown = 0
            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                let began = Self.clock.now
                rig.coordinator.toggleReader()
                XCTAssertTrue(PerfProbe.spin(timeout: 30) { tab.reader.isActive }, "Reader opened")
                rig.draw()
                if PerfProbe.spin(timeout: 5, until: { tab.reader.presentedPage != nil }) {
                    shown += 1
                }
                rig.draw()
                opened.append(PerfProbe.ms(Self.clock.now - began))
                let closing = Self.clock.now
                rig.coordinator.toggleReader()
                rig.draw()
                closed.append(PerfProbe.ms(Self.clock.now - closing))
            }
            PerfProbe.report("P5-reader-open", PerfProbe.summary(opened) + " readerViewShown=\(shown)of\(opened.count)")
            PerfProbe.report("P5-reader-close", PerfProbe.summary(closed))
            rig.tearDown()
        }
    }

    // MARK: - P6

    /// A 20-page PDF in a new tab: from the call to the page loaded and two frames drawn. Falls back to the address alone when
    /// WebKit's PDF viewer never reports the load done (`pageReportedDone` says which).
    func testOpeningAPDF() {
        MainActor.assumeIsolated {
            guard let rig = Rig(shown: false) else { return }
            var index = 0
            var wall: [Double] = []
            var done = 0
            let options = XCTMeasureOptions.budgeted
            options.invocationOptions = [.manuallyStart, .manuallyStop]
            measure(metrics: [XCTClockMetric()], options: options) {
                index += 1
                let target = rig.url("/doc.pdf")
                startMeasuring()
                let began = Self.clock.now
                let tab = rig.browser.newTab(url: target)
                rig.tabs.append(tab)
                tab.page.ignoresWindowOcclusion = true
                if PerfProbe.spin(timeout: 15, until: { tab.page.url == target && !tab.page.isLoading }) {
                    done += 1
                } else {
                    XCTAssertEqual(tab.page.url, target, "The PDF's address is the page's")
                }
                rig.draw()
                rig.draw()
                wall.append(PerfProbe.ms(Self.clock.now - began))
                stopMeasuring()
                rig.browser.close(tab)
                rig.run { await tab.waitForRetirement() }
            }
            PerfProbe.report("P6-pdf-open", PerfProbe.summary(wall) + " pageReportedDone=\(done)of\(wall.count) bytes=\(Self.pdf(pages: 20).count)")
            rig.tearDown()
        }
    }
}
