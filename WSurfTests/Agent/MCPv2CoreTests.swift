// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// End-to-end coverage of MCP v2 Phase 1: new-tab-first defaults, user-tab protection on `navigate`, Chromium default with
/// WebKit switching (`setTabEngine`), autofill read-redaction with write-allowance, Control password entry with automatic
/// scrubbing and black-box screenshot masking, anonymized `vaultHint`, `requestUserLogin` Vault/manual flows, and the
/// `credentialTainted` + live-secret DevTools / `evaluateScript` security guard on both WebKit and Chromium.
@MainActor
@Suite(.serialized, .boundedWebViews, .noAnnouncePause)
struct MCPv2CoreTests {
    static let vaultPassword = "VaultSecret-2026!Qx"
    static let controlPassword = "CtrlSecret-2026!Zp"
    static let otpCode = "739204"
    static let hidden = MCPSecretScrubber.replacement

    static let loginHTML = """
        <!doctype html><title>Sign In</title>
        <style>
          body { margin: 0; font-family: -apple-system, sans-serif; }
          input { display: block; width: 240px; height: 32px; border: 0; padding: 0; margin: 0 0 8px 0; }
          #pw { background: #f00; color: #fff; }
          #plain { width: 240px; height: 32px; background: #00f; }
        </style>
        <form id=login-form onsubmit="event.preventDefault(); document.body.dataset.submitted = 'yes';">
          <input id=user name=username autocomplete=username aria-label="Email">
          <input id=pw name=password type=password autocomplete=current-password aria-label="Password">
          <input id=otp autocomplete=one-time-code aria-label="Verification code">
          <div id=plain></div>
          <button id=submit type=submit onclick="document.body.dataset.loginClicked='yes'">Log in</button>
        </form>
        <button id=oauth onclick="document.body.dataset.oauthClicked='yes'">Continue with Google</button>
        <button id=probe onclick="runProbe()">Run probe</button>
        <a href="/other">Other</a>
        <p id=echo></p>
        <script>
          const pw = document.getElementById('pw');
          pw.addEventListener('input', () => {
            document.getElementById('echo').textContent = 'Typed ' + pw.value;
          });
          async function runProbe() {
            const secret = document.getElementById('pw').value || 'empty';
            console.log('vault-probe', { token: secret, kind: 'login' });
            await fetch('/echo', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ note: 'login-submit', value: secret })
            });
            document.body.dataset.probed = 'yes';
          }
        </script>
        """

    private static let autofillHTML = """
        <!doctype html><title>Checkout</title>
        <form>
          <input id=email autocomplete=username aria-label="Email" value="saved-user@example.test" data-wsurf-autofilled="1">
          <input id=addr autocomplete=street-address aria-label="Street address" value="742 Evergreen Terrace" data-wsurf-contact="1">
          <input id=pw type=password aria-label="Password" value="old-vault-pw" data-wsurf-password="1">
        </form>
        """

    private static let dashboardHTML = """
        <!doctype html><title>Dashboard</title>
        <p>Welcome to the dashboard</p>
        <button id=dash-probe onclick="runDashProbe()">Dashboard probe</button>
        <script>
          async function runDashProbe() {
            console.log('dash-probe', { ok: true, area: 'dashboard' });
            await fetch('/api', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ hello: 'dashboard-body' })
            });
            document.body.dataset.dashProbed = 'yes';
          }
        </script>
        """

    struct Rig {
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let trust: MCPTrustStore
        let window: NSWindow
        let root: NSView
        let owner: BrowserTab
    }

