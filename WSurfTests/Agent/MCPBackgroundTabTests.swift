// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A connection works in a shared tab the person is not looking at. The page stays in its window out of sight, it renders
/// and answers there, and the person's selected tab and keyboard focus stay where they were.
@MainActor
@Suite(.serialized)
struct MCPBackgroundTabTests {
    private static let page = """
        <!doctype html><title>Background</title><meta name="viewport" content="width=device-width">
        <style>body { margin: 0; background: #00c000 } button { position: absolute; left: 8px; top: 8px }</style>
        <button onclick="document.title = 'Clicked'">Go</button>
        <a href="/other" style="position: absolute; left: 8px; top: 48px">Other</a>
        """

    /// A browser window arranged the way `BrowserHost` builds one (content and parking shelf), ordered behind other windows
    /// and never made key. `owner` is the person's tab and the selected one; `shared` is the connection's tab, which the
    /// person had on screen, shared with Control, and then left: it waits on the shelf.
    private struct Rig {
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let window: NSWindow
        let session: MCPBrowserSession
        let owner: BrowserTab
        let shared: BrowserTab
    }

    private func withRig(engine: BrowserEngine, registersWindow: Bool = true, _ body: (Rig) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html(Self.page),
            "/other": .html("<!doctype html><title>Other</title><style>body { background: #00c000 }</style><p>Other page</p>"),
            "/mine": .html("<!doctype html><title>Mine</title><input aria-label=Note>"),
        ])
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPBackground-\(UUID().uuidString).json")))
        let url = try server.url()
        browser.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        window.contentView = root
        window.orderBack(nil)
        if registersWindow {
            browser.context.extensions.register(browser: browser, window: window)
        }
        let shared = browser.newTab(url: url)
        // On screen first, as a tab the person shares is: a Chromium page loads only once it is in a window.
        let container = WebViewContainer(page: shared.page)
        container.parksWhenIdle = true
        container.frame = root.bounds
        root.addSubview(container)
        try #require(await waitUntil { shared.page.url == url && !shared.page.isLoading && shared.page.mainDocumentID != nil })
        shared.assistantAccess.persistsAnswers = false
        shared.assistantAccess.pageChanged(url: url)
        let session = MCPBrowserSession(
            browser: browser, available: { true }, consent: { _, _, _ in .control }, openConsent: { _, _ in true })
        session.clientName = "Codex"
        session.grants[shared.id] = .init(origin: SitePermissions.origin(for: url), access: .control)
        // The person moves on: their own tab is selected and the shared page goes to the shelf.
        let owner = browser.newTab(url: try server.url("/mine"))
        container.removeFromSuperview()
        try #require(shared.page.isParked)
        try #require(browser.activeTabID == owner.id)
        let rig = Rig(server: server, browser: browser, window: window, session: session, owner: owner, shared: shared)
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
        rig.session.revoke()
        let tabs = rig.browser.tabs
        rig.browser.closeAllTabs(saving: false)
        for tab in tabs {
            await tab.waitForRetirement()
        }
        rig.browser.context.extensions.unregister(browser: rig.browser)
        rig.window.contentView = nil
        rig.window.close()
    }

    private func call(_ rig: Rig, _ name: String, _ tab: BrowserTab?, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private func observation(_ result: CallTool.Result) throws -> String {
        try #require(result.structuredContent?.objectValue?["observationID"]?.stringValue, "\(text(result))")
    }

    /// The nearest of green, white and black at the centre of a captured image. A blank or unpainted capture is white or
    /// black; the fixture's background is green.
    private func centreColour(_ result: CallTool.Result) throws -> String {
        let data = try #require(result.content.compactMap { block -> Data? in
            guard case .image(let data, _, _, _) = block else { return nil }
            return Data(base64Encoded: data)
        }.first, "no image in: \(text(result))")
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let colour = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let sample = [colour.redComponent, colour.greenComponent, colour.blueComponent].map(Double.init)
        let palette: [(String, [Double])] = [("green", [0, 0.75, 0]), ("white", [1, 1, 1]), ("black", [0, 0, 0])]
        return palette.min { a, b in
            zip(a.1, sample).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) < zip(b.1, sample).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        }?.0 ?? "none"
    }

    private func pageResponder(of tab: BrowserTab, in window: NSWindow) -> Bool {
        (window.firstResponder as? NSView)?.isDescendant(of: tab.page) == true
    }

    /// A tab the person had on screen and left, which no connection holds: it waits on the shelf, as `shared` does.
    private func parkedTab(_ rig: Rig, path: String) async throws -> BrowserTab {
        let url = try rig.server.url(path)
        let tab = rig.browser.newTab(url: url, activate: false)
        let container = WebViewContainer(page: tab.page)
        container.parksWhenIdle = true
        container.frame = rig.window.contentView?.bounds ?? .zero
        rig.window.contentView?.addSubview(container)
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        container.removeFromSuperview()
        try #require(tab.page.isParked)
        return tab
    }

    /// What the page itself reads: `document.visibilityState` and `document.hidden`.
    private func visibility(of tab: BrowserTab) async -> String {
        (try? await tab.page.evaluateJavaScript("document.visibilityState + ' ' + document.hidden")) as? String ?? "unanswered"
    }

    // MARK: Working in the background

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aParkedTabIsReadClickedAndCapturedWithoutChangingTheSelection(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            let responder = rig.window.firstResponder
            let read = try await call(rig, "readPage", rig.shared)
            #expect(read.isError == false, "\(engine): \(text(read))")

            let clicked = try await call(rig, "clickOnPage", rig.shared, ["observationID": .string(try observation(read)), "ref": 1])
            #expect(clicked.isError == false, "\(engine): \(text(clicked))")
            #expect(
                await waitUntil { (try? await rig.shared.page.evaluateJavaScript("document.title")) as? String == "Clicked" },
                "\(engine): the click reached the page")

            let shot = try await call(rig, "screenshotPage", rig.shared)
            #expect(shot.isError == false, "\(engine): \(text(shot))")
            #expect(try centreColour(shot) == "green", "\(engine): the capture shows the painted page, not a blank one")

            #expect(rig.browser.activeTabID == rig.owner.id, "\(engine): the person's tab stays selected")
            #expect(rig.shared.page.isParked, "\(engine): the shared page stays out of sight")
            #expect(rig.window.firstResponder === responder, "\(engine): keyboard focus did not move")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func newTabOpensBehindThePersonsTabAndLoadsInItsWindow(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            _ = try await call(rig, "readPage", rig.shared)
            let other = try rig.server.url("/other")
            let opened = try await call(rig, "newTab", nil, ["url": .string(other.absoluteString)])
            #expect(opened.isError == false, "\(engine): \(text(opened))")
            #expect(text(opened).contains("in the background"))
            let tab = try #require(rig.browser.tabs.first { rig.session.openedTabs.contains($0.id) })

            #expect(rig.browser.activeTabID == rig.owner.id, "\(engine): the new tab does not take the person's place")
            #expect(tab.page.window === rig.window && tab.page.isParked, "\(engine): the new page waits on the shelf")
            #expect(tab.page.engine == engine)
            #expect(
                await waitUntil { tab.page.url == other && !tab.page.isLoading && tab.page.mainDocumentID != nil },
                "\(engine): the page loads off screen")
            let read = try await call(rig, "readPage", tab)
            #expect(read.isError == false, "\(engine): \(text(read))")
            #expect(text(read).contains("Other page"))
        }
    }

    /// WebKit only: a tab the person never had on screen is attached to the window by the first call that needs its page.
    @Test(.boundedWebViews)
    func aNeverShownTabIsKeptInTheWindowByTheFirstCall() async throws {
        try await withRig(engine: .webKit) { rig in
            let url = try rig.server.url()
            let unseen = rig.browser.newTab(url: url, activate: false)
            try #require(await waitUntil { unseen.page.url == url && !unseen.page.isLoading })
            unseen.assistantAccess.persistsAnswers = false
            unseen.assistantAccess.pageChanged(url: url)
            rig.session.grants[unseen.id] = .init(origin: SitePermissions.origin(for: url), access: .control)
            #expect(unseen.page.window == nil)

            let shot = try await call(rig, "screenshotPage", unseen)
            #expect(shot.isError == false, "\(text(shot))")
            #expect(unseen.page.window === rig.window && unseen.page.isParked)
            #expect(try centreColour(shot) == "green")
            #expect(rig.browser.activeTabID == rig.owner.id)
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aParkedTabNeverTakesKeyboardFocus(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            let responder = rig.window.firstResponder
            let read = try await call(rig, "readPage", rig.shared)
            let pressed = try await call(rig, "pressKey", rig.shared, ["observationID": .string(try observation(read)), "ref": 1, "key": "Enter"])
            #expect(pressed.isError == true)
            #expect(text(pressed).contains("visible tab"), "\(engine): \(text(pressed))")
            #expect(rig.window.firstResponder === responder, "\(engine): the window's first responder is unchanged")
            #expect(!pageResponder(of: rig.shared, in: rig.window))
            #expect(!PageDriver.focusForKeyboard(rig.shared.page, in: rig.window), "the shared helper refuses a parked page")
            #expect(rig.window.firstResponder === responder)
        }
    }

    // MARK: Kept loaded and rendering

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aControlledTabIsKeptLoadedAndRendersWhileItsWindowIsCovered(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            #expect(rig.shared.processState.externalControllers == [rig.session.id], "the grant marks the tab")
            #expect(rig.browser.protectionReason(for: rig.shared) == .externalControl)
            #expect(!rig.browser.unload(rig.shared), "a tab a connection holds is not unloaded")
            #expect(rig.shared.isMaterialised)

            _ = try await call(rig, "readPage", rig.shared)
            let occlusionSPI = rig.shared.page.webKit?.responds(to: NSSelectorFromString("_windowOcclusionDetectionEnabled")) == true
            if occlusionSPI {
                #expect(rig.shared.page.ignoresWindowOcclusion, "WebKit keeps painting the tab while its window is covered")
            }

            rig.session.revoke()
            #expect(rig.shared.processState.externalControllers.isEmpty)
            #expect(rig.browser.protectionReason(for: rig.shared) == nil)
            #expect(!rig.shared.page.ignoresWindowOcclusion, "the page pauses again when covered once nobody controls it")
        }
    }

    /// A controlled tab's page behaves as if the person were looking, also with its window covered: it reports visible, so its
    /// timers, rendering and checks that wait to be seen (bot checks) run. The person's own background tab keeps what its
    /// engine reports. The window moves off every screen, which counts as covered: WebKit hides the person's tab there, and
    /// Chromium's process-wide switch keeps every tab visible. Ending and giving back the grant turns WebKit's tab hidden and
    /// visible again at once, while the window stays covered.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aControlledBackgroundTabReportsVisibleAndTheOthersAreUnchanged(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            let mine = try await parkedTab(rig, path: "/other")
            rig.window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            let covered = await waitUntil(timeout: .seconds(3)) { !rig.window.occlusionState.contains(.visible) }
            let hidesCovered = covered && engine == .webKit
            if hidesCovered {
                #expect(await waitUntil { await visibility(of: mine) == "hidden true" }, "a covered window hides the person's WebKit tab")
            }
            let before = await visibility(of: mine)

            let read = try await call(rig, "readPage", rig.shared)
            #expect(read.isError == false, "\(engine): \(text(read))")
            #expect(await waitUntil { await visibility(of: rig.shared) == "visible false" }, "\(engine), covered \(covered): the controlled tab is seen")
            #expect(await visibility(of: mine) == before, "\(engine): the person's tab is unchanged")

            let grant = try #require(rig.session.grants[rig.shared.id])
            rig.session.grants[rig.shared.id] = nil
            if hidesCovered {
                #expect(await waitUntil { await visibility(of: rig.shared) == "hidden true" }, "once nobody controls it, the tab is hidden again")
            }
            rig.session.grants[rig.shared.id] = grant
            #expect(await waitUntil { await visibility(of: rig.shared) == "visible false" }, "\(engine): a new grant shows the tab at once")
            #expect(await visibility(of: mine) == before)
            #expect(rig.browser.activeTabID == rig.owner.id && rig.shared.page.isParked, "\(engine): nothing was shown to the person")
        }
    }

    @Test(.boundedWebViews)
    func aGrantOfAnotherConnectionKeepsTheMarkUntilItEndsToo() async throws {
        try await withRig(engine: .webKit) { rig in
            let other = MCPBrowserSession(browser: rig.browser, available: { true })
            other.grants[rig.shared.id] = rig.session.grants[rig.shared.id]
            #expect(rig.shared.processState.externalControllers == [rig.session.id, other.id])
            rig.session.grants[rig.shared.id] = nil
            #expect(rig.shared.processState.externalControllers == [other.id])
            #expect(rig.browser.protectionReason(for: rig.shared) == .externalControl)
            other.revoke()
            #expect(rig.shared.processState.externalControllers.isEmpty)
        }
    }

    @Test(.boundedWebViews)
    func aBackgroundTabWithNoWindowToKeepItInIsRefusedWithoutBeingShown() async throws {
        try await withRig(engine: .webKit, registersWindow: false) { rig in
            let url = try rig.server.url()
            let unseen = rig.browser.newTab(url: url, activate: false)
            try #require(await waitUntil { unseen.page.url == url && !unseen.page.isLoading })
            unseen.assistantAccess.persistsAnswers = false
            unseen.assistantAccess.pageChanged(url: url)
            rig.session.grants[unseen.id] = .init(origin: SitePermissions.origin(for: url), access: .control)

            let read = try await call(rig, "readPage", unseen)
            #expect(read.isError == false, "reading needs no window: \(text(read))")
            let clicked = try await call(rig, "clickOnPage", unseen, ["observationID": .string(try observation(read)), "ref": 1])
            #expect(clicked.isError == true)
            #expect(text(clicked).contains("switchTab"), "\(text(clicked))")
            #expect(try await unseen.page.evaluateJavaScript("document.title") as? String == "Background", "nothing was clicked")
            #expect(rig.browser.activeTabID == rig.owner.id)
            #expect(unseen.page.window == nil)
        }
    }

    // MARK: Playwright MCP names

    /// An agent written for Playwright MCP works in a background tab on both engines, through WSurf's own tools.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func playwrightNamesWorkInABackgroundTab(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            func playwright(_ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
                try await rig.session.call(name: name, arguments: arguments)
            }
            let tabs = try await playwright("browser_tabs", ["action": "list"])
            #expect(text(tabs).contains(rig.shared.id.uuidString), "\(engine): \(text(tabs))")

            let snapshot = try await playwright("browser_snapshot")
            #expect(snapshot.isError == false && text(snapshot).contains("ACCESSIBILITY TREE"), "\(engine): \(text(snapshot))")
            #expect(text(snapshot).contains("[1]"), "\(engine): the outline carries the refs the other names take")

            let clicked = try await playwright("browser_click", ["element": "Go button", "ref": "e1"])
            #expect(clicked.isError == false, "\(engine): \(text(clicked))")
            #expect(
                await waitUntil { (try? await rig.shared.page.evaluateJavaScript("document.title")) as? String == "Clicked" },
                "\(engine): the click reached the page")

            let waited = try await playwright("browser_wait_for", ["text": "Other"])
            #expect(waited.isError == false, "\(engine): \(text(waited))")
            let shot = try await playwright("browser_take_screenshot", ["type": "png"])
            #expect(try centreColour(shot) == "green", "\(engine): \(text(shot))")
            let script = try await playwright("browser_evaluate", ["function": "() => document.title"])
            #expect(script.isError == true && text(script) == MCPBrowserSession.developerRefusal, "\(engine): Developer tier only: \(text(script))")

            let other = try rig.server.url("/other")
            let opened = try await playwright("browser_tabs", ["action": "new", "url": .string(other.absoluteString)])
            #expect(opened.isError == false, "\(engine): \(text(opened))")
            let tab = try #require(rig.browser.tabs.first { rig.session.openedTabs.contains($0.id) })
            #expect(rig.session.playwrightTab == tab.id, "the new tab is the current one")
            #expect(await waitUntil { tab.page.url == other && !tab.page.isLoading && tab.page.mainDocumentID != nil })
            let read = try await playwright("browser_snapshot")
            #expect(text(read).contains("/other"), "\(engine): the snapshot reads the current tab: \(text(read))")
            // index counts the shared tabs in listTabs order, which is the window's tab order.
            let index = try #require(rig.browser.tabs.filter { rig.session.grants[$0.id] != nil }.firstIndex { $0 === rig.shared })
            let selected = try await playwright("browser_tabs", ["action": "select", "index": .int(index)])
            #expect(selected.isError == false && rig.session.playwrightTab == rig.shared.id, "\(engine): \(text(selected))")

            let tools = rig.session.activity.entries.compactMap { entry -> String? in
                guard case .tool(let name) = entry.event else { return nil }
                return name
            }
            #expect(tools.contains("clickOnPage") && !tools.contains { $0.hasPrefix("browser_") }, "Agent Activity names the WSurf tool: \(tools)")
            #expect(rig.browser.activeTabID == rig.owner.id, "\(engine): the person's tab stays selected")
            #expect(rig.shared.page.isParked && tab.page.isParked, "\(engine): both pages stay out of sight")
        }
    }

    /// The Playwright names are refused exactly where their tools are: by the grant, by the tier, and with nothing shared.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func playwrightNamesAreRefusedExactlyWhereTheirToolsAre(engine: BrowserEngine) async throws {
        try await withRig(engine: engine) { rig in
            typealias Call = (name: String, arguments: [String: Value])
            let pairs: [(alias: Call, tool: Call)] = [
                (("browser_snapshot", [:]), ("readAccessibility", [:])),
                (("browser_click", ["ref": "1"]), ("clickOnPage", ["ref": 1])),
                (("browser_resize", ["width": 500, "height": 400]), ("setViewport", ["width": 500, "height": 400])),
                (("browser_console_messages", ["level": "error"]), ("readConsole", ["level": "error"])),
                (("browser_evaluate", ["function": "() => 1"]), ("evaluateScript", ["source": "() => 1"])),
                (("browser_handle_dialog", ["accept": true]), ("handleDialog", ["action": "accept"])),
            ]
            let origin = try #require(rig.session.grants[rig.shared.id]).origin
            for access in [MCPAccessConsent.Access.readOnly, .control, .development] {
                rig.session.grants[rig.shared.id] = .init(origin: origin, access: access)
                for pair in pairs {
                    let tool = try await call(rig, pair.tool.name, rig.shared, pair.tool.arguments)
                    let alias = try await rig.session.call(name: pair.alias.name, arguments: pair.alias.arguments)
                    #expect(alias.isError == tool.isError, "\(engine) \(access) \(pair.alias.name): \(text(alias)) | \(pair.tool.name): \(text(tool))")
                    if tool.isError == true {
                        #expect(text(alias) == text(tool), "\(engine) \(access) \(pair.alias.name) is refused as \(pair.tool.name) is")
                    }
                }
            }
            rig.session.grants = [:]
            for pair in pairs {
                let tool = try await call(rig, pair.tool.name, rig.shared, pair.tool.arguments)
                let alias = try await rig.session.call(name: pair.alias.name, arguments: pair.alias.arguments)
                #expect(tool.isError == true && alias.isError == true, "\(engine) \(pair.alias.name) with nothing shared")
                #expect(text(alias) == MCPBrowserSession.noPlaywrightTab)
            }
            #expect(rig.browser.activeTabID == rig.owner.id)
        }
    }
}
