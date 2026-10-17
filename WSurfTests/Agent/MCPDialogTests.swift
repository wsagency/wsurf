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
    /// Controls in document order: 1 alert, 2 confirm, 3 prompt, 4 secret prompt, 5 consequential confirm, 6 and 7 prompts
    /// that carry a decision, 8 a prompt whose default is too long to approve. The script keeps the
    /// consequential words out of the button, so clicking it needs no approval; only accepting the confirm does.
    private static let page = """
        <!doctype html><title>Dialogs</title>
        <button onclick="document.body.dataset.stage='before'; alert('Saved. See https://docs.example/a?token=abc#x'); document.body.dataset.stage='after'">Alert</button>
        <button onclick="document.body.dataset.answer = String(confirm('Keep going?'))">Confirm</button>
        <button onclick="document.body.dataset.answer = String(prompt('Your name?', 'Anon'))">Prompt</button>
        <button onclick="document.body.dataset.answer = String(prompt('Enter your password', ''))">Secret</button>
        <script>
        function danger() { document.body.dataset.answer = String(confirm('Delete account now?')) }
        function typeDelete() { document.body.dataset.answer = String(prompt('Type DELETE to confirm', '')) }
        function amount() { document.body.dataset.answer = String(prompt('Enter amount to transfer', '')) }
        function longDefault() { document.body.dataset.answer = String(prompt('Long default', 'x'.repeat(400))) }
        </script>
        <button onclick="danger()">Danger</button>
        <button onclick="typeDelete()">Typed</button>
        <button onclick="amount()">Sum</button>
        <button onclick="longDefault()">Long</button>
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
        _ engine: BrowserEngine, html: String = MCPDialogTests.page, development: Bool = false
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
        let session = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in development ? .development : .control })
        let made = Rig(server: server, browser: browser, tab: tab, window: window, session: session)
        _ = try await call(made, "requestAccess", nil, development ? ["development": true] : [:])
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

    /// Answers `dialog`. `consent` stands for the user's choice in the sheet WSurf would show; `asked` sees each question.
    private func answer(
        _ rig: Rig, _ dialog: [String: Value], _ action: String, text: String? = nil,
        consent: AgentActionConsent.Decision? = nil, asked: ((String, SensitiveAction.Category) -> Void)? = nil
    ) async throws -> CallTool.Result {
        var arguments: [String: Value] = ["dialogID": dialog["dialogID"] ?? .null, "action": .string(action)]
        if let text { arguments["text"] = .string(text) }
        guard let consent else { return try await call(rig, "handleDialog", rig.tab, arguments) }
        return try await AgentActionConsent.$decisionForTesting.withValue(.init { label, category, _, _ in
            asked?(label, category)
            return consent
        }) {
            try await call(rig, "handleDialog", rig.tab, arguments)
        }
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
    func aConsentedPromptAnswerReachesThePage(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { rig.close() }
        var questions: [(String, SensitiveAction.Category)] = []
        let first = try await openDialog(rig, ref: 3, type: "prompt")
        #expect(first["defaultText"]?.stringValue?.contains("Anon") == true)
        #expect(first["userMustAnswer"]?.boolValue == false)
        let answered = try await answer(rig, first, "accept", text: "Alice", consent: .allowOnce, asked: { questions.append(($0, $1)) })
        #expect(status(answered) == "ok")
        #expect(try await pageValue(rig, "answer") == "Alice")
        #expect(questions.count == 1 && questions[0].0.contains("Your·name?") && questions[0].0.contains("Alice"), "the user is shown the reply")
        let second = try await openDialog(rig, ref: 3, type: "prompt")
        #expect(status(try await answer(rig, second, "accept", consent: .allowOnce)) == "ok")
        #expect(try await pageValue(rig, "answer") == "Anon", "no text accepts the page's default, like pressing OK")
        let third = try await openDialog(rig, ref: 3, type: "prompt")
        #expect(status(try await answer(rig, third, "dismiss")) == "ok", "Cancel needs no approval")
        #expect(try await pageValue(rig, "answer") == "null")
    }

    @Test(.timeLimit(.minutes(2)), arguments: BrowserEngine.allCases)
    func aGeneralConnectionCannotAnswerAPromptWithoutConsent(engine: BrowserEngine) async throws {
        let rig = try await makeRig(engine)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 3, type: "prompt")
        let unasked = try await answer(rig, dialog, "accept", text: "Alice")
        #expect(status(unasked) == "denied", "nobody approved it")
        let declined = try await answer(rig, dialog, "accept", text: "Alice", consent: .decline)
        #expect(status(declined) == "denied")
        #expect(rig.tab.dialogs.hasOpenDialog, "the prompt is still waiting")
        #expect(status(try await answer(rig, dialog, "dismiss")) == "ok")
        #expect(try await pageValue(rig, "answer") == "null", "nothing the connection typed reached the page")
    }

    @Test func aPromptThatCarriesADecisionNamesItsConsequenceToTheUser() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        for (ref, reply, category) in [(6, "DELETE", SensitiveAction.Category.deletion), (7, "500", .transfer)] {
            let dialog = try await openDialog(rig, ref: ref, type: "prompt")
            var asked: [SensitiveAction.Category] = []
            let declined = try await answer(rig, dialog, "accept", text: reply, consent: .decline, asked: { asked.append($1) })
            #expect(status(declined) == "denied" && asked == [category])
            #expect(rig.tab.dialogs.hasOpenDialog)
            let allowed = try await answer(rig, dialog, "accept", text: reply, consent: .allowOnce, asked: { asked.append($1) })
            #expect(status(allowed) == "ok" && asked == [category, category], "one question per attempt, naming the consequence")
            #expect(try await pageValue(rig, "answer") == reply)
        }
    }

    @Test func theDevelopmentGateLetsALoopbackConnectionAnswerAPromptUnasked() async throws {
        let rig = try await makeRig(.webKit, development: true)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 3, type: "prompt")
        var asked = 0
        let answered = try await answer(rig, dialog, "accept", text: "Alice", consent: .decline, asked: { _, _ in asked += 1 })
        #expect(status(answered) == "ok" && asked == 0, "development access on this Mac needs no approval for an ordinary prompt")
        #expect(try await pageValue(rig, "answer") == "Alice")
        // Even there, a decision is the user's to approve, and a secret stays theirs.
        let danger = try await openDialog(rig, ref: 6, type: "prompt")
        let refused = try await answer(rig, danger, "accept", text: "DELETE", consent: .decline, asked: { _, _ in asked += 1 })
        #expect(status(refused) == "denied" && asked == 1)
        #expect(status(try await answer(rig, danger, "dismiss")) == "ok")
        let secret = try await openDialog(rig, ref: 4, type: "prompt", userOwned: true)
        #expect(status(try await answer(rig, secret, "accept", text: "hunter2", consent: .allowOnce)) == "denied")
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "answer")) == "null" })
    }

    @Test func aStoredAlwaysAllowDoesNotAnswerAPromptReply() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        // The user once chose "always allow" for deletions on this site, for this connection.
        let confirm = try await openDialog(rig, ref: 5, type: "confirm")
        #expect(status(try await answer(rig, confirm, "accept", consent: .allowAlways)) == "ok")
        let again = try await openDialog(rig, ref: 5, type: "confirm")
        var confirmQuestions = 0
        let remembered = try await answer(rig, again, "accept", consent: .decline, asked: { _, _ in confirmQuestions += 1 })
        #expect(status(remembered) == "ok" && confirmQuestions == 0, "the grant is stored: a confirm is no longer asked")
        // A prompt reply that names the same consequence is still asked, and the question says what it does.
        let prompt = try await openDialog(rig, ref: 6, type: "prompt")
        var asked: [(String, SensitiveAction.Category)] = []
        let declined = try await answer(rig, prompt, "accept", text: "DELETE", consent: .decline, asked: { asked.append(($0, $1)) })
        #expect(status(declined) == "denied", "the stored grant did not let the reply through")
        #expect(asked.count == 1 && asked[0].1 == .deletion && asked[0].0.contains("DELETE"))
        #expect(rig.tab.dialogs.hasOpenDialog)
        let allowed = try await answer(rig, prompt, "accept", text: "DELETE", consent: .allowOnce)
        #expect(status(allowed) == "ok")
        #expect(try await pageValue(rig, "answer") == "DELETE")
    }

    @Test func aReplyOverTheBoundIsRefusedAndOneAtTheBoundIsShownWhole() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 3, type: "prompt")
        var labels: [String] = []
        let tooLong = String(repeating: "a", count: PageDialogText.maxReplyScalars + 1)
        let refused = try await answer(rig, dialog, "accept", text: tooLong, consent: .allowOnce, asked: { label, _ in labels.append(label) })
        #expect(status(refused) == "invalidInput" && labels.isEmpty, "nothing is asked or sent for a reply the user cannot read whole")
        #expect(rig.tab.dialogs.hasOpenDialog)
        let atTheBound = String(repeating: "b", count: PageDialogText.maxReplyScalars)
        let allowed = try await answer(rig, dialog, "accept", text: atTheBound, consent: .allowOnce, asked: { label, _ in labels.append(label) })
        #expect(status(allowed) == "ok")
        #expect(labels.count == 1 && labels[0].contains(atTheBound), "the user is shown all of it")
        #expect(try await pageValue(rig, "answer") == atTheBound)
    }

    @Test func aDefaultTooLongToApproveIsRefusedUntilTheConnectionSendsItsOwnText() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 8, type: "prompt")
        let refused = try await answer(rig, dialog, "accept", consent: .allowOnce)
        #expect(status(refused) == "invalidInput" && rig.tab.dialogs.hasOpenDialog)
        #expect(status(try await answer(rig, dialog, "accept", text: "short", consent: .allowOnce)) == "ok")
        #expect(try await pageValue(rig, "answer") == "short")
    }

    @Test func paddingAndLineBreaksInAReplyAreDrawnInTheQuestion() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 3, type: "prompt")
        var labels: [String] = []
        let reply = "Alice   \n\u{200B}"
        _ = try await answer(rig, dialog, "accept", text: reply, consent: .decline, asked: { label, _ in labels.append(label) })
        #expect(labels.count == 1 && labels[0].contains("Alice···⏎‹U+200B›"), "\(labels)")
        _ = try await answer(rig, dialog, "dismiss")
    }

    @Test func aConnectionWithOnlyControlAccessGetsNoDevelopmentGate() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let dialog = try await openDialog(rig, ref: 3, type: "prompt")
        var asked = 0
        let answered = try await answer(rig, dialog, "accept", text: "Alice", consent: .allowOnce, asked: { _, _ in asked += 1 })
        #expect(status(answered) == "ok" && asked == 1)
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

    /// Leaves the page by `navigate`, whose claim outlives its call (on a clock that never advances), and waits for the new page.
    private func navigateAway(_ rig: Rig) async throws -> URL {
        rig.tab.dialogs.clock = TestClock()
        _ = try await observation(rig)
        let next = try rig.server.url("/next")
        let leaving = try await call(rig, "navigate", rig.tab, ["url": .string(next.absoluteString)])
        #expect(leaving.isError == false)
        #expect(await waitUntil { rig.tab.page.url == next })
        return next
    }

    /// A page dialog the page opens on its own, a moment after this returns.
    private func openDialogLater(_ rig: Rig) async throws {
        _ = try await rig.tab.page.evaluateJavaScript("setTimeout(() => { document.body.dataset.later = 'before'; alert('Later'); document.body.dataset.later = 'after' }, 0); true")
    }

    @Test func aUserClickAfterAnAgentCallShowsTheDialogToTheUserAtOnce() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        _ = try await navigateAway(rig)
        #expect(rig.tab.dialogs.isIntercepting, "the navigation's claim is still held")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 250, y: 200), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown {
                #expect(PageUserGesture.page(receiving: event) === rig.tab.page, "the click is found to be in this tab's page")
            }
            NSApp.sendEvent(event)
        }
        #expect(!rig.tab.dialogs.isIntercepting, "the user's click ended the claim")
        try await openDialogLater(rig)
        #expect(await waitUntil { rig.window.attachedSheet != nil }, "the dialog is the user's, shown at once")
        #expect(!rig.tab.dialogs.hasOpenDialog)
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "later")) == "after" })
    }

    @Test func aDialogOnATabWhoseCallReturnedIsTheUsers() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        // Any call but a navigation lets go of the tab when it returns.
        let dialog = try await openDialog(rig, ref: 1, type: "alert")
        #expect(status(try await answer(rig, dialog, "accept")) == "ok")
        #expect(!rig.tab.dialogs.isIntercepting)
        try await openDialogLater(rig)
        #expect(await waitUntil { rig.window.attachedSheet != nil }, "the user, not the connection, is shown a dialog after its call")
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "later")) == "after" })
        #expect(!rig.tab.dialogs.hasOpenDialog)
    }

    @Test func connectionBsDialogNeverRoutesToConnectionAsClaim() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let other = MCPBrowserSession(browser: rig.browser, available: { true }, consent: { _, _, _ in .development })
        let tabID: Value = .string(rig.tab.id.uuidString)
        _ = try await other.call(name: "requestAccess", arguments: ["development": true])
        #expect(try await other.call(name: "startDiagnostics", arguments: ["tabID": tabID]).isError == false)
        _ = try await navigateAway(rig)
        #expect(rig.tab.developmentRelation(of: other.id) == .own, "B still holds the lease")
        #expect(!rig.tab.dialogs.isIntercepting, "A's claim and B's lease are two connections: nobody can say whose action it is")
        try await openDialogLater(rig)
        #expect(await waitUntil { rig.window.attachedSheet != nil }, "the user is shown it")
        #expect(rig.tab.dialogs.pending(for: rig.session.id).isEmpty && rig.tab.dialogs.pending(for: other.id).isEmpty)
        let sheet = try #require(rig.window.attachedSheet)
        rig.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { (try? await self.pageValue(rig, "later")) == "after" })
    }

    @Test func aDevelopmentLeaseReceivesDialogsBetweenCalls() async throws {
        let rig = try await makeRig(.webKit)
        defer { rig.close() }
        let developer = MCPBrowserSession(browser: rig.browser, available: { true }, consent: { _, _, _ in .development })
        _ = try await developer.call(name: "requestAccess", arguments: ["development": true])
        let lease = try await developer.call(name: "startDiagnostics", arguments: ["tabID": .string(rig.tab.id.uuidString)])
        #expect(lease.isError == false)
        _ = try await rig.tab.page.evaluateJavaScript("setTimeout(() => { document.body.dataset.later = 'before'; alert('Later'); document.body.dataset.later = 'after' }, 0); true")
        #expect(await waitUntil { rig.tab.dialogs.hasOpenDialog })
        #expect(rig.window.attachedSheet == nil)
        let report = try await developer.call(name: "handleDialog", arguments: ["tabID": .string(rig.tab.id.uuidString)])
        let dialog = try #require((report.structuredContent?.objectValue?["dialogs"]?.arrayValue ?? []).first?.objectValue)
        #expect(dialog["type"]?.stringValue == "alert")
        let done = try await developer.call(
            name: "handleDialog",
            arguments: ["tabID": .string(rig.tab.id.uuidString), "dialogID": dialog["dialogID"] ?? .null, "action": "accept"])
        #expect(status(done) == "ok")
        #expect(try await pageValue(rig, "later") == "after")
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
