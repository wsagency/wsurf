// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A browser window built the way `BrowserHost` builds one, ordered behind other windows and never made key, with the person's
/// own tab selected and `shared`, a page the connection holds with Control, parked out of sight on the shelf. Password entry
/// is allowed through an in-memory trust store. Used by the MCP v2 Phase 2 suites.
@MainActor
struct MCPPhase2Rig {
    let server: HTTPFixtureServer
    let browser: BrowserModel
    let window: NSWindow
    let trust: MCPTrustStore
    let session: MCPBrowserSession
    let owner: BrowserTab
    let shared: BrowserTab

    static func with(
        engine: BrowserEngine, routes: [String: HTTPFixtureServer.Response], path: String = "/",
        _ body: (MCPPhase2Rig) async throws -> Void
    ) async throws {
        var routes = routes
        routes["/mine"] = .html("<!doctype html><title>Mine</title><input aria-label=Note>")
        let server = try await HTTPFixtureServer.start(routes: routes)
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPPhase2-\(UUID().uuidString).json")))
        let url = try server.url(path)
        browser.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        window.contentView = root
        window.orderBack(nil)
        browser.context.extensions.register(browser: browser, window: window)
        let shared = browser.newTab(url: url)
        let container = WebViewContainer(page: shared.page)
        container.parksWhenIdle = true
        container.frame = root.bounds
        root.addSubview(container)
        try #require(await waitUntil { shared.page.url == url && !shared.page.isLoading && shared.page.mainDocumentID != nil })
        shared.assistantAccess.persistsAnswers = false
        shared.assistantAccess.pageChanged(url: url)
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true }, consent: { _, _, _ in .control }, openConsent: { _, _ in true })
        session.clientName = "Codex"
        session.grants[shared.id] = .init(origin: SitePermissions.origin(for: url), access: .control)
        let owner = browser.newTab(url: try server.url("/mine"))
        container.removeFromSuperview()
        try #require(shared.page.isParked)
        try #require(browser.activeTabID == owner.id)
        let rig = MCPPhase2Rig(server: server, browser: browser, window: window, trust: trust, session: session, owner: owner, shared: shared)
        defer { _ = server }
        do {
            try await body(rig)
        } catch {
            await rig.retire()
            throw error
        }
        await rig.retire()
    }

    private func retire() async {
        session.revoke()
        let tabs = browser.tabs
        browser.closeAllTabs(saving: false)
        for tab in tabs {
            await tab.waitForRetirement()
        }
        browser.context.extensions.unregister(browser: browser)
        window.contentView = nil
        window.close()
    }

    func call(_ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await session.call(name: name, arguments: arguments)
    }

    func js(_ script: String, in tab: BrowserTab? = nil) async -> Any? {
        try? await (tab ?? shared).page.evaluateJavaScript(script)
    }

    /// Every text block and the structured copy, so a test can prove a value appears nowhere in a reply.
    static func text(_ result: CallTool.Result) -> String {
        let blocks = result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }
        let structured = result.structuredContent.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? ""
        return (blocks + [structured]).joined(separator: "\n")
    }

    static func observation(_ result: CallTool.Result) throws -> String {
        try #require(result.structuredContent?.objectValue?["observationID"]?.stringValue, "\(text(result))")
    }

    /// The ref of the control `readPage` printed with `kind "label"`.
    static func ref(_ kind: String, _ label: String, in result: CallTool.Result) throws -> Int {
        let content = try #require(result.structuredContent?.objectValue?["content"]?.stringValue, "\(text(result))")
        let line = try #require(content.split(separator: "\n").first { $0.contains("\(kind) \"\(label)\"") }, "no \(kind) \(label) in \(content)")
        return try #require(Int(line.dropFirst().prefix { $0.isNumber }))
    }

    /// The page's centre of element `id`, in viewport CSS pixels.
    func centre(of id: String) async throws -> (x: Double, y: Double) {
        let box = try #require(
            await js("(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")
                as? [Double])
        return (box[0], box[1])
    }
}
