// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// Under an Allow Control default, a visible password or payment field makes the assistant ask before it uses the page.
@MainActor
@Suite(.boundedWebViews)
struct PageSensitiveProbeTests {
    private func loadedWebView(_ body: String) async -> BrowserPage {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            ),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        page.loadHTMLString("<!doctype html><html><body>\(body)</body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
        return page
    }

    @Test(arguments: [
        #"<input type="password" aria-label="Password">"#,
        #"<input type="text" autocomplete="cc-number" aria-label="Number">"#,
        #"<input type="text" name="cardnumber">"#,
        #"<input type="text" autocomplete="one-time-code">"#,
        #"<input type="text" placeholder="Security code">"#,
        #"<input type="text" placeholder="IBAN">"#,
        #"<div id="host"></div><script>host.attachShadow({mode:'open'}).innerHTML='<input type=password>'</script>"#,
        #"<iframe srcdoc="<input type=password>" width="300" height="80"></iframe>"#,
        #"<iframe title="Secure card payment input frame" src="about:blank" width="300" height="80"></iframe>"#,
    ])
    func aVisiblePasswordOrPaymentFieldIsFound(_ body: String) async {
        let page = await loadedWebView(body)
        #expect(await PageSensitiveProbe.hasSensitiveField(in: page))
    }

    @Test(arguments: [
        #"<input type="search" aria-label="Search the site">"#,
        #"<input type="email" aria-label="Email"><button>Next</button>"#,
        #"<textarea aria-label="Comment"></textarea>"#,
        #"<input type="password" style="display:none">"#,
        #"<div hidden><input type="password"></div>"#,
        #"<div id="pin-board">Pinned notes</div><a href="/">Home</a>"#,
        #"<iframe title="Advertisement" src="about:blank" width="300" height="80"></iframe>"#,
        "<p>No fields at all.</p>",
    ])
    func anOrdinaryPageIsNotSensitive(_ body: String) async {
        let page = await loadedWebView(body)
        #expect(!(await PageSensitiveProbe.hasSensitiveField(in: page)))
    }

    /// A look that cannot run is not an answer of "no fields".
    @Test func aPageThatCannotBeInspectedIsTreatedAsSensitive() async {
        let page = await loadedWebView("<p>No fields at all.</p>")
        let refusing = PageAutomationGuard(documentURL: "about:blank", snapshot: nil) { false }

        let answer = await PageAutomationGuard.$current.withValue(refusing) {
            await PageSensitiveProbe.hasSensitiveField(in: page)
        }

        #expect(answer)
    }

    /// The probe asks the page through the engine-neutral script path, so Chromium answers the same way.
    @Test(arguments: BrowserEngine.allCases)
    func bothEnginesFindThePasswordFieldAndLeaveAPlainPageAlone(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/login": .html(#"<!doctype html><input type="password" aria-label="Password">"#),
            "/plain": .html(#"<!doctype html><input type="search" aria-label="Search"><p>Plain</p>"#),
        ])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url("/login")) { page in
            #expect(await PageSensitiveProbe.hasSensitiveField(in: page), "engine \(engine)")
        }
        try await withPage(engine: engine, url: server.url("/plain")) { page in
            #expect(!(await PageSensitiveProbe.hasSensitiveField(in: page)), "engine \(engine)")
        }
    }

    private func withPage(engine: BrowserEngine, url: URL, body: (BrowserPage) async throws -> Void) async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration),
                context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try await body(page)
        } catch {
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        await page.close()
        await context.endPrivateSession()
    }
}
