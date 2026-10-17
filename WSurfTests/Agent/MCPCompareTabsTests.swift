// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// `compareTabs` and `openComparison` on real pages: two tabs, each hosted in a window of its own as the app hosts a pane. The
/// pages hold no text, so what differs between two engines' renderings is the page's own doing and not a font's.
@MainActor
@Suite(.boundedWebViews)
struct MCPCompareTabsTests {
    private static func page(box: String, script: String = "") -> String {
        """
        <!doctype html><title>Compare</title><meta name="viewport" content="width=device-width">
        <style>
          body { margin: 0; background: #fff }
          #box { position: absolute; left: 40px; top: 30px; width: 200px; height: 100px; background: \(box) }
        </style>
        <div id=box></div><script>\(script)</script>
        """
    }

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/same": .html(page(box: "#222")), "/dark": .html(page(box: "#222")), "/light": .html(page(box: "#ddd")),
        "/quiet": .html(page(box: "#222")),
        "/noisy": .html(
            page(box: "#222", script: "console.error('noisy-error 7'); console.error('login failed for s3cret-value-xyz'); fetch('/missing');")),
        "/other": .html(page(box: "#222")),
        "/engine": .html(
            page(
                box: "#222",
                script: "console.error(/Chrome\\//.test(navigator.userAgent) ? 'chromium-only 7' : 'webkit-only 7');")),
    ]

    private struct Rig {
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let session: MCPBrowserSession
        var tabs: [BrowserTab]
        var windows: [NSWindow]
    }

    private func host(_ tab: BrowserTab, size: CGSize = CGSize(width: 500, height: 400)) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 50, y: 50), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        let width = Int(container.bounds.width)
        #expect(
            await waitUntil {
                guard tab.page.superview === container, tab.page.url != nil, !tab.page.isLoading, tab.page.mainDocumentID != nil else { return false }
                return (try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int == width
            }, "the page is loaded and laid out at the container's width \(width)")
        return window
    }

    /// A browser with one tab per entry of `pages`, all in one split, and a connection that was given `answer` for them.
    private func withRig(
        _ pages: [(path: String, engine: BrowserEngine)], sizes: [CGSize] = [], answer: MCPAccessConsent.Access? = .development,
        _ body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let permissions = SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPCompare-\(UUID().uuidString).json"))
        if pages.contains(where: { $0.engine == .chromium }) {
            try ChromiumRuntime.shared.ensureInitialized()
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let session = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in answer }, openConsent: { _, _ in true })
        // No wait between the captures of a test.
        session.feedback.sleep = { _ in }
        var rig = Rig(server: server, browser: browser, session: session, tabs: [], windows: [])
        for (index, page) in pages.enumerated() {
            let url = try server.url(page.path)
            let tab = browser.newTab(url: url, activate: false, engine: page.engine)
            tab.assistantAccess.persistsAnswers = false
            tab.assistantAccess.pageChanged(url: url)
            rig.tabs.append(tab)
            rig.windows.append(await host(tab, size: sizes.indices.contains(index) ? sizes[index] : CGSize(width: 500, height: 400)))
        }
        browser.split(rig.tabs[0], with: rig.tabs[1], axis: .sideBySide)
        browser.activate(rig.tabs[0])
        do {
            try await body(rig)
        } catch {
            await retire(rig)
            throw error
        }
        await retire(rig)
    }

    private func retire(_ rig: Rig) async {
        let tabs = rig.browser.tabs
        rig.browser.closeAllTabs(saving: false)
        for tab in tabs {
            await tab.waitForRetirement()
        }
        for window in rig.windows {
            window.contentView = nil
            window.close()
        }
    }

    private func call(_ rig: Rig, _ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        try await rig.session.call(name: name, arguments: arguments)
    }

    private func compare(_ rig: Rig, _ extra: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = extra
        arguments["tabA"] = .string(rig.tabs[0].id.uuidString)
        arguments["tabB"] = .string(rig.tabs[1].id.uuidString)
        return try await call(rig, "compareTabs", arguments)
    }

    private func object(_ result: CallTool.Result) -> [String: Value] {
        result.structuredContent?.objectValue ?? [:]
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private func images(_ result: CallTool.Result) -> [Data] {
        result.content.compactMap { block -> Data? in
            guard case .image(let data, _, _, _) = block else { return nil }
            return Data(base64Encoded: data)
        }
    }

    private func share(_ rig: Rig) async throws {
        let shared = try await call(rig, "requestAccess", ["development": true])
        #expect(shared.isError == false, "\(text(shared))")
    }

    /// Starts capture on both tabs and loads both again, so the load itself is captured.
    private func capture(_ rig: Rig) async throws {
        for name in ["startDiagnostics", "reloadPage"] {
            for tab in rig.tabs {
                let result = try await call(rig, name, ["tabID": .string(tab.id.uuidString)])
                #expect(result.isError == false, "\(name): \(text(result))")
            }
        }
    }

    // MARK: Pixels

    @Test func identicalPagesHaveZeroDiff() async throws {
        try await withRig([("/same", .webKit), ("/same", .webKit)]) { rig in
            try await share(rig)
            let result = try await compare(rig)
            #expect(result.isError == false, "\(text(result))")
            let report = object(result)
            #expect(report["status"]?.stringValue == "ok")
            let shot = try #require(report["screenshot"]?.objectValue)
            #expect(shot["compared"]?.boolValue == true, "\(shot)")
            #expect(shot["diffRatio"]?.doubleValue == 0)
            #expect(shot["changedPixels"]?.intValue == 0)
            #expect(shot["regions"]?.arrayValue?.isEmpty == true)
            #expect(report["layout"]?.objectValue?["differences"]?.arrayValue?.isEmpty == true)
            #expect(report["viewport"]?.objectValue?["width"]?.intValue == 500)
            #expect(report["a"]?.objectValue?["engine"]?.stringValue == "webkit")
            // No image unless asked for, and a report of about 2 KB.
            #expect(images(result).isEmpty)
            #expect(text(result).utf8.count < 2_500, "\(text(result).utf8.count) bytes")
            // Without capture on both tabs the report says how to get it.
            #expect(report["diagnostics"]?.objectValue?["compared"]?.boolValue == false)
        }
    }

    @Test func aCSSDifferenceGivesARegionDiff() async throws {
        try await withRig([("/dark", .webKit), ("/light", .webKit)]) { rig in
            try await share(rig)
            let result = try await compare(rig)
            #expect(result.isError == false, "\(text(result))")
            let report = object(result)
            let shot = try #require(report["screenshot"]?.objectValue)
            let ratio = try #require(shot["diffRatio"]?.doubleValue)
            // The box is 200 by 100 of a 500 by 400 viewport: 10 %.
            #expect(ratio > 0.08 && ratio < 0.12, "\(ratio)")
            let region = try #require(shot["regions"]?.arrayValue?.first?.objectValue)
            let x = try #require(region["x"]?.intValue), y = try #require(region["y"]?.intValue)
            let width = try #require(region["width"]?.intValue), height = try #require(region["height"]?.intValue)
            let cell = PageImageDiff.cell
            #expect(x <= 40 && x > 40 - cell && y <= 30 && y > 30 - cell, "\(region)")
            #expect(x + width >= 240 && x + width < 240 + cell && y + height >= 130 && y + height < 130 + cell, "\(region)")
            #expect(shot["regions"]?.arrayValue?.count == 1)
            // The layout is the same, and the picture appears only when asked for.
            #expect(report["layout"]?.objectValue?["differences"]?.arrayValue?.isEmpty == true)
            #expect(images(result).isEmpty)
            let withImage = try await compare(rig, ["image": true])
            let picture = try #require(images(withImage).first)
            #expect(images(withImage).count == 1 && picture.count <= MCPCompareTools.imageBytes)
            let bitmap = try #require(NSBitmapImageRep(data: picture))
            #expect(bitmap.pixelsWide == 500 && bitmap.pixelsHigh == 400)
            let red = try #require(bitmap.colorAt(x: 140, y: 80)?.usingColorSpace(.sRGB))
            #expect(red.redComponent > 0.7 && red.greenComponent < 0.4, "the differing box is marked in red")
        }
    }

    @Test func tabsOfDifferentSizesAreRejectedAndBothSizesReported() async throws {
        try await withRig([("/same", .webKit), ("/same", .webKit)], sizes: [CGSize(width: 500, height: 400), CGSize(width: 460, height: 400)]) { rig in
            try await share(rig)
            let result = try await compare(rig)
            #expect(result.isError == true)
            let report = object(result)
            #expect(report["status"]?.stringValue == "invalidInput")
            #expect(report["message"]?.stringValue?.contains("setViewport") == true)
            #expect(report["a"]?.objectValue?["viewport"]?.objectValue?["width"]?.intValue == 500)
            #expect(report["b"]?.objectValue?["viewport"]?.objectValue?["width"]?.intValue == 460)
            #expect(report["screenshot"] == nil, "nothing was captured")
        }
    }

    // MARK: Console and network

    @Test func aConsoleErrorAndAFailedRequestOnlyInOneTabAreReported() async throws {
        try await withRig([("/quiet", .webKit), ("/noisy", .webKit)]) { rig in
            try await share(rig)
            try await capture(rig)
            var last: CallTool.Result?
            let seen = await waitUntil {
                last = try? await compare(rig)
                let console = last.flatMap { object($0)["diagnostics"]?.objectValue?["console"]?.objectValue }
                return console?["onlyB"]?.arrayValue?.isEmpty == false
            }
            let result = try #require(last)
            #expect(seen, "\(text(result))")
            let diagnostics = try #require(object(result)["diagnostics"]?.objectValue)
            let console = try #require(diagnostics["console"]?.objectValue)
            let errors = console["onlyB"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue } ?? []
            #expect(errors.contains("noisy-error 7"), "\(errors)")
            #expect(console["onlyB"]?.arrayValue?.allSatisfy { $0.objectValue?["level"]?.stringValue == "error" } == true)
            #expect(console["onlyA"]?.arrayValue?.isEmpty == true)
            // The request the noisy page made and the quiet one did not.
            let missing = try await waitForRequest(rig, in: "onlyB", containing: "/missing")
            #expect(missing, "the failed request is listed")
            #expect(text(result).utf8.count < 4_000)
        }
    }

    @Test func aConsoleErrorOnlyInOneEngineIsReportedAndTheSamePageLooksTheSame() async throws {
        try await withRig([("/engine", .webKit), ("/engine", .chromium)]) { rig in
            try await share(rig)
            try await capture(rig)
            var last: CallTool.Result?
            _ = await waitUntil {
                last = try? await compare(rig)
                let console = last.flatMap { object($0)["diagnostics"]?.objectValue?["console"]?.objectValue }
                return console?["onlyA"]?.arrayValue?.isEmpty == false && console?["onlyB"]?.arrayValue?.isEmpty == false
            }
            let result = try #require(last)
            let report = object(result)
            #expect(report["a"]?.objectValue?["engine"]?.stringValue == "webkit" && report["b"]?.objectValue?["engine"]?.stringValue == "chromium")
            let console = try #require(report["diagnostics"]?.objectValue?["console"]?.objectValue)
            let onlyA = console["onlyA"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue } ?? []
            let onlyB = console["onlyB"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue } ?? []
            #expect(onlyA == ["webkit-only 7"], "\(text(result))")
            #expect(onlyB == ["chromium-only 7"], "\(text(result))")
            // The same markup in two engines differs by anti-aliasing at most: the box is where it was and as dark.
            let shot = try #require(report["screenshot"]?.objectValue)
            #expect(shot["compared"]?.boolValue == true && (shot["diffRatio"]?.doubleValue ?? 1) < 0.02, "\(shot)")
            #expect(report["layout"]?.objectValue?["differences"]?.arrayValue?.isEmpty == true, "\(text(result))")
        }
    }

    private func waitForRequest(_ rig: Rig, in list: String, containing needle: String) async throws -> Bool {
        await waitUntil {
            let result = try? await compare(rig)
            let listed = result.flatMap { object($0)["diagnostics"]?.objectValue?["network"]?.objectValue?[list]?.arrayValue } ?? []
            return listed.contains { $0.stringValue?.contains(needle) == true }
        }
    }

    @Test func aSecretTheConnectionTypedNeverAppearsInTheReport() async throws {
        try await withRig([("/quiet", .webKit), ("/noisy", .webKit)]) { rig in
            try await share(rig)
            #expect(rig.session.secrets.register("s3cret-value-xyz") == .registered)
            try await capture(rig)
            var last: CallTool.Result?
            _ = await waitUntil {
                last = try? await compare(rig)
                return last.map { text($0).contains("login failed") } ?? false
            }
            let result = try #require(last)
            #expect(text(result).contains("login failed"), "\(text(result))")
            #expect(!text(result).contains("s3cret-value-xyz"))
            #expect(!(result.structuredContent.map { "\($0)" } ?? "").contains("s3cret-value-xyz"))
        }
    }

    // MARK: Access

    @Test func aControlGrantCannotCompareAndNothingIsOpened() async throws {
        try await withRig([("/same", .webKit), ("/same", .webKit)], answer: .control) { rig in
            try await share(rig)
            let result = try await compare(rig)
            #expect(result.isError == true)
            #expect(object(result)["status"]?.stringValue == "denied", "\(text(result))")
            #expect(object(result)["screenshot"] == nil)
            let before = rig.browser.tabs.count
            let opened = try await call(rig, "openComparison", ["url": .string(try rig.server.url("/same").absoluteString)])
            #expect(opened.isError == true && text(opened).contains("development access"), "\(text(opened))")
            let chosen = try await call(rig, "newTab", ["url": .string(try rig.server.url("/other").absoluteString), "engine": "webkit"])
            #expect(chosen.isError == true && text(chosen).contains("development access"), "\(text(chosen))")
            #expect(rig.browser.tabs.count == before)
        }
    }

    @Test func tabsThatAreNotSharedCannotBeCompared() async throws {
        try await withRig([("/same", .webKit), ("/same", .webKit)]) { rig in
            let unshared = try await compare(rig)
            #expect(unshared.isError == true)
            #expect(object(unshared)["screenshot"] == nil)
            try await share(rig)
            let stranger = try await call(rig, "compareTabs", ["tabA": .string(rig.tabs[0].id.uuidString), "tabB": .string(UUID().uuidString)])
            #expect(stranger.isError == true)
            let same = try await call(rig, "compareTabs", ["tabA": .string(rig.tabs[0].id.uuidString), "tabB": .string(rig.tabs[0].id.uuidString)])
            #expect(same.isError == true && object(same)["status"]?.stringValue == "invalidInput")
            let malformed = try await call(rig, "compareTabs", ["tabA": "nonsense", "tabB": .string(rig.tabs[1].id.uuidString)])
            #expect(malformed.isError == true)
        }
    }

    @Test func tabsNotSideBySideOnScreenAreRefused() async throws {
        try await withRig([("/same", .webKit), ("/same", .webKit)]) { rig in
            try await share(rig)
            rig.browser.dissolveSplit(containing: rig.tabs[0])
            let result = try await compare(rig)
            #expect(result.isError == true)
            #expect(object(result)["status"]?.stringValue == "invalidInput" && text(result).contains("on screen"), "\(text(result))")
        }
    }

    @Test func anotherConnectionsLeaseBlocksTheComparison() async throws {
        try await withRig([("/same", .webKit), ("/same", .webKit)]) { rig in
            try await share(rig)
            let other = MCPBrowserSession(browser: rig.browser, available: { true }, consent: { _, _, _ in .development })
            _ = try await other.call(name: "requestAccess", arguments: ["development": true])
            let started = try await other.call(name: "startDiagnostics", arguments: ["tabID": .string(rig.tabs[1].id.uuidString)])
            #expect(started.isError == false, "\(text(started))")
            let result = try await compare(rig)
            #expect(result.isError == true)
            #expect(object(result)["status"]?.stringValue == "ownershipConflict", "\(text(result))")
            #expect(object(result)["screenshot"] == nil)
        }
    }

    // MARK: Engines

    @Test func anEngineOverrideStaysWithTheTabAndNeverChangesSiteSettings() async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let url = try server.url("/same")
        let origin = SitePermissions.origin(for: url)
        let permissions = SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPCompare-\(UUID().uuidString).json"))
        // The user's setting for this website is Chromium.
        permissions.setEngine(.chromium, for: origin)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let ordinary = browser.makeTab(for: url)
        let overridden = browser.makeTab(for: url)
        overridden.engineOverride = .webKit
        #expect(ordinary.preferredEngine(for: url) == .chromium)
        #expect(overridden.preferredEngine(for: url) == .webKit, "the override wins over the setting")
        #expect(overridden.preferredEngine(for: try server.url("/other")) == .webKit, "and over every address the tab loads")
        // A live tab opened with an engine runs in it, keeps it across loads, and leaves the setting alone.
        let tab = browser.newTab(url: url, activate: false, engine: .webKit)
        let window = await host(tab)
        #expect(tab.page.engine == .webKit && tab.engineOverride == .webKit)
        tab.load(try server.url("/other"), transition: .agent)
        #expect(await waitUntil { tab.page.url == (try? server.url("/other")) && !tab.page.isLoading })
        #expect(tab.page.engine == .webKit)
        await browser.applyStoredEngine(to: origin)
        #expect(tab.page.engine == .webKit, "the website's setting does not move a comparison tab")
        #expect(permissions.engine(for: origin) == .chromium, "the user's setting was not written")
        browser.closeAllTabs(saving: false)
        await tab.waitForRetirement()
        window.contentView = nil
        window.close()
    }

    /// A browser with a paired client whose standing grant is `standing`, on the loopback address the fixture serves.
    private func withDeveloperSession(_ body: (HTTPFixtureServer, BrowserModel, MCPBrowserSession) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        try ChromiumRuntime.shared.ensureInitialized()
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(.development, for: client.id)
        try trust.setDeveloperProfile(Profile.originalID)
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPCompare-\(UUID().uuidString).json")))
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true }, consent: { _, _, _ in nil }, openConsent: { _, _ in false })
        session.pairedClient = trust.client(id: client.id)
        session.feedback.sleep = { _ in }
        do {
            try await body(server, browser, session)
        } catch {
            browser.closeAllTabs(saving: false)
            throw error
        }
        let tabs = browser.tabs
        browser.closeAllTabs(saving: false)
        for tab in tabs {
            await tab.waitForRetirement()
        }
    }

    @Test func openComparisonSharesBothEnginesWithoutASheetAndReusesOrReplacesThePair() async throws {
        try await withDeveloperSession { server, browser, session in
            let url = try server.url("/same")
            let user = browser.newTab(url: try server.url("/other"))
            let before = browser.closedTabs.count
            let opened = try await session.call(name: "openComparison", arguments: ["url": .string(url.absoluteString)])
            #expect(opened.isError == false, "\(text(opened))")
            let report = object(opened)
            let webKit = try #require(browser.tabs.first { $0.id.uuidString == report["webkit"]?.stringValue })
            let chromium = try #require(browser.tabs.first { $0.id.uuidString == report["chromium"]?.stringValue })
            #expect(webKit.page.engine == .webKit && chromium.page.engine == .chromium)
            #expect(report["reused"]?.boolValue == false)
            // Side by side and on screen, the user's own tab left alone, no site setting written.
            #expect(browser.activeTab === webKit)
            #expect(Set(browser.splitPanes?.map(\.id) ?? []) == [webKit.id, chromium.id])
            #expect(browser.tabs.contains { $0 === user })
            #expect(browser.sitePermissions.engine(for: SitePermissions.origin(for: url)) == .webKit)
            for tab in [webKit, chromium] {
                let grant = try #require(session.grants[tab.id])
                #expect(grant.access == .development && grant.source == .standing)
            }
            let windows = [await host(webKit), await host(chromium)]
            defer {
                for window in windows {
                    window.contentView = nil
                    window.close()
                }
            }
            // Once the pages have loaded, the connection may use development tools on both.
            for tab in [webKit, chromium] {
                #expect(session.permits(tab, capability: .development))
            }
            let compared = try await session.call(
                name: "compareTabs", arguments: ["tabA": .string(webKit.id.uuidString), "tabB": .string(chromium.id.uuidString)])
            #expect(compared.isError == false, "\(text(compared))")
            let both = object(compared)
            #expect(both["a"]?.objectValue?["engine"]?.stringValue == "webkit" && both["b"]?.objectValue?["engine"]?.stringValue == "chromium")
            #expect(both["screenshot"]?.objectValue?["compared"]?.boolValue == true, "\(text(compared))")
            #expect(both["layout"]?.objectValue?["differences"]?.arrayValue?.isEmpty == true, "\(text(compared))")
            // The same website again loads the same two tabs.
            let again = try await session.call(name: "openComparison", arguments: ["url": .string(try server.url("/other").absoluteString)])
            #expect(object(again)["reused"]?.boolValue == true)
            #expect(object(again)["webkit"]?.stringValue == webKit.id.uuidString && object(again)["chromium"]?.stringValue == chromium.id.uuidString)
            // Another website replaces them, and leaves nothing to reopen.
            let elsewhere = URL(string: url.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))
            let replaced = try await session.call(name: "openComparison", arguments: ["url": .string(try #require(elsewhere).absoluteString)])
            #expect(replaced.isError == false, "\(text(replaced))")
            #expect(object(replaced)["reused"]?.boolValue == false)
            #expect(object(replaced)["webkit"]?.stringValue != webKit.id.uuidString)
            #expect(!browser.tabs.contains { $0 === webKit || $0 === chromium })
            #expect(browser.closedTabs.count == before)
            #expect(session.grants[webKit.id] == nil)
        }
    }

    @Test func newTabOpensInTheChosenEngineOnADeveloperSite() async throws {
        try await withDeveloperSession { server, browser, session in
            let opened = try await session.call(name: "newTab", arguments: ["url": .string(try server.url("/same").absoluteString), "engine": "chromium"])
            #expect(opened.isError == false, "\(text(opened))")
            #expect(text(opened).contains("Chromium"))
            let tab = try #require(browser.tabs.first)
            #expect(tab.page.engine == .chromium && tab.engineOverride == .chromium)
            #expect(browser.sitePermissions.engine(for: SitePermissions.origin(for: try server.url())) == .webKit)
            let invalid = try? await session.call(name: "newTab", arguments: ["url": .string(try server.url("/same").absoluteString), "engine": "gecko"])
            #expect(invalid == nil, "an engine that does not exist is refused before anything runs")
        }
    }
}
