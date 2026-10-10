// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The agent's hands, against real pages. Every fixture is a condition the
/// open web presents: duplicate labels, shadow roots, iframes, selects, fields
/// that must be refused, elements that vanish between the read and the act.
/// Real `WKWebView`s rather than mocks, because what is under test is
/// precisely the JavaScript that runs inside WebKit.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageDriverTests {
    private static let stage: BrowserPage = {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        return BrowserPage(webKit: view, context: BrowserProfileContext(profile: .privateBrowsing()))
    }()

    private func loadedWebView(_ body: String) async -> BrowserPage {
        let webView = Self.stage
        webView.loadHTMLString("<!doctype html><html><body>\(body)</body></html>", baseURL: nil)
        #expect(await PageSettle.untilIdle(webView, timeout: .seconds(30)))
        return webView
    }

    private func js(_ webView: BrowserPage, _ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script)
    }

    /// The refs the observation assigned, in the order listed.
    private func refs(in observation: String, matching needle: String) -> [Int] {
        observation
            .components(separatedBy: "\n")
            .filter { $0.contains(needle) }
            .compactMap { line in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<close])
            }
    }

    // MARK: - Observation

    @Test func highlightFitsAllEdgesDespitePageStylesAndBodyTransforms() async throws {
        let view = await loadedWebView("""
        <style>
          body { transform: translate(31px, 17px); }
          div { box-sizing: content-box !important; padding: 19px !important; margin: 20px !important; }
          button { width: 180px; height: 44px; border-radius: 12px; }
        </style>
        <button id="target">Fixture control</button>
        """)
        _ = await PageDriver.readRenderedPage(view)
        await PageDriver.announce(ref: 1, in: view, pause: false)
        let gaps = try #require(await js(view, """
        (() => {
          const a = document.getElementById('target').getBoundingClientRect();
          const b = document.querySelector('.__wsurf-ring').getBoundingClientRect();
          return [a.left-b.left, a.top-b.top, b.right-a.right, b.bottom-a.bottom];
        })()
        """) as? [Double])
        #expect(gaps.count == 4)
        #expect(gaps.allSatisfy { abs($0 - 4) < 0.5 })
        #expect(await js(view, "getComputedStyle(document.querySelector('.__wsurf-ring')).pointerEvents") as? String == "none")
    }

    @Test func highlightTracksLayoutChangesAndDisappearsWithItsControl() async throws {
        let view = await loadedWebView("<button id='target' style='width:180px;height:44px'>Fixture control</button>")
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        _ = await PageDriver.readRenderedPage(view)
        await PageDriver.announce(ref: 1, in: view, pause: false)
        _ = await js(view, "document.getElementById('target').style.cssText='margin-left:40px;width:240px;height:64px'")
        #expect(await waitUntil {
            await js(view, """
            (() => {
              const a = document.getElementById('target').getBoundingClientRect();
              const ring = document.querySelector('.__wsurf-ring');
              if (!ring) return false;
              const b = ring.getBoundingClientRect();
              return Math.abs(a.left-b.left-4)<0.5 && Math.abs(b.width-a.width-8)<0.5 && Math.abs(b.height-a.height-8)<0.5;
            })()
            """) as? Bool == true
        })
        _ = await js(view, "document.getElementById('target').remove()")
        #expect(await waitUntil { await js(view, "document.querySelector('.__wsurf-ring') === null") as? Bool == true })
    }

    @Test func numbersEveryControlAndSaysWhatItIs() async {
        let webView = await loadedWebView("""
        <p>Welcome to the shop.</p>
        <button>Add to Bag</button>
        <a href="https://example.com/product">Product page</a>
        <input placeholder="Search">
        """)
        let observation = await PageDriver.readRenderedPage(webView)

        #expect(observation.contains("PAGE TEXT:"))
        #expect(observation.contains("Welcome to the shop."))
        #expect(observation.contains("CONTROLS"))
        #expect(observation.contains("button \"Add to Bag\""))
        #expect(observation.contains("link \"Product page\" → https://example.com/product"))
        #expect(observation.contains("field \"Search\""))
        #expect(!refs(in: observation, matching: "Add to Bag").isEmpty)
    }

    /// The activity trail and the navigation allowlist both read the links
    /// out of an observation. Only anchors count: a bare domain printed in
    /// prose - which is how Hacker News labels every story - is text.
    @Test func onlyAnchorsCountAsLinks() async {
        let webView = await loadedWebView("""
        <p>Discussed on news.ycombinator.com and simonwillison.net today.</p>
        <a href="https://example.com/story">The story</a>
        <a href="https://example.com/story">The story again</a>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let links = PageDriver.listedLinks(in: observation)

        #expect(links.map(\.url.absoluteString) == ["https://example.com/story"])
        #expect(links.first?.label == "The story")
    }

    @Test func aLinkListingSurvivesItsOwnPunctuation() {
        let controls: [[String: Any]] = [
            ["r": 1, "k": "link", "l": "Home \u{2192} Shop", "h": "https://example.com/shop", "d": 1],
            ["r": 2, "k": "button", "l": "Buy"],
            ["r": 3, "k": "link", "l": "Mail us", "h": "mailto:hi@example.com"],
        ]
        let links = PageDriver.listedLinks(in: PageDriver.renderControls(controls))

        #expect(links.map(\.url.absoluteString) == ["https://example.com/shop"])
        #expect(links.first?.label == "Home \u{2192} Shop")
    }

    /// The reason refs exist: five "More" buttons are five different rows,
    /// not one row shown once.
    @Test func duplicateLabelsGetDistinctRefs() async {
        let webView = await loadedWebView("""
        <button onclick="window.__hit='first'">More</button>
        <button onclick="window.__hit='second'">More</button>
        <button onclick="window.__hit='third'">More</button>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let more = refs(in: observation, matching: "\"More\"")
        #expect(more.count == 3)
        #expect(Set(more).count == 3)
    }

    @Test func clickByRefHitsExactlyTheElementNamed() async throws {
        let webView = await loadedWebView("""
        <button onclick="window.__hit='first'">More</button>
        <button onclick="window.__hit='second'">More</button>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let more = refs(in: observation, matching: "\"More\"")
        let second = try #require(more.dropFirst().first)

        let result = await PageDriver.click(ref: second, label: "", in: webView)
        #expect(result.hasPrefix("Clicked"))
        #expect(await js(webView, "window.__hit") as? String == "second")
    }

    @Test func ambiguousLabelRequiresAnExplicitRef() async {
        let webView = await loadedWebView("""
        <button onclick="window.__hit='a'">Accept cookies</button>
        <button onclick="window.__hit='b'">Accept cookies</button>
        """)
        let result = await PageDriver.click(ref: 0, label: "accept cookies", in: webView)
        #expect(result.contains("Several controls match"))
        #expect(await js(webView, "window.__hit === undefined") as? Bool == true)
    }

    @Test func aMissingLabelListsWhatIsActuallyThere() async {
        let webView = await loadedWebView("""
        <button>Sign up</button>
        <button>Log in</button>
        """)
        let result = await PageDriver.click(ref: 0, label: "Subscribe", in: webView)
        #expect(result.contains("Nothing matches"))
        #expect(result.contains("sign up"))
        #expect(result.contains("log in"))
    }

    // MARK: - The modern web

    @Test func seesInsideOpenShadowRoots() async {
        let webView = await loadedWebView("""
        <div id="host"></div>
        <script>
          const root = document.getElementById('host').attachShadow({ mode: 'open' });
          root.innerHTML = '<button>Shadow Button</button>';
          root.querySelector('button').addEventListener('click', () => { window.__shadowHit = true; });
        </script>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        #expect(observation.contains("Shadow Button"))

        let result = await PageDriver.click(ref: 0, label: "Shadow Button", in: webView)
        #expect(result.hasPrefix("Clicked"))
        #expect(await js(webView, "window.__shadowHit") as? Bool == true)
    }

    @Test func seesInsideSameOriginIframes() async {
        let webView = await loadedWebView("""
        <iframe srcdoc="<p>Inside the frame.</p><button onclick='parent.__frameHit = true'>Frame Button</button>"></iframe>
        """)
        // The iframe loads after the main document; poll the observation
        // until its content appears rather than sleeping a guessed amount.
        var observation = ""
        _ = await waitUntil {
            observation = await PageDriver.readRenderedPage(webView)
            return observation.contains("Frame Button")
        }
        #expect(observation.contains("Frame Button"))
        #expect(observation.contains("Inside the frame."))

        let result = await PageDriver.click(ref: 0, label: "Frame Button", in: webView)
        #expect(result.hasPrefix("Clicked"))
        #expect(await js(webView, "window.__frameHit") as? Bool == true)
    }

    @Test func nativeFrameNonceBindsSelectedFrameOperations() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<iframe src='/child'></iframe><p>Main page</p>"),
            "/child": .html("<p>Selected frame</p>"),
            "/next": .html("<p>Replacement document</p>"),
        ])
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        do {
            page.load(URLRequest(url: try server.url()))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))

            guard await waitUntil({ !(await PageFrameRegistry.shared.targets(in: page)).isEmpty }),
                  let target = await PageFrameRegistry.shared.targets(in: page).first,
                  let main = await PageFrameRegistry.shared.mainFrame(in: page) else {
                Issue.record("frame unavailable")
                await page.close()
                return
            }
            let readyNonce = try await page.callAsyncJavaScript(
                "await globalThis.__wsurfNativeFrameReady; return globalThis.__wsurfNativeFrameNonce;",
                in: main,
                contentWorld: PageAutomationGuard.world
            ) as? String
            #expect(readyNonce == main.documentID)
            #expect(PageFrameRegistry.shared.currentMainFrame(
                matching: main, documentNonce: main.documentID, in: page
            )?.documentID == main.documentID)
            #expect(PageFrameRegistry.shared.currentMainFrame(
                matching: main, documentNonce: UUID().uuidString, in: page
            ) == nil)

            let selectedResult = await PageDriver.$selectedFrame.withValue(target) {
                await PageDriver.evaluateJSON(
                    "JSON.stringify({ text: document.body.textContent, nonce: typeof globalThis.__wsurfNativeFrameNonce })",
                    in: page
                )
            }
            #expect(selectedResult?["text"] as? String == "Selected frame")
            #expect(selectedResult?["nonce"] as? String == "string")
            #expect(await js(page, "typeof globalThis.__wsurfNativeFrameNonce") as? String == "undefined")

            let priorNonce = main.documentID
            page.load(URLRequest(url: try server.url("/next")))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            try #require(await waitUntil {
                guard let current = PageFrameRegistry.shared.mainFrame(in: page) else { return false }
                return current.documentID != priorNonce
            })
            #expect(PageFrameRegistry.shared.currentMainFrame(
                matching: main, documentNonce: priorNonce, in: page
            ) == nil)
            await page.close()
        } catch {
            await page.close()
            throw error
        }
    }

    @Test func sharedWebKitControllerKeepsScriptReplacementAndUnrelatedScripts() async throws {
        let controller = WKUserContentController()
        let configurationA = WebViewPool.makeConfiguration()
        configurationA.userContentController = controller
        configurationA.websiteDataStore = .nonPersistent()
        let configurationB = WebViewPool.makeConfiguration()
        configurationB.userContentController = controller
        configurationB.websiteDataStore = .nonPersistent()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let pageA = BrowserPage(webKit: WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configurationA
        ), context: context)
        let pageB = BrowserPage(webKit: WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configurationB
        ), context: context)
        let oldScript = "window.__oldScriptRuns = (window.__oldScriptRuns || 0) + 1;"
        let newScript = "window.__newScriptRuns = (window.__newScriptRuns || 0) + 1;"
        let unrelatedScript = "window.__unrelatedScriptRuns = (window.__unrelatedScriptRuns || 0) + 1;"
        do {
            pageA.installScript(oldScript, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            pageB.installScript(oldScript, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            pageA.installScript(unrelatedScript, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            pageB.installScript(unrelatedScript, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            try await pageA.replaceScript(oldScript, with: newScript, in: .page)
            try await pageB.replaceScript(oldScript, with: newScript, in: .page)

            pageA.loadHTMLString("<!doctype html><html><body>Shared controller</body></html>", baseURL: nil)
            #expect(await PageSettle.untilIdle(pageA, timeout: .seconds(30)))
            #expect(await js(pageA, "window.__oldScriptRuns === undefined") as? Bool == true)
            #expect(await js(pageA, "window.__newScriptRuns") as? Int == 1)
            #expect(await js(pageA, "window.__unrelatedScriptRuns") as? Int == 1)
        } catch {
            await pageA.close()
            await pageB.close()
            throw error
        }
        await pageA.close()
        await pageB.close()
    }

    @Test func chromiumScriptReplacementTakesEffectBeforeNextNavigation() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/before": .html("<!doctype html><title>Before</title>"),
            "/after": .html("<!doctype html><title>After</title>"),
        ])
        let page = BrowserPage(chromium: ChromiumPage(
            context: BrowserProfileContext(profile: .privateBrowsing())
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        do {
            page.load(URLRequest(url: try server.url("/before")))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let oldScript = "window.__oldScriptRuns = (window.__oldScriptRuns || 0) + 1;"
            let newScript = "window.__newScriptRuns = (window.__newScriptRuns || 0) + 1;"
            let unrelatedScript = "window.__unrelatedScriptRuns = (window.__unrelatedScriptRuns || 0) + 1;"
            page.installScript(oldScript, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            page.installScript(unrelatedScript, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            try await page.replaceScript(oldScript, with: newScript, in: .page)
            page.load(URLRequest(url: try server.url("/after")))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            #expect(await js(page, "window.__oldScriptRuns === undefined") as? Bool == true)
            #expect(await js(page, "window.__newScriptRuns") as? Int == 1)
            #expect(await js(page, "window.__unrelatedScriptRuns") as? Int == 1)
            await page.close()
        } catch {
            await page.close()
            window.contentView = nil
            window.close()
            throw error
        }
        window.contentView = nil
        window.close()
    }

    @Test
    func chromiumFrameDriverUsesLiveFrameTargets() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Top</title><h1>Top-level text</h1><iframe src='/child'></iframe>"),
            "/child": .html("<!doctype html><title>Child</title><button onclick='parent.__frameHit=true'>Frame Button</button>"),
        ])
        try await ChromiumRuntime.shared.ensureInitialized()
        let page = BrowserPage(chromium: ChromiumPage(
            context: BrowserProfileContext(profile: .privateBrowsing())
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        do {
            page.load(URLRequest(url: try server.url()))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            #expect(await waitUntil {
                await PageFrameRegistry.shared.targets(in: page).contains { $0.url.path == "/child" }
            })
            let target = try #require(
                await PageFrameRegistry.shared.targets(in: page).first(where: { $0.url.path == "/child" })
            )
            #expect(await PageFrameRegistry.shared.isLive(target, in: page))

            let observation = await PageDriver.$selectedFrame.withValue(target) {
                await PageDriver.readRenderedPage(page)
            }
            #expect(observation.contains("Frame Button"))
            #expect(!observation.contains("Top-level text"))
            let ref = try #require(refs(in: observation, matching: "Frame Button").first)
            let result = await PageDriver.$selectedFrame.withValue(target) {
                await PageDriver.click(ref: ref, label: "Frame Button", in: page)
            }
            #expect(result.hasPrefix("Clicked"))
            #expect(await js(page, "window.__frameHit") as? Bool == true)
            await page.close()
            window.contentView = nil
            window.close()
        } catch {
            await page.close()
            window.contentView = nil
            window.close()
            throw error
        }
    }

    @Test
    func inheritedAboutFramesAreNotExposedAsFrameTargets() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
            <!doctype html><title>Top</title>
            <iframe src="about:blank"></iframe>
            <iframe srcdoc="&lt;p&gt;srcdoc frame&lt;/p&gt;"></iframe>
            """),
        ])
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let tab = BrowserTab(
            adopting: webView, opensBlank: false, privately: true, context: context
        )
        let page = tab.page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        do {
            page.load(URLRequest(url: try server.url()))
            #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            #expect(await PageFrameRegistry.shared.targets(in: page).isEmpty)
            await page.close()
            window.contentView = nil
            window.close()
        } catch {
            await page.close()
            window.contentView = nil
            window.close()
            throw error
        }
    }

    @Test func doesNotReadOrControlCrossOriginFrames() async throws {
        let framed = try await HTTPFixtureServer.start(routes: [
            "/framed": .html("<p>Cross-origin secret</p><button>Hidden action</button>"),
        ])
        let framedURL = try framed.url("/framed")
        let top = try await HTTPFixtureServer.start(routes: [
            "/": .html("<h1>Top-level text</h1><iframe src=\"\(framedURL.absoluteString)\"></iframe>"),
        ])
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(
                frame: NSRect(x: 0, y: 0, width: 500, height: 400),
                configuration: configuration
            ),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        page.load(URLRequest(url: try top.url()))
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))

        let observation = await PageDriver.readRenderedPage(page)
        #expect(observation.contains("Top-level text"))
        #expect(!observation.contains("Cross-origin secret"))
        #expect(!observation.contains("Hidden action"))
    }

    @Test func invisibleElementsAreNotOffered() async {
        let webView = await loadedWebView("""
        <button>Visible</button>
        <button style="display:none">Hidden</button>
        <button style="visibility:hidden">Ghost</button>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        #expect(observation.contains("\"Visible\""))
        #expect(!observation.contains("\"Hidden\""))
        #expect(!observation.contains("\"Ghost\""))
    }

    @Test func aWrapperAndItsInnerControlAreOneRow() async {
        let webView = await loadedWebView("""
        <div role="button" onclick="window.__hit=1">
          <button>Buy tickets</button>
        </div>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        #expect(refs(in: observation, matching: "Buy tickets").count == 1)
    }

    // MARK: - Staleness and disabled controls

    @Test func aStaleRefSaysSoInsteadOfGuessing() async throws {
        let webView = await loadedWebView(#"<button id="gone">Remove me</button>"#)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "Remove me").first)

        _ = await js(webView, "document.getElementById('gone').remove()")
        let result = await PageDriver.click(ref: ref, label: "", in: webView)
        #expect(result.contains("gone"))
        #expect(result.contains("readPage"))
    }

    @Test func aStaleFieldRefDoesNotTypeIntoAReplacement() async throws {
        let webView = await loadedWebView(#"<input id="gone" placeholder="Search">"#)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "Search").first)

        _ = await js(webView, "document.getElementById('gone').remove()")
        _ = await js(webView, "document.body.innerHTML = '<input id=\"replacement\" placeholder=\"Search\">'")
        let result = await PageDriver.type(
            text: "private text",
            intoField: "",
            ref: ref,
            submit: false,
            in: webView
        )

        #expect(result.contains("gone"))
        #expect(result.contains("readPage"))
        #expect(await js(webView, "document.getElementById('replacement').value") as? String == "")
    }

    @Test func aStaleSelectRefDoesNotChooseFromAReplacement() async throws {
        let webView = await loadedWebView("""
        <select id="gone" aria-label="Size"><option>Small</option><option>Large</option></select>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "Size").first)

        _ = await js(webView, "document.getElementById('gone').remove()")
        _ = await js(webView, "document.body.innerHTML = '<select id=\"replacement\" aria-label=\"Size\"><option>Small</option><option>Large</option></select>'")
        let result = await PageDriver.selectOption("Large", ref: ref, field: "", in: webView)

        #expect(result.contains("gone"))
        #expect(result.contains("readPage"))
        #expect(await js(webView, "document.getElementById('replacement').value") as? String == "Small")
    }

    @Test func aDisabledControlIsMarkedAndNotClicked() async throws {
        let webView = await loadedWebView(#"<script>window.__hit=0</script><button disabled onclick="window.__hit++">Continue</button>"#)
        let observation = await PageDriver.readRenderedPage(webView)
        #expect(observation.contains("(disabled)"))

        let ref = try #require(refs(in: observation, matching: "Continue").first)
        let result = await PageDriver.click(ref: ref, label: "", in: webView)
        #expect(result.contains("disabled"))
        #expect(await js(webView, "window.__hit") as? Int == 0)
    }

    // MARK: - Typing

    @Test func typesByRefAndFiresTheEventsFrameworksListenFor() async throws {
        let webView = await loadedWebView("""
        <input id="q" placeholder="Search">
        <script>
          window.__events = [];
          const q = document.getElementById('q');
          q.addEventListener('input', () => window.__events.push('input'));
          q.addEventListener('change', () => window.__events.push('change'));
        </script>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "Search").first)

        let result = await PageDriver.type(text: "running shoes", intoField: "", ref: ref, submit: false, in: webView)
        #expect(result.hasPrefix("Typed into “Search”"))
        #expect(await js(webView, "document.getElementById('q').value") as? String == "running shoes")
        let events = await js(webView, "JSON.stringify(window.__events)") as? String
        #expect(events?.contains("input") == true)
        #expect(events?.contains("change") == true)
    }

    @Test func submitReachesTheForm() async {
        let webView = await loadedWebView("""
        <form onsubmit="window.__submitted = true; return false;">
          <input name="q" placeholder="Search">
        </form>
        """)
        let result = await PageDriver.type(text: "shoes", intoField: "Search", ref: 0, submit: true, in: webView)
        #expect(result.contains("requested submission"))
        #expect(await js(webView, "window.__submitted") as? Bool == true)
    }

    // MARK: - Selects

    @Test func listsASelectWithItsOptionsAndCurrentChoice() async {
        let webView = await loadedWebView("""
        <label for="size">Size</label>
        <select id="size">
          <option>Small</option><option selected>Medium</option><option>Large</option>
        </select>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        #expect(observation.contains("select \"Size\" = \"Medium\""))
        #expect(observation.contains("Small | Medium | Large"))
    }

    @Test func choosesAnOptionByRefAndFiresChange() async throws {
        let webView = await loadedWebView("""
        <label for="size">Size</label>
        <select id="size" onchange="window.__changed = this.value">
          <option>Small</option><option selected>Medium</option><option>Large</option>
        </select>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "select \"Size\"").first)

        let result = await PageDriver.selectOption("Large", ref: ref, field: "", in: webView)
        #expect(result.hasPrefix("Selected “Large” in “Size”"))
        #expect(await js(webView, "document.getElementById('size').value") as? String == "Large")
        #expect(await js(webView, "window.__changed") as? String == "Large")
    }

    @Test func choosesAnOptionByTheSelectsLabel() async {
        let webView = await loadedWebView("""
        <label for="country">Country</label>
        <select id="country"><option>France</option><option>Germany</option></select>
        """)
        let result = await PageDriver.selectOption("germany", ref: 0, field: "Country", in: webView)
        #expect(result.hasPrefix("Selected “Germany”"))
    }

    @Test func aMissingOptionListsWhatTheSelectOffers() async throws {
        let webView = await loadedWebView("""
        <label for="size">Size</label>
        <select id="size"><option>Small</option><option>Large</option></select>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        let ref = try #require(refs(in: observation, matching: "select").first)

        let result = await PageDriver.selectOption("Enormous", ref: ref, field: "", in: webView)
        #expect(result.contains("No option matches"))
        #expect(result.contains("Small | Large"))
    }

    // MARK: - Checkboxes

    @Test func checkboxesReadTheirLabelsAndReportTheirState() async throws {
        let webView = await loadedWebView("""
        <input type="checkbox" id="news">
        <label for="news">Subscribe to the newsletter</label>
        """)
        let observation = await PageDriver.readRenderedPage(webView)
        #expect(observation.contains("checkbox \"Subscribe to the newsletter\" (unchecked)"))

        let ref = try #require(refs(in: observation, matching: "checkbox").first)
        let result = await PageDriver.click(ref: ref, label: "", in: webView)
        #expect(result.hasPrefix("Clicked"))
        #expect(await js(webView, "document.getElementById('news').checked") as? Bool == true)
    }

    // MARK: - Scrolling and reading

    /// "Visible now" has to mean the viewport, not the top of the document -
    /// after a scroll those differ by exactly the amount scrolled.
    @Test func scrollReportsWhatIsActuallyOnScreen() async {
        let webView = await loadedWebView("""
        <p>TOPMARKER at the very top.</p>
        <div style="height: 500px"></div>
        <p>BOTTOMMARKER further down.</p>
        """)
        let result = await PageDriver.scroll(direction: "down", in: webView)
        #expect(result.contains("BOTTOMMARKER"))
        #expect(!result.contains("TOPMARKER"))
    }

    @Test func lookingForReturnsThePartOfThePageAboutIt() async {
        let filler = String(repeating: "Nothing to see in this paragraph of filler prose. ", count: 120)
        let webView = await loadedWebView("""
        <p>\(filler)</p>
        <p>The warranty on this product lasts 24 months from delivery.</p>
        """)
        let plain = await PageDriver.readRenderedPage(webView)
        #expect(!plain.contains("24 months"), "the answer sits past the budget without lookingFor")

        let aimed = await PageDriver.readRenderedPage(webView, lookingFor: "warranty period")
        #expect(aimed.contains("warranty"))
        #expect(aimed.contains("24 months"))
    }

    @Test func anActionWithNeitherRefNorLabelAsksForOne() async {
        let webView = await loadedWebView("<button>Fine</button>")
        let result = await PageDriver.click(ref: 0, label: "", in: webView)
        #expect(result.contains("Say which element"))
    }
}

extension PageDriverTests {
    @Test func aBatchFillsIndependentFieldsWithoutSubmitting() async throws {
        let webView = await loadedWebView("""
        <form onsubmit="window.submitted=true;return false">
          <input aria-label="First"><input aria-label="Second">
          <select aria-label="Choice"><option>A</option><option>B</option></select>
          <button>Save</button>
        </form>
        """)
        let page = await PageDriver.readRenderedPage(webView)
        let first = try #require(refs(in: page, matching: "field \"First\"").first)
        let second = try #require(refs(in: page, matching: "field \"Second\"").first)
        let select = try #require(refs(in: page, matching: "select \"Choice\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: first, value: "fixture-one", select: false),
            .init(ref: second, value: "fixture-two", select: false),
            .init(ref: select, value: "B", select: true),
        ], in: webView)
        #expect(result.hasPrefix("Filled 3 of 3 fields."))
        #expect(await js(webView, "document.querySelectorAll('input')[0].value") as? String == "fixture-one")
        #expect(await js(webView, "document.querySelectorAll('input')[1].value") as? String == "fixture-two")
        #expect(await js(webView, "document.querySelector('select').value") as? String == "B")
        #expect(await js(webView, "window.submitted === true") as? Bool == false)
        #expect(result.contains("CONTROLS"))
    }

    @Test func aBatchContinuesAfterFillingEditableText() async throws {
        let webView = await loadedWebView("""
        <div contenteditable="true" aria-label="First"><span>Original text</span></div>
        <textarea aria-label="Second">Original notes</textarea>
        <input aria-label="Third">
        """)
        let page = await PageDriver.readRenderedPage(webView)
        let first = try #require(refs(in: page, matching: "field \"First\"").first)
        let second = try #require(refs(in: page, matching: "field \"Second\"").first)
        let third = try #require(refs(in: page, matching: "field \"Third\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: first, value: "Updated text", select: false),
            .init(ref: second, value: "Updated notes", select: false),
            .init(ref: third, value: "Last value", select: false),
        ], in: webView)
        #expect(result.hasPrefix("Filled 3 of 3 fields."))
        #expect(await js(webView, "document.querySelector('[contenteditable]').textContent") as? String == "Updated text")
        #expect(await js(webView, "document.querySelector('textarea').value") as? String == "Updated notes")
        #expect(await js(webView, "document.querySelector('input').value") as? String == "Last value")
    }

    @Test func aBatchStopsWhenEditableTextTriggersValidation() async throws {
        let webView = await loadedWebView("""
        <div contenteditable="true" aria-label="First"
             oninput="document.getElementById('validation').textContent='Check the first value'"></div>
        <input aria-label="Second"><div id="validation"></div>
        """)
        let page = await PageDriver.readRenderedPage(webView)
        let first = try #require(refs(in: page, matching: "field \"First\"").first)
        let second = try #require(refs(in: page, matching: "field \"Second\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: first, value: "Updated text", select: false),
            .init(ref: second, value: "never-entered", select: false),
        ], in: webView)
        #expect(result.hasPrefix("Filled 1 of 2 fields."))
        #expect(result.contains("page changed"))
        #expect(await js(webView, "document.querySelector('input').value") as? String == "")
    }

    @Test func aBatchStopsWhenValidationChangesTheForm() async throws {
        let webView = await loadedWebView("""
        <input aria-label="First" onchange="document.getElementById('validation').textContent='Check the first value'">
        <input aria-label="Second"><div id="validation"></div>
        """)
        let page = await PageDriver.readRenderedPage(webView)
        let first = try #require(refs(in: page, matching: "field \"First\"").first)
        let second = try #require(refs(in: page, matching: "field \"Second\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: first, value: "fixture-one", select: false),
            .init(ref: second, value: "fixture-two", select: false),
        ], in: webView)
        #expect(result.hasPrefix("Filled 1 of 2 fields."))
        #expect(result.contains("page changed"))
        #expect(await js(webView, "document.querySelectorAll('input')[1].value") as? String == "")
    }

    @Test func aBatchCannotBypassSensitiveFieldChecks() async throws {
        let webView = await loadedWebView("<input aria-label='Password' type='password'><input aria-label='Other'>")
        let page = await PageDriver.readRenderedPage(webView)
        let password = try #require(refs(in: page, matching: "field \"Password\"").first)
        let other = try #require(refs(in: page, matching: "field \"Other\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: password, value: "fixture-secret", select: false),
            .init(ref: other, value: "safe-value", select: false),
        ], in: webView)
        #expect(result.hasPrefix("Filled 1 of 2 fields."))
        #expect(result.contains("sensitive field"))
        #expect(await js(webView, "document.querySelector('input[type=password]').value") as? String == "")
        #expect(await js(webView, "document.querySelectorAll('input')[1].value") as? String == "safe-value")
    }

    @Test func aBatchRejectsDuplicateOrStaleRefsBeforeFurtherWrites() async throws {
        let webView = await loadedWebView("<input aria-label='First'>")
        let page = await PageDriver.readRenderedPage(webView)
        let first = try #require(refs(in: page, matching: "field \"First\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: first, value: "one", select: false),
            .init(ref: first, value: "two", select: false),
        ], in: webView)
        #expect(result.contains("distinct"))
        #expect(await js(webView, "document.querySelector('input').value") as? String == "")
    }

    @Test func individualActionsReturnFreshRefsAfterValidation() async throws {
        let webView = await loadedWebView("""
        <input aria-label="First" onchange="document.body.insertAdjacentHTML('afterbegin','<button>Validation help</button>')">
        <input aria-label="Second">
        """)
        let page = await PageDriver.readRenderedPage(webView)
        let first = try #require(refs(in: page, matching: "field \"First\"").first)
        let result = await PageDriver.type(text: "one", intoField: "", ref: first, submit: false, in: webView)
        let newSecond = try #require(refs(in: result, matching: "field \"Second\"").first)
        let secondResult = await PageDriver.type(text: "two", intoField: "", ref: newSecond, submit: false, in: webView)
        #expect(secondResult.hasPrefix("Typed"))
        #expect(await js(webView, "document.querySelectorAll('input')[1].value") as? String == "two")
    }
    @Test func mixedFormFillsTenOfFourteenAndSkipsIneligibleControls() async throws {
        let webView = await loadedWebView("""
        <form onsubmit="window.submitted=true;return false">
          <input aria-label="Name"><textarea aria-label="Notes"></textarea>
          <select aria-label="Choice"><option>A</option><option>B</option></select>
          <input aria-label="City" list="cities"><datalist id="cities"><option value="Paris"></datalist>
          <input aria-label="Color" type="color" value="#563d7c">
          <input aria-label="Date" type="date" onfocus="document.body.insertAdjacentHTML('beforeend','<p>Calendar open</p>')">
          <input aria-label="Range" type="range" min="0" max="10" step="1">
          <input aria-label="Checked" type="checkbox" checked>
          <input aria-label="Unchecked" type="checkbox">
          <input aria-label="First radio" type="radio" name="choice" checked>
          <input aria-label="Second radio" type="radio" name="choice">
          <input aria-label="Password" type="password"><input aria-label="File" type="file">
          <input aria-label="Disabled" disabled><input aria-label="Readonly" readonly>
          <button>Submit</button>
        </form>
        <script>window.events=[]; document.addEventListener('change', e => window.events.push(e.target.getAttribute('aria-label')));</script>
        """)
        let page = await PageDriver.readRenderedPage(webView)
        let values = [
            ("Name", "Jordan"), ("Notes", "Sample"), ("Choice", "B"), ("City", "Paris"),
            ("Color", "#3366AA"), ("Date", "2026-10-15"), ("Range", "7"),
            ("Checked", "false"), ("Unchecked", "true"), ("Second radio", "true"),
            ("Password", "never-write"), ("File", "never-write"), ("Disabled", "never-write"), ("Readonly", "never-write"),
        ]
        let fields = try values.map { label, value in
            PageDriver.FieldValue(
                ref: try #require(refs(in: page, matching: "\"\(label)\"").first),
                value: value, select: label == "Choice"
            )
        }
        let result = await PageDriver.fillFields(fields, in: webView)
        #expect(result.hasPrefix("Filled 10 of 14 fields."), "\(result)")
        #expect(await js(webView, "document.querySelector('[type=color]').value") as? String == "#3366aa")
        #expect(await js(webView, "document.querySelector('[type=range]').value") as? String == "7")
        #expect(await js(webView, "document.querySelector('[type=date]').value") as? String == "2026-10-15")
        #expect(await js(webView, "Array.from(document.querySelectorAll('[type=checkbox],[type=radio]')).map(e=>e.checked)") as? [Bool] == [false, true, false, true])
        #expect(await js(webView, "Array.from(document.querySelectorAll('[type=password],[type=file],[disabled],[readonly]')).every(e=>e.value==='')") as? Bool == true)
        #expect(await js(webView, "window.submitted === true") as? Bool == false)
        #expect(await js(webView, "window.events.filter(x=>x==='Color'||x==='Range').length") as? Int == 2)
        #expect(await js(webView, "document.body.textContent.includes('Calendar open')") as? Bool == false)
        let verified = fields.prefix(10).map { "[\($0.ref)]" }.joined(separator: ", ")
        #expect(result.contains("Verified refs: \(verified)."), "\(result)")
    }

    @Test(arguments: ["11", "3", "", "NaN"])
    func invalidColorDateAndRangeDoNotBlockSafeFields(range: String) async {
        let webView = await loadedWebView("""
        <input aria-label="Color" type="color" value="#563d7c">
        <input aria-label="Range" type="range" min="0" max="10" step="2" value="4">
        <input aria-label="Date" type="date" value="2026-10-15">
        <input aria-label="Name">
        """)
        _ = await PageDriver.readRenderedPage(webView)
        let result = await PageDriver.fillFields([
            .init(ref: 1, value: "red", select: false), .init(ref: 2, value: range, select: false),
            .init(ref: 3, value: "not-a-date", select: false), .init(ref: 4, value: "Jordan", select: false),
        ], in: webView)
        #expect(result.hasPrefix("Filled 1 of 4 fields."), "\(result)")
        #expect(result.contains("Verified refs: [4]."), "\(result)")
        #expect(await js(webView, "document.querySelector('[type=color]').value") as? String == "#563d7c")
        #expect(await js(webView, "document.querySelector('[type=range]').value") as? String == "4")
        #expect(await js(webView, "document.querySelector('[type=date]').value") as? String == "2026-10-15")
        #expect(await js(webView, "document.querySelector('[aria-label=Name]').value") as? String == "Jordan")
        #expect((await PageDriver.inspectControl(ref: 2, in: webView)).contains("\"step\":\"2\""))
    }

    @Test func oversizedAndInvalidRefBatchesCannotPartiallyWrite() async {
        let webView = await loadedWebView("<input aria-label='First'>")
        _ = await PageDriver.readRenderedPage(webView)
        let batches = [
            (1...33).map { $0 },
            [1, 1],
            [0, 1],
            [-1],
        ]
        for refs in batches {
            let result = await PageDriver.fillFields(refs.map { .init(ref: $0, value: "unexpected", select: false) }, in: webView)
            #expect(result.contains(refs.count > 32 ? "one to 32" : "distinct positive"))
            #expect(await js(webView, "document.querySelector('input').value") as? String == "")
        }
    }

    @Test func laterRadioSelectionInvalidatesEarlierVerifiedState() async {
        let webView = await loadedWebView("""
        <input aria-label="First" type="radio" name="choice"><input aria-label="Second" type="radio" name="choice">
        """)
        _ = await PageDriver.readRenderedPage(webView)
        let result = await PageDriver.fillFields([
            .init(ref: 1, value: "true", select: false), .init(ref: 2, value: "true", select: false),
        ], in: webView)
        #expect(result.hasPrefix("Filled 1 of 2 fields."))
        #expect(result.contains("[1] not verified"))
        #expect(await js(webView, "document.querySelectorAll('input')[1].checked") as? Bool == true)
        #expect(result.contains("Verified refs: [2]."), "\(result)")
    }

    @Test func ariaCheckedValueChangeDoesNotStopIndependentFields() async throws {
        let view = await loadedWebView("""
            <div role="checkbox" aria-label="Agreement" aria-checked="false" tabindex="0"
              onclick="this.setAttribute('aria-checked', 'true');window.checkWrites=(window.checkWrites||0)+1">Agreement</div>
            <input aria-label="Name" oninput="window.nameWrites=(window.nameWrites||0)+1">
            """)
        let observation = await PageDriver.readRenderedPage(view)
        let checkbox = try #require(refs(in: observation, matching: "checkbox \"Agreement\"").first)
        let name = try #require(refs(in: observation, matching: "field \"Name\"").first)
        let result = await PageDriver.fillFields([
            .init(ref: checkbox, value: "true", select: false),
            .init(ref: name, value: "Jordan", select: false),
        ], in: view)
        #expect(await js(view, "document.querySelector('[role=checkbox]').getAttribute('aria-checked')") as? String == "true")
        #expect(await js(view, "document.querySelector('input').value") as? String == "Jordan")
        #expect(await js(view, "[window.checkWrites,window.nameWrites]") as? [Int] == [1, 1])
        #expect(result.contains("Verified refs: [\(checkbox)], [\(name)]."), "\(result)")
    }
}
