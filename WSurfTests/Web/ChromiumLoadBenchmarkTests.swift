// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import WebKit
import XCTest

@testable import WSurf

// What Chromium's DevTools connection costs the main thread while a page loads: the events of a busy load, the context lookups
// of a page with many frames, the start-up commands of a tab, and the pause of cross-site frames until their scripts are in.
//
// These cases are reported, not budgeted (no entry in `Tools/check-performance.sh`): the clock of a case is in the result bundle's
// metrics, and each case prints `WSURF-LOAD-BENCH` lines with the main thread's CPU time and the counts, which do not depend on the machine. The counts are
// asserted where they are the point of a change. A run on a quiet Mac, `-parallel-testing-enabled NO`, is the only fair one.
//
// Not in the WSurf-Performance plan, and not named `*PerformanceTests`, on purpose. `testPreparingAChromiumTab` and
// `testLoadingAPageWithCrossSiteFrames` start CEF inside an XCTest method, and once CEF runs in an XCTest host, XCTest's CPU and
// memory metrics crash it (`objc_release` in `-[MXMInstrument measureAutomatically:options:block:]`, on the first `measure` with
// `XCTMemoryMetric` after it; `XCTCPUMetric` was seen to abort such a host too). In the Performance plan that cost the budgeted
// case that ran next its metrics, and `Tools/check-performance.sh` then failed on the missing sample. This class measures only the
// clock, which is unaffected, and no suite of the Serial plan uses a CPU or memory metric. Do not add one there. Run it alone, or
// in the Serial plan.
//
// XCTest owns and runs one instance serially. Sendable lets its synchronous measurement callback enter the app target's main-actor
// boundary.
nonisolated final class ChromiumLoadBenchmarkTests: XCTestCase, @unchecked Sendable {
    /// The main thread's CPU time so far, in milliseconds. A load mostly waits for Chromium, so its clock moves little when the main
    /// thread does less, and the work the main thread did is what this layer is about. (`XCTCPUMetric` aborts this test host.)
    private static func mainThreadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    private static var metrics: [XCTMetric] {
        [XCTClockMetric()]
    }

    // MARK: Events

    /// 200 resources, five events each in the shapes Chromium sends them (about 1.6 KB, 1.1 KB, 2.8 KB, 0.9 KB and 0.1 KB), one
    /// resource in 50 a document, handed to the page's session as CEF hands them: a name and the parameters as JSON.
    func testReceivingTheNetworkEventsOfABusyPageLoad() {
        MainActor.assumeIsolated {
            let context = BrowserProfileContext(profile: .privateBrowsing())
            let native = ChromiumPage(context: context)
            let devTools = ChromiumDevTools(page: native)
            let events = (0..<200).flatMap { Self.events(ofResource: $0) }
            let repeats = 10
            var delivered = 0
            var cpu = 0.0
            var runs = 0
            measure(metrics: Self.metrics, options: .budgeted) {
                let began = Self.mainThreadCPU()
                defer {
                    cpu += Self.mainThreadCPU() - began
                    runs += 1
                }
                for _ in 0..<repeats {
                    for event in events {
                        event.payload.withUnsafeBytes { bytes in
                            devTools.receiveEvent(name: event.name, pointer: bytes.baseAddress, size: bytes.count)
                        }
                        delivered += 1
                    }
                }
            }
            let statistics = devTools.loadStatistics
            print("WSURF-LOAD-BENCH case=events delivered=\(delivered) received=\(statistics.eventsReceived) parsed=\(statistics.eventsParsed) "
                + "mainCpuMsPerRun=\(String(format: "%.2f", cpu / Double(max(runs, 1))))")
            XCTAssertEqual(statistics.eventsReceived, delivered)
            withExtendedLifetime(native) {}
        }
    }

    private struct Event {
        let name: String
        let payload: Data
    }

    private static func events(ofResource index: Int) -> [Event] {
        let id = "4242.\(index + 1)"
        let isDocument = index % 50 == 0
        let type = isDocument ? "Document" : ["Script", "Image", "Stylesheet", "Font", "XHR"][index % 5]
        let url = "https://cdn\(index % 7).example.net/assets/\(index)/bundle.min.js?v=20261026&session=\(index * 7919)"
        func object(_ pairs: [(String, String)]) -> String {
            "{" + pairs.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",") + "}"
        }
        let requestHeaders = object([
            ("Accept", "*/*"), ("Accept-Encoding", "gzip, deflate, br, zstd"), ("Accept-Language", "en-US,en;q=0.9"),
            ("Cache-Control", "no-cache"), ("Pragma", "no-cache"), ("Referer", "https://www.example.com/news/story/\(index)"),
            ("Sec-Fetch-Dest", "script"), ("Sec-Fetch-Mode", "no-cors"), ("Sec-Fetch-Site", "cross-site"),
            ("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"),
            ("sec-ch-ua", "\\\"Not A(Brand\\\";v=\\\"99\\\", \\\"Chromium\\\";v=\\\"154\\\""), ("sec-ch-ua-mobile", "?0"), ("sec-ch-ua-platform", "\\\"macOS\\\""),
        ])
        let responseHeaders = object([
            ("accept-ranges", "bytes"), ("access-control-allow-origin", "*"), ("age", "10234"),
            ("cache-control", "public, max-age=31536000, immutable"), ("content-encoding", "br"), ("content-length", "48213"),
            ("content-type", "text/javascript; charset=utf-8"), ("date", "Mon, 26 Oct 2026 19:00:00 GMT"),
            ("etag", "\\\"5f3a9c1e8b7d4a2c\\\""), ("last-modified", "Tue, 20 Oct 2026 08:00:00 GMT"),
            ("server", "cloudflare"), ("strict-transport-security", "max-age=31536000; includeSubDomains"),
            ("vary", "Accept-Encoding"), ("x-content-type-options", "nosniff"), ("cf-ray", "8f2a1b3c4d5e6f70-AMS"),
        ])
        let timing = "{\"requestTime\":1234.5,\"proxyStart\":-1,\"proxyEnd\":-1,\"dnsStart\":0.3,\"dnsEnd\":4.2,\"connectStart\":4.2,"
            + "\"connectEnd\":21.7,\"sslStart\":9.8,\"sslEnd\":21.7,\"workerStart\":-1,\"workerReady\":-1,\"workerFetchStart\":-1,"
            + "\"workerRespondWithSettled\":-1,\"sendStart\":22.1,\"sendEnd\":22.3,\"pushStart\":0,\"pushEnd\":0,\"receiveHeadersStart\":58.9,"
            + "\"receiveHeadersEnd\":59.4}"
        let security = "{\"protocol\":\"TLS 1.3\",\"keyExchange\":\"\",\"keyExchangeGroup\":\"X25519MLKEM768\",\"cipher\":\"AES_128_GCM\","
            + "\"certificateId\":0,\"subjectName\":\"cdn.example.net\",\"sanList\":[\"cdn.example.net\",\"*.cdn.example.net\"],"
            + "\"issuer\":\"Example CA 1\",\"validFrom\":1760000000,\"validTo\":1790000000,\"signedCertificateTimestampList\":[],"
            + "\"certificateTransparencyCompliance\":\"compliant\",\"serverSignatureAlgorithm\":2052,\"encryptedClientHello\":false}"
        let request = "{\"url\":\"\(url)\",\"method\":\"GET\",\"headers\":\(requestHeaders),\"mixedContentType\":\"none\","
            + "\"initialPriority\":\"Low\",\"referrerPolicy\":\"strict-origin-when-cross-origin\",\"isSameSite\":false}"
        let initiator = "{\"type\":\"parser\",\"url\":\"https://www.example.com/news/story/\(index)\",\"lineNumber\":\(index % 90),\"columnNumber\":\(index % 40)}"
        let response = "{\"url\":\"\(url)\",\"status\":200,\"statusText\":\"\",\"headers\":\(responseHeaders),\"mimeType\":\"text/javascript\","
            + "\"charset\":\"utf-8\",\"connectionReused\":true,\"connectionId\":\(100 + index % 6),\"remoteIPAddress\":\"104.18.\(index % 250).7\","
            + "\"remotePort\":443,\"fromDiskCache\":false,\"fromServiceWorker\":false,\"fromPrefetchCache\":false,\"fromEarlyHints\":false,"
            + "\"encodedDataLength\":412,\"timing\":\(timing),\"responseTime\":1.7e12,\"protocol\":\"h3\",\"alternateProtocolUsage\":\"unspecifiedReason\","
            + "\"securityState\":\"secure\",\"securityDetails\":\(security)}"
        let sent = "{\"requestId\":\"\(id)\",\"loaderId\":\"7E4B1C0A9D2F\",\"documentURL\":\"https://www.example.com/news/story/\(index)\","
            + "\"request\":\(request),\"timestamp\":1234.5,\"wallTime\":1.7e9,\"initiator\":\(initiator),\"redirectHasExtraInfo\":false,"
            + "\"type\":\"\(type)\",\"frameId\":\"B1A2C3D4E5F60718293A4B5C6D7E8F90\",\"hasUserGesture\":false}"
        let sentExtra = "{\"requestId\":\"\(id)\",\"associatedCookies\":[],\"headers\":\(requestHeaders),\"connectTiming\":{\"requestTime\":1234.5},"
            + "\"clientSecurityState\":{\"initiatorIsSecureContext\":true,\"initiatorIPAddressSpace\":\"Public\",\"privateNetworkRequestPolicy\":\"PreflightWarn\"},"
            + "\"siteHasCookieInOtherPartition\":false}"
        let received = "{\"requestId\":\"\(id)\",\"loaderId\":\"7E4B1C0A9D2F\",\"timestamp\":1234.6,\"type\":\"\(type)\",\"response\":\(response),"
            + "\"hasExtraInfo\":true,\"frameId\":\"B1A2C3D4E5F60718293A4B5C6D7E8F90\"}"
        let receivedExtra = "{\"requestId\":\"\(id)\",\"blockedCookies\":[],\"headers\":\(object([("content-type", "text/javascript"), ("vary", "Accept-Encoding"), ("server", "cloudflare")])),"
            + "\"resourceIPAddressSpace\":\"Public\",\"statusCode\":200,\"headersText\":\"HTTP/1.1 200 OK\\r\\n\"}"
        let finished = "{\"requestId\":\"\(id)\",\"timestamp\":1234.7,\"encodedDataLength\":48213}"
        return [
            Event(name: "Network.requestWillBeSent", payload: Data(sent.utf8)),
            Event(name: "Network.requestWillBeSentExtraInfo", payload: Data(sentExtra.utf8)),
            Event(name: "Network.responseReceived", payload: Data(received.utf8)),
            Event(name: "Network.responseReceivedExtraInfo", payload: Data(receivedExtra.utf8)),
            Event(name: "Network.loadingFinished", payload: Data(finished.utf8)),
        ]
    }

    // MARK: Contexts

    /// 120 frames, each with four isolated worlds and a main world; one lookup of each world of each frame, many times.
    func testFindingTheIsolatedContextsOfAPageWithManyFrames() {
        MainActor.assumeIsolated {
            let context = BrowserProfileContext(profile: .privateBrowsing())
            let native = ChromiumPage(context: context)
            let devTools = ChromiumDevTools(page: native)
            let worlds = ["WSurfAutofill", "WSurfServices", "WSurfPull", "WSurfPageBridge", ""]
            var keys: [(frame: String, document: String, world: String)] = []
            for frame in 0..<120 {
                let id = "F\(frame)", document = "L\(frame)"
                devTools.framesByID[id] = ChromiumDevTools.FrameState(
                    id: id, parentID: frame == 0 ? nil : "F0", documentID: document, url: URL(string: "https://frame\(frame).example/")!,
                    securityOrigin: BrowserSecurityOrigin(protocol: "https", host: "frame\(frame).example", port: 443),
                    hasTrustedSecurityOrigin: true, isMainFrame: frame == 0, serializedOrigin: "https://frame\(frame).example"
                )
                for (offset, world) in worlds.enumerated() {
                    let execution = frame * 10 + offset + 1
                    let unique = "\(id)/\(document)/\(world)/\(execution)"
                    devTools.contextsByUniqueID[unique] = ChromiumDevTools.ContextState(
                        executionID: world.isEmpty ? 0 : execution, uniqueID: unique, frameID: id, worldName: world, documentID: document
                    )
                    devTools.uniqueIDByExecutionID[execution] = unique
                    keys.append((id, document, world))
                }
            }
            let lookups = keys.count * 20
            var found = 0
            var generator = SeededGenerator(seed: 1)
            let orders = (0..<20).map { _ in keys.shuffled(using: &generator) }
            var iterations = 0
            var cpu = 0.0
            measure(metrics: Self.metrics, options: .budgeted) {
                iterations += 1
                let began = Self.mainThreadCPU()
                defer { cpu += Self.mainThreadCPU() - began }
                runAndWait(timeout: 120) {
                    for order in orders {
                        for key in order {
                            let context = try? await devTools.isolatedContext(frameID: key.frame, documentID: key.document, worldName: key.world)
                            if context != nil {
                                found += 1
                            }
                        }
                    }
                }
            }
            print("WSURF-LOAD-BENCH case=contexts contexts=\(keys.count) lookups=\(lookups) found=\(found) "
                + "mainCpuMsPerRun=\(String(format: "%.2f", cpu / Double(max(iterations, 1))))")
            XCTAssertEqual(found, lookups * iterations, "every context was found")
            withExtendedLifetime(native) {}
        }
    }

    /// The search every message of the page goes through for a session's name, as it was (`Data.range(of:)`) and as it is
    /// (`memmem`, over the bytes CEF hands over), over the same 1,000 messages ten times, best of five.
    func testSearchingTheMessagesOfAPageLoadForASessionsName() {
        let messages = (0..<200).flatMap { Self.events(ofResource: $0) }.map {
            Data("{\"method\":\"\($0.name)\",\"params\":".utf8) + $0.payload + Data("}".utf8)
        }
        let needle = Data("\"sessionId\"".utf8)
        let clock = ContinuousClock()
        var foundOld = 0, foundNew = 0
        var bestOld = Duration.seconds(1_000), bestNew = Duration.seconds(1_000)
        for _ in 0..<5 {
            foundOld = 0
            bestOld = min(bestOld, clock.measure {
                for _ in 0..<10 {
                    for message in messages where message.range(of: needle) != nil {
                        foundOld += 1
                    }
                }
            })
            foundNew = 0
            bestNew = min(bestNew, clock.measure {
                for _ in 0..<10 {
                    for message in messages {
                        let hit = message.withUnsafeBytes { memmem($0.baseAddress, $0.count, "\"sessionId\"", 11) != nil }
                        if hit {
                            foundNew += 1
                        }
                    }
                }
            })
        }
        print("WSURF-LOAD-BENCH case=scan messages=\(messages.count * 10) dataRangeMs=\(String(format: "%.2f", Self.milliseconds(bestOld))) "
            + "memmemMs=\(String(format: "%.2f", Self.milliseconds(bestNew)))")
        XCTAssertEqual(foundOld, 0)
        XCTAssertEqual(foundNew, 0, "no message of the page names a session")
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) {
            state = seed &+ 0x9E37_79B9_7F4A_7C15
        }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    // MARK: A tab and a page

    private final class Run: @unchecked Sendable {
        var readyDocuments = Set<String>()
        var commands: [String: Int] = [:]
        var firstCommand: ContinuousClock.Instant?
    }

    /// The scripts and handlers the app puts on a page, as far as the engine layer is concerned: the four autofill features (each
    /// installs the shared form script before its own), Input History, iframe audio, and the pull-to-refresh wheel watch, whose
    /// world has no handler.
    @MainActor
    private static func installTheAppsScripts(on page: BrowserPage, run: Run) {
        let world = AutofillPage.world
        let form = AutofillFormScript.source + AutofillSuggestionScript.source
        let features: [(client: String, handler: String)] = [
            (PasswordAutofillScript.clientSource, "wsurfPasswords"), (AutofillSaveScript.clientSource, "wsurfAutofillSave"),
            (ContactAutofillScript.clientSource, "wsurfContactAutofill"), (PaymentCardScript.clientSource, "wsurfCardAutofill"),
        ]
        for feature in features {
            page.installScript(form, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            page.installScript(feature.client, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            page.addScriptMessageHandler(name: feature.handler, in: world) { message in
                guard feature.handler == "wsurfPasswords", (message.body as? [String: Any])?["action"] as? String == "ready" else { return }
                run.readyDocuments.insert(message.frameInfo.documentID)
            }
        }
        page.installScript(InputHistoryScript.clientSource, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: InputHistoryCapture.handlerName, in: world) { _ in }
        page.installScript(MediaScript.source, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: MediaCenter.frameScriptHandlerName, in: BrowserPage.servicesWorld) { _ in }
        PullToRefreshMonitor.install(in: page)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @MainActor
    private final class Harness {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        let run = Run()

        init() {
            native = ChromiumPage(context: context)
            page = BrowserPage(chromium: native)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let run = run
            native.devTools.commandObserver = { method, _ in
                run.firstCommand = run.firstCommand ?? .now
                run.commands[method, default: 0] += 1
            }
            ChromiumLoadBenchmarkTests.installTheAppsScripts(on: page, run: run)
        }

        /// Puts the page in a window, which makes its browser and starts its session's preparation.
        func attach() {
            window.contentView = page
            window.orderBack(nil)
        }

        func close() async {
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
        }

        var commandSummary: String {
            let count = { (method: String) in self.run.commands[method, default: 0] }
            let total = run.commands.values.reduce(0, +)
            return "commands=\(total) addScript=\(count("Page.addScriptToEvaluateOnNewDocument")) addBinding=\(count("Runtime.addBinding")) "
                + "isolatedWorld=\(count("Page.createIsolatedWorld")) evaluate=\(count("Runtime.evaluate")) "
                + "resume=\(count("Runtime.runIfWaitingForDebugger")) detach=\(count("Target.detachFromTarget"))"
        }
    }

    /// Runs `work` on the main actor while this synchronous callback waits for it, so `measure` can wrap async work.
    private func runAndWait(timeout: TimeInterval, _ work: @escaping @MainActor () async throws -> Void) {
        let done = expectation(description: "work")
        let failure = FailureBox()
        Task { @MainActor in
            do {
                try await work()
            } catch {
                failure.error = error
            }
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        if let error = failure.error {
            XCTFail("\(error)")
        }
    }

    private final class FailureBox: @unchecked Sendable {
        var error: Error?
    }

    /// Seven runs, the first of which is the warm-up. Plain loops and the clocks of this file, not `measure`: its manual start and stop
    /// crashed the test host from inside XCTest now and then when driven from an async task.
    private static let runs = 7

    /// A fresh Chromium tab's own start-up: from its attach to the end of its session's preparation, which the first load waits for
    /// (`ChromiumPage.ensureReady`). The browser itself is created before the clock starts.
    func testPreparingAChromiumTab() throws {
        try MainActor.assumeIsolated {
            try ChromiumRuntime.shared.ensureInitialized()
            var lines: [String] = []
            for run in 0..<Self.runs {
                runAndWait(timeout: 60) {
                    let harness = Harness()
                    harness.attach()
                    let began = Self.mainThreadCPU()
                    let started = ContinuousClock.now
                    try await harness.native.ensureReady()
                    let wall = Self.milliseconds(ContinuousClock.now - started)
                    let cpu = Self.mainThreadCPU() - began
                    lines.append("case=prepare run=\(run) wallMs=\(String(format: "%.2f", wall)) mainCpuMs=\(String(format: "%.2f", cpu)) \(harness.commandSummary)")
                    await harness.close()
                }
            }
            for line in lines {
                print("WSURF-LOAD-BENCH \(line)")
            }
        }
    }

    /// A page with 60 subresources and four frames of other sites, each its own process. The clock runs from the load to the moment
    /// the page and every frame have run the autofill scripts, which a cross-site frame cannot do before its session has registered
    /// them. Each run prints what the session spent: its commands, how long the frames were held, and how many events were parsed.
    func testLoadingAPageWithCrossSiteFrames() throws {
        try MainActor.assumeIsolated {
            try ChromiumRuntime.shared.ensureInitialized()
            let frames = 4
            let resources = (0..<60).map { "<script async src=\"/r/\($0).js\"></script>" }.joined()
            let frameTags = (0..<frames).map { index in
                "<script>{const f = document.createElement('iframe'); f.src = 'http://f\(index).localhost:' + location.port + '/frame'; document.body.append(f);}</script>"
            }.joined()
            var table: [String: HTTPFixtureServer.Response] = [
                "/": .html("<!doctype html><html><body><input id=\"u\" autocomplete=\"username\">\(resources)\(frameTags)</body></html>"),
                "/frame": .html("<!doctype html><html><body><input id=\"u\" autocomplete=\"username\"></body></html>"),
            ]
            for index in 0..<60 {
                table["/r/\(index).js"] = .bytes(Data("/* \(index) */".utf8), contentType: "text/javascript")
            }
            let routes = table
            let serverBox = ServerBox()
            runAndWait(timeout: 30) { serverBox.server = try await HTTPFixtureServer.start(routes: routes) }
            let server = try XCTUnwrap(serverBox.server)
            let url = try server.url("/")
            var lines: [String] = []
            for run in 0..<Self.runs {
                runAndWait(timeout: 90) {
                    let harness = Harness()
                    harness.attach()
                    try await harness.native.ensureReady()
                    let before = harness.run.commands
                    let began = Self.mainThreadCPU()
                    let started = ContinuousClock.now
                    harness.page.load(URLRequest(url: url))
                    let finished = await waitUntil(timeout: .seconds(60)) {
                        harness.run.readyDocuments.count >= frames + 1 && harness.native.devTools.loadStatistics.framePauses >= frames
                    }
                    let wall = Self.milliseconds(ContinuousClock.now - started)
                    let cpu = Self.mainThreadCPU() - began
                    XCTAssertTrue(finished, "the page and its \(frames) frames ran their scripts")
                    let statistics = harness.native.devTools.loadStatistics
                    let loadCommands = harness.run.commands.reduce(0) { $0 + $1.value - before[$1.key, default: 0] }
                    lines.append("case=load run=\(run) frames=\(frames) wallMs=\(String(format: "%.2f", wall)) mainCpuMs=\(String(format: "%.2f", cpu)) "
                        + "loadCommands=\(loadCommands) \(harness.commandSummary) "
                        + "events=\(statistics.eventsReceived) parsed=\(statistics.eventsParsed) sessionParsed=\(statistics.sessionMessagesParsed) "
                        + "pauses=\(statistics.framePauses) pauseTotalMs=\(String(format: "%.2f", Self.milliseconds(statistics.framePauseTotal))) "
                        + "pauseMaxMs=\(String(format: "%.2f", Self.milliseconds(statistics.framePauseMax)))")
                    await harness.close()
                }
            }
            for line in lines {
                print("WSURF-LOAD-BENCH \(line)")
            }
            withExtendedLifetime(server) {}
        }
    }

    private final class ServerBox: @unchecked Sendable {
        var server: HTTPFixtureServer?
    }
}
