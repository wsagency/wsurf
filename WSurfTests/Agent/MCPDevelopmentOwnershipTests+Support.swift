// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// Hosting, fixture lifetime and the reading helpers of `MCPDevelopmentOwnershipTests`.
extension MCPDevelopmentOwnershipTests {
    /// Runs `body` on a fixture for `engine` and retires the tab afterwards: a Chromium browser stays alive until it is closed.
    func withFixture(
        engine: BrowserEngine, html: String = MCPDevelopmentOwnershipTests.page,
        routes: [String: HTTPFixtureServer.Response] = [:], host: String? = nil,
        _ body: (HTTPFixtureServer, BrowserModel, BrowserTab) async throws -> Void
    ) async throws {
        let (server, browser, tab) = try await fixture(html: html, routes: routes, engine: engine, host: host)
        defer { _ = server }
        do {
            try await body(server, browser, tab)
        } catch {
            await retire(browser, tab)
            throw error
        }
        await retire(browser, tab)
    }

    private func retire(_ browser: BrowserModel, _ tab: BrowserTab) async {
        browser.closeAllTabs(saving: false)
        await tab.waitForRetirement()
        for window in hosting.windows.values {
            hide(window)
        }
        hosting.windows.removeAll()
    }

    // MARK: Consumer helpers

    func text(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            if case .text(let text, _, _) = $0 {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    func images(_ result: CallTool.Result) -> [Data] {
        result.content.compactMap {
            if case .image(let data, _, _, _) = $0 {
                return Data(base64Encoded: data)
            }
            return nil
        }
    }

    /// The `content` string a client receives for a page tool: the tool's own text inside the untrusted-content wrapper.
    func content(_ result: CallTool.Result) throws -> String {
        try #require(result.structuredContent?.objectValue?["content"]?.stringValue)
    }

    /// The JSON a findElements / inspectElement result carries (`prefix` is `ELEMENTS:` or `ELEMENT:`), read back out of the
    /// wrapper the way a client does.
    func payload(_ result: CallTool.Result, prefix: String) throws -> [String: Any] {
        let unwrapped = try content(result)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let start = try #require(unwrapped.range(of: prefix + "\n"))
        let end = try #require(unwrapped.range(of: "\nobservationID: ", options: .backwards))
        let json = Data(unwrapped[start.upperBound..<end.lowerBound].utf8)
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    func requestDevelopment(_ subject: MCPBrowserSession) async throws {
        _ = try await call(subject, "requestAccess", nil, ["development": true])
    }

    /// findElements on `selector`: the observation to pass back and the first match's ref.
    func find(_ subject: MCPBrowserSession, _ tab: BrowserTab, _ selector: String) async throws -> (observation: String, ref: Int) {
        let found = try await call(subject, "findElements", tab, ["selector": .string(selector)])
        #expect(found.isError == false, "\(text(found))")
        let items = try #require(try payload(found, prefix: "ELEMENTS:")["items"] as? [[String: Any]])
        return (
            try #require(found.structuredContent?.objectValue?["observationID"]?.stringValue),
            try #require(items.first?["r"] as? Int)
        )
    }

    func screenshot(_ subject: MCPBrowserSession, _ tab: BrowserTab, _ target: (observation: String, ref: Int)) async throws -> CallTool.Result {
        try await call(subject, "screenshotPage", tab, ["observationID": .string(target.observation), "ref": .int(target.ref)])
    }

    /// Hosts the tab's page in a window the way the app does, inside a `WebViewContainer`. Element screenshots need a laid-out,
    /// attached view, and the container is what lays out a development viewport: a page outside one cannot be resized.
    /// Returns once the page has the container's width, not the 800-point default of a page nobody hosts.
    func show(_ tab: BrowserTab) async -> NSWindow {
        if let hosted = hosting.windows[tab.id] {
            return hosted
        }
        let forward = Self.foreground && tab.page.engine == .chromium
        let window = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: forward ? [.titled, .closable] : [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = WebViewContainer(page: tab.page)
        window.contentView = container
        window.orderBack(nil)
        hosting.windows[tab.id] = window
        if forward {
            window.title = "WSurf development verification"
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Activation can take several seconds, or be refused; the resize check below is what the tests depend on.
            _ = await waitUntil(timeout: .seconds(8)) { NSApp.isActive && window.isKeyWindow }
        }
        let width = Int(container.bounds.width)
        #expect(
            await waitUntil {
                guard tab.page.superview === container else { return false }
                return (try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int == width
            }, "the page is laid out at the container's width \(width)")
        if forward {
            await confirmResizesReachThePage(tab, restoring: width)
        }
        return window
    }

    /// A page that has never been resized may ignore its first resize; one resize and its undo, awaited, tell the tests that follow
    /// whether Chromium applies resizes at all in this session.
    private func confirmResizesReachThePage(_ tab: BrowserTab, restoring width: Int) async {
        @MainActor func innerWidth() async -> Int? {
            (try? await tab.page.evaluateJavaScript("window.innerWidth")) as? Int
        }
        tab.page.developmentViewport = CGSize(width: 401, height: 401)
        #expect(await waitUntil(timeout: .seconds(30)) { await innerWidth() == 401 }, "Chromium applies a resize to the hosted page")
        tab.page.developmentViewport = nil
        #expect(await waitUntil { await innerWidth() == width }, "the resize is undone")
    }

    func hide(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }
}
