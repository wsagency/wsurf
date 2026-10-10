// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized)
struct ChromiumPageTests {
    @Test(.boundedWebViews)
    func cachedHistoryRestoresIsolatedWorldAndMessages() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/first": .html("<h1>First fixture</h1><iframe src='/child'></iframe>"),
            "/second": .html("<h1>Second fixture</h1>"),
            "/child": .html("<h2>Child fixture</h2>"),
        ])
        let firstURL = try server.url("/first")
        let secondURL = try server.url("/second")
        let profile = Profile(id: UUID(), name: "Cache regression", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let world = WKContentWorld.defaultClient
        let messageWorld = WKContentWorld.world(name: "WSurfCacheRegression")
        var messages: [BrowserScriptMessage] = []
        var committedURL: URL?
        page.onNavigationCommitted = { [weak page] _ in committedURL = page?.url }
        page.addScriptMessageHandler(name: "cacheEcho", in: messageWorld) { messages.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.close() }

        do {
            page.load(URLRequest(url: firstURL))
            try #require(await waitUntil { committedURL == firstURL && !page.isLoading })
            let firstFrame = try #require(try await native.frames().first(where: \.isMainFrame))
            _ = try await page.evaluateJavaScript(
                "globalThis.savedCacheValue = 'cached-first';", in: nil, contentWorld: world
            )
            _ = try await page.evaluateJavaScript(
                "__wsurfSend('cacheEcho', 'before');", in: nil, contentWorld: messageWorld
            )
            try #require(await waitUntil { messages.last?.body as? String == "before" })

            page.load(URLRequest(url: secondURL))
            try #require(await waitUntil { committedURL == secondURL && !page.isLoading })
            let secondFrame = try #require(try await native.frames().first(where: \.isMainFrame))
            _ = try await page.evaluateJavaScript(
                "globalThis.savedCacheValue = 'cached-second';", in: nil, contentWorld: world
            )

            committedURL = nil
            page.goBack()
            try #require(await waitUntil { committedURL == firstURL })
            let restored = try await page.evaluateJavaScript(
                "globalThis.savedCacheValue", in: nil, contentWorld: world
            ) as? String
            #expect(restored == "cached-first")
            #expect(try await native.isLive(frame: firstFrame))
            #expect(try await native.isLive(frame: secondFrame) == false)
            _ = try await page.evaluateJavaScript(
                "__wsurfSend('cacheEcho', 'after');", in: nil, contentWorld: messageWorld
            )
            try #require(await waitUntil { messages.last?.body as? String == "after" })
            #expect(messages.last?.frameInfo.documentID == firstFrame.documentID)
            #expect(!page.isLoading)

            try #require(page.canGoForward)
            committedURL = nil
            try #require(page.goForward() != nil)
            try #require(await waitUntil { committedURL == secondURL && !page.isLoading })
            let forwarded = try await page.evaluateJavaScript(
                "globalThis.savedCacheValue", in: nil, contentWorld: world
            ) as? String
            #expect(forwarded == "cached-second")
            #expect(try await native.isLive(frame: firstFrame) == false)
            #expect(try await native.isLive(frame: secondFrame))
            #expect(page.canGoBack)
            #expect(!page.canGoForward)
            _ = try await page.evaluateJavaScript(
                "__wsurfSend('cacheEcho', 'after-forward');", in: nil, contentWorld: messageWorld
            )
            try #require(await waitUntil { messages.last?.body as? String == "after-forward" })
            #expect(messages.last?.frameInfo.documentID == secondFrame.documentID)
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }
}
