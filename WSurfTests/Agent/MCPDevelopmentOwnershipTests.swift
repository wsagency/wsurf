// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Development access, the one-owner-per-tab lease, and the events that must release it.
@MainActor
@Suite(.boundedWebViews)
struct MCPDevelopmentOwnershipTests {
    private static let page = "<!doctype html><title>Dev</title><p id=a class=x>Hello</p><button class=x>Go</button>"

    /// `profileWide` builds the browser on a profile context that owns its site permissions, the wiring the Settings > Websites
    /// page reaches; the default uses a standalone store, which no settings change can reach.
    private func fixture(
        html: String = MCPDevelopmentOwnershipTests.page, routes extra: [String: HTTPFixtureServer.Response] = [:],
        profileWide: Bool = false
    ) async throws -> (HTTPFixtureServer, BrowserModel, BrowserTab) {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html)].merging(extra) { $1 })
        let browser =
            profileWide
            ? BrowserModel(
                context: BrowserProfileContext(profile: Profile(id: UUID(), name: "Dev fixture", symbol: "person", color: .gray)),
                windowID: UUID(), database: .temporary())
            : BrowserModel(
                database: .temporary(),
                sitePermissions: SitePermissions(
                    storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDev-\(UUID().uuidString).json")))
        let url = try server.url()
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page))
        if !profileWide {
            tab.assistantAccess.persistsAnswers = false
        }
        tab.assistantAccess.pageChanged(url: url)
        return (server, browser, tab)
    }

    private func session(
        _ browser: BrowserModel, answer: MCPAccessConsent.Access = .development, asked: ((Bool) -> Void)? = nil
    ) -> MCPBrowserSession {
        MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, development in
            asked?(development)
            return answer
        })
    }

    private func call(
        _ session: MCPBrowserSession, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]
    ) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await session.call(name: name, arguments: arguments)
    }

    private func status(_ result: CallTool.Result) -> String? { result.structuredContent?.objectValue?["status"]?.stringValue }

    private let phone: [String: Value] = ["width": 400, "height": 700]

    @Test func developmentIsOnlyGrantedWhenRequested() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        var asked: Bool?
        let subject = session(browser, asked: { asked = $0 })
        _ = try await call(subject, "requestAccess")
        #expect(asked == false)
        let denied = try await call(subject, "setViewport", tab, phone)
        #expect(denied.isError == true)
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(asked == true)
        #expect(try await call(subject, "setViewport", tab, phone).isError == false)
    }

    @Test func controlGrantCannotUseDevelopmentTools() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser, answer: .control)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        for name in ["setViewport", "startDiagnostics", "readConsole", "readNetwork", "reloadPage", "resetDevelopment"] {
            let result = try await call(subject, name, tab, name == "setViewport" ? phone : [:])
            #expect(result.isError == true, "\(name)")
        }
        #expect(tab.developmentOwner == nil)
    }

    @Test func onlyOneConnectionOwnsATab() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let first = session(browser), second = session(browser)
        _ = try await call(first, "requestAccess", nil, ["development": true])
        _ = try await call(second, "requestAccess", nil, ["development": true])
        #expect(status(try await call(first, "setViewport", tab, phone)) == "ok")
        let size = try #require(tab.page.developmentViewport)
        #expect(status(try await call(second, "setViewport", tab, ["width": 800, "height": 600])) == "ownershipConflict")
        #expect(status(try await call(second, "startDiagnostics", tab)) == "ownershipConflict")
        #expect(status(try await call(second, "resetDevelopment", tab)) == "ownershipConflict")
        #expect(status(try await call(second, "reloadPage", tab)) == "ownershipConflict")
        #expect(tab.page.developmentViewport == size, "a rejected request must not change the owner's viewport")
        #expect(tab.developmentRelation(of: first.id) == .own)
        // Reads stay available to the non-owner and report who holds the lease.
        let info = try await call(second, "getDevelopmentInfo", tab)
        #expect(info.structuredContent?.objectValue?["owner"]?.stringValue == "other")
        #expect(status(try await call(first, "resetDevelopment", tab)) == "ok")
        #expect(status(try await call(first, "resetDevelopment", tab)) == "ok", "reset is idempotent")
        #expect(tab.page.developmentViewport == nil)
        #expect(status(try await call(second, "setViewport", tab, phone)) == "ok")
    }

    @Test func disconnectReleasesTheLease() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(status(try await call(subject, "setViewport", tab, phone)) == "ok")
        await subject.revoke()
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
    }

    @Test func policyDowngradeReleasesTheLeaseOnTheNextCall() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(status(try await call(subject, "setViewport", tab, phone)) == "ok")
        tab.assistantAccess.set(.readOnly)
        _ = try await call(subject, "getDevelopmentInfo", tab)
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
        #expect(try await call(subject, "setViewport", tab, phone).isError == true)
    }

    @Test func rejectedRequestsLeaveTheSlotFreeAndTheTabUntouched() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        #expect(status(try await call(subject, "setViewport", tab, ["width": 10, "height": 700])) == "invalidInput")
        #expect(status(try await call(subject, "emulateDevice", tab, ["profile": "nope", "orientation": "portrait"])) == "invalidInput")
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
    }

    @Test func findingElementsNeedsDevelopmentAccessAndReturnsRefsForInspection() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let plain = session(browser, answer: .control)
        _ = try await call(plain, "requestAccess")
        #expect(try await call(plain, "findElements", tab, ["selector": ".x"]).isError == true)
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let found = try await call(subject, "findElements", tab, ["selector": ".x"])
        #expect(found.isError == false)
        #expect(try await call(subject, "findElements", tab, ["selector": ".x", "limit": 101]).isError == true)
        let observation = try #require(found.structuredContent?.objectValue?["observationID"]?.stringValue)
        let inspected = try await call(subject, "inspectElement", tab, ["observationID": .string(observation), "ref": 1])
        #expect(inspected.isError == false)
    }

    @Test func viewportIsMeasuredInThePageAndResetRestoresIt() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let applied = try await call(subject, "setViewport", tab, phone)
        #expect(status(applied) == "ok")
        let measured = try #require(applied.structuredContent?.objectValue?["viewport"]?.objectValue)
        #expect(measured["innerWidth"]?.intValue == 400)
        #expect(measured["innerHeight"]?.intValue == 700)
        #expect(try await tab.page.evaluateJavaScript("window.innerWidth") as? Int == 400)
        _ = try await call(subject, "resetDevelopment", tab)
        #expect(try await tab.page.evaluateJavaScript("window.innerWidth") as? Int != 400)
    }

    @Test func diagnosticsCaptureOnlyAfterStartAndStopOnReset() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        _ = try await tab.page.evaluateJavaScript("console.log('before-start'); 0")
        #expect(status(try await call(subject, "readConsole", tab)) == "invalidInput", "reading needs a running capture")
        #expect(status(try await call(subject, "startDiagnostics", tab)) == "ok")
        _ = try await tab.page.evaluateJavaScript("console.log('after-start'); 0")
        var records: [Value] = []
        for _ in 0..<50 where records.isEmpty {
            let read = try await call(subject, "readConsole", tab)
            records = read.structuredContent?.objectValue?["records"]?.arrayValue ?? []
            if records.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let text = records.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        #expect(text.contains("after-start"))
        #expect(!text.contains("before-start"))
        let bad = try await call(subject, "readConsole", tab, ["cursor": "not-a-cursor"])
        #expect(status(bad) == "invalidInput")
        _ = try await call(subject, "resetDevelopment", tab)
        #expect(tab.developmentOwner == nil)
        #expect(status(try await call(subject, "readConsole", tab)) == "invalidInput")
    }

    // MARK: Lease lifecycle against the tab

    @Test func aLeaseEndsWhenItsPageIsReplacedAndNoLeaseIsGrantedOnAReplacedPage() async throws {
        let (server, _, tab) = try await fixture()
        defer { _ = server }
        let outgoing = tab.page
        guard case .acquired(let owner) = tab.acquireDevelopment(connection: UUID(), page: outgoing, isAuthorized: { true }) else {
            Issue.record("the first acquisition must succeed")
            return
        }
        var reason: DevelopmentReleaseReason?
        owner.onRelease { reason = $0 }
        tab.liveView = nil
        #expect(reason == .engineReplaced)
        #expect(tab.developmentOwner == nil)
        guard case .pageGone = tab.acquireDevelopment(connection: UUID(), page: outgoing, isAuthorized: { true }) else {
            Issue.record("a replaced page must not be leased")
            return
        }
    }

    @Test func anIdleLeaseEndsWhenItsConnectionLosesAccess() async throws {
        let (server, _, tab) = try await fixture()
        defer { _ = server }
        var allowed = true
        guard case .acquired = tab.acquireDevelopment(connection: UUID(), page: tab.page, isAuthorized: { allowed }) else {
            Issue.record("the first acquisition must succeed")
            return
        }
        allowed = false
        tab.assistantAccess.set(.readOnly)
        #expect(tab.developmentOwner == nil, "a policy change releases a lease that applied nothing")
    }

    @Test func aNavigationOutsideTheGrantEndsTheLeaseAtCommit() async throws {
        let (server, _, tab) = try await fixture()
        defer { _ = server }
        let other = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Other</title>")])
        let granted = try server.url().port
        guard case .acquired = tab.acquireDevelopment(
            connection: UUID(), page: tab.page, isAuthorized: { [weak tab] in tab?.page.url?.port == granted })
        else {
            Issue.record("the first acquisition must succeed")
            return
        }
        tab.page.load(URLRequest(url: try other.url()))
        #expect(await PageSettle.untilIdle(tab.page))
        #expect(tab.developmentOwner == nil)
    }

    @Test func aReleasedLeaseCanNeverReleaseANewerOne() async throws {
        let (server, _, tab) = try await fixture()
        defer { _ = server }
        guard case .acquired(let first) = tab.acquireDevelopment(connection: UUID(), page: tab.page, isAuthorized: { true }) else {
            Issue.record("the first acquisition must succeed")
            return
        }
        tab.releaseDevelopment(first, reason: .reset)
        guard case .acquired(let second) = tab.acquireDevelopment(connection: UUID(), page: tab.page, isAuthorized: { true }) else {
            Issue.record("the slot must be free after a release")
            return
        }
        tab.releaseDevelopment(first, reason: .documentDenied)
        first.requestRelease?(.documentDenied)
        #expect(tab.developmentOwner === second)
        #expect(tab.isCurrent(second))
    }

    @Test func catalogBoundsReadsAndPaging() throws {
        func entry(_ name: String) throws -> MCPToolCatalog.Entry {
            try #require(MCPToolCatalog.entries.first { $0.name == name })
        }
        let tab: Value = .string(UUID().uuidString)
        let find = try entry("findElements")
        try find.validate(["tabID": tab, "selector": ".x", "offset": 10_000, "limit": 100])
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "limit": 101]) }
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "limit": 0]) }
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "offset": 10_001]) }
        #expect(throws: (any Error).self) { try find.validate(["tabID": tab, "selector": ".x", "offset": -1]) }
        let console = try entry("readConsole")
        try console.validate(["tabID": tab, "limit": 100])
        #expect(throws: (any Error).self) { try console.validate(["tabID": tab, "limit": 101]) }
        try entry("requestAccess").validate(["development": true])
        #expect(throws: (any Error).self) { try entry("requestAccess").validate(["development": "yes"]) }
        #expect(throws: (any Error).self) { try entry("setViewport").validate(["tabID": tab, "width": 63, "height": 700]) }
    }

    // MARK: Consumer helpers

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            if case .text(let text, _, _) = $0 {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func images(_ result: CallTool.Result) -> [Data] {
        result.content.compactMap {
            if case .image(let data, _, _, _) = $0 {
                return Data(base64Encoded: data)
            }
            return nil
        }
    }

    /// The `content` string a client receives for a page tool: the tool's own text inside the untrusted-content wrapper.
    private func content(_ result: CallTool.Result) throws -> String {
        try #require(result.structuredContent?.objectValue?["content"]?.stringValue)
    }

    /// The JSON a findElements / inspectElement result carries (`prefix` is `ELEMENTS:` or `ELEMENT:`), read back out of the
    /// wrapper the way a client does.
    private func payload(_ result: CallTool.Result, prefix: String) throws -> [String: Any] {
        let unwrapped = try content(result)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let start = try #require(unwrapped.range(of: prefix + "\n"))
        let end = try #require(unwrapped.range(of: "\nobservationID: ", options: .backwards))
        let json = Data(unwrapped[start.upperBound..<end.lowerBound].utf8)
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func requestDevelopment(_ subject: MCPBrowserSession) async throws {
        _ = try await call(subject, "requestAccess", nil, ["development": true])
    }

    /// findElements on `selector`: the observation to pass back and the first match's ref.
    private func find(_ subject: MCPBrowserSession, _ tab: BrowserTab, _ selector: String) async throws -> (observation: String, ref: Int) {
        let found = try await call(subject, "findElements", tab, ["selector": .string(selector)])
        #expect(found.isError == false, "\(text(found))")
        let items = try #require(try payload(found, prefix: "ELEMENTS:")["items"] as? [[String: Any]])
        return (
            try #require(found.structuredContent?.objectValue?["observationID"]?.stringValue),
            try #require(items.first?["r"] as? Int)
        )
    }

    private func screenshot(_ subject: MCPBrowserSession, _ tab: BrowserTab, _ target: (observation: String, ref: Int)) async throws -> CallTool.Result {
        try await call(subject, "screenshotPage", tab, ["observationID": .string(target.observation), "ref": .int(target.ref)])
    }

    /// Element screenshots need the page in a window: WebKit only snapshots a laid-out, attached view.
    private func show(_ tab: BrowserTab) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderBack(nil)
        #expect(await waitUntil { ((try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int ?? 0) >= 400 })
        return window
    }

    private func hide(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private static let shotPage =
        "<!doctype html><title>Shot</title><div id=box style='width:120px;height:60px;background:#c00'>Box</div>"
        + "<button id=go style='width:80px;height:30px' onclick=\"document.body.dataset.clicked='yes'\">Go</button>"

    // MARK: Screenshots of found elements through the MCP tool

    @Test func aFoundElementIsCapturedWithDevelopmentAccessAndRefusedOnceTheGrantDrops() async throws {
        let (server, browser, tab) = try await fixture(html: Self.shotPage)
        defer { _ = server }
        let window = await show(tab)
        defer { hide(window) }
        let subject = session(browser)
        try await requestDevelopment(subject)
        let captured = try await screenshot(subject, tab, try await find(subject, tab, "#box"))
        #expect(captured.isError == false, "\(text(captured))")
        let image = try #require(images(captured).first)
        #expect(image.starts(with: [0xFF, 0xD8]), "the client gets a JPEG")
        // The grant drops between findElements and screenshotPage: the element is still on screen, the image must not be.
        let target = try await find(subject, tab, "#box")
        tab.assistantAccess.set(.readOnly)
        let refused = try await screenshot(subject, tab, target)
        #expect(refused.isError == true)
        #expect(images(refused).isEmpty)
        #expect(text(refused).contains(ScreenshotFailure.needsDevelopment.message), "\(text(refused))")
    }

    @Test func aConnectionWithoutDevelopmentAccessCannotCaptureAFoundElement() async throws {
        let (server, browser, tab) = try await fixture(html: Self.shotPage)
        defer { _ = server }
        let window = await show(tab)
        defer { hide(window) }
        let developer = session(browser), plain = session(browser, answer: .control)
        try await requestDevelopment(developer)
        _ = try await call(plain, "requestAccess")
        let target = try await find(developer, tab, "#box")
        let refused = try await screenshot(plain, tab, target)
        #expect(refused.isError == true)
        #expect(images(refused).isEmpty)
        #expect(try await tab.page.evaluateJavaScript("1") as? Int == 1, "the page itself is untouched")
    }

    @Test func aControlRefIsCapturedWithReadOnlyAccess() async throws {
        let (server, browser, tab) = try await fixture(html: Self.shotPage)
        defer { _ = server }
        let window = await show(tab)
        defer { hide(window) }
        let subject = session(browser, answer: .control)
        _ = try await call(subject, "requestAccess")
        let read = try await call(subject, "readPage", tab)
        #expect(read.isError == false, "\(text(read))")
        #expect(text(read).contains("Go"))
        let observation = try #require(read.structuredContent?.objectValue?["observationID"]?.stringValue)
        tab.assistantAccess.set(.readOnly)
        let captured = try await screenshot(subject, tab, (observation, 1))
        #expect(captured.isError == false, "\(text(captured))")
        #expect(images(captured).count == 1)
    }

    @Test func aRemovedFoundElementIsStaleNotAPermissionFailure() async throws {
        let (server, browser, tab) = try await fixture(html: Self.shotPage)
        defer { _ = server }
        let window = await show(tab)
        defer { hide(window) }
        let subject = session(browser)
        try await requestDevelopment(subject)
        let target = try await find(subject, tab, "#box")
        _ = try await tab.page.evaluateJavaScript("document.getElementById('box').remove(); 0")
        let result = try await screenshot(subject, tab, target)
        #expect(result.isError == true)
        #expect(images(result).isEmpty)
        #expect(text(result).contains(ScreenshotFailure.stale.message), "\(text(result))")
        #expect(!text(result).contains(ScreenshotFailure.needsDevelopment.message))
    }

    @Test func aFoundRefCannotDriveClickTypeOrHover() async throws {
        let (server, browser, tab) = try await fixture(html: Self.shotPage)
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        let actions: [(String, [String: Value])] = [("clickOnPage", [:]), ("typeOnPage", ["text": "x"]), ("hoverOnPage", [:])]
        for (name, extra) in actions {
            let target = try await find(subject, tab, "#go")
            var arguments: [String: Value] = ["observationID": .string(target.observation), "ref": .int(target.ref)]
            arguments.merge(extra) { $1 }
            let result = try await call(subject, name, tab, arguments)
            #expect(result.isError == true, "\(name)")
            #expect(text(result).contains(PageDriver.staleMessage), "\(name): \(text(result))")
        }
        #expect(try await tab.page.evaluateJavaScript("document.body.dataset.clicked || ''") as? String == "")
    }

    // MARK: Old and new owners

    @Test func aLateResetFromAReleasedLeaseLeavesTheNewOwnersViewportAlone() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let first = session(browser), second = session(browser)
        try await requestDevelopment(first)
        try await requestDevelopment(second)
        #expect(status(try await call(first, "setViewport", tab, phone)) == "ok")
        let old = try #require(tab.developmentOwner)
        #expect(status(try await call(first, "resetDevelopment", tab)) == "ok")
        #expect(status(try await call(second, "setViewport", tab, ["width": 800, "height": 600])) == "ok")
        let current = try #require(tab.developmentOwner)
        #expect(current !== old)
        // Everything the old lease can still do, late.
        tab.releaseDevelopment(old, reason: .reset)
        old.requestRelease?(.documentDenied)
        #expect(status(try await call(first, "resetDevelopment", tab)) == "ownershipConflict")
        #expect(status(try await call(first, "setViewport", tab, phone)) == "ownershipConflict")
        #expect(tab.developmentOwner === current)
        #expect(tab.page.developmentViewport == CGSize(width: 800, height: 600))
        #expect(try await tab.page.evaluateJavaScript("window.innerWidth") as? Int == 800)
        let info = try await call(second, "getDevelopmentInfo", tab)
        #expect(info.structuredContent?.objectValue?["owner"]?.stringValue == "self")
    }

    @Test func replacingThePageEndsTheLeaseAndTheNewPageStartsClean() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let first = session(browser), second = session(browser)
        try await requestDevelopment(first)
        try await requestDevelopment(second)
        #expect(status(try await call(first, "setViewport", tab, phone)) == "ok")
        let outgoing = tab.page
        try #require(tab.canDiscardWebContent)
        tab.discardWebContent()
        #expect(tab.developmentOwner == nil)
        #expect(tab.developmentRelation(of: first.id) == .none)
        tab.realizeDeferredSession()
        let granted = try server.url()
        #expect(await waitUntil { tab.page.url?.port == granted.port && !tab.page.isLoading })
        #expect(tab.page !== outgoing)
        #expect(tab.page.developmentViewport == nil)
        #expect(status(try await call(second, "setViewport", tab, ["width": 800, "height": 600])) == "ok")
        #expect(tab.developmentRelation(of: first.id) == .other)
    }

    @Test func aReleasedLeasesLateApplyNeverUndoesTheNextLeasesViewport() async throws {
        let (server, _, tab) = try await fixture()
        defer { _ = server }
        let page = tab.page
        let request = PageViewport.Request(width: 400, height: 700)
        let size = CGSize(width: 400, height: 700)
        guard case .acquired(let first) = tab.acquireDevelopment(connection: UUID(), page: page, isAuthorized: { true }) else {
            Issue.record("the first acquisition must succeed")
            return
        }
        let late = Task { await page.applyDevelopmentViewport(request, profile: nil, owner: first, tab: tab) }
        #expect(await waitUntil { page.developmentViewport != nil }, "the first lease's apply is running")
        tab.releaseDevelopment(first, reason: .reset)
        guard case .acquired(let second) = tab.acquireDevelopment(connection: UUID(), page: page, isAuthorized: { true }) else {
            Issue.record("the slot must be free after a release")
            return
        }
        // No suspension between the release and this request: the first lease's cleanup turn is already queued ahead of it.
        let outcome = await page.applyDevelopmentViewport(request, profile: nil, owner: second, tab: tab)
        guard case .applied = outcome else {
            Issue.record("the new lease's viewport must apply: \(outcome)")
            return
        }
        guard case .stale = await late.value else {
            Issue.record("the released lease's own apply must end stale")
            return
        }
        #expect(tab.isCurrent(second))
        #expect(page.developmentViewport == size)
        #expect(second.viewport?.size == size)
        #expect(try await page.evaluateJavaScript("window.innerWidth") as? Int == 400)
    }

    @Test(arguments: [AssistantAccessPolicy.readOnly, .deny])
    func aSettingsChangeToTheSiteEndsAnIdleViewportLease(policy: AssistantAccessPolicy) async throws {
        let (server, browser, tab) = try await fixture(profileWide: true)
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        #expect(status(try await call(subject, "setViewport", tab, phone)) == "ok")
        #expect(tab.developmentOwner != nil)
        // The Settings > Websites path: the store changes, no tab and no connection is involved, and nothing calls the server.
        browser.sitePermissions.setAssistantAccess(policy, for: tab.assistantAccess.origin)
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
    }

    /// Both ways Settings clears every site answer reach the lease: the assistant answers alone, and "remove everything"
    /// (which cookie clearing calls on the shared store, with no tab involved).
    @Test(arguments: [false, true])
    func resettingEverySiteAnswerEndsAnIdleViewportLease(removingEverything: Bool) async throws {
        let (server, browser, tab) = try await fixture(profileWide: true)
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        #expect(status(try await call(subject, "setViewport", tab, phone)) == "ok")
        if removingEverything {
            browser.sitePermissions.removeEverything()
        } else {
            browser.sitePermissions.removeAllAssistantAccess()
        }
        #expect(tab.developmentOwner == nil)
        #expect(tab.page.developmentViewport == nil)
    }

    @Test func aCancelledCallNeverEndsAnotherConnectionsLease() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let first = session(browser), second = session(browser)
        try await requestDevelopment(first)
        try await requestDevelopment(second)
        #expect(status(try await call(first, "setViewport", tab, phone)) == "ok")
        let owner = try #require(tab.developmentOwner)
        let size = try #require(tab.page.developmentViewport)
        let problems = await Task { @MainActor () -> [String] in
            withUnsafeCurrentTask { $0?.cancel() }
            var problems: [String] = []
            // The lease checks the owner's connection from this cancelled task.
            if tab.developmentRelation(of: second.id) != .other { problems.append("relation") }
            tab.releaseInvalidDevelopment()
            switch tab.acquireDevelopment(connection: second.id, page: tab.page, isAuthorized: { true }) {
            case .conflict:
                break
            default:
                problems.append("acquire")
            }
            let calls = [(second, "getDevelopmentInfo"), (second, "resetDevelopment"), (first, "getDevelopmentInfo")]
            for (connection, name) in calls {
                let result = try? await self.call(connection, name, tab)
                if result?.isError != true || result?.structuredContent != nil {
                    problems.append(name)
                }
            }
            return problems
        }.value
        #expect(problems.isEmpty, "\(problems)")
        #expect(tab.developmentOwner === owner)
        #expect(tab.page.developmentViewport == size)
        let info = try await call(first, "getDevelopmentInfo", tab)
        #expect(info.structuredContent?.objectValue?["owner"]?.stringValue == "self")
    }

    /// A `setViewport` call waiting behind another turn on the page's emulation queue is cancelled by its caller: it applies
    /// nothing and the lease it acquired for nothing is not kept. The call has acquired its lease (`developmentOwner` is set)
    /// before it reserves its turn, with no suspension in between, so the cancel reaches a call that is inside the apply.
    @Test func aSetViewportCancelledWhileQueuedAppliesNothingAndFreesItsLease() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        let page = tab.page
        let widthBefore = try #require(try await page.evaluateJavaScript("window.innerWidth") as? Int)
        var open: CheckedContinuation<Void, Never>?
        let gate = page.emulationQueue.enqueue { await withCheckedContinuation { open = $0 } }
        #expect(await waitUntil { open != nil })
        let request = Task { try await self.call(subject, "setViewport", tab, self.phone) }
        #expect(await waitUntil { tab.developmentOwner != nil })
        request.cancel()
        open?.resume()
        await gate.value
        let result = try? await request.value
        #expect(result?.isError != false)
        #expect(page.developmentViewport == nil)
        #expect(try await page.evaluateJavaScript("window.innerWidth") as? Int == widthBefore)
        #expect(tab.developmentOwner == nil)
    }

    /// The apply itself, cancelled before or while it waits for its turn (both orders end the same way): nothing is applied and
    /// the lease keeps the diagnostics it already held.
    @Test func aCancelledApplyLeavesTheLeasesDiagnosticsAndNoViewport() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        #expect(status(try await call(subject, "startDiagnostics", tab)) == "ok")
        let owner = try #require(tab.developmentOwner)
        let page = tab.page
        let widthBefore = try #require(try await page.evaluateJavaScript("window.innerWidth") as? Int)
        var open: CheckedContinuation<Void, Never>?
        let gate = page.emulationQueue.enqueue { await withCheckedContinuation { open = $0 } }
        #expect(await waitUntil { open != nil })
        let apply = Task { await page.applyDevelopmentViewport(.init(width: 400, height: 700), profile: nil, owner: owner, tab: tab) }
        apply.cancel()
        open?.resume()
        await gate.value
        guard case .cancelled = await apply.value else {
            Issue.record("a cancelled apply must report .cancelled")
            return
        }
        #expect(page.developmentViewport == nil)
        #expect(try await page.evaluateJavaScript("window.innerWidth") as? Int == widthBefore)
        #expect(tab.isCurrent(owner))
        #expect(owner.diagnostics != nil)
        #expect(owner.viewport == nil)
    }

    // MARK: Diagnostics follow the document

    @Test func diagnosticsFollowANavigationCommitWithoutAnyRead() async throws {
        let (server, browser, tab) = try await fixture(routes: [
            "/two": .html("<!doctype html><title>Two</title><p>second</p>"),
            "/old-fetch": .bytes(Data("old".utf8), contentType: "text/plain"),
            "/new-fetch": .bytes(Data("new".utf8), contentType: "text/plain"),
        ])
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        let started = try await call(subject, "startDiagnostics", tab)
        #expect(status(started) == "ok")
        let firstEpoch = try #require(started.structuredContent?.objectValue?["epoch"]?.intValue)
        let firstDocument = try #require(started.structuredContent?.objectValue?["documentID"]?.stringValue)
        _ = try await tab.page.evaluateJavaScript("console.log('old-doc'); fetch('/old-fetch').catch(() => {}); 0")
        let diagnostics = try #require(tab.developmentOwner?.diagnostics)
        tab.page.load(URLRequest(url: try server.url("/two")))
        #expect(await PageSettle.untilIdle(tab.page))
        // The commit itself re-attaches the capture: nothing has read it yet.
        #expect(await waitUntil {
            diagnostics.reattachments == 1 && !diagnostics.gaps.contains { $0.hasPrefix("The hook is not attached") }
        })
        _ = try await tab.page.evaluateJavaScript("console.log('new-doc'); fetch('/new-fetch').catch(() => {}); 0")
        func lines(_ result: CallTool.Result, _ key: String) -> [String] {
            (result.structuredContent?.objectValue?["records"]?.arrayValue ?? []).compactMap { $0.objectValue?[key]?.stringValue }
        }
        var console = try await call(subject, "readConsole", tab)
        #expect(await waitUntil {
            console = try await self.call(subject, "readConsole", tab)
            return lines(console, "text").contains { $0.contains("new-doc") }
        })
        #expect(!lines(console, "text").contains { $0.contains("old-doc") })
        let epoch = try #require(console.structuredContent?.objectValue?["epoch"]?.intValue)
        let document = try #require(console.structuredContent?.objectValue?["documentID"]?.stringValue)
        #expect(epoch != firstEpoch)
        #expect(document != firstDocument)
        #expect(Set(lines(console, "documentID")) == [document])
        var network = try await call(subject, "readNetwork", tab)
        #expect(await waitUntil {
            network = try await self.call(subject, "readNetwork", tab)
            return lines(network, "url").contains { $0.contains("new-fetch") }
        })
        #expect(!lines(network, "url").contains { $0.contains("old-fetch") })
        #expect(Set(lines(network, "documentID")) == [document])
    }

    @Test func navigatingOutsideTheGrantStopsCaptureAndEndsTheLeaseAtCommit() async throws {
        let (server, browser, tab) = try await fixture()
        defer { _ = server }
        let other = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Other</title><p>other</p>")])
        defer { _ = other }
        let subject = session(browser)
        try await requestDevelopment(subject)
        #expect(status(try await call(subject, "startDiagnostics", tab)) == "ok")
        let diagnostics = try #require(tab.developmentOwner?.diagnostics)
        tab.page.load(URLRequest(url: try other.url()))
        #expect(await PageSettle.untilIdle(tab.page))
        // Ended by the commit, with no call from the connection.
        #expect(await waitUntil { tab.developmentOwner == nil })
        #expect(await diagnostics.sync() == false, "the capture is stopped, not just detached")
        #expect(try await call(subject, "readConsole", tab).isError == true)
    }

    // MARK: The bytes a client receives

    /// Every character class that grows when escaped (quote, backslash, `&<>`, `/`, a control character) plus multibyte text.
    private static let hostileAlphabets = ["\"\\", "<&>", "/\u{1}", "€🙂"]

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func hostileList(_ alphabet: String) -> String {
        let long = attribute(String(repeating: alphabet, count: 200))
        let classes = (0..<6).map { "c\($0)" + long }.joined(separator: " ")
        let items = (0..<100).map { "<p id=\"\($0)\(long)\" class=\"\(classes)\" aria-label=\"\(long)\">x</p>" }.joined()
        return "<!doctype html><title>Hostile</title>" + items
    }

    private static func hostileTarget(_ alphabet: String) -> String {
        let long = attribute(String(repeating: alphabet, count: 120))
        let classes = (0..<4).map { "k\($0)" + long }.joined(separator: " ")
        let attributes = (0..<40).map { "aria-x\($0)=\"\(long)\"" }.joined(separator: " ")
        let open = (0..<18).map { "<div id=\"d\($0)\(long)\" class=\"\(classes)\">" }.joined()
        return "<!doctype html><title>Hostile</title>" + open + "<p id=t \(attributes)>target</p>" + String(repeating: "</div>", count: 18)
    }

    @Test(arguments: hostileAlphabets)
    func findElementsPagesStayUnderTheClientByteBoundAndLoseNothing(alphabet: String) async throws {
        let (server, browser, tab) = try await fixture(html: Self.hostileList(alphabet))
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        var offset = 0, pages = 0, hasMore = true
        var ordinals: [Int] = []
        while hasMore, pages < 100 {
            let result = try await call(subject, "findElements", tab, ["selector": "p", "offset": .int(offset), "limit": 100])
            #expect(result.isError == false, "page \(pages): \(text(result).prefix(200))")
            let bytes = try content(result).utf8.count
            #expect(bytes <= 32 * 1024, "page \(pages) is \(bytes) bytes")
            let page = try payload(result, prefix: "ELEMENTS:")
            let items = try #require(page["items"] as? [[String: Any]])
            let returned = try #require(page["returned"] as? Int)
            #expect(page["offset"] as? Int == offset)
            #expect(returned == items.count && returned > 0, "every page advances")
            for item in items {
                let id = try #require(item["id"] as? String)
                let digits = id.prefix { $0.isNumber }
                ordinals.append(try #require(Int(digits)))
                let rest = id.dropFirst(digits.count)
                #expect(!rest.isEmpty && rest.allSatisfy { alphabet.contains($0) }, "hostile characters survive intact")
            }
            offset += returned
            hasMore = page["hasMore"] as? Bool == true
            pages += 1
        }
        #expect(pages > 1, "the page is sized to need more than one response")
        #expect(!hasMore)
        #expect(ordinals == Array(0..<100), "every element exactly once, in order")
    }

    @Test(arguments: hostileAlphabets)
    func inspectElementStaysUnderTheClientByteBound(alphabet: String) async throws {
        let (server, browser, tab) = try await fixture(html: Self.hostileTarget(alphabet))
        defer { _ = server }
        let subject = session(browser)
        try await requestDevelopment(subject)
        let target = try await find(subject, tab, "#t")
        let result = try await call(subject, "inspectElement", tab, ["observationID": .string(target.observation), "ref": .int(target.ref)])
        #expect(result.isError == false, "\(text(result).prefix(200))")
        let bytes = try content(result).utf8.count
        #expect(bytes <= 32 * 1024, "the inspection is \(bytes) bytes")
        let element = try payload(result, prefix: "ELEMENT:")
        #expect(element["tag"] as? String == "p")
        let attributes = try #require(element["attributes"] as? [String: String])
        for value in attributes.values where !value.isEmpty {
            #expect(value.allSatisfy { alphabet.contains($0) }, "hostile characters survive intact")
        }
    }
}
