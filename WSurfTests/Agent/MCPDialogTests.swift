// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Page dialogs over MCP: a dialog blocks the page, so the call that caused it returns the dialog, and the connection
/// answers it with `handleDialog`. Real pages, real dialogs, on both engines.
@MainActor
@Suite(.boundedWebViews)
struct MCPDialogTests {
    /// Controls in document order: 1 alert, 2 confirm, 3 prompt, 4 secret prompt, 5 consequential confirm. The script keeps the
    /// consequential words out of the button, so clicking it needs no approval; only accepting the confirm does.
    private static let page = """
        <!doctype html><title>Dialogs</title>
        <button onclick="document.body.dataset.stage='before'; alert('Saved. See https://docs.example/a?token=abc#x'); document.body.dataset.stage='after'">Alert</button>
        <button onclick="document.body.dataset.answer = String(confirm('Keep going?'))">Confirm</button>
        <button onclick="document.body.dataset.answer = String(prompt('Your name?', 'Anon'))">Prompt</button>
        <button onclick="document.body.dataset.answer = String(prompt('Enter your password', ''))">Secret</button>
        <script>function danger() { document.body.dataset.answer = String(confirm('Delete account now?')) }</script>
        <button onclick="danger()">Danger</button>
        <a href="/next">Next</a>
        """