    func withRig(
        ownerPath: String = "/mine",
        ownerEngine: BrowserEngine = .webKit,
        _ body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Home</title><p>Home fixture</p><a href=\"/other\">Other</a>"),
            "/mine": .html("<!doctype html><title>User Tab</title><p>User personal tab</p>"),
            "/other": .html("<!doctype html><title>Other</title><h1>Other destination</h1><a href=\"/next\">Next</a>"),
            "/next": .html("<!doctype html><title>Next</title><p>Next destination</p>"),
            "/login": .html(Self.loginHTML),
            "/autofill": .html(Self.autofillHTML),
            "/dashboard": .html(Self.dashboardHTML),
            "/echo": .bytes(Data("{\"echoed\":\"server-response-body\"}".utf8), contentType: "application/json"),
            "/api": .bytes(Data("{\"status\":\"dashboard-response-body\"}".utf8), contentType: "application/json"),
        ])
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPv2Core-\(UUID().uuidString).json")))
        let ownerURL = try server.url(ownerPath)
        browser.sitePermissions.setEngine(ownerEngine, for: SitePermissions.origin(for: ownerURL))

        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 640, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        window.contentView = root
        window.orderBack(nil)
        browser.context.extensions.register(browser: browser, window: window)

        let owner = browser.newTab(url: ownerURL)
        let container = WebViewContainer(page: owner.page)
        container.parksWhenIdle = true
        container.frame = root.bounds
        root.addSubview(container)
        try #require(await waitUntil { owner.page.url == ownerURL && !owner.page.isLoading && owner.page.mainDocumentID != nil })
        owner.assistantAccess.persistsAnswers = false
        owner.assistantAccess.pageChanged(url: ownerURL)

        let rig = Rig(server: server, browser: browser, trust: trust, window: window, root: root, owner: owner)
        defer { _ = server }
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
        rig.browser.context.extensions.unregister(browser: rig.browser)
        rig.window.contentView = nil
        rig.window.close()
    }

    func everything(_ result: CallTool.Result) -> String {
        let blocks = result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }
        let structured = result.structuredContent.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? ""
        return (blocks + [structured]).joined(separator: "\n")
    }

    func observation(_ result: CallTool.Result) throws -> String {
        try #require(result.structuredContent?.objectValue?["observationID"]?.stringValue, "\(everything(result))")
    }

    func fieldRef(_ label: String, in result: CallTool.Result) throws -> Int {
        let content = try #require(result.structuredContent?.objectValue?["content"]?.stringValue, "\(everything(result))")
        let line = try #require(
            content.split(separator: "\n").first { $0.contains("field \"\(label)\"") },
            "no field \(label) in \(content)")
        return try #require(Int(line.dropFirst().prefix { $0.isNumber }))
    }

    func buttonRef(_ label: String, in result: CallTool.Result) throws -> Int {
        let content = try #require(result.structuredContent?.objectValue?["content"]?.stringValue, "\(everything(result))")
        let line = try #require(
            content.split(separator: "\n").first { $0.contains("button \"\(label)\"") },
            "no button \(label) in \(content)")
        return try #require(Int(line.dropFirst().prefix { $0.isNumber }))
    }

    func call(
        _ session: MCPBrowserSession, _ name: String, tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]
    ) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await session.call(name: name, arguments: arguments)
    }

    func sampleColor(in result: CallTool.Result, at point: CGPoint, scale: CGFloat) throws -> (red: Double, green: Double, blue: Double) {
        let data = try #require(result.content.compactMap { block -> Data? in
            guard case .image(let base64, _, _, _) = block else { return nil }
            return Data(base64Encoded: base64)
        }.first, "no image in screenshot")
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let px = max(0, min(bitmap.pixelsWide - 1, Int((point.x * scale).rounded())))
        let py = max(0, min(bitmap.pixelsHigh - 1, Int((point.y * scale).rounded())))
        let color = try #require(bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    func elementCenter(_ id: String, in tab: BrowserTab) async throws -> CGPoint {
        let raw = try #require(try await tab.page.evaluateJavaScript(
            "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")
            as? [Double])
        return CGPoint(x: raw[0], y: raw[1])
    }

    func fakeVault(
        accountLabel: String = "vault-user@example.test",
        username: String = "vault-user@example.test",
        password: String = MCPv2CoreTests.vaultPassword
    ) -> MCPVaultProvider {
        let summary = MCPVaultProvider.AccountSummary(
            id: UUID(), label: accountLabel, vaultID: UUID(), revision: 1, epoch: 1)
        return MCPVaultProvider(
            savedAccounts: { _, _, _ in [summary] },
            blindFill: { _, view, url, _, submit, registerSecret in
                if !password.isEmpty, !registerSecret(password) {
                    return PageDriver.VaultFillResult(
                        ok: false, documentID: nil, fieldsFilled: [], submitted: false,
                        error: "Could not register the saved password for output scrubbing. Nothing was filled.")
                }
                return await PageDriver.fillVaultLogin(
                    username: username, password: password, submit: submit,
                    expectedOrigin: SitePermissions.origin(for: url), in: view)
            }
        )
    }

    func emptyVault() -> MCPVaultProvider {
        MCPVaultProvider(savedAccounts: { _, _, _ in [] }, blindFill: { _, _, _, _, _, _ in nil })
    }

    // MARK: 1. New Tab Default & User Tab Protection

    @Test func newTabOpensWithoutPriorGrantsInChromiumAndLeavesUserActiveTabUntouched() async throws {
        try await withRig { rig in
            var openPrompts = 0
            var allowOpen = false
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in
                    Issue.record("requestAccess consent sheet must not appear when opening via newTab")
                    return nil
                },
                openConsent: { _, _ in
                    openPrompts += 1
                    return allowOpen
                })
            defer { session.revoke() }

            let destination = try rig.server.url("/other")
            let declined = try await call(session, "newTab", ["url": .string(destination.absoluteString)])
            #expect(declined.isError == true)
            #expect(openPrompts == 1)
            #expect(rig.browser.tabs.count == 1)
            #expect(session.grants.isEmpty)

            allowOpen = true
            let opened = try await call(session, "newTab", ["url": .string(destination.absoluteString)])
            #expect(opened.isError == false, "\(everything(opened))")
            #expect(openPrompts == 2)

            let payload = try #require(opened.structuredContent?.objectValue)
            let tabID = try #require(payload["tabID"]?.stringValue.flatMap(UUID.init(uuidString:)))
            #expect(payload["engine"]?.stringValue == "chromium")
            #expect(payload["background"]?.boolValue == true)
            #expect(rig.browser.activeTabID == rig.owner.id, "user active tab remains selected")
            #expect(session.grants[rig.owner.id] == nil, "user active tab is never shared")
            #expect(session.grants[tabID]?.access == .control)
            #expect(session.openedTabs.contains(tabID))

            let newTab = try #require(rig.browser.tabs.first { $0.id == tabID })
            #expect(newTab.engine == .chromium)
            #expect(newTab.page.isParked)
            #expect(await waitUntil { newTab.page.url == destination && !newTab.page.isLoading && newTab.page.mainDocumentID != nil })
            let read = try await call(session, "readPage", tab: newTab)
            #expect(read.isError == false, "\(everything(read))")
            #expect(everything(read).contains("Other destination"))
        }
    }

    @Test func newTabCoveredByWebsiteDefaultOpensImmediatelyWithoutPrompting() async throws {
        try await withRig { rig in
            let client = try rig.trust.pair(token: SyntheticToken.first, name: "Codex", kind: .codex)
            rig.browser.sitePermissions.setAssistantDefault(.control)
            try rig.trust.setAppsFollowDefault(true, level: .control)
            var openPrompts = 0
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                openConsent: { _, _ in
                    openPrompts += 1
                    return true
                })
            session.pairedClient = rig.trust.client(id: client.id)
            defer { session.revoke() }

            let destination = try rig.server.url("/other")
            let opened = try await call(session, "newTab", ["url": .string(destination.absoluteString)])
            #expect(opened.isError == false, "\(everything(opened))")
            #expect(openPrompts == 0, "Website access default opens immediately without a sheet")
            #expect(rig.browser.activeTabID == rig.owner.id)
            #expect(session.grants[rig.owner.id] == nil)
        }
    }

    @Test func navigateProtectsUserOwnedTabsByDefaultAndAllowsInPlaceWhenRequested() async throws {
        try await withRig(ownerPath: "/") { rig in
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                openConsent: { _, _ in true })
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            _ = try await call(session, "readPage", tab: rig.owner)
            let ownerStartURL = try rig.server.url("/")
            let otherURL = try rig.server.url("/other")
            let nextURL = try rig.server.url("/next")

            // User-owned tab (not in openedTabs): navigate opens destination in a new background tab.
            let redirected = try await call(session, "navigate", tab: rig.owner, ["url": .string(otherURL.absoluteString)])
            #expect(redirected.isError == false, "\(everything(redirected))")
            let payload = try #require(redirected.structuredContent?.objectValue)
            #expect(payload["openedNewTab"]?.boolValue == true)
            let openedID = try #require(payload["tabID"]?.stringValue.flatMap(UUID.init(uuidString:)))
            #expect(openedID != rig.owner.id)
            #expect(session.openedTabs.contains(openedID))
            #expect(rig.browser.activeTabID == rig.owner.id)
            #expect(rig.owner.page.url == ownerStartURL, "user tab stays untouched at its original URL")

            let agentTab = try #require(rig.browser.tabs.first { $0.id == openedID })
            #expect(await waitUntil { agentTab.page.url == otherURL && !agentTab.page.isLoading && agentTab.page.mainDocumentID != nil })
            _ = try await call(session, "readPage", tab: agentTab)

            // Agent-opened tab (in openedTabs): navigate navigates in-place.
            let countBefore = rig.browser.tabs.count
            let inAgentTab = try await call(session, "navigate", tab: agentTab, ["url": .string(nextURL.absoluteString)])
            #expect(inAgentTab.isError == false, "\(everything(inAgentTab))")
            #expect(rig.browser.tabs.count == countBefore)
            #expect(await waitUntil { agentTab.page.url == nextURL && !agentTab.page.isLoading })

            // Explicit inPlace: true on a user-owned tab navigates it in-place.
            let explicitInPlace = try await call(
                session, "navigate", tab: rig.owner,
                ["url": .string(otherURL.absoluteString), "inPlace": true])
            #expect(explicitInPlace.isError == false, "\(everything(explicitInPlace))")
            #expect(rig.browser.tabs.count == countBefore)
            #expect(await waitUntil { rig.owner.page.url == otherURL && !rig.owner.page.isLoading })
        }
    }

    @Test func playwrightNavigateAutoOpensBackgroundTabAndBindsSubsequentSnapshots() async throws {
        try await withRig { rig in
            var openPrompts = 0
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                openConsent: { _, _ in
                    openPrompts += 1
                    return true
                })
            defer { session.revoke() }

            // Case 1: No shared tabs yet -> browser_navigate opens a new background tab and binds playwrightTab.
            let otherURL = try rig.server.url("/other")
            let navigated = try await call(session, "browser_navigate", ["url": .string(otherURL.absoluteString)])
            #expect(navigated.isError == false, "\(everything(navigated))")
            #expect(openPrompts == 1)
            #expect(rig.browser.activeTabID == rig.owner.id)
            let boundID = try #require(session.playwrightTab)
            #expect(boundID != rig.owner.id)
            #expect(session.openedTabs.contains(boundID))

            let agentTab = try #require(rig.browser.tabs.first { $0.id == boundID })
            #expect(await waitUntil { agentTab.page.url == otherURL && !agentTab.page.isLoading && agentTab.page.mainDocumentID != nil })
            let snap = try await call(session, "browser_snapshot")
            #expect(snap.isError == false, "\(everything(snap))")
            #expect(everything(snap).contains("Other destination"))
            #expect(session.grants[rig.owner.id] == nil)
        }
    }

    // MARK: 2. Chromium Default, WebKit Switch & webKitOnlyOrigins

    @Test func newTabAndSetTabEngineSwitchBetweenChromiumAndWebKitAndRespectWebKitOnlyOrigins() async throws {
        try await withRig { rig in
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                openConsent: { _, _ in true })
            defer { session.revoke() }

            // WebKit selectable under Control (no developer tier required).
            let otherURL = try rig.server.url("/other")
            let webkitOpen = try await call(session, "newTab", ["url": .string(otherURL.absoluteString), "engine": "webkit"])
            #expect(webkitOpen.isError == false, "\(everything(webkitOpen))")
            let tabID = try #require(webkitOpen.structuredContent?.objectValue?["tabID"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let tab = try #require(rig.browser.tabs.first { $0.id == tabID })
            #expect(tab.engine == .webKit)
            #expect(await waitUntil { tab.page.url == otherURL && !tab.page.isLoading && tab.page.mainDocumentID != nil })

            // Switch WebKit -> Chromium -> WebKit via setTabEngine while staying parked & shared.
            let toChromium = try await call(session, "setTabEngine", tab: tab, ["engine": "chromium"])
            #expect(toChromium.isError == false, "\(everything(toChromium))")
            #expect(toChromium.structuredContent?.objectValue?["switched"]?.boolValue == true)
            #expect(tab.engine == .chromium)
            #expect(session.grants[tab.id]?.access == .control)
            #expect(tab.page.isParked)
            #expect(await waitUntil { tab.page.url == otherURL && !tab.page.isLoading && tab.page.mainDocumentID != nil })
            let readChromium = try await call(session, "readPage", tab: tab)
            #expect(readChromium.isError == false, "\(everything(readChromium))")
            #expect(everything(readChromium).contains("Other destination"))

            // No-op switch when already on requested engine.
            let noop = try await call(session, "setTabEngine", tab: tab, ["engine": "chromium"])
            #expect(noop.isError == false)
            #expect(noop.structuredContent?.objectValue?["switched"]?.boolValue == false)

            let backToWebKit = try await call(session, "setTabEngine", tab: tab, ["engine": "webkit"])
            #expect(backToWebKit.isError == false, "\(everything(backToWebKit))")
            #expect(tab.engine == .webKit)
            #expect(await waitUntil { tab.page.url == otherURL && !tab.page.isLoading && tab.page.mainDocumentID != nil })

            // Origins in SitePermissions.webKitOnlyOrigins refuse Chromium on both newTab and setTabEngine.
            let googleURL = "https://accounts.google.com/"
            #expect(SitePermissions.webKitOnlyOrigins.contains("https://accounts.google.com"))
            let refusedOpen = try await call(session, "newTab", ["url": .string(googleURL), "engine": "chromium"])
            #expect(refusedOpen.isError == true)
            #expect(everything(refusedOpen).contains("requires WebKit"))

            let googleTab = rig.browser.newTab(url: nil, activate: false)
            googleTab.loadHTML("<p>Offline Google fixture</p>", baseURL: URL(string: googleURL)!)
            #expect(await waitUntil { googleTab.page.url?.host() == "accounts.google.com" && !googleTab.page.isLoading })
            session.grants[googleTab.id] = .init(origin: "https://accounts.google.com", access: .control)
            let refusedSwitch = try await call(session, "setTabEngine", tab: googleTab, ["engine": "chromium"])
            #expect(refusedSwitch.isError == true)
            #expect(everything(refusedSwitch).contains("requires WebKit"))
            #expect(googleTab.engine == .webKit)
        }
    }

    // MARK: 3. Autofill Read-Redaction + Write-Allowance

    @Test func autofilledUsernameAndContactFieldsHidePriorValuesOnReadButAcceptWrites() async throws {
        try await withRig(ownerPath: "/autofill") { rig in
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control })
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            let read = try await call(session, "readPage", tab: rig.owner)
            #expect(read.isError == false, "\(everything(read))")
            let readText = everything(read)
            #expect(!readText.contains("saved-user@example.test"), "autofilled username must be hidden on read")
            #expect(!readText.contains("742 Evergreen Terrace"), "autofilled contact address must be hidden on read")
            #expect(!readText.contains("old-vault-pw"), "autofilled password must be hidden on read")
            #expect(readText.contains("(filled, hidden)"))

            let emailRef = try fieldRef("Email", in: read)
            let addrRef = try fieldRef("Street address", in: read)
            let obs = try observation(read)

            let filled = try await call(session, "fillFields", tab: rig.owner, [
                "observationID": .string(obs),
                "fields": .array([
                    .object(["ref": .int(emailRef), "value": "agent@example.test", "select": false]),
                    .object(["ref": .int(addrRef), "value": "100 Main St", "select": false]),
                ]),
            ])
            #expect(filled.isError == false, "\(everything(filled))")
            #expect(everything(filled).contains("Filled 2 of 2"))
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('email').value") as? String == "agent@example.test")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('addr').value") as? String == "100 Main St")

            // Playwright alias browser_type also overwrites non-secret autofilled fields cleanly.
            session.playwrightTab = rig.owner.id
            let typed = try await call(session, "browser_type", [
                "ref": .string(String(emailRef)), "text": "playwright@example.test",
            ])
            #expect(typed.isError == false, "\(everything(typed))")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('email').value") as? String == "playwright@example.test")
        }
    }

    // MARK: 4. Control Password Entry, Black-Box Masking & Plain Login Submit

    @Test func controlPasswordEntryAutoScrubsMasksScreenshotsAndAllowsPlainLoginSubmit() async throws {
        try await withRig(ownerPath: "/login") { rig in
            try rig.trust.setAllowsPasswordEntry(true)
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                vaultProvider: emptyVault())
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            #expect(!session.permits(rig.owner, capability: .developer), "this test exercises standard Control, not Developer")
            let read = try await call(session, "readPage", tab: rig.owner)
            let obs = try observation(read)
            let pwRef = try fieldRef("Password", in: read)
            let otpRef = try fieldRef("Verification code", in: read)
            let loginBtn = try buttonRef("Log in", in: read)
            let oauthBtn = try buttonRef("Continue with Google", in: read)

            // Type password directly under Control WITHOUT secret: true.
            let typedPW = try await call(session, "typeOnPage", tab: rig.owner, [
                "observationID": .string(obs), "ref": .int(pwRef), "text": .string(Self.controlPassword),
            ])
            #expect(typedPW.isError == false, "\(everything(typedPW))")
            #expect(!everything(typedPW).contains(Self.controlPassword))
            #expect(everything(typedPW).contains("(sensitive field, value hidden)"))
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == Self.controlPassword)

            // Page echoed the password into #echo; readPage must scrub it to ‹secret›.
            let afterType = try await call(session, "readPage", tab: rig.owner)
            #expect(!everything(afterType).contains(Self.controlPassword))
            #expect(everything(afterType).contains(Self.hidden))

            // OTP via fillFields works directly without secret: true.
            let filledOTP = try await call(session, "fillFields", tab: rig.owner, [
                "observationID": .string(try observation(afterType)),
                "fields": .array([.object(["ref": .int(otpRef), "value": .string(Self.otpCode), "select": false])]),
            ])
            #expect(filledOTP.isError == false, "\(everything(filledOTP))")
            #expect(!everything(filledOTP).contains(Self.otpCode))
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('otp').value") as? String == Self.otpCode)

            // Screenshot under Control masks the red password field black while leaving #plain blue.
            let shot = try await call(session, "screenshotPage", tab: rig.owner)
            #expect(shot.isError == false, "\(everything(shot))")
            let width = try #require(try await rig.owner.page.evaluateJavaScript("window.innerWidth") as? Int)
            let imageData = try #require(shot.content.compactMap { block -> Data? in
                guard case .image(let base64, _, _, _) = block else { return nil }
                return Data(base64Encoded: base64)
            }.first)
            let scale = CGFloat(try #require(NSBitmapImageRep(data: imageData)).pixelsWide) / CGFloat(width)
            let pwColor = try sampleColor(in: shot, at: try await elementCenter("pw", in: rig.owner), scale: scale)
            let plainColor = try sampleColor(in: shot, at: try await elementCenter("plain", in: rig.owner), scale: scale)
            #expect(pwColor.red < 0.15 && pwColor.green < 0.15 && pwColor.blue < 0.15, "password box is masked black: \(pwColor)")
            #expect(plainColor.blue > 0.6 && plainColor.red < 0.3 && plainColor.green < 0.3, "non-secret region stays blue: \(plainColor)")

            // Plain "Log in" submit button clicks WITHOUT asking AgentActionConsent; "Continue with Google" still asks.
            var askedCategories: [SensitiveAction.Category] = []
            let clickedLogin = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, _ in
                askedCategories.append(category)
                return .decline
            }) {
                try await call(session, "clickOnPage", tab: rig.owner, [
                    "observationID": .string(try observation(shot)), "ref": .int(loginBtn),
                ])
            }
            #expect(clickedLogin.isError == false, "\(everything(clickedLogin))")
            #expect(askedCategories.isEmpty, "plain Log in button must not prompt for accountAccess")
            #expect(try await rig.owner.page.evaluateJavaScript("document.body.dataset.loginClicked") as? String == "yes")

            let clickedOAuth = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, _ in
                askedCategories.append(category)
                return .decline
            }) {
                try await call(session, "clickOnPage", tab: rig.owner, [
                    "observationID": .string(try observation(clickedLogin)), "ref": .int(oauthBtn),
                ])
            }
            #expect(clickedOAuth.isError == true)
            #expect(askedCategories == [.accountAccess])

            // Turning off allowsPasswordEntry refuses Control password writes AND screenshots with a filled password.
            try rig.trust.setAllowsPasswordEntry(false)
            let blockedRead = try await call(session, "readPage", tab: rig.owner)
            let blockedWrite = try await call(session, "typeOnPage", tab: rig.owner, [
                "observationID": .string(try observation(blockedRead)), "ref": .int(pwRef), "text": "blocked-2026",
            ])
            #expect(blockedWrite.isError == true)
            let blockedShot = try await call(session, "screenshotPage", tab: rig.owner)
            #expect(blockedShot.isError == true)
            #expect(everything(blockedShot).contains("Screenshot refused"))
        }
    }

    // MARK: 5. Anonymized vaultHint & requestUserLogin Flows

    @Test func vaultHintIsAnonymizedOnLoginFormsAndOmittedOnNonLoginPages() async throws {
        try await withRig(ownerPath: "/login") { rig in
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                vaultProvider: fakeVault(accountLabel: "secret.identity@corp.example", username: "secret.identity@corp.example"))
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            let read = try await call(session, "readPage", tab: rig.owner)
            #expect(read.isError == false)
            let hint = try #require(read.structuredContent?.objectValue?["vaultHint"]?.objectValue)
            #expect(hint["hasSavedLogin"]?.boolValue == true)
            #expect(hint["requiresUserApproval"]?.boolValue == true)
            #expect(hint.keys.sorted() == ["hasSavedLogin", "requiresUserApproval"])
            #expect(!everything(read).contains("secret.identity@corp.example"), "vaultHint must never leak usernames")

            let pwRef = try fieldRef("Password", in: read)
            let inspected = try await call(session, "inspectControl", tab: rig.owner, [
                "observationID": .string(try observation(read)), "ref": .int(pwRef),
            ])
            #expect(inspected.isError == false)
            let inspectHint = try #require(inspected.structuredContent?.objectValue?["vaultHint"]?.objectValue)
            #expect(inspectHint["hasSavedLogin"]?.boolValue == true)
            #expect(inspectHint["requiresUserApproval"]?.boolValue == true)
            #expect(!everything(inspected).contains("secret.identity@corp.example"))

            // Without saved accounts, hasSavedLogin is false.
            session.vaultProvider = emptyVault()
            let readNoSaved = try await call(session, "readPage", tab: rig.owner)
            let noSavedHint = try #require(readNoSaved.structuredContent?.objectValue?["vaultHint"]?.objectValue)
            #expect(noSavedHint["hasSavedLogin"]?.boolValue == false)
            #expect(noSavedHint["requiresUserApproval"]?.boolValue == true)

            // Non-login page omits vaultHint entirely.
            let otherURL = try rig.server.url("/other")
            _ = try await call(session, "navigate", tab: rig.owner, ["url": .string(otherURL.absoluteString), "inPlace": true])
            #expect(await waitUntil { rig.owner.page.url == otherURL && !rig.owner.page.isLoading })
            let nonLogin = try await call(session, "readPage", tab: rig.owner)
            #expect(nonLogin.structuredContent?.objectValue?["vaultHint"] == nil)
        }
    }

    @Test func requestUserLoginHandlesManualNoSavedDeclineTakeOverFillAndFillAndSignIn() async throws {
        try await withRig(ownerPath: "/login") { rig in
            enum Action { case decline, takeOver, fill, fillAndSignIn }
            var nextAction: Action = .decline
            var consentCalls = 0
            var manualFlags: [Bool] = []
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                loginConsent: { _, _, accounts, allowsManual, _ in
                    consentCalls += 1
                    manualFlags.append(allowsManual)
                    switch nextAction {
                    case .decline:
                        return .decline
                    case .takeOver:
                        return .takeOver
                    case .fill:
                        return .fill(accountID: accounts.first?.id)
                    case .fillAndSignIn:
                        return .fillAndSignIn(accountID: accounts.first?.id)
                    }
                },
                vaultProvider: fakeVault())
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")

            // 1. Decline: touches nothing, keeps grant.
            nextAction = .decline
            let declined = try await call(session, "requestUserLogin", tab: rig.owner, ["reason": "Sign in to view invoices"])
            #expect(declined.isError == false)
            #expect(declined.structuredContent?.objectValue?["status"]?.stringValue == "declined")
            #expect(manualFlags.last == true)
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == "")
            #expect(session.grants[rig.owner.id] != nil)

            // 2. vaultFill with empty Vault: returns noSavedLogin without prompting sheet.
            session.vaultProvider = emptyVault()
            let beforeNoSaved = consentCalls
            let noSaved = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(noSaved.isError == false)
            #expect(noSaved.structuredContent?.objectValue?["status"]?.stringValue == "noSavedLogin")
            #expect(consentCalls == beforeNoSaved)
            session.vaultProvider = fakeVault()

            // 3. Vault Fill (without submitting): fills DOM, hides values, marks document credentialTainted.
            nextAction = .fill
            let filled = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultOrManual"])
            #expect(filled.isError == false, "\(everything(filled))")
            let fillObj = try #require(filled.structuredContent?.objectValue)
            #expect(fillObj["status"]?.stringValue == "filledByVault")
            #expect(fillObj["submitted"]?.boolValue == false)
            #expect(fillObj["valuesHidden"]?.boolValue == true)
            #expect(fillObj["documentProtected"]?.boolValue == true)
            let fieldsFilled = fillObj["fieldsFilled"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(fieldsFilled == ["username", "password"])
            #expect(!everything(filled).contains(Self.vaultPassword))
            #expect(!everything(filled).contains("vault-user@example.test"))
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('user').value") as? String == "vault-user@example.test")
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value") as? String == Self.vaultPassword)
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('user').hasAttribute('data-wsurf-autofilled')") as? Bool == true)
            #expect(try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').hasAttribute('data-wsurf-password')") as? Bool == true)
            #expect(try await rig.owner.page.evaluateJavaScript("document.body.dataset.submitted || ''") as? String == "")
            #expect(rig.owner.isMCPCredentialTainted)

            // 4. Vault Fill & Sign In (`mode: vaultFill` hides Sign In Myself): fills DOM AND submits the form.
            nextAction = .fillAndSignIn
            let filledAndSubmitted = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(filledAndSubmitted.isError == false, "\(everything(filledAndSubmitted))")
            #expect(manualFlags.last == false, "mode: vaultFill hides Sign In Myself")
            #expect(filledAndSubmitted.structuredContent?.objectValue?["status"]?.stringValue == "filledByVault")
            #expect(filledAndSubmitted.structuredContent?.objectValue?["submitted"]?.boolValue == true)
            #expect(try await rig.owner.page.evaluateJavaScript("document.body.dataset.submitted") as? String == "yes")

            // 5. Take Over: hands tab back to user.
            nextAction = .takeOver
            let tookOver = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultOrManual"])
            #expect(tookOver.isError == false)
            #expect(tookOver.structuredContent?.objectValue?["status"]?.stringValue == "waitingForUser")
            #expect(session.grants[rig.owner.id] == nil)

            // 6. mode: manualLogin on a newly connected session: hands tab back directly without showing Vault sheet.
            let manualSession = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .control },
                loginConsent: { _, _, _, _, _ in
                    consentCalls += 1
                    return .decline
                },
                vaultProvider: fakeVault())
            defer { manualSession.revoke() }
            _ = try await call(manualSession, "requestAccess")
            #expect(manualSession.grants[rig.owner.id] != nil)
            let beforeManual = consentCalls
            let manual = try await call(manualSession, "requestUserLogin", tab: rig.owner, ["mode": "manualLogin"])
            #expect(manual.isError == false)
            #expect(manual.structuredContent?.objectValue?["status"]?.stringValue == "waitingForUser")
            #expect(consentCalls == beforeManual)
            #expect(manualSession.grants[rig.owner.id] == nil)
        }
    }

    private func expectEvaluateScriptDenied(
        _ session: MCPBrowserSession, tab: BrowserTab, engine: BrowserEngine,
        leakFlag: String, hiddenValue: String
    ) async throws {
        for world in ["page", "isolated"] {
            let denied = try await call(session, "evaluateScript", tab: tab, [
                "source": "(() => { window.\(leakFlag) = true; return document.getElementById('pw').value; })()",
                "world": .string(world),
            ])
            #expect(denied.isError == true, "\(engine)/\(world): evaluateScript must be denied")
            #expect(denied.structuredContent?.objectValue?["status"]?.stringValue == "denied")
            #expect(denied.structuredContent?.objectValue?["code"]?.stringValue == "protectedSecretPresent")
            #expect(!everything(denied).contains(hiddenValue))
            #expect(try await tab.page.evaluateJavaScript("window.\(leakFlag) || false") as? Bool == false)
        }
    }

    private func waitForDiagnosticsRecord(
        _ session: MCPBrowserSession, tool: String, tab: BrowserTab,
        arguments: [String: Value] = [:],
        matching predicate: @escaping ([String: Value]) -> Bool
    ) async -> [String: Value]? {
        var found: [String: Value]?
        _ = await waitUntil {
            guard let res = try? await self.call(session, tool, tab: tab, arguments),
                let records = res.structuredContent?.objectValue?["records"]?.arrayValue
            else { return false }
            for case .object(let rec) in records where predicate(rec) {
                found = rec
                return true
            }
            return false
        }
        return found
    }

    // MARK: 6. CRITICAL SECURITY INVARIANT: credentialTainted + Live Secret Guard (WebKit & Chromium)

    @Test(arguments: BrowserEngine.allCases)
    func protectedCredentialDocumentBlocksEvaluateScriptAndOmitsDevToolsBodiesUntilNavigation(engine: BrowserEngine) async throws {
        try await withRig(ownerPath: "/login", ownerEngine: engine) { rig in
            let client = try rig.trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
            try rig.trust.setStanding(.developer, for: client.id)
            try rig.trust.setDeveloperProfile(Profile.originalID)
            let session = MCPBrowserSession(
                browser: rig.browser, trust: rig.trust, available: { true },
                consent: { _, _, _ in .developer },
                loginConsent: { _, _, accounts, _, _ in .fill(accountID: accounts.first?.id) },
                vaultProvider: fakeVault())
            session.pairedClient = rig.trust.client(id: client.id)
            defer { session.revoke() }

            _ = try await call(session, "requestAccess")
            #expect(session.permits(rig.owner, capability: .developer), "\(engine): Developer tier active")
            let started = try await call(session, "startDiagnostics", tab: rig.owner, [
                "headers": true, "bodies": true, "fullConsole": true,
            ])
            #expect(started.isError == false, "\(engine): \(everything(started))")
            #expect(try await call(session, "evaluateScript", tab: rig.owner, ["source": "2 + 2", "world": "page"]).isError == false)

            // Part A: Live filled password field (without Vault fill) blocks evaluateScript in BOTH worlds.
            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = 'UserTypedSecret-88!'; 0")
            try await expectEvaluateScriptDenied(session, tab: rig.owner, engine: engine, leakFlag: "__leaked", hiddenValue: "UserTypedSecret-88!")
            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = ''; 0")
            #expect(try await call(session, "evaluateScript", tab: rig.owner, ["source": "'ok'"]).isError == false)

            // Part B: Vault Fill taints the document (`credentialTainted`).
            let vaultFill = try await call(session, "requestUserLogin", tab: rig.owner, ["mode": "vaultFill"])
            #expect(vaultFill.isError == false, "\(engine): \(everything(vaultFill))")
            #expect(vaultFill.structuredContent?.objectValue?["documentProtected"]?.boolValue == true)
            try await expectEvaluateScriptDenied(session, tab: rig.owner, engine: engine, leakFlag: "__vaultLeaked", hiddenValue: Self.vaultPassword)

            // Trigger network POST + console object dump on the tainted login document via clickOnPage.
            let readBeforeProbe = try await call(session, "readPage", tab: rig.owner)
            let clickedProbe = try await call(session, "clickOnPage", tab: rig.owner, [
                "observationID": .string(try observation(readBeforeProbe)), "ref": .int(try buttonRef("Run probe", in: readBeforeProbe)),
            ])
            #expect(clickedProbe.isError == false, "\(engine): \(everything(clickedProbe))")
            #expect(await waitUntil { (try? await rig.owner.page.evaluateJavaScript("document.body.dataset.probed")) as? String == "yes" })

            let netRec = try #require(
                await waitForDiagnosticsRecord(session, tool: "readNetwork", tab: rig.owner, arguments: ["urlContains": "/echo"]) {
                    $0["url"]?.stringValue?.contains("/echo") == true
                }, "\(engine): captured /echo network record while tainted")
            #expect(netRec["requestBody"] == nil && netRec["responseBody"] == nil, "\(engine): bodies omitted: \(netRec)")
            #expect(netRec["requestBodyNote"]?.stringValue == DevelopmentDiagnostics.protectedCredentialBodyNote, "\(engine): \(netRec)")
            #expect(netRec["responseBodyNote"]?.stringValue == DevelopmentDiagnostics.protectedCredentialBodyNote, "\(engine): \(netRec)")
            let netSerialized = String(decoding: (try? JSONEncoder().encode(Value.object(netRec))) ?? Data(), as: UTF8.self)
            #expect(!netSerialized.contains(Self.vaultPassword) && !netSerialized.contains("server-response-body"))

            let conRec = try #require(
                await waitForDiagnosticsRecord(session, tool: "readConsole", tab: rig.owner) {
                    $0["text"]?.stringValue?.contains("vault-probe") == true
                }, "\(engine): captured vault-probe console record while tainted")
            #expect(conRec["preview"] == nil, "\(engine): console preview must be omitted: \(conRec)")
            let conSerialized = String(decoding: (try? JSONEncoder().encode(Value.object(conRec))) ?? Data(), as: UTF8.self)
            #expect(!conSerialized.contains(Self.vaultPassword))

            // Even after clearing #pw.value in the SAME document, taint still blocks evaluateScript!
            _ = try await rig.owner.page.evaluateJavaScript("document.getElementById('pw').value = ''; 0")
            let stillTainted = try await call(session, "evaluateScript", tab: rig.owner, ["source": "'should-fail'"])
            #expect(stillTainted.isError == true && stillTainted.structuredContent?.objectValue?["code"]?.stringValue == "protectedSecretPresent")

            // Part C: Navigating to a clean post-login document (/dashboard) clears taint and restores tools!
            let dashURL = try rig.server.url("/dashboard")
            let nav = try await call(session, "navigate", tab: rig.owner, ["url": .string(dashURL.absoluteString), "inPlace": true])
            #expect(nav.isError == false, "\(engine): \(everything(nav))")
            #expect(await waitUntil { rig.owner.page.url == dashURL && !rig.owner.page.isLoading && rig.owner.page.mainDocumentID != nil })

            let afterNavEval = try await call(session, "evaluateScript", tab: rig.owner, ["source": "document.title"])
            #expect(afterNavEval.isError == false && everything(afterNavEval).contains("Dashboard"), "\(engine): \(everything(afterNavEval))")

            let dashRead = try await call(session, "readPage", tab: rig.owner)
            _ = try await call(session, "clickOnPage", tab: rig.owner, [
                "observationID": .string(try observation(dashRead)), "ref": .int(try buttonRef("Dashboard probe", in: dashRead)),
            ])
            #expect(await waitUntil { (try? await rig.owner.page.evaluateJavaScript("document.body.dataset.dashProbed")) as? String == "yes" })

            let dashNet = try #require(
                await waitForDiagnosticsRecord(session, tool: "readNetwork", tab: rig.owner, arguments: ["urlContains": "/api"]) {
                    $0["url"]?.stringValue?.contains("/api") == true
                }, "\(engine): captured /api network record on clean dashboard")
            #expect(dashNet["requestBody"]?.stringValue?.contains("dashboard-body") == true, "\(engine): \(dashNet)")
            #expect(dashNet["responseBody"]?.stringValue?.contains("dashboard-response-body") == true, "\(engine): \(dashNet)")
        }
    }
}
