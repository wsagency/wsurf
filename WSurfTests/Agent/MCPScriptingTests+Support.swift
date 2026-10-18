// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A Developer-tier connection to a page on a loopback fixture server, for either engine: the page, the browser it is in, the
/// trust store that makes it a developer site in the Developer profile, and the session under test.
@MainActor
final class ScriptingRig {
    let server: HTTPFixtureServer
    let browser: BrowserModel
    let trust: MCPTrustStore
    let client: PairedClient
    let session: MCPBrowserSession
    let tab: BrowserTab
    private var windows: [NSWindow] = []

    init(
        server: HTTPFixtureServer, browser: BrowserModel, trust: MCPTrustStore, client: PairedClient, session: MCPBrowserSession,
        tab: BrowserTab
    ) {
        self.server = server
        self.browser = browser
        self.trust = trust
        self.client = client
        self.session = session
        self.tab = tab
    }

    /// Hosts the tab's page in a window, as the app does. A Chromium page loads only once a window holds it.
    func host() async {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        windows.append(window)
        let width = Int(container.bounds.width)
        #expect(
            await waitUntil {
                guard tab.page.superview === container else { return false }
                return (try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int == width
            }, "the page is laid out at the container's width")
    }

    /// Closes the tab and the window that held it. A Chromium browser stays alive until it is closed.
    func retire() async {
        browser.closeAllTabs(saving: false)
        await tab.waitForRetirement()
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows = []
    }

    // MARK: Calls

    func call(_ name: String, _ arguments: [String: Value] = [:], tab target: BrowserTab? = nil) async throws -> CallTool.Result {
        var arguments = arguments
        arguments["tabID"] = .string((target ?? tab).id.uuidString)
        return try await session.call(name: name, arguments: arguments)
    }

    /// `evaluateScript` on the tab.
    func run(_ source: String, world: String? = nil, timeoutMs: Int? = nil) async throws -> CallTool.Result {
        var arguments: [String: Value] = ["source": .string(source)]
        arguments["world"] = world.map { .string($0) }
        arguments["timeoutMs"] = timeoutMs.map { .int($0) }
        return try await call("evaluateScript", arguments)
    }

    /// `editDOM` on the tab with an operation and the rest of its arguments.
    func edit(_ op: String, _ arguments: [String: Value]) async throws -> CallTool.Result {
        try await call("editDOM", arguments.merging(["op": .string(op)]) { $1 })
    }

    /// What the page itself says, read outside the connection.
    func page(_ expression: String) async throws -> Any {
        try await tab.page.evaluateJavaScript(expression)
    }

    /// `findElements` on `selector`: the observation to pass back and the first match's ref.
    func find(_ selector: String) async throws -> (observation: String, ref: Int) {
        let found = try await call("findElements", ["selector": .string(selector)])
        #expect(found.isError == false, "\(found.allText)")
        let items = try #require(try Self.payload(found, prefix: "ELEMENTS:")["items"] as? [[String: Any]])
        return (
            try #require(found.fields["observationID"]?.stringValue),
            try #require(items.first?["r"] as? Int)
        )
    }

    /// The JSON a findElements / inspectElement result carries (`prefix` is `ELEMENTS:` or `ELEMENT:`), read back out of the
    /// untrusted-content wrapper the way a client does.
    static func payload(_ result: CallTool.Result, prefix: String) throws -> [String: Any] {
        let wrapped = try #require(result.fields["content"]?.stringValue)
        let unwrapped = wrapped
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let start = try #require(unwrapped.range(of: prefix + "\n"))
        let end = try #require(unwrapped.range(of: "\nobservationID: ", options: .backwards))
        let json = Data(unwrapped[start.upperBound..<end.lowerBound].utf8)
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }
}

extension ScriptingRig {
    /// A Developer-tier rig on `html`. `standing` is the level the paired app was set to; `paired` false leaves the connection
    /// unpaired, and `profile` is the profile chosen for developer work (nil chooses none).
    static func make(
        engine: BrowserEngine = .webKit, html: String, routes: [String: HTTPFixtureServer.Response] = [:],
        standing: PairedClient.Standing = .developer, paired: Bool = true, profile: UUID? = Profile.originalID,
        sheet: MCPAccessConsent.Access? = nil
    ) async throws -> ScriptingRig {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html)].merging(routes) { $1 })
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
        try trust.setStanding(standing, for: client.id)
        try trust.setDeveloperProfile(profile)
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPScripting-\(UUID().uuidString).json")))
        let address = try server.url()
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: address))
        }
        let session = MCPBrowserSession(browser: browser, trust: trust, available: { true }, consent: { _, _, _ in sheet })
        if paired {
            session.pairedClient = trust.client(id: client.id)
        }
        let tab = browser.newTab(url: address)
        let rig = ScriptingRig(server: server, browser: browser, trust: trust, client: client, session: session, tab: tab)
        if engine == .chromium {
            await rig.host()
        }
        #expect(tab.page.engine == engine)
        #expect(await PageSettle.untilIdle(tab.page))
        #expect(await waitUntil { tab.page.mainDocumentID != nil }, "the page registered its main document")
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: address)
        _ = try await session.call(name: "requestAccess", arguments: ["development": true, "developer": true])
        return rig
    }

    /// Runs `body` and retires the rig afterwards, also when it throws.
    static func with(
        engine: BrowserEngine = .webKit, html: String, routes: [String: HTTPFixtureServer.Response] = [:],
        standing: PairedClient.Standing = .developer, paired: Bool = true, profile: UUID? = Profile.originalID,
        sheet: MCPAccessConsent.Access? = nil, _ body: (ScriptingRig) async throws -> Void
    ) async throws {
        let rig = try await make(
            engine: engine, html: html, routes: routes, standing: standing, paired: paired, profile: profile, sheet: sheet)
        do {
            try await body(rig)
        } catch {
            await rig.retire()
            throw error
        }
        await rig.retire()
    }
}

nonisolated extension CallTool.Result {
    /// The text a client reads.
    var allText: String {
        content.compactMap {
            if case .text(let text, _, _) = $0 {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    var fields: [String: Value] {
        structuredContent?.objectValue ?? [:]
    }

    var status: String? {
        fields["status"]?.stringValue
    }
}