    private struct Rig {
        let server: HTTPFixtureServer
        let browser: BrowserModel
        let tab: BrowserTab
        let window: NSWindow
        let session: MCPBrowserSession

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private func makeRig(
        _ engine: BrowserEngine, html: String = MCPDialogTests.page, access: MCPAccessConsent.Access = .control
    ) async throws -> Rig {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html), "/next": .html("<title>Next</title><p>Next page</p>")])
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDialog-\(UUID().uuidString).json")))
        let url = try server.url()
        if engine == .chromium {
            browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let tab = browser.newTab(url: url)
        try #require(tab.page.engine == engine)
        // Chromium starts loading once its view is in a window.
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        #expect(await PageSettle.untilIdle(tab.page))
        #expect(await waitUntil { tab.page.mainDocumentID != nil }, "the page registered its main document")
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        #expect(
            await waitUntil {
                guard tab.page.superview === container else { return false }
                return ((try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int ?? 0) > 0
            }, "the page is laid out in the window")
        let session = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in access })
        let made = Rig(server: server, browser: browser, tab: tab, window: window, session: session)
        _ = try await call(made, "requestAccess", nil)
        return made
    }

    private func call(_ rig: Rig, _ name: String, _ tab: BrowserTab?, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    private func status(_ result: CallTool.Result) -> String? { result.structuredContent?.objectValue?["status"]?.stringValue }

    private func dialogs(_ result: CallTool.Result) -> [[String: Value]] {
        (result.structuredContent?.objectValue?["dialogs"]?.arrayValue ?? []).compactMap(\.objectValue)
    }

    private func observation(_ rig: Rig) async throws -> String {
        let read = try await call(rig, "readPage", rig.tab)
        return try #require(read.structuredContent?.objectValue?["observationID"]?.stringValue)
    }

    /// Clicks control `ref` and returns what the call reported: the page is blocked, so it returns the dialog it opened.
    private func click(_ rig: Rig, _ ref: Int) async throws -> CallTool.Result {
        let id = try await observation(rig)
        return try await call(rig, "clickOnPage", rig.tab, ["observationID": .string(id), "ref": .int(ref)])
    }

    private func answer(
        _ rig: Rig, _ dialog: [String: Value], _ action: String, text: String? = nil
    ) async throws -> CallTool.Result {
        var arguments: [String: Value] = ["dialogID": dialog["dialogID"] ?? .null, "action": .string(action)]
        if let text { arguments["text"] = .string(text) }
        return try await call(rig, "handleDialog", rig.tab, arguments)
    }

    private func pageValue(_ rig: Rig, _ key: String) async throws -> String? {
        try await rig.tab.page.evaluateJavaScript("document.body.dataset.\(key) || ''") as? String
    }

    /// Opens a dialog by clicking control `ref`. A connection holds it, unless `userOwned`: then the user's sheet is up.
    private func openDialog(_ rig: Rig, ref: Int, type: String, userOwned: Bool = false) async throws -> [String: Value] {
        let opened = try await click(rig, ref)
        #expect(status(opened) == "dialogOpened", "\(opened.content)")
        #expect(opened.isError == false)
        let dialog = try #require(dialogs(opened).first)
        #expect(dialog["type"]?.stringValue == type)
        if userOwned {
            #expect(await waitUntil { rig.window.attachedSheet != nil }, "the user is shown the dialog")
        } else {
            #expect(rig.window.attachedSheet == nil, "the user is not shown a sheet while the connection holds the dialog")
        }
        return dialog
    }

    // MARK: Answering

    @Test(.timeLimit(.minutes(2)), arguments: BrowserEngine.allCases)
    func anAlertDuringAControlledClickIsQueuedAndAccepted(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 1, type: "alert")
        let message = try #require(dialog["message"]?.stringValue)
        #expect(message.contains("Saved. See https://docs.example/a"))
        #expect(message.contains("untrusted"), "page text is wrapped as untrusted")
        for hidden in ["token", "abc", "#x"] {
            #expect(!message.contains(hidden), "a link in a dialog is cleaned: \(hidden)")
        }
        let port = try #require(try rig.server.url().port)
        #expect(dialog["origin"]?.stringValue == "http://127.0.0.1:\(port)")
        #expect(rig.tab.dialogs.hasOpenDialog)
        let done = try await answer(rig, dialog, "accept")
        #expect(status(done) == "ok" && done.isError == false)
        #expect(try await pageValue(rig, "stage") == "after", "the page continued after the alert")
        #expect(!rig.tab.dialogs.hasOpenDialog)
        // The click that opened it finished too, so the next read starts from a settled page.
        #expect(status(try await call(rig, "readPage", rig.tab)) == nil)
    }

    @Test(.timeLimit(.minutes(2)), arguments: BrowserEngine.allCases)
    func confirmAcceptOrDismissReachesThePage(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { rig.close() }
        let first = try await openDialog(rig, ref: 2, type: "confirm")
        #expect(status(try await answer(rig, first, "dismiss")) == "ok")
        #expect(try await pageValue(rig, "answer") == "false")
        let second = try await openDialog(rig, ref: 2, type: "confirm")
        #expect(second["dialogID"] != first["dialogID"], "each dialog has its own ID")
        #expect(status(try await answer(rig, second, "accept")) == "ok")
        #expect(try await pageValue(rig, "answer") == "true")
    }

    @Test(.timeLimit(.minutes(2)), arguments: BrowserEngine.allCases)
    func promptReturnsTheAgentsText(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { rig.close() }
        let first = try await openDialog(rig, ref: 3, type: "prompt")
        #expect(first["defaultText"]?.stringValue?.contains("Anon") == true)
        #expect(status(try await answer(rig, first, "accept", text: "Alice")) == "ok")
        #expect(try await pageValue(rig, "answer") == "Alice")
        let second = try await openDialog(rig, ref: 3, type: "prompt")
        #expect(status(try await answer(rig, second, "accept")) == "ok")
        #expect(try await pageValue(rig, "answer") == "Anon", "no text accepts the page's default, like pressing OK")
        let third = try await openDialog(rig, ref: 3, type: "prompt")
        #expect(status(try await answer(rig, third, "dismiss")) == "ok")
        #expect(try await pageValue(rig, "answer") == "null")
    }

    // MARK: Tools while a dialog is open

    @Test(.timeLimit(.minutes(2)), arguments: BrowserEngine.allCases)
    func callsReturnImmediatelyWhileADialogIsPending(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 2, type: "confirm")
        let id = rig.session.observations[rig.tab.id]?.id ?? "stale"
        for (name, arguments) in [
            ("readPage", [:]), ("clickOnPage", ["observationID": .string(id), "ref": 1]), ("waitForPage", ["condition": "ready", "value": ""]),
            ("getDevelopmentInfo", [:]), ("navigate", ["url": .string(try rig.server.url("/next").absoluteString)]),
        ] as [(String, [String: Value])] {
            let refused = try await call(rig, name, rig.tab, arguments)
            #expect(status(refused) == "dialogPending" && refused.isError == true, "\(name)")
            #expect(dialogs(refused).first?["dialogID"] == dialog["dialogID"], "\(name) names the dialog")
        }
        let listed = try await call(rig, "listTabs", nil)
        #expect(listed.isError == false, "tools that do not touch the page still work")
        let report = try await call(rig, "handleDialog", rig.tab)
        #expect(status(report) == "ok")
        #expect(dialogs(report).first?["dialogID"] == dialog["dialogID"])
        _ = try await answer(rig, dialog, "dismiss")
    }

    @Test func handleDialogWithoutADialogIsInvalidInput() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        #expect(status(try await call(rig, "handleDialog", rig.tab)) == "invalidInput")
        let named = try await call(rig, "handleDialog", rig.tab, ["dialogID": "nope", "action": "accept"])
        #expect(status(named) == "invalidInput" && named.isError == true)
    }

    @Test func badHandleDialogInputChangesNothing() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 2, type: "confirm")
        let stale = try await call(rig, "handleDialog", rig.tab, ["dialogID": "not-this-one", "action": "accept"])
        #expect(status(stale) == "stale")
        #expect(status(try await call(rig, "handleDialog", rig.tab, ["dialogID": dialog["dialogID"] ?? .null])) == "invalidInput")
        #expect(status(try await call(rig, "handleDialog", rig.tab, ["dialogID": dialog["dialogID"] ?? .null, "action": "maybe"])) == "invalidInput")
        #expect(status(try await answer(rig, dialog, "accept", text: "not a prompt")) == "invalidInput")
        #expect(status(try await answer(rig, dialog, "dismiss", text: "x")) == "invalidInput")
        #expect(rig.tab.dialogs.hasOpenDialog, "the dialog is still waiting")
        #expect(status(try await answer(rig, dialog, "dismiss")) == "ok")
    }

    @Test func aReadOnlyConnectionCannotAnswerDialogs() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let reader = MCPBrowserSession(browser: rig.browser, available: { true }, consent: { _, _, _ in .readOnly })
        _ = try await reader.call(name: "requestAccess", arguments: [:])
        let denied = try await reader.call(name: "handleDialog", arguments: ["tabID": .string(rig.tab.id.uuidString)])
        #expect(denied.isError == true)
    }

    // MARK: The user keeps what a connection must not decide

    @Test func aSecretLookingPromptGoesToTheUser() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 4, type: "prompt", userOwned: true)
        #expect(dialog["userMustAnswer"]?.boolValue == true)
        let refused = try await answer(rig, dialog, "accept", text: "hunter2")
        #expect(status(refused) == "denied")
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "answer")) == "null" }, "the user's Cancel reached the page")
        #expect(!rig.tab.dialogs.hasOpenDialog)
    }

    @Test func acceptingAConsequentialConfirmNeedsApproval() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 5, type: "confirm")
        var categories: [SensitiveAction.Category] = []
        let declined = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, _ in
            categories.append(category)
            return .decline
        }) {
            try await answer(rig, dialog, "accept")
        }
        #expect(status(declined) == "denied")
        #expect(categories == [.deletion])
        #expect(rig.tab.dialogs.hasOpenDialog, "a declined approval leaves the dialog for the connection to dismiss")
        // Dismissing never needs approval.
        let dismissed = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in
            Issue.record("dismissing a dialog must not ask")
            return .decline
        }) {
            try await answer(rig, dialog, "dismiss")
        }
        #expect(status(dismissed) == "ok")
        #expect(try await pageValue(rig, "answer") == "false")
        // Approved, accepting reaches the page.
        let again = try await openDialog(rig, ref: 5, type: "confirm")
        let accepted = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in .allowOnce }) {
            try await answer(rig, again, "accept")
        }
        #expect(status(accepted) == "ok")
        #expect(try await pageValue(rig, "answer") == "true")
    }

    @Test func anUnansweredDialogFallsBackToTheUserAfterTheTimeout() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let clock = TestClock()
        rig.tab.dialogs.clock = clock
        let dialog = try await openDialog(rig, ref: 1, type: "alert")
        #expect(await waitUntil { clock.pendingCount >= 1 })
        clock.advance(by: .seconds(61))
        #expect(await waitUntil { rig.window.attachedSheet != nil }, "the user is shown the dialog")
        let late = try await answer(rig, dialog, "accept")
        #expect(status(late) == "denied", "the connection cannot answer once the user has it")
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "stage")) == "after" })
    }

    @Test func disconnectHandsThePendingDialogToTheUser() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        _ = try await openDialog(rig, ref: 1, type: "alert")
        rig.session.revoke()
        #expect(await waitUntil { rig.window.attachedSheet != nil }, "the user is shown the dialog")
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "stage")) == "after" })
        #expect(!rig.tab.dialogs.hasOpenDialog)
    }

    @Test func dialogsOnUncontrolledTabsStillGoToTheUser() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        // The connection shares the tab but runs nothing on it, so it does not control it.
        _ = try await rig.tab.page.evaluateJavaScript("setTimeout(() => { document.body.dataset.stage = 'before'; alert('Hello'); document.body.dataset.stage = 'after' }, 0); true")
        #expect(await waitUntil { rig.window.attachedSheet != nil }, "the native sheet is shown")
        #expect(!rig.tab.dialogs.hasOpenDialog)
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "stage")) == "after" })
    }

    @Test func aDevelopmentLeaseReceivesDialogsBetweenCalls() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let developer = MCPBrowserSession(browser: rig.browser, available: { true }, consent: { _, _, _ in .development })
        _ = try await developer.call(name: "requestAccess", arguments: ["development": true])
        let lease = try await developer.call(name: "startDiagnostics", arguments: ["tabID": .string(rig.tab.id.uuidString)])
        #expect(lease.isError == false)
        _ = try await rig.tab.page.evaluateJavaScript("setTimeout(() => { document.body.dataset.stage = 'before'; alert('Later'); document.body.dataset.stage = 'after' }, 0); true")
        #expect(await waitUntil { rig.tab.dialogs.hasOpenDialog })
        #expect(rig.window.attachedSheet == nil)
        let report = try await developer.call(name: "handleDialog", arguments: ["tabID": .string(rig.tab.id.uuidString)])
        let dialog = try #require((report.structuredContent?.objectValue?["dialogs"]?.arrayValue ?? []).first?.objectValue)
        #expect(dialog["type"]?.stringValue == "alert")
        let done = try await developer.call(
            name: "handleDialog",
            arguments: ["tabID": .string(rig.tab.id.uuidString), "dialogID": dialog["dialogID"] ?? .null, "action": "accept"])
        #expect(status(done) == "ok")
        #expect(try await pageValue(rig, "stage") == "after")
    }

    @Test func closingTheTabEndsAPendingDialogWithoutASheet() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        _ = try await openDialog(rig, ref: 1, type: "alert")
        let closed = try await call(rig, "closeTab", rig.tab)
        #expect(closed.isError == false)
        #expect(!rig.tab.dialogs.hasOpenDialog)
        #expect(rig.window.attachedSheet == nil)
    }

    // MARK: beforeunload

    private static let guarded = """
        <!doctype html><title>Unsaved</title>
        <script>window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; return ''; }</script>
        <a href="/next">Next</a>
        """

    @Test(.timeLimit(.minutes(2)))
    func beforeUnloadIsQueuedOnChromium() async throws {
        let rig = try await makeRig(.chromium, html: Self.guarded)
        defer { rig.close() }
        // Chromium shows a beforeunload prompt only to a page that has had user activation: send it a real click.
        let chromium = try #require(rig.tab.page.chromium)
        for type in ["mousePressed", "mouseReleased"] {
            _ = try await chromium.command("Input.dispatchMouseEvent", params: ["type": type, "x": 5, "y": 5, "button": "left", "clickCount": 1])
        }
        #expect(try await rig.tab.page.evaluateJavaScript("navigator.userActivation.hasBeenActive") as? Bool == true)
        _ = try await observation(rig)
        let original = try #require(rig.tab.page.url)
        let next = try rig.server.url("/next")
        func leave() async throws -> [String: Value] {
            // Chromium asks about beforeunload a moment after the navigation starts, so the call may already have returned.
            _ = try await call(rig, "navigate", rig.tab, ["url": .string(next.absoluteString)])
            #expect(await waitUntil { rig.tab.dialogs.hasOpenDialog }, "Chromium asked before leaving")
            let report = try await call(rig, "handleDialog", rig.tab)
            return try #require(dialogs(report).first)
        }
        let dialog = try await leave()
        #expect(dialog["type"]?.stringValue == "beforeUnload")
        #expect(dialog["userMustAnswer"]?.boolValue == false)
        #expect(rig.window.attachedSheet == nil, "the user is not shown a sheet while the connection holds the dialog")
        #expect(status(try await answer(rig, dialog, "dismiss")) == "ok")
        #expect(rig.tab.page.url == original, "Stay keeps the page")
        let again = try await leave()
        #expect(status(try await answer(rig, again, "accept")) == "ok")
        #expect(await waitUntil { rig.tab.page.url == next }, "Leave goes on")
    }

    @Test(.timeLimit(.minutes(2)))
    func webKitNeverShowsABeforeUnloadDialog() async throws {
        let rig = try await makeRig(.webKit, html: Self.guarded)
        defer { rig.close() }
        _ = try await observation(rig)
        let next = try rig.server.url("/next")
        let leaving = try await call(rig, "navigate", rig.tab, ["url": .string(next.absoluteString)])
        #expect(status(leaving) != "dialogOpened")
        #expect(await waitUntil { rig.tab.page.url == next })
        #expect(!rig.tab.dialogs.hasOpenDialog)
        #expect(rig.window.attachedSheet == nil)
    }

    // MARK: Chromium's own sheet

    @Test func chromiumPromptSheetUsesAPlainTextField() {
        let alert = ChromiumClient.jsDialogAlert(kind: 2, origin: "https://example.com", message: "Name?", prompt: "Anon")
        let field = alert.accessoryView as? NSTextField
        #expect(field?.stringValue == "Anon")
        #expect(!(alert.accessoryView is NSSecureTextField), "what the user types is shown, as in WebKit")
        #expect(ChromiumClient.jsDialogAlert(kind: 0, origin: "", message: "x", prompt: "").buttons.count == 1)
        #expect(ChromiumClient.jsDialogAlert(kind: 1, origin: "", message: "x", prompt: "").buttons.count == 2)
    }
}
