// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Media and network emulation and scoped site-data clearing: Developer tier only, per tab, undone with the lease, and never
/// able to reach the everyday profile or another site. Sessions use an in-memory trust store and loopback fixture servers.
@MainActor
struct MCPEnvironmentTests {
    private struct Rig {
        let browser: BrowserModel
        let permissions: SitePermissions
        let trust: MCPTrustStore
        let session: MCPBrowserSession
        let profile: Profile
        let sheets: Sheets
    }

    private final class Sheets {
        var shown = 0
    }

    private static let cookieValue = "cookieSecret42"

    /// A paired client at `standing` and a window of a profile of its own, chosen as the Developer profile. `everyday` puts the
    /// window in the owner's everyday profile and chooses that one, which is a choice the owner can make.
    private func makeRig(standing: PairedClient.Standing = .developer, everyday: Bool = false) throws -> Rig {
        let profile = everyday ? Profile.original() : Profile(id: UUID(), name: "Developer fixture", symbol: "hammer", color: .teal)
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(standing, for: client.id)
        try trust.setDeveloperProfile(profile.id)
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPEnvironment-\(UUID().uuidString).json"))
        let browser =
            everyday
            ? BrowserModel(database: .temporary(), sitePermissions: permissions)
            : BrowserModel(
                context: BrowserProfileContext(profile: profile), windowID: UUID(), database: .temporary(), sitePermissions: permissions)
        let sheets = Sheets()
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true },
            consent: { _, _, _ in
                sheets.shown += 1
                return .control
            },
            openConsent: { _, _ in false })
        session.pairedClient = trust.client(id: client.id)
        return Rig(browser: browser, permissions: permissions, trust: trust, session: session, profile: profile, sheets: sheets)
    }

    private func call(_ rig: Rig, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    private func status(_ result: CallTool.Result) -> String? {
        result.structuredContent?.objectValue?["status"]?.stringValue
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    /// Hosts the tab's page in a window the way the app does. A Chromium page starts loading only once it is attached.
    private func show(_ tab: BrowserTab) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        return window
    }

    private func hide(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// A tab of `rig` on the loopback server in `engine`, shown and loaded, with the standing Developer grant in place.
    private func open(_ rig: Rig, _ server: HTTPFixtureServer, engine: BrowserEngine) async throws -> (BrowserTab, NSWindow) {
        let url = try server.url()
        rig.permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let tab = rig.browser.newTab(url: url)
        tab.assistantAccess.persistsAnswers = false
        let window = await show(tab)
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        tab.assistantAccess.pageChanged(url: url)
        #expect(tab.page.engine == engine)
        let agent = try await script(tab, "navigator.userAgent") as? String
        #expect((agent?.contains("Chrome/") == true) == (engine == .chromium), "the page runs in \(engine)")
        return (tab, window)
    }

    private func server() async throws -> HTTPFixtureServer {
        try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Env</title><p>Hello</p>"),
            "/ping": .html("pong"),
        ])
    }

    private func share(_ rig: Rig, expecting tab: BrowserTab) async throws {
        let shared = try await call(rig, "requestAccess")
        #expect(shared.isError == false, "\(text(shared))")
        #expect(rig.session.grants[tab.id]?.access == .developer)
    }

    private func script(_ tab: BrowserTab, _ source: String) async throws -> Any? {
        try await tab.page.evaluateJavaScript(source)
    }

    private func prefersDark(_ tab: BrowserTab) async throws -> Bool {
        try await script(tab, "matchMedia('(prefers-color-scheme: dark)').matches") as? Bool ?? false
    }

    private func reducesMotion(_ tab: BrowserTab) async throws -> Bool {
        try await script(tab, "matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool ?? false
    }

    /// 200 when the request reaches the server, -1 when it fails to start.
    private func ping(_ tab: BrowserTab) async throws -> Int {
        let result = try await tab.page.callAsyncJavaScript(
            "try { return (await fetch('/ping', { cache: 'no-store' })).status } catch (error) { return -1 }",
            in: nil, contentWorld: .page)
        return (result as? NSNumber)?.intValue ?? -2
    }

    // MARK: Catalog

    @Test func environmentToolsNeedTheDeveloperTier() throws {
        for name in ["emulateMedia", "clearSiteData"] {
            let entry = try #require(MCPToolCatalog.entries.first { $0.name == name })
            #expect(entry.scope == .developer, "\(name)")
            #expect(!entry.usesRef && !entry.readOnly, "\(name)")
            #expect(entry.parameters.contains { $0.name == "tabID" })
        }
        let tab: Value = .string(UUID().uuidString)
        let media = try #require(MCPToolCatalog.entries.first { $0.name == "emulateMedia" })
        try media.validate(["tabID": tab, "colorScheme": "dark", "reducedMotion": "reduce", "offline": true])
        #expect(throws: (any Error).self) { try media.validate(["tabID": tab, "offline": "yes"]) }
        #expect(throws: (any Error).self) { try media.validate(["tabID": tab, "printMedia": true]) }
        let clear = try #require(MCPToolCatalog.entries.first { $0.name == "clearSiteData" })
        #expect(throws: (any Error).self) { try clear.validate(["tabID": tab, "origin": "http://localhost"]) }
        #expect(throws: (any Error).self) { try clear.validate([:]) }
    }

    @Test(arguments: [
        ("127.0.0.1", "127.0.0.1", true), (".example.com", "example.com", true), ("example.com", "example.com", true),
        ("EXAMPLE.com.", "example.com", true), ("[::1]", "::1", true), ("localhost", "localhost", true),
        ("example.com", "www.example.com", false), (".example.com", "www.example.com", false),
        ("www.example.com", "example.com", false), ("sibling.example.com", "www.example.com", false),
        ("evil-localhost", "localhost", false), ("localhost.evil.test", "localhost", false), ("", "localhost", false),
    ])
    func onlyCookiesOfTheExactHostAreInScope(domain: String, host: String, expected: Bool) {
        #expect(DevelopmentSiteData.isHostCookie(domain: domain, host: host) == expected)
    }

    // MARK: Media emulation

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func darkColorSchemeIsMeasuredAndResetRestoresIt(engine: BrowserEngine) async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        #expect(rig.sheets.shown == 0, "a standing grant needs no sheet")

        let baseline = try await prefersDark(tab)
        let wanted = baseline ? "light" : "dark"
        let applied = try await call(rig, "emulateMedia", tab, ["colorScheme": .string(wanted)])
        #expect(status(applied) == "ok", "\(text(applied))")
        let measured = try #require(applied.structuredContent?.objectValue?["measured"]?.objectValue)
        #expect(measured["prefersDark"]?.boolValue == !baseline)
        #expect(applied.structuredContent?.objectValue?["emulation"]?.objectValue?["colorScheme"]?.stringValue == wanted)
        #expect(try await prefersDark(tab) == !baseline, "the page itself reports the emulated scheme")
        let info = try await call(rig, "getDevelopmentInfo", tab)
        #expect(info.structuredContent?.objectValue?["emulation"]?.objectValue?["colorScheme"]?.stringValue == wanted)

        // `system` removes the override without ending the lease's other work.
        // The emulation belongs to the tab, not the document: it survives a reload.
        #expect(status(try await call(rig, "reloadPage", tab)) == "ok")
        #expect(try await waitUntil { try await prefersDark(tab) == !baseline })

        let cleared = try await call(rig, "emulateMedia", tab, ["colorScheme": "system"])
        #expect(status(cleared) == "ok")
        #expect(try await waitUntil { try await prefersDark(tab) == baseline })
        #expect(status(try await call(rig, "emulateMedia", tab, ["colorScheme": .string(wanted)])) == "ok")

        let owner = tab.developmentOwner
        #expect(status(try await call(rig, "resetDevelopment", tab)) == "ok")
        await owner?.cleanup?.value
        #expect(tab.developmentOwner == nil)
        #expect(try await waitUntil { try await prefersDark(tab) == baseline }, "reset puts the page's own scheme back")
        if engine == .webKit {
            #expect(tab.page.webKit?.appearance == nil, "the view's own appearance is back")
        }
    }

    @Test(.boundedWebViews)
    func resetRemovesMediaEmulationAndTheViewportTogether() async throws {
        let engine = BrowserEngine.webKit
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        let baseline = try await prefersDark(tab)
        #expect(status(try await call(rig, "emulateMedia", tab, ["colorScheme": .string(baseline ? "light" : "dark")])) == "ok")
        let sized = try await call(rig, "setViewport", tab, ["width": 400, "height": 700])
        #expect(status(sized) == "ok", "\(text(sized))")
        #expect(try await prefersDark(tab) == !baseline, "a viewport change leaves the emulated scheme alone")

        let owner = tab.developmentOwner
        #expect(status(try await call(rig, "resetDevelopment", tab)) == "ok")
        await owner?.cleanup?.value
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
        #expect(try await waitUntil { try await prefersDark(tab) == baseline })
    }

    @Test(.boundedWebViews)
    func webkitRejectsReducedMotionAndOfflineBeforeAnyChange() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        try await share(rig, expecting: tab)

        for arguments: [String: Value] in [
            ["reducedMotion": "reduce"], ["offline": true], ["offline": false], ["reducedMotion": "system"],
            // The supported part of a mixed request is not applied either.
            ["colorScheme": "dark", "offline": true], ["colorScheme": "dark", "reducedMotion": "reduce"],
        ] {
            let result = try await call(rig, "emulateMedia", tab, arguments)
            #expect(status(result) == "unsupported", "\(arguments)")
            #expect(result.isError == true)
            let capabilities = result.structuredContent?.objectValue?["capabilities"]?.objectValue?["media"]?.objectValue
            #expect(capabilities?["reducedMotion"]?.objectValue?["status"]?.stringValue == "unsupported")
            #expect(capabilities?["offline"]?.objectValue?["status"]?.stringValue == "unsupported")
            #expect(tab.developmentOwner == nil, "a rejected request does not claim the tab")
            #expect(tab.page.webKit?.appearance == nil, "\(arguments) left the view alone")
        }
        #expect(try await ping(tab) == 200)
    }

    @Test(.boundedWebViews)
    func badOrEmptyMediaRequestsAreInvalidInput() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        for arguments: [String: Value] in [[:], ["colorScheme": "purple"], ["reducedMotion": "maybe"], ["colorScheme": ""]] {
            #expect(status(try await call(rig, "emulateMedia", tab, arguments)) == "invalidInput", "\(arguments)")
        }
        #expect(tab.developmentOwner == nil)
    }

    @Test(.boundedWebViews)
    func chromiumReducedMotionIsMeasuredAndResetRestoresIt() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .chromium)
        defer { hide(window) }
        try await share(rig, expecting: tab)

        let baseline = try await reducesMotion(tab)
        let reduce = try await call(rig, "emulateMedia", tab, ["reducedMotion": baseline ? "no-preference" : "reduce"])
        #expect(status(reduce) == "ok", "\(text(reduce))")
        #expect(try await reducesMotion(tab) == !baseline)
        // A later request keeps the earlier axis.
        let dark = try await call(rig, "emulateMedia", tab, ["colorScheme": "dark"])
        #expect(status(dark) == "ok")
        #expect(try await reducesMotion(tab) == !baseline)
        #expect(try await prefersDark(tab))
        let owner = tab.developmentOwner
        #expect(status(try await call(rig, "resetDevelopment", tab)) == "ok")
        await owner?.cleanup?.value
        #expect(try await reducesMotion(tab) == baseline)
    }

    @Test(.boundedWebViews)
    func chromiumOfflineFailsFetchAndResetRestoresIt() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .chromium)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        #expect(try await ping(tab) == 200)

        let offline = try await call(rig, "emulateMedia", tab, ["offline": true])
        #expect(status(offline) == "ok", "\(text(offline))")
        #expect(offline.structuredContent?.objectValue?["measured"]?.objectValue?["online"]?.boolValue == false)
        #expect(try await ping(tab) == -1, "a request fails while the page is offline")

        let online = try await call(rig, "emulateMedia", tab, ["offline": false])
        #expect(status(online) == "ok")
        #expect(try await ping(tab) == 200)

        #expect(status(try await call(rig, "emulateMedia", tab, ["offline": true])) == "ok")
        let owner = tab.developmentOwner
        #expect(status(try await call(rig, "resetDevelopment", tab)) == "ok")
        await owner?.cleanup?.value
        #expect(try await ping(tab) == 200, "reset puts the network back")
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func mediaEmulationEndsWithTheLease(engine: BrowserEngine) async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        let baseline = try await prefersDark(tab)
        let wanted = baseline ? "light" : "dark"

        // A disconnect (what Stop does to a connection) ends it.
        #expect(status(try await call(rig, "emulateMedia", tab, ["colorScheme": .string(wanted)])) == "ok")
        var owner = try #require(tab.developmentOwner)
        rig.session.revoke()
        await owner.cleanup?.value
        #expect(tab.developmentOwner == nil)
        #expect(try await waitUntil { try await prefersDark(tab) == baseline })

        // So does the Developer tier no longer applying: the lease holds Developer-tier work, so Development access alone
        // does not keep it.
        let again = try makeRig()
        let (second, secondWindow) = try await open(again, server, engine: engine)
        defer { hide(secondWindow) }
        try await share(again, expecting: second)
        #expect(status(try await call(again, "emulateMedia", second, ["colorScheme": .string(wanted)])) == "ok")
        owner = try #require(second.developmentOwner)
        try again.trust.setIncludesThisMac(false)
        again.session.refreshStanding()
        await owner.cleanup?.value
        #expect(second.developmentOwner == nil)
        #expect(try await waitUntil { try await prefersDark(second) == baseline })
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func mediaEmulationNeverLeaksToAnotherTab(engine: BrowserEngine) async throws {
        let rig = try makeRig()
        let server = try await server()
        let (first, firstWindow) = try await open(rig, server, engine: engine)
        defer { hide(firstWindow) }
        try await share(rig, expecting: first)
        let baseline = try await prefersDark(first)
        let wanted = baseline ? "light" : "dark"
        #expect(status(try await call(rig, "emulateMedia", first, ["colorScheme": .string(wanted)])) == "ok")
        #expect(try await prefersDark(first) == !baseline)

        // A tab opened afterwards, and one that was already open elsewhere in the window, keep the page's own value.
        let (second, secondWindow) = try await open(rig, server, engine: engine)
        defer { hide(secondWindow) }
        #expect(try await prefersDark(second) == baseline)
        #expect(second.developmentOwner == nil)
        #expect(try await prefersDark(first) == !baseline, "the first tab keeps its emulation")
        if engine == .webKit {
            #expect(second.page.webKit?.appearance == nil)
        }
        // The second tab is not shared, so the connection cannot emulate on it.
        #expect(try await call(rig, "emulateMedia", second, ["colorScheme": .string(wanted)]).isError == true)
        #expect(try await prefersDark(second) == baseline)
        _ = try await call(rig, "resetDevelopment", first)
    }

    @Test(.boundedWebViews)
    func mediaEmulationNeedsTheDeveloperTier() async throws {
        let rig = try makeRig(standing: .development)
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        let shared = try await call(rig, "requestAccess")
        #expect(shared.isError == false)
        #expect(rig.session.grants[tab.id]?.access == .development)
        let calls: [(String, [String: Value])] = [("emulateMedia", ["colorScheme": "dark"]), ("clearSiteData", [:])]
        for (name, arguments) in calls {
            let result = try await call(rig, name, tab, arguments)
            #expect(result.isError == true, "\(name) is Developer-tier work")
        }
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.webKit?.appearance == nil)
    }

    // MARK: Site data

    private let seed = """
        localStorage.setItem('k', 'v'); sessionStorage.setItem('s', 'v');
        document.cookie = 'session=cookieSecret42; path=/';
        await new Promise((resolve, reject) => {
          const request = indexedDB.open('fixtureDB', 1);
          request.onupgradeneeded = () => request.result.createObjectStore('items');
          request.onsuccess = () => { request.result.close(); resolve(); };
          request.onerror = () => reject(request.error);
        });
        return true;
        """

    private func seedStorage(_ tab: BrowserTab) async throws {
        let seeded = try await tab.page.callAsyncJavaScript(seed, in: nil, contentWorld: .page)
        #expect(seeded as? Bool == true)
    }

    private struct Remaining: Equatable {
        var localStorage: Int
        var sessionStorage: Int
        var cookie: Bool
        var databases: Int
    }

    private func remaining(_ tab: BrowserTab) async throws -> Remaining {
        let raw = try await tab.page.callAsyncJavaScript(
            """
            return JSON.stringify({ localStorage: localStorage.length, sessionStorage: sessionStorage.length,
              cookie: document.cookie.includes('session='), databases: (await indexedDB.databases()).length });
            """, in: nil, contentWorld: .page)
        let json = try #require(raw as? String)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return Remaining(
            localStorage: object["localStorage"] as? Int ?? -1, sessionStorage: object["sessionStorage"] as? Int ?? -1,
            cookie: object["cookie"] as? Bool ?? false, databases: object["databases"] as? Int ?? -1)
    }

    private static let foreignDomain = "other.example.test"

    private func plantForeignCookie(_ tab: BrowserTab) async throws {
        if let webKit = tab.page.webKit {
            let cookie = try #require(
                HTTPCookie(properties: [.domain: Self.foreignDomain, .path: "/", .name: "keep", .value: "1"]))
            await webKit.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        } else if let chromium = tab.page.chromium {
            _ = try await chromium.command(
                "Network.setCookie", params: ["name": "keep", "value": "1", "domain": Self.foreignDomain, "path": "/"])
        }
    }

    private func hasForeignCookie(_ tab: BrowserTab) async throws -> Bool {
        if let webKit = tab.page.webKit {
            return await webKit.configuration.websiteDataStore.httpCookieStore.allCookies().contains { $0.domain == Self.foreignDomain }
        }
        let chromium = try #require(tab.page.chromium)
        let all = try await chromium.command("Network.getAllCookies")
        return ((all["cookies"] as? [[String: Any]]) ?? []).contains { $0["domain"] as? String == Self.foreignDomain }
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func clearSiteDataOnADeveloperSiteNeedsNoSheet(engine: BrowserEngine) async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        try await seedStorage(tab)
        try await plantForeignCookie(tab)
        #expect(try await remaining(tab) == Remaining(localStorage: 1, sessionStorage: 1, cookie: true, databases: 1))

        let cleared = try await call(rig, "clearSiteData", tab)
        #expect(status(cleared) == "ok", "\(text(cleared))")
        #expect(rig.sheets.shown == 0, "no sheet on a developer site in the Developer profile")
        let fields = try #require(cleared.structuredContent?.objectValue)
        #expect(fields["cookieScope"]?.stringValue == "host")
        #expect(fields["origin"]?.stringValue == SitePermissions.origin(for: try server.url()))
        let counts = try #require(fields["cleared"]?.objectValue)
        #expect(counts["localStorageItems"]?.intValue == 1)
        #expect(counts["sessionStorageItems"]?.intValue == 1)
        #expect(counts["indexedDBDatabases"]?.intValue == 1)
        #expect((counts["cookies"]?.intValue ?? 0) >= 1)
        #expect(fields["notCleared"]?.arrayValue?.compactMap(\.stringValue) == ["httpCache"])
        #expect(!text(cleared).contains(Self.cookieValue), "nothing that was removed is returned")

        #expect(try await remaining(tab) == Remaining(localStorage: 0, sessionStorage: 0, cookie: false, databases: 0))
        #expect(try await hasForeignCookie(tab), "a cookie of another site stays")
        // The tab stays on its page and keeps working.
        let address = try server.url()
        #expect(tab.page.url == address)
        #expect(try await ping(tab) == 200)
    }

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func otherOriginsAndPortsKeepTheirStorage(engine: BrowserEngine) async throws {
        let rig = try makeRig()
        let server = try await server()
        let neighbour = try await self.server()
        let (tab, window) = try await open(rig, server, engine: engine)
        defer { hide(window) }
        let (other, otherWindow) = try await open(rig, neighbour, engine: engine)
        defer { hide(otherWindow) }
        // The neighbour is another port of the same host and is not shared with the connection.
        #expect(rig.browser.activeTabID == other.id)
        rig.browser.activeTabID = tab.id
        try await share(rig, expecting: tab)
        #expect(rig.session.grants[other.id] == nil)
        try await seedStorage(tab)
        _ = try await other.page.callAsyncJavaScript(
            "localStorage.setItem('other', 'keep'); sessionStorage.setItem('other', 'keep'); return true",
            in: nil, contentWorld: .page)

        #expect(status(try await call(rig, "clearSiteData", tab)) == "ok")
        #expect(try await remaining(tab).localStorage == 0)
        let kept = try await other.page.callAsyncJavaScript(
            "return localStorage.getItem('other') + '/' + sessionStorage.getItem('other')", in: nil, contentWorld: .page)
        #expect(kept as? String == "keep/keep", "another port keeps its storage")
        // Cookies belong to the host, not the port: both ports lose them, and the result says so.
        let cookieLeft = try await other.page.callAsyncJavaScript("return document.cookie.includes('session=')", in: nil, contentWorld: .page)
        #expect(cookieLeft as? Bool == false)
    }

    @Test(.boundedWebViews)
    func clearSiteDataRefusesTheEverydayProfileEvenWhenItIsTheDeveloperProfile() async throws {
        let rig = try makeRig(everyday: true)
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        // The owner chose the everyday profile, so the Developer tier holds there.
        try await share(rig, expecting: tab)
        #expect(rig.session.permits(tab, capability: .developer))
        try await seedStorage(tab)

        let refused = try await call(rig, "clearSiteData", tab)
        #expect(status(refused) == "denied")
        #expect(refused.isError == true)
        #expect(text(refused).contains("everyday"))
        #expect(try await remaining(tab) == Remaining(localStorage: 1, sessionStorage: 1, cookie: true, databases: 1), "nothing was removed")
        // This profile is the app's own default store; leave it as it was found.
        _ = try await tab.page.callAsyncJavaScript(
            "localStorage.clear(); sessionStorage.clear(); document.cookie = 'session=; Max-Age=0; path=/'; return true", in: nil, contentWorld: .page)
    }

    @Test(.boundedWebViews)
    func siteDataIsRefusedOutsideTheDeveloperProfileAndTheDeveloperSites() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        let local = try server.url()
        #expect(rig.session.siteDataRefusal(view: tab.page, url: local) == nil)
        // Not a developer site, even in the Developer profile.
        for address in ["https://shop.example.com/", "http://192.168.1.10:3000/", "http://localhost.evil.test/", "http://127.0.0.2/"] {
            let url = try #require(URL(string: address))
            #expect(rig.session.siteDataRefusal(view: tab.page, url: url) != nil, "\(address)")
        }
        // A listed site is a developer site; removing it takes it away again.
        let listed = try #require(URL(string: "https://staging.example.com:8443/"))
        #expect(rig.session.siteDataRefusal(view: tab.page, url: listed) != nil)
        let site = try rig.trust.addDeveloperSite("staging.example.com:8443")
        #expect(rig.session.siteDataRefusal(view: tab.page, url: listed) == nil)
        try rig.trust.removeDeveloperSite(site)
        #expect(rig.session.siteDataRefusal(view: tab.page, url: listed) != nil)
        // Another profile than the chosen one.
        try rig.trust.setDeveloperProfile(UUID())
        #expect(rig.session.siteDataRefusal(view: tab.page, url: local) != nil)
        try rig.trust.setDeveloperProfile(nil)
        #expect(rig.session.siteDataRefusal(view: tab.page, url: local) != nil)
        // The everyday profile is refused whichever profile is chosen, and so is a store that is not the profile's own.
        let everyday = try makeRig(everyday: true)
        let (home, homeWindow) = try await open(everyday, server, engine: .webKit)
        defer { hide(homeWindow) }
        #expect(everyday.session.siteDataRefusal(view: home.page, url: local)?.contains("everyday") == true)
        let privateContext = BrowserProfileContext(profile: .privateBrowsing())
        let privatePage = BrowserPage(webKit: privateContext.webViewPool.makeColdView(), context: privateContext)
        #expect(rig.session.siteDataRefusal(view: privatePage, url: local) != nil)
    }

    @Test(.boundedWebViews)
    func aNonDeveloperTabCannotClearOrEmulateAnything() async throws {
        let rig = try makeRig()
        let remote = await parkTab(rig.browser, at: try #require(URL(string: "https://shop.invalid/")))
        let shared = try await call(rig, "requestAccess")
        #expect(shared.isError == false, "\(text(shared))")
        #expect(rig.sheets.shown == 1, "a site that is not a developer site still asks")
        #expect(rig.session.grants[remote.id]?.access == .control)
        let calls: [(String, [String: Value])] = [("emulateMedia", ["colorScheme": "dark"]), ("clearSiteData", [:])]
        for (name, arguments) in calls {
            #expect(try await call(rig, name, remote, arguments).isError == true, "\(name)")
        }
        #expect(remote.developmentOwner == nil)
    }

    @Test(.boundedWebViews)
    func clearingStopsWhenAccessIsLostAndNeverReachesTheCookiesFirst() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        try await seedStorage(tab)
        let url = try server.url()

        // Refused before anything runs.
        var outcome = await tab.page.clearDevelopmentSiteData(for: url, authorize: { false })
        guard case .stale = outcome else {
            Issue.record("a refused request must report stale")
            return
        }
        #expect(try await remaining(tab) == Remaining(localStorage: 1, sessionStorage: 1, cookie: true, databases: 1))

        // Access lost after the page script ran: the storage is gone, but the cookies are not touched.
        var checks = 0
        outcome = await tab.page.clearDevelopmentSiteData(for: url, authorize: {
            checks += 1
            return checks < 2
        })
        guard case .stale = outcome else {
            Issue.record("losing access must stop the work")
            return
        }
        let left = try await remaining(tab)
        #expect(left.localStorage == 0 && left.sessionStorage == 0)
        #expect(left.cookie, "the cookies are removed only while access still holds")

        // The page is on another origin than the one that was authorized: the script itself refuses to run.
        let wrong = try #require(URL(string: "http://127.0.0.1:1/"))
        try await seedStorage(tab)
        outcome = await tab.page.clearDevelopmentSiteData(for: wrong, authorize: { true })
        guard case .stale = outcome else {
            Issue.record("a different origin must report stale")
            return
        }
        #expect(try await remaining(tab).localStorage == 1, "the page's own storage was not touched")
    }

    @Test(.boundedWebViews)
    func clearSiteDataLeavesSitePermissionsAndOtherSitesAlone() async throws {
        let rig = try makeRig()
        let server = try await server()
        let (tab, window) = try await open(rig, server, engine: .webKit)
        defer { hide(window) }
        try await share(rig, expecting: tab)
        let origin = SitePermissions.origin(for: try server.url())
        rig.permissions.setAssistantAccess(.control, for: origin)
        rig.permissions.setAssistantAccess(.readOnly, for: "https://elsewhere.example")
        try await seedStorage(tab)
        try await plantForeignCookie(tab)

        #expect(status(try await call(rig, "clearSiteData", tab)) == "ok")
        #expect(rig.permissions.assistantAccess(for: origin) == .control)
        #expect(rig.permissions.assistantAccess(for: "https://elsewhere.example") == .readOnly)
        #expect(rig.permissions.engine(for: origin) == .webKit)
        #expect(try await hasForeignCookie(tab))
    }
}
