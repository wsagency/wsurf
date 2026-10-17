// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Selector targeting, drag and key chords as an external client reaches them.
@MainActor
@Suite(.boundedWebViews)
struct MCPInputToolsTests {
    private static let html = """
        <!doctype html><title>Input fixture</title>
        <style>.box { position: fixed; bottom: 20px; width: 100px; height: 50px; border: 1px solid #000; }</style>
        <input aria-label="Email" data-testid="email">
        <input aria-label="Password" type="password" data-testid="password">
        <select aria-label="Plan" data-testid="plan"><option>Free</option><option>Pro</option></select>
        <label><input type="checkbox" data-testid="agree"> Agree</label>
        <button data-testid="save" onclick="document.body.dataset.saved = 'yes'">Save</button>
        <button data-test="a" onclick="document.body.dataset.a = 'yes'">Alpha</button>
        <button data-test-id="b" onclick="document.body.dataset.b = 'yes'">Beta</button>
        <button data-cy="c" onclick="document.body.dataset.c = 'yes'">Gamma</button>
        <button data-automation-id="d" onclick="document.body.dataset.d = 'yes'">Delta</button>
        <button class="twin" onclick="document.body.dataset.twin = 'yes'">One</button>
        <button class="twin" onclick="document.body.dataset.twin = 'yes'">Two</button>
        <button data-testid="hidden" style="display: none" onclick="document.body.dataset.hidden = 'yes'">Hidden</button>
        <input type="hidden" name="token" value="s3cret">
        <div id="note" data-testid="note">Just text</div>
        <div id="card" class="box" style="left: 20px" draggable="true" role="button" aria-label="Card" data-testid="card">Card</div>
        <div id="zone" class="box" style="left: 220px" role="button" aria-label="Zone" data-testid="zone">Zone</div>
        <div id="status" role="status"></div>
        <script>window.drops = [];
        document.getElementById('zone').addEventListener('dragover', e => e.preventDefault());
        document.getElementById('zone').addEventListener('drop', e => {
          window.drops.push('zone');
          document.getElementById('status').textContent = 'Dropped on zone';
        });</script>
        """

    /// The fixture server and the window that hosts the tab.
    @MainActor private final class Hosted {
        let server: HTTPFixtureServer
        let window: NSWindow

        init(server: HTTPFixtureServer, window: NSWindow) {
            self.server = server
            self.window = window
        }

