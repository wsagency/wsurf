// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// One shared tab on a loopback page, driven through `MCPBrowserSession.call` the way a client does, on either engine.
@MainActor
struct MCPFeedbackRig {
    let server: HTTPFixtureServer
    let browser: BrowserModel
    let tab: BrowserTab
    let session: MCPBrowserSession
    private let window: NSWindow

    /// A product page with enough text and links to be a realistic read (about 40 controls), and a button whose click
    /// changes a few things near it.
    static let shop: String = {
        let links = (1...24).map { "<li><a href='/p/\($0)'>Product number \($0)</a></li>" }.joined()
        let copy = (1...6).map { "<p>Paragraph \($0): trail shoes built for wet rock, mud and long days. Light, grippy and easy to clean.</p>" }.joined()
        return """
            <!doctype html><title>Shop</title>
            <header><a href='/'>Home</a> <a href='/products'>Products</a> <a id=cart href='/cart'>Cart (0)</a></header>
            <main><h1>Trail shoes</h1>\(copy)
            <label>Size <select id=size aria-label='Size'><option>40</option><option>41</option><option>42</option></select></label>
            <input id=note aria-label='Gift note' placeholder='Gift note'>
            <button id=add>Add to cart</button><div id=status role=status></div>
            <ul>\(links)</ul></main>
            <script>
              let count = 0;
              document.getElementById('add').addEventListener('click', () => {
                count += 1;
                document.getElementById('cart').textContent = 'Cart (' + count + ')';
                document.getElementById('status').textContent = 'Added to cart';
                if (!document.getElementById('checkout')) {
                  const b = document.createElement('button'); b.id = 'checkout'; b.textContent = 'Checkout';
                  document.getElementById('add').after(b);
                }
              });
            </script>
            """
    }()

    static func make(
        engine: BrowserEngine = .webKit, html: String = shop, routes extra: [String: HTTPFixtureServer.Response] = [:],
        access: MCPAccessConsent.Access = .control
    ) async throws -> MCPFeedbackRig {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html)].merging(extra) { $1 })
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPFeedback-\(UUID().uuidString).json"))
        let url = try server.url()
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: url)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        try #require(await waitUntil { tab.page.url == url && !tab.page.isLoading && tab.page.mainDocumentID != nil })
        #expect((tab.page.chromium != nil) == (engine == .chromium), "the tab runs on \(engine)")
        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: url)
        let session = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in access })
        return MCPFeedbackRig(server: server, browser: browser, tab: tab, session: session, window: window)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    @discardableResult
    func call(_ name: String, _ arguments: [String: Value] = [:], tab override: BrowserTab? = nil) async throws -> CallTool.Result {
        var arguments = arguments
        if !["requestAccess", "listTabs", "newTab"].contains(name) {
            arguments["tabID"] = .string((override ?? tab).id.uuidString)
        }
        return try await session.call(name: name, arguments: arguments)
    }

    /// Shares the tab and reads it, returning the first observation.
    func start(development: Bool = false) async throws -> CallTool.Result {
        try await call("requestAccess", development ? ["development": true] : [:])
        let read = try await call("readPage")
        #expect(read.isError == false, "\(Self.text(read))")
        return read
    }

    /// The ref of the first control of `kind` whose rendered line contains `label` in a `readPage` result.
    static func ref(of label: String, in read: CallTool.Result) throws -> Int {
        try ref(of: label, inText: try #require(read.structuredContent?.objectValue?["content"]?.stringValue))
    }

    static func ref(of label: String, inText content: String) throws -> Int {
        let line = try #require(
            content.split(separator: "\n").first { $0.hasPrefix("[") && $0.contains("\"\(label)\"") }, "no control “\(label)” in \(content)")
        return try #require(Int(line.dropFirst().prefix { $0 != "]" }))
    }

    static func text(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            guard case .text(let text, _, _) = $0 else { return nil }
            return text
        }.joined(separator: "\n")
    }

    static func images(_ result: CallTool.Result) -> [Data] {
        result.content.compactMap {
            guard case .image(let data, _, _, _) = $0 else { return nil }
            return Data(base64Encoded: data)
        }
    }

    static func object(_ result: CallTool.Result) -> [String: Value] {
        result.structuredContent?.objectValue ?? [:]
    }

    /// The `content` string a client receives: the tool's text inside the untrusted-content wrapper, unescaped.
    static func content(_ result: CallTool.Result) -> String {
        (object(result)["content"]?.stringValue ?? "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
