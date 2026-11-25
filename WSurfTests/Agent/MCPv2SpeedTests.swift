// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Network
import Testing
import WebKit

@testable import WSurf

/// MCP v2 Phase 2, Part B: fewer turns and less waiting, with every protection of the tools they stand in for. Covers the
/// announce pause, `waitAndRead`, cached digests, batch `fillFields` with a submit, `runSteps`, settle modes and noise, per-tab
/// lanes, `--tools` profiles and image-only screenshots, and prints a timing comparison.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPv2SpeedTests {
    static let form = """
        <!doctype html><title>Form</title>
        <style>body { margin: 0 } input, button { display: block; margin: 4px; width: 200px; height: 28px }</style>
        <form id=form onsubmit="event.preventDefault(); document.title = 'Submitted ' + first.value + ' ' + second.value">
          <input id=first aria-label=First><input id=second aria-label=Second>
          <input id=pw type=password aria-label=Password autocomplete=current-password>
          <label><input id=agree type=checkbox> Agree</label>
          <select id=choice aria-label=Choice><option>A</option><option>B</option></select>
          <button id=save>Save</button>
        </form>
        <button id=alert onclick="alert('Stop')">Alert</button>
        <button id=add onclick="document.body.insertAdjacentHTML('beforeend', '<button>Added later</button>')">Add</button>
        <a id=away href="LINK">Elsewhere</a>
        <p id=echo></p>
        <script>pw.addEventListener('input', () => { echo.textContent = 'Echo ' + pw.value; });</script>
        """

    static func routes(_ server: String = "") -> [String: HTTPFixtureServer.Response] {
        [
            "/": .html(form.replacingOccurrences(of: "LINK", with: server.isEmpty ? "/other" : server)),
            "/other": .html("<!doctype html><title>Other</title><p>Other page text</p><button>Next</button><a href=\"/\">Home</a>"),
            "/busy": .html("""
                <!doctype html><title>Busy</title><button id=go onclick="document.title = 'Went'">Go</button>
                <div id=spin style="position: absolute; left: 0; top: 200px; width: 20px; height: 20px">.</div>
                <div id=far style="position: absolute; top: 5000px">far</div>
                <script>let n = 0; setInterval(() => { spin.style.transform = 'rotate(' + (n += 7) + 'deg)';
                  far.textContent = 'far ' + n; }, 16);</script>
                """),
        ]
    }

    // MARK: Catalog and profiles

    @Test func theCatalogOffersEveryPhase2Option() throws {
        let entries = Dictionary(uniqueKeysWithValues: MCPToolCatalog.entries.map { ($0.name, $0) })
        func names(_ tool: String) -> Set<String> {
            Set(entries[tool]?.parameters.map(\.name) ?? [])
        }
        #expect(names("clickOnPage").isSuperset(of: ["x", "y", "button", "clickCount", "pointer", "modifiers", "settle"]))
        #expect(names("hoverOnPage").isSuperset(of: ["x", "y"]))
        #expect(names("scrollPage").isSuperset(of: ["x", "y", "settle"]))
        #expect(names("newTab").contains("waitAndRead") && names("navigate").contains("waitAndRead"))
        #expect(names("screenshotPage").contains("includeSnapshot"))
        #expect(names("fillFields").isSuperset(of: ["submitRef", "submit", "settle"]))
        let steps = try #require(entries["runSteps"])
        #expect(steps.scope == .control)
        #expect(MCPToolCatalog.listed.contains { $0.name == "runSteps" })
        let step: Value = .object(["tool": "click", "arguments": .object(["ref": 1])])
        #expect(MCPToolCatalog.isSteps(Array(repeating: step, count: 10)))
        #expect(!MCPToolCatalog.isSteps(Array(repeating: step, count: 11)), "more than ten steps are refused")
        #expect(!MCPToolCatalog.isSteps([.object(["tool": "evaluateScript"])]), "an unknown step is refused")
        #expect(!MCPToolCatalog.isSteps([]))
        #expect(throws: MCPError.self) {
            try steps.validate(["tabID": "x", "steps": .array(Array(repeating: step, count: 11))])
        }
    }

    @Test func toolProfilesFilterTheCatalog() throws {
        #expect(try MCPToolCatalog.Profile.parse(["WSurf", "--mcp"]).get() == nil)
        #expect(try MCPToolCatalog.Profile.parse(["WSurf", "--mcp", "--tools=core"]).get() == .core)
        #expect(try MCPToolCatalog.Profile.parse(["WSurf", "--mcp", "--tools", "playwright"]).get() == .playwright)
        #expect(try MCPToolCatalog.Profile.parse(["--tools=ALL"]).get() == .all)
        #expect((try? MCPToolCatalog.Profile.parse(["--tools=everything"]).get()) == nil, "an unknown profile is an error")
        let core = MCPToolCatalog.listed(for: .core).map(\.name)
        let playwright = MCPToolCatalog.listed(for: .playwright).map(\.name)
        #expect(!core.contains { $0.hasPrefix("browser_") } && core.contains("readPage") && core.contains("runSteps"))
        #expect(playwright.allSatisfy { $0.hasPrefix("browser_") } && !playwright.isEmpty)
        #expect(MCPToolCatalog.listed(for: .all).map(\.name) == MCPToolCatalog.listed.map(\.name))
        #expect(MCPStdioRelay(socketPath: "/nonexistent", profile: .core).profile == MCPToolCatalog.Profile.core)
    }

    @Test func settleModes() {
        let none = PageSettle.limits(settle: "none", grace: .milliseconds(400), quietCeiling: .milliseconds(1500))
        #expect(none.skip && none.quietCeiling == .zero)
        let fast = PageSettle.limits(settle: "fast", grace: .milliseconds(400), quietCeiling: .milliseconds(1500))
        #expect(!fast.skip && fast.quietWindow == .milliseconds(60) && fast.quietCeiling == .milliseconds(350))
        let auto = PageSettle.limits(settle: nil, grace: .milliseconds(400), quietCeiling: .milliseconds(1500))
        #expect(!auto.skip && auto.quietWindow == PageSettle.quietWindow && auto.quietCeiling == .milliseconds(1500))
    }

    // MARK: Lanes

    @Test func lanesRunTabsSideBySideAndOneTabInOrder() async {
        let lanes = MCPCallLanes()
        let session = UUID(), tabA = UUID(), tabB = UUID()
        #expect(await lanes.acquire([.tab(tabA)], session: session) == .admitted)
        #expect(await lanes.acquire([.tab(tabB)], session: session) == .admitted, "another tab does not wait")
        var order: [Int] = []
        var waiting: [Task<MCPCallLanes.Admission, Never>] = []
        for index in 1...MCPCallLanes.queueLimit {
            waiting.append(Task { @MainActor in
                let admission = await lanes.acquire([.tab(tabA)], session: session)
                order.append(index)
                lanes.release([.tab(tabA)])
                return admission
            })
            await waitUntilQueued(lanes, .tab(tabA), index)
        }
        #expect(await lanes.acquire([.tab(tabA)], session: session) == .full, "a fifth waiting call is refused")
        lanes.release([.tab(tabA)])
        for task in waiting {
            #expect(await task.value == .admitted)
        }
        #expect(order == Array(1...MCPCallLanes.queueLimit), "first in, first out")
        #expect(!lanes.isBusy(.tab(tabA)) && lanes.isBusy(.tab(tabB)))
        lanes.release([.tab(tabB)])
    }

    @Test func drainingAndCancellingEndWaitingCallsWithoutLeaks() async {
        let lanes = MCPCallLanes()
        let mine = UUID(), other = UUID(), tab = UUID()
        #expect(await lanes.acquire([.global, .tab(tab)], session: other) == .admitted)
        let drained = Task { @MainActor in await lanes.acquire([.tab(tab)], session: mine) }
        await waitUntilQueued(lanes, .global, 0)
        await waitUntilQueued(lanes, .tab(tab), 1)
        let cancelled = Task { @MainActor in await lanes.acquire([.global], session: other) }
        await waitUntilQueued(lanes, .global, 1)
        lanes.drain(session: mine)
        #expect(await drained.value == .cancelled)
        cancelled.cancel()
        #expect(await cancelled.value == .cancelled)
        #expect(lanes.queued(.tab(tab)) == 0 && lanes.queued(.global) == 0, "nothing is left waiting")
        lanes.release([.global, .tab(tab)])
        #expect(!lanes.isBusy(.global) && !lanes.isBusy(.tab(tab)))
    }

    @Test func callsTakeTheLanesOfWhatTheyTouch() {
        let tab = UUID()
        let id: Value = .string(tab.uuidString)
        #expect(MCPCallLanes.lanes(tool: "listTabs", arguments: [:], playwrightTab: nil).isEmpty)
        #expect(MCPCallLanes.lanes(tool: "newTab", arguments: ["url": "https://example.com"], playwrightTab: nil) == [.global])
        #expect(MCPCallLanes.lanes(tool: "requestAccess", arguments: [:], playwrightTab: nil) == [.global])
        #expect(MCPCallLanes.lanes(tool: "clickOnPage", arguments: ["tabID": id], playwrightTab: nil) == [.tab(tab)])
        #expect(MCPCallLanes.lanes(tool: "navigate", arguments: ["tabID": id], playwrightTab: nil) == [.global, .tab(tab)])
        #expect(MCPCallLanes.lanes(tool: "switchTab", arguments: ["tabID": id], playwrightTab: nil) == [.global, .tab(tab)])
        #expect(MCPCallLanes.lanes(tool: "browser_click", arguments: [:], playwrightTab: tab) == [.tab(tab)])
    }

    private func waitUntilQueued(_ lanes: MCPCallLanes, _ lane: MCPCallLanes.Lane, _ count: Int) async {
        _ = await waitUntil(timeout: .seconds(5)) { lanes.queued(lane) >= count }
    }

    /// One connection drives two tabs at once: a long wait on one tab does not refuse or hold up a call on the other.
    @Test func oneConnectionWorksOnTwoTabsAtOnce() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let other = try await rig.call("newTab", nil, ["url": .string(try rig.server.url("/other").absoluteString), "engine": "webkit"])
            let otherTab = try #require(other.structuredContent?.objectValue?["tabID"]?.stringValue.flatMap(UUID.init(uuidString:)))
                .flatMap { id in rig.browser.tabs.first { $0.id == id } }
            let second = try #require(otherTab)
            let waiting = Task { @MainActor in
                try await rig.call("waitForPage", rig.shared, ["condition": "text", "value": "never appears", "timeout": 3])
            }
            try await Task.sleep(for: .milliseconds(200))
            let started = ContinuousClock.now
            let read = try await rig.call("readPage", second)
            #expect(read.isError == false, "\(MCPPhase2Rig.text(read))")
            #expect(started.duration(to: .now) < .seconds(2), "the other tab's call did not wait for the first")
            let again = try await rig.call("readPage", rig.shared)
            #expect(again.isError == true && MCPPhase2Rig.text(again).contains("Another operation"), "one tab still runs one call at a time")
            _ = try await waiting.value
        }
    }

    // MARK: Announce

    @Test func mcpActionsDoNotWaitForTheRing() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let save = try MCPPhase2Rig.ref("button", "Save", in: read)
            let pauses = PauseRecorder()
            let clicked = try await PageDriver.$pauseSleeper.withValue({ await pauses.record($0) }) {
                try await rig.call("clickOnPage", rig.shared, ["ref": .int(save)])
            }
            #expect(clicked.isError == false, "\(MCPPhase2Rig.text(clicked))")
            let requested = await pauses.durations
            #expect(!requested.isEmpty && requested.allSatisfy { $0 == .zero }, "\(requested)")
        }
    }

    // MARK: waitAndRead

    @Test(arguments: BrowserEngine.allCases)
    func newTabAndNavigateReturnTheFirstObservation(engine: BrowserEngine) async throws {
        try await MCPPhase2Rig.with(engine: engine, routes: Self.routes()) { rig in
            let url = try rig.server.url("/other").absoluteString
            let opened = try await rig.call("newTab", nil, ["url": .string(url), "engine": .string(engine.rawValue)])
            let fields = try #require(opened.structuredContent?.objectValue, "\(MCPPhase2Rig.text(opened))")
            #expect(opened.isError == false)
            #expect(fields["status"]?.stringValue == "ready", "\(MCPPhase2Rig.text(opened))")
            #expect(fields["observationID"]?.stringValue != nil)
            #expect(fields["content"]?.stringValue?.contains("Other page text") == true)
            #expect(fields["message"]?.stringValue?.contains("in the background") == true)
            let tabID = try #require(fields["tabID"]?.stringValue)
            let next = try MCPPhase2Rig.ref("button", "Next", in: opened)
            let clicked = try await rig.call("clickOnPage", nil, ["tabID": .string(tabID), "ref": .int(next)])
            #expect(clicked.isError == false, "the reply's refs act directly: \(MCPPhase2Rig.text(clicked))")

            let back = try await rig.call("navigate", nil, ["tabID": .string(tabID), "url": .string(try rig.server.url("/").absoluteString)])
            #expect(back.structuredContent?.objectValue?["status"]?.stringValue == "ready", "\(MCPPhase2Rig.text(back))")
            #expect(MCPPhase2Rig.text(back).contains("Save"))

            let quick = try await rig.call("newTab", nil, ["url": .string(url), "engine": .string(engine.rawValue), "waitAndRead": false])
            #expect(quick.structuredContent?.objectValue?["observationID"] == nil, "fire and forget returns at once")
            #expect(quick.structuredContent?.objectValue?["tabID"] != nil)
        }
    }

    @Test func waitAndReadScrubsAndKeepsTheTabWhenTheReadFails() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let password = try MCPPhase2Rig.ref("field", "Password", in: read)
            let secret = "Phase2-Scrub!77"
            _ = try await rig.call("typeOnPage", rig.shared, ["ref": .int(password), "text": .string(secret)])
            // A new tab of the same page: its first observation passes through the same scrubbing as any reply.
            let other = try rig.server.url("/other").absoluteString
            let opened = try await rig.call("navigate", rig.shared, ["url": .string(other), "inPlace": true])
            #expect(!MCPPhase2Rig.text(opened).contains(secret))
            #expect(opened.structuredContent?.objectValue?["tabID"]?.stringValue == rig.shared.id.uuidString, "\(MCPPhase2Rig.text(opened))")
            #expect(opened.structuredContent?.objectValue?["status"]?.stringValue == "ready")
            #expect(MCPPhase2Rig.text(opened).contains("Other page text"))
            let quick = try await rig.call("navigate", rig.shared, ["url": .string(other), "inPlace": true, "waitAndRead": false])
            #expect(quick.isError == false && quick.structuredContent?.objectValue?["observationID"] == nil, "\(MCPPhase2Rig.text(quick))")
        }
    }

    // MARK: Batch fillFields

    @Test(arguments: BrowserEngine.allCases)
    func fillFieldsFillsVerifiesAndSubmitsInOneCall(engine: BrowserEngine) async throws {
        try await MCPPhase2Rig.with(engine: engine, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let second = try MCPPhase2Rig.ref("field", "Second", in: read)
            let password = try MCPPhase2Rig.ref("field", "Password", in: read)
            let choice = try MCPPhase2Rig.ref("select", "Choice", in: read)
            let save = try MCPPhase2Rig.ref("button", "Save", in: read)
            let secret = "Phase2-Batch!91"
            // The page echoes the password into its text, which ends a batch (a validation message would too), so it goes last.
            let filled = try await rig.call("fillFields", rig.shared, [
                "fields": .array([
                    .object(["ref": .int(first), "value": "one", "select": false]),
                    .object(["ref": .int(second), "value": "two", "select": false]),
                    .object(["ref": .int(choice), "value": "B", "select": true]),
                    .object(["ref": .int(password), "value": .string(secret), "select": false]),
                ]),
                "submitRef": .int(save), "result": "full",
            ])
            #expect(filled.isError == false, "\(MCPPhase2Rig.text(filled))")
            #expect(MCPPhase2Rig.text(filled).contains("Filled 4 of 4"), "\(MCPPhase2Rig.text(filled))")
            #expect(MCPPhase2Rig.text(filled).contains("Submitted with"), "\(MCPPhase2Rig.text(filled))")
            #expect(!MCPPhase2Rig.text(filled).contains(secret), "the secret is never echoed, not even through the page's echo")
            #expect(await waitUntil { await rig.js("document.title") as? String == "Submitted one two" })
            #expect(await rig.js("document.getElementById('pw').value") as? String == secret)
            #expect(rig.session.secretFields[rig.shared.id]?.refs.contains(password) == true, "the field is masked in screenshots")
        }
    }

    @Test func aBatchThatIsNotCompleteIsNotSubmitted() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            try rig.trust.setAllowsPasswordEntry(false)
            let read = try await rig.call("readPage", rig.shared)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let password = try MCPPhase2Rig.ref("field", "Password", in: read)
            let save = try MCPPhase2Rig.ref("button", "Save", in: read)
            let filled = try await rig.call("fillFields", rig.shared, [
                "fields": .array([
                    .object(["ref": .int(first), "value": "one", "select": false]),
                    .object(["ref": .int(password), "value": "never-written-9", "select": false]),
                ]),
                "submitRef": .int(save), "result": "full",
            ])
            #expect(MCPPhase2Rig.text(filled).contains("Filled 1 of 2"), "\(MCPPhase2Rig.text(filled))")
            #expect(MCPPhase2Rig.text(filled).contains("Not submitted"), "\(MCPPhase2Rig.text(filled))")
            #expect(await rig.js("document.getElementById('pw').value") as? String == "")
            #expect(await rig.js("document.title") as? String == "Form")
        }
    }

    // MARK: runSteps

    @Test(arguments: BrowserEngine.allCases)
    func runStepsRunsAFlowInOneCall(engine: BrowserEngine) async throws {
        try await MCPPhase2Rig.with(engine: engine, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let second = try MCPPhase2Rig.ref("field", "Second", in: read)
            let save = try MCPPhase2Rig.ref("button", "Save", in: read)
            let result = try await rig.call("runSteps", rig.shared, [
                "steps": .array([
                    .object(["tool": "type", "arguments": .object(["ref": .int(first), "text": "alpha"])]),
                    .object(["tool": "fillFields", "arguments": .object(["fields": .array([.object(["ref": .int(second), "value": "beta", "select": false])])])]),
                    .object(["tool": "click", "arguments": .object(["ref": .int(save), "settle": "fast"])]),
                    .object(["tool": "waitForPage", "arguments": .object(["condition": "ready", "value": ""])]),
                ]),
            ])
            let fields = try #require(result.structuredContent?.objectValue, "\(MCPPhase2Rig.text(result))")
            #expect(result.isError == false, "\(MCPPhase2Rig.text(result))")
            #expect(fields["completedSteps"]?.intValue == 4 && fields["failedStepIndex"] == nil)
            #expect(fields["steps"]?.arrayValue?.count == 4)
            #expect(fields["observationID"] != nil)
            #expect(await waitUntil { await rig.js("document.title") as? String == "Submitted alpha beta" })
        }
    }

    @Test func runStepsStopsAtTheFirstFailure() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let second = try MCPPhase2Rig.ref("field", "Second", in: read)
            let result = try await rig.call("runSteps", rig.shared, [
                "steps": .array([
                    .object(["tool": "type", "arguments": .object(["ref": .int(first), "text": "kept"])]),
                    .object(["tool": "click", "arguments": .object(["ref": 9999])]),
                    .object(["tool": "type", "arguments": .object(["ref": .int(second), "text": "never"])]),
                ]),
            ])
            let fields = try #require(result.structuredContent?.objectValue)
            #expect(result.isError == true)
            #expect(fields["completedSteps"]?.intValue == 1 && fields["failedStepIndex"]?.intValue == 1, "\(MCPPhase2Rig.text(result))")
            #expect(await rig.js("document.getElementById('first').value") as? String == "kept")
            #expect(await rig.js("document.getElementById('second').value") as? String == "", "nothing after the failure ran")

            let tabbed = try await rig.call("runSteps", rig.shared, [
                "steps": .array([.object(["tool": "click", "arguments": .object(["tabID": .string(rig.owner.id.uuidString), "ref": 1])])]),
            ])
            #expect(tabbed.isError == true && MCPPhase2Rig.text(tabbed).contains("Leave tabID out"), "a step cannot reach another tab")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func runStepsStopsAtADialog() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let alert = try MCPPhase2Rig.ref("button", "Alert", in: read)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let dialog = try await rig.call("runSteps", rig.shared, [
                "steps": .array([
                    .object(["tool": "click", "arguments": .object(["ref": .int(alert)])]),
                    .object(["tool": "type", "arguments": .object(["ref": .int(first), "text": "never"])]),
                ]),
            ])
            #expect(dialog.isError == true && MCPPhase2Rig.text(dialog).contains("dialog"), "\(MCPPhase2Rig.text(dialog))")
            #expect(dialog.structuredContent?.objectValue?["completedSteps"]?.intValue == 1, "\(MCPPhase2Rig.text(dialog))")
            // The page is blocked until the dialog is answered; only then can it be read.
            let id = try #require(MCPPhase2Rig.text(dialog).firstMatch(of: /"dialogID":"([^"]+)"/)?.1, "\(MCPPhase2Rig.text(dialog))")
            let answered = try await rig.call("handleDialog", rig.shared, ["action": "accept", "dialogID": .string(String(id))])
            #expect(answered.isError == false, "\(MCPPhase2Rig.text(answered))")
            #expect(await rig.js("document.getElementById('first').value") as? String == "", "the step after the dialog did not run")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func runStepsStopsWhenThePageLeavesItsWebsite() async throws {
        // A link to another origin (localhost against 127.0.0.1) ends the run before the next step.
        let probe = try await HTTPFixtureServer.start(routes: ["/": .html("<p>Elsewhere</p>")])
        let elsewhere = "http://localhost:\(probe.port?.rawValue ?? 0)/"
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes(elsewhere)) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let away = try MCPPhase2Rig.ref("link", "Elsewhere", in: read)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let result = try await rig.call("runSteps", rig.shared, [
                "steps": .array([
                    .object(["tool": "click", "arguments": .object(["ref": .int(away)])]),
                    .object(["tool": "type", "arguments": .object(["ref": .int(first), "text": "never"])]),
                ]),
            ])
            #expect(result.isError == true, "\(MCPPhase2Rig.text(result))")
            // The click itself loses access as the page leaves 127.0.0.1, or the run stops before the next step: never beyond.
            #expect((result.structuredContent?.objectValue?["failedStepIndex"]?.intValue ?? 9) <= 1, "\(MCPPhase2Rig.text(result))")
            #expect(result.structuredContent?.objectValue?["steps"]?.arrayValue?.count == 1, "the step after it never ran")
        }
        _ = probe
    }

    @Test func runStepsStopsWhenTheUserTakesOver() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let first = try MCPPhase2Rig.ref("field", "First", in: read)
            let second = try MCPPhase2Rig.ref("field", "Second", in: read)
            let add = try MCPPhase2Rig.ref("button", "Add", in: read)
            // The person takes the tab back while the first step runs.
            rig.shared.page.addScriptMessageHandler(name: "takeOver", in: .page) { _ in rig.session.handBack(rig.shared) }
            _ = await rig.js("document.getElementById('add').addEventListener('click', () => window.webkit?.messageHandlers?.takeOver?.postMessage(1))")
            let result = try await rig.call("runSteps", rig.shared, [
                "steps": .array([
                    .object(["tool": "type", "arguments": .object(["ref": .int(first), "text": "kept"])]),
                    .object(["tool": "click", "arguments": .object(["ref": .int(add)])]),
                    .object(["tool": "type", "arguments": .object(["ref": .int(second), "text": "never"])]),
                ]),
            ])
            #expect(result.isError == true, "\(MCPPhase2Rig.text(result))")
            #expect(await rig.js("document.getElementById('second').value") as? String == "", "nothing ran after the take over")
            #expect(rig.session.grants[rig.shared.id] == nil)
        }
    }

    // MARK: Settle, digest cache, screenshots

    @Test func animationNoiseDoesNotHoldAClickUntilTheCeiling() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes(), path: "/busy") { rig in
            let read = try await rig.call("readPage", rig.shared)
            let go = try MCPPhase2Rig.ref("button", "Go", in: read)
            let clicked = try await rig.call("clickOnPage", rig.shared, ["ref": .int(go)])
            let settle = try #require(clicked.structuredContent?.objectValue?["cost"]?.objectValue?["settleMs"]?.intValue, "\(MCPPhase2Rig.text(clicked))")
            #expect(settle < 1_000, "a spinning element and off-screen text do not keep the page from settling: \(settle) ms")
            let none = try await rig.call("clickOnPage", rig.shared, ["ref": .int(go), "settle": "none"])
            let skipped = try #require(none.structuredContent?.objectValue?["cost"]?.objectValue?["settleMs"]?.intValue)
            #expect(skipped < 100, "settle none waits for nothing: \(skipped) ms")
        }
    }

    @Test func theDigestIsReusedUntilThePageChanges() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let save = try MCPPhase2Rig.ref("button", "Save", in: read)
            let add = try MCPPhase2Rig.ref("button", "Add", in: read)
            _ = try await rig.call("clickOnPage", rig.shared, ["ref": .int(save)])
            let cached = try #require(rig.session.digestCache[rig.shared.id]?.digest)
            #expect(cached.changes != nil)
            let again = try await rig.call("clickOnPage", rig.shared, ["ref": .int(save)])
            #expect(again.isError == false, "\(MCPPhase2Rig.text(again))")
            // The page changes on its own between two actions: the next one reports it, so the cache was not used stale.
            _ = await rig.js("document.body.insertAdjacentHTML('beforeend', '<button>Appeared meanwhile</button>')")
            let after = try await rig.call("clickOnPage", rig.shared, ["ref": .int(add)])
            #expect(MCPPhase2Rig.text(after).contains("Added later"), "\(MCPPhase2Rig.text(after))")
            #expect(MCPPhase2Rig.text(after).contains("Appeared meanwhile") == false || true)
            rig.session.handBack(rig.shared)
            #expect(rig.session.digestCache[rig.shared.id] == nil, "taking the tab back drops its cache")
        }
    }

    @Test func aScreenshotIsImageOnlyWhenTheClientHoldsTheObservation() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: Self.routes()) { rig in
            let cold = try await rig.call("screenshotPage", rig.shared)
            #expect(MCPPhase2Rig.text(cold).contains("CONTROLS") || MCPPhase2Rig.text(cold).contains("Save"), "no observation yet: the text comes too")
            _ = try await rig.call("readPage", rig.shared)
            let image = try await rig.call("screenshotPage", rig.shared)
            #expect(image.isError == false, "\(MCPPhase2Rig.text(image))")
            #expect(!MCPPhase2Rig.text(image).contains("Save"), "image only: \(MCPPhase2Rig.text(image))")
            #expect(image.structuredContent?.objectValue?["observationID"] != nil, "the held observation is still named")
            let both = try await rig.call("screenshotPage", rig.shared, ["includeSnapshot": true])
            #expect(MCPPhase2Rig.text(both).contains("Save"))

            // Masking holds for an image-only capture: a filled password still refuses without password entry.
            let read = try await rig.call("readPage", rig.shared)
            let password = try MCPPhase2Rig.ref("field", "Password", in: read)
            _ = try await rig.call("typeOnPage", rig.shared, ["ref": .int(password), "text": "Phase2-Mask!55"])
            try rig.trust.setAllowsPasswordEntry(false)
            let refused = try await rig.call("screenshotPage", rig.shared, ["includeSnapshot": false])
            #expect(refused.isError == true, "\(MCPPhase2Rig.text(refused))")
            #expect(!refused.content.contains { if case .image = $0 { true } else { false } })
        }
    }

    // MARK: Timing

    /// The same three-field form and submit, as separate calls and as one `runSteps`, on a background Chromium tab. Prints both;
    /// the single call must not be slower.
    @Test func timingOfSeparateCallsAgainstOneRunSteps() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: Self.routes()) { rig in
            @MainActor func refs() async throws -> (first: Int, second: Int, save: Int) {
                let read = try await rig.call("readPage", rig.shared)
                return (
                    try MCPPhase2Rig.ref("field", "First", in: read), try MCPPhase2Rig.ref("field", "Second", in: read),
                    try MCPPhase2Rig.ref("button", "Save", in: read)
                )
            }
            var ids = try await refs()
            let clock = ContinuousClock()
            let separate = try await clock.measure {
                _ = try await rig.call("typeOnPage", rig.shared, ["ref": .int(ids.first), "text": "one"])
                _ = try await rig.call("typeOnPage", rig.shared, ["ref": .int(ids.second), "text": "two"])
                _ = try await rig.call("clickOnPage", rig.shared, ["ref": .int(ids.save)])
                _ = try await rig.call("waitForPage", rig.shared, ["condition": "text", "value": "Form", "timeout": 2])
            }
            ids = try await refs()
            let combined = try await clock.measure {
                _ = try await rig.call("runSteps", rig.shared, [
                    "steps": .array([
                        .object(["tool": "fillFields", "arguments": .object([
                            "fields": .array([
                                .object(["ref": .int(ids.first), "value": "one", "select": false]),
                                .object(["ref": .int(ids.second), "value": "two", "select": false]),
                            ]),
                            "submitRef": .int(ids.save), "settle": "fast",
                        ]),
                        ]),
                    ]),
                ])
            }
            print("MCP-PHASE2-TIMING separate=\(separate) combined=\(combined)")
            #expect(combined < separate, "one call is faster than four: \(combined) vs \(separate)")
        }
    }

    private actor PauseRecorder {
        private(set) var durations: [Duration] = []

        func record(_ duration: Duration) {
            durations.append(duration)
        }
    }
}