        func url(_ path: String = "/") throws -> URL {
            try server.url(path)
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private func fixture(
        engine: BrowserEngine = .webKit, extra: [String: HTTPFixtureServer.Response] = [:]
    ) async throws -> (Hosted, BrowserModel, BrowserTab) {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.html)].merging(extra) { $1 })
        let permissions = SitePermissions(storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPInput-\(UUID().uuidString).json"))
        let url = try server.url()
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: url)
        #expect((tab.page.chromium != nil) == (engine == .chromium), "the tab runs on \(engine)")
        let window = show(tab)
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        return (Hosted(server: server, window: window), browser, tab)
    }

    /// Hosts the tab's page in a window the way the app does: a Chromium view loads only once it is attached.
    private func show(_ tab: BrowserTab) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        return window
    }

    private func session(_ browser: BrowserModel, access: MCPAccessConsent.Access = .development) -> MCPBrowserSession {
        MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in access })
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func call(_ session: MCPBrowserSession, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab {
            arguments["tabID"] = .string(tab.id.uuidString)
        }
        return try await session.call(name: name, arguments: arguments)
    }

    private func attribute(_ tab: BrowserTab, _ name: String) async -> String? {
        (try? await tab.page.evaluateJavaScript("document.body.dataset.\(name) || null")) as? String
    }

    /// The ref `readPage` gave the control labelled `label`, read from the structured reply.
    private func ref(of label: String, in read: CallTool.Result) throws -> Int {
        let content = try #require(read.structuredContent?.objectValue?["content"]?.stringValue, "\(text(read))")
        let line = try #require(content.components(separatedBy: "\n").first { $0.contains("\"\(label)\"") }, "\(content)")
        return try #require(Int(line.drop { $0 != "[" }.dropFirst().prefix { $0.isNumber }), "\(line)")
    }

    // MARK: The catalog

    @Test func selectorsAndModifiersAreOfferedOnlyWhereTheyApply() throws {
        let entries = Dictionary(uniqueKeysWithValues: MCPToolCatalog.entries.map { ($0.name, $0) })
        for name in ["clickOnPage", "typeOnPage", "selectOption", "setChecked", "hoverOnPage", "pressKey"] {
            let entry = try #require(entries[name])
            let parameters = Dictionary(uniqueKeysWithValues: entry.parameters.map { ($0.name, $0) })
            #expect(parameters["selector"]?.required == false, "\(name)")
            #expect(parameters["ref"]?.required == false, "\(name)")
            #expect(parameters["observationID"]?.required == false, "\(name)")
            #expect(entry.scope == .control, "\(name)")
            #expect(entry.parameters.filter(\.required).map(\.name).contains("tabID"))
            #expect(!(entry.parameters.filter(\.required).map(\.name).contains("ref")), "\(name) names its control by ref or selector")
        }
        let pressKey = try #require(entries["pressKey"])
        #expect(pressKey.parameters.contains { $0.name == "modifiers" })
        for name in ["fillFields", "scrollPage", "inspectControl", "readPage", "findElements", "inspectElement", "screenshotPage"] {
            #expect(!(entries[name]?.parameters.contains { $0.name == "selector" && $0.type == "string" && $0.description.contains("exactly one visible control") } ?? true), "\(name)")
        }
        for name in ["clickOnPage", "typeOnPage", "selectOption", "setChecked", "hoverOnPage"] {
            #expect(!(entries[name]?.parameters.contains { $0.name == "modifiers" } ?? true), "\(name)")
        }
        let drag = try #require(entries["dragOnPage"])
        #expect(drag.scope == .control)
        #expect(drag.usesRef == false, "a selector drag needs no observation")
        #expect(drag.parameters.filter(\.required).map(\.name) == ["tabID"])
        #expect(Set(drag.parameters.map(\.name)).isSuperset(of: ["ref", "selector", "toRef", "toSelector", "dx", "dy", "pointer", "observationID"]))
        #expect(MCPBrowserSession.actionTitle(forTool: "dragOnPage") == String(localized: "Drag on Page"))
        try drag.validate(["tabID": "x", "selector": "#a", "toSelector": "#b", "pointer": true])
        #expect(throws: (any Error).self) { try drag.validate(["tabID": "x", "dx": 9_999, "dy": 0]) }
        #expect(throws: (any Error).self) { try drag.validate(["tabID": "x", "pointer": "yes"]) }
    }

    @Test func aDragNamesOneSourceAndOneDestination() {
        func targets(_ arguments: [String: Value]) -> String? {
            if case .failure(let failed) = MCPBrowserSession.dragTargets(arguments) {
                return failed.message
            }
            return nil
        }
        #expect(targets(["ref": 1, "toRef": 2]) == nil)
        #expect(targets(["selector": "#a", "toSelector": "#b"]) == nil)
        #expect(targets(["selector": "#a", "dx": 10, "dy": -5]) == nil)
        #expect(targets(["ref": 1, "selector": "#a", "toRef": 2])?.contains("source") == true)
        #expect(targets(["toRef": 2])?.contains("source") == true)
        #expect(targets(["ref": 1])?.contains("destination") == true)
        #expect(targets(["ref": 1, "toRef": 2, "dx": 5, "dy": 5])?.contains("destination") == true)
        #expect(targets(["ref": 1, "dx": 5])?.contains("both dx and dy") == true)
        #expect(targets(["ref": 1, "dx": 0, "dy": 0])?.contains("cannot both be 0") == true)
    }

    // MARK: Selectors

    @Test(arguments: BrowserEngine.allCases)
    func aSelectorActsOnTheOnlyMatchingControl(engine: BrowserEngine) async throws {
        let (server, browser, tab) = try await fixture(engine: engine)
        defer { server.close() }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let click = try await call(subject, "clickOnPage", tab, ["selector": "[data-testid=save]"])
        #expect(click.isError == false, "\(text(click))")
        #expect(text(click).contains("Clicked"))
        #expect(await attribute(tab, "saved") == "yes")
        // The result carries the observation the next action can use, with no readPage in between.
        let structured = try #require(click.structuredContent?.objectValue)
        let observation = try #require(structured["observationID"]?.stringValue)
        let next = try await call(subject, "clickOnPage", tab, ["selector": "[data-test=a]", "observationID": .string(observation)])
        #expect(next.isError == false, "\(text(next))")
        #expect(await attribute(tab, "a") == "yes")
    }

    @Test(arguments: BrowserEngine.allCases)
    func testIDSelectorsWork(engine: BrowserEngine) async throws {
        let (server, browser, tab) = try await fixture(engine: engine)
        defer { server.close() }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        for (selector, name) in [("[data-test=a]", "a"), ("[data-test-id=b]", "b"), ("[data-cy=c]", "c"), ("[data-automation-id=d]", "d")] {
            let result = try await call(subject, "clickOnPage", tab, ["selector": .string(selector)])
            #expect(result.isError == false, "\(selector): \(text(result))")
            #expect(await attribute(tab, name) == "yes", "\(selector)")
        }
        let typed = try await call(subject, "typeOnPage", tab, ["selector": "[data-testid=email]", "text": "kris@example.test"])
        #expect(typed.isError == false, "\(text(typed))")
        #expect(try await tab.page.evaluateJavaScript("document.querySelector('[data-testid=email]').value") as? String == "kris@example.test")
        let chosen = try await call(subject, "selectOption", tab, ["selector": "[data-testid=plan]", "option": "Pro"])
        #expect(chosen.isError == false, "\(text(chosen))")
        #expect(try await tab.page.evaluateJavaScript("document.querySelector('[data-testid=plan]').value") as? String == "Pro")
        let checked = try await call(subject, "setChecked", tab, ["selector": "[data-testid=agree]", "checked": true])
        #expect(checked.isError == false, "\(text(checked))")
        #expect(try await tab.page.evaluateJavaScript("document.querySelector('[data-testid=agree]').checked") as? Bool == true)
    }

    @Test(arguments: BrowserEngine.allCases)
    func ambiguousMissingHiddenOrSensitiveSelectorsAreRefused(engine: BrowserEngine) async throws {
        let (server, browser, tab) = try await fixture(engine: engine)
        defer { server.close() }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        func refused(_ name: String, _ arguments: [String: Value], _ needle: String) async throws {
            let result = try await call(subject, name, tab, arguments)
            #expect(result.isError == true && text(result).contains(needle), "\(arguments): \(text(result))")
        }
        try await refused("clickOnPage", ["selector": ".twin"], "matches 2 controls")
        try await refused("clickOnPage", ["selector": "[data-testid=nothing]"], "No element matches")
        try await refused("clickOnPage", ["selector": "[data-testid=hidden]"], "none is a visible control")
        try await refused("clickOnPage", ["selector": "[data-testid=note]"], "none is a visible control")
        try await refused("clickOnPage", ["selector": "[data-testid=password]"], "sensitive")
        try await refused("typeOnPage", ["selector": "[data-testid=password]", "text": "hunter2"], "sensitive")
        try await refused("typeOnPage", ["selector": "[data-testid=save]", "text": "x"], "cannot use")
        try await refused("selectOption", ["selector": "[data-testid=email]", "option": "x"], "cannot use")
        try await refused("clickOnPage", ["selector": ""], "selector must be")
        try await refused("clickOnPage", ["selector": "[data-testid=save]", "ref": 1], "either ref or selector")
        try await refused("clickOnPage", [:], "ref from readPage or with a selector")
        for name in ["twin", "hidden", "saved"] {
            #expect(await attribute(tab, name) == nil, "\(name) was clicked")
        }
        #expect(try await tab.page.evaluateJavaScript("document.querySelector('[type=password]').value") as? String == "")
    }

    @Test func unsafeAttributeSelectorsAreRefused() async throws {
        let (server, browser, tab) = try await fixture()
        defer { server.close() }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        for selector in ["input[type=hidden][value^=s3]", "input[value='s3cret']", "[data-secret=x]", "a[href^=http]", "button:has([value])"] {
            let result = try await call(subject, "clickOnPage", tab, ["selector": .string(selector)])
            #expect(result.isError == true && text(result).contains("not exposed"), "\(selector): \(text(result))")
        }
        let invalid = try await call(subject, "clickOnPage", tab, ["selector": "button["])
        #expect(invalid.isError == true && text(invalid).contains("Invalid selector"), "\(text(invalid))")
    }

    @Test func selectorsNeedDevelopmentAccessAndRefsDoNot() async throws {
        let (server, browser, tab) = try await fixture()
        defer { server.close() }
        let subject = session(browser, access: .control)
        _ = try await call(subject, "requestAccess")
        let refused = try await call(subject, "clickOnPage", tab, ["selector": "[data-testid=save]"])
        #expect(refused.isError == true && text(refused).contains("development access"), "\(text(refused))")
        #expect(await attribute(tab, "saved") == nil)
        let read = try await call(subject, "readPage", tab)
        let observation = try #require(read.structuredContent?.objectValue?["observationID"]?.stringValue)
        let save = try ref(of: "Save", in: read)
        let clicked = try await call(subject, "clickOnPage", tab, ["observationID": .string(observation), "ref": .int(save)])
        #expect(clicked.isError == false, "\(text(clicked))")
        #expect(await attribute(tab, "saved") == "yes")
    }

    @Test func aSelectorIsResolvedInTheSharedPageOnly() async throws {
        let other = "<!doctype html><title>Other</title><button data-testid=\"save\" onclick=\"document.body.dataset.saved = 'other'\">Save elsewhere</button>"
            + "<button data-testid=\"only-other\" onclick=\"document.body.dataset.only = 'yes'\">Only here</button>"
        let (server, browser, tab) = try await fixture(extra: ["/other": .html(other)])
        defer { server.close() }
        let background = browser.newTab(url: try server.url("/other"), activate: false)
        #expect(await PageSettle.untilIdle(background.page))
        browser.activate(tab)
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        // The same selector acts in the shared tab; one that exists only in the other tab finds nothing.
        let own = try await call(subject, "clickOnPage", tab, ["selector": "[data-testid=save]"])
        #expect(own.isError == false, "\(text(own))")
        let foreign = try await call(subject, "clickOnPage", tab, ["selector": "[data-testid=only-other]"])
        #expect(foreign.isError == true && text(foreign).contains("No element matches"), "\(text(foreign))")
        let unshared = try await call(subject, "clickOnPage", background, ["selector": "[data-testid=only-other]"])
        #expect(unshared.isError == true, "an unshared tab cannot be addressed at all")
        #expect(await attribute(tab, "saved") == "yes")
        #expect(await attribute(background, "saved") == nil)
        #expect(await attribute(background, "only") == nil)
    }

    @Test func aSelectorInsideACrossOriginFrameFindsNothing() async throws {
        let framed = "<!doctype html><title>Framed</title><iframe src=\"data:text/html,%3Cbutton%20data-testid%3Dinner%3EInner%3C%2Fbutton%3E\"></iframe>"
        let (server, browser, tab) = try await fixture(extra: ["/framed": .html(framed)])
        defer { server.close() }
        _ = tab.load(try server.url("/framed"))
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.pageChanged(url: try server.url("/framed"))
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let result = try await call(subject, "clickOnPage", tab, ["selector": "[data-testid=inner]"])
        #expect(result.isError == true && text(result).contains("No element matches"), "\(text(result))")
    }

    // MARK: Chords

    @Test func chordsAreRefusedBeforeAnythingIsSentAndNeverCloseTabs() async throws {
        let (server, browser, tab) = try await fixture()
        defer { server.close() }
        let subject = session(browser, access: .control)
        _ = try await call(subject, "requestAccess")
        let read = try await call(subject, "readPage", tab)
        let observation = try #require(read.structuredContent?.objectValue?["observationID"]?.stringValue)
        let tabs = browser.tabs.count
        for (key, modifiers) in [("w", "command"), ("q", "command"), (",", "command"), ("t", "command"), ("v", "command"), ("w", "control"), ("Escape", "command+option")] {
            let result = try await call(subject, "pressKey", tab, ["observationID": .string(observation), "ref": 1, "key": .string(key), "modifiers": .string(modifiers)])
            #expect(result.isError == true && !text(result).contains("Sent "), "\(key) \(modifiers): \(text(result))")
        }
        let unknown = try await call(subject, "pressKey", tab, ["observationID": .string(observation), "ref": 1, "key": "Command+W"])
        #expect(unknown.isError == true, "\(text(unknown))")
        #expect(browser.tabs.count == tabs)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(!tab.isShowingSystemPage)
    }

    // MARK: Drag

    @Test func aDragByRefsNeedsOnlyControlAccessAndOneBySelectorNeedsDevelopment() async throws {
        let (server, browser, tab) = try await fixture()
        defer { server.close() }
        let subject = session(browser, access: .control)
        _ = try await call(subject, "requestAccess")
        let bySelector = try await call(subject, "dragOnPage", tab, ["selector": "#card", "toSelector": "#zone"])
        #expect(bySelector.isError == true && text(bySelector).contains("development access"), "\(text(bySelector))")
        let toSelector = try await call(subject, "dragOnPage", tab, ["selector": "#card", "toRef": 1])
        #expect(toSelector.isError == true, "\(text(toSelector))")
        #expect(try await tab.page.evaluateJavaScript("window.drops.length") as? Int == 0)

        let read = try await call(subject, "readPage", tab)
        let observation = try #require(read.structuredContent?.objectValue?["observationID"]?.stringValue)
        let dragged = try await call(subject, "dragOnPage", tab, ["observationID": .string(observation), "ref": .int(try ref(of: "Card", in: read)), "toRef": .int(try ref(of: "Zone", in: read))])
        #expect(dragged.isError == false, "\(text(dragged))")
        #expect(text(dragged).contains("Sent drag from"))
        #expect(try await tab.page.evaluateJavaScript("window.drops.length") as? Int == 1)
        // A ref needs the observation of the latest read; one from before it is stale.
        let stale = try await call(subject, "dragOnPage", tab, ["observationID": .string(observation), "ref": .int(try ref(of: "Card", in: read)), "toRef": .int(try ref(of: "Zone", in: read))])
        #expect(stale.isError == true, "the dragged page produced a newer observation")
    }

    @Test(arguments: BrowserEngine.allCases)
    func aDragReportsWhatItChangedAndFullRestoresTheSnapshot(engine: BrowserEngine) async throws {
        let (server, browser, tab) = try await fixture(engine: engine)
        defer { server.close() }
        let subject = session(browser, access: .control)
        _ = try await call(subject, "requestAccess")
        let read = try await call(subject, "readPage", tab)
        let card = try ref(of: "Card", in: read), zone = try ref(of: "Zone", in: read)
        let delta = try await call(subject, "dragOnPage", tab, ["ref": .int(card), "toRef": .int(zone)])
        #expect(delta.isError == false, "\(text(delta))")
        let reply = try #require(delta.structuredContent?.objectValue, "\(text(delta))")
        let content = try #require(reply["content"]?.stringValue)
        #expect(reply["status"]?.stringValue == "ok" && reply["action"]?.stringValue == "dragOnPage", "\(text(delta))")
        #expect(content.contains("Sent drag from") && content.contains("Dropped on zone"), "\(content)")
        #expect(!content.contains("PAGE TEXT:"), "a drag reports its changes, not the page: \(content)")
        #expect(reply["cost"]?.objectValue?["bytes"]?.intValue != nil, "\(text(delta))")

        let full = try await call(subject, "dragOnPage", tab, ["ref": .int(card), "toRef": .int(zone), "result": "full"])
        #expect(full.isError == false, "\(text(full))")
        let snapshot = try #require(full.structuredContent?.objectValue?["content"]?.stringValue, "\(text(full))")
        #expect(snapshot.contains("Sent drag from") && snapshot.contains("PAGE TEXT:"), "\(snapshot)")
        #expect(try await tab.page.evaluateJavaScript("window.drops.length") as? Int == 2)
    }

    @Test(arguments: BrowserEngine.allCases)
    func aDragBySelectorWorksWithDevelopmentAccessAndNoRead(engine: BrowserEngine) async throws {
        let (server, browser, tab) = try await fixture(engine: engine)
        defer { server.close() }
        let subject = session(browser)
        _ = try await call(subject, "requestAccess", nil, ["development": true])
        let result = try await call(subject, "dragOnPage", tab, ["selector": "[data-testid=card]", "toSelector": "[data-testid=zone]"])
        #expect(result.isError == false, "\(text(result))")
        #expect(try await tab.page.evaluateJavaScript("window.drops.length") as? Int == 1)
        let offset = try await call(subject, "dragOnPage", tab, ["selector": "#card", "dx": 200, "dy": 0])
        #expect(offset.isError == false, "\(text(offset))")
        #expect(try await tab.page.evaluateJavaScript("window.drops.length") as? Int == 2)
        let incomplete = try await call(subject, "dragOnPage", tab, ["selector": "#card"])
        #expect(incomplete.isError == true && text(incomplete).contains("destination"))
    }
}
