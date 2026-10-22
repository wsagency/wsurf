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

    /// Chromium reaches a subframe's world through an object of it, so a reply finds the frame that asked: the site guard
    /// (in the services world) holds an iframe's autoplay until its policy arrives, and under Allow the media then plays.
    @Test(.boundedWebViews)
    func subframePageWorldRepliesReachTheFrameThatAsked() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Top</title><iframe src='/child' width='300' height='150'></iframe>"),
            "/child": .html("<!doctype html><title>Child</title><audio id='media' src='/tone.wav' autoplay muted loop></audio>"),
            "/tone.wav": .bytes(Self.silentWAV(), contentType: "audio/wav"),
        ])
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let profile = Profile(id: UUID(), name: "Subframe page world", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let suite = AppDatabase.defaultsSuite("ChromiumSubframe-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = BrowserSettings(defaults: defaults)
        settings.autoplay = .allow
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("ChromiumSubframe-\(UUID().uuidString).json")
        SiteContentGuard.shared.install(in: page, permissions: SitePermissions(storageURL: storage), settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: storage)
        }

        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            var child: BrowserFrame?
            try #require(await waitUntil {
                child = try? await native.frames().first { !$0.isMainFrame && $0.request.url?.path == "/child" }
                return child != nil
            })
            let frame = try #require(child)
            #expect(try await page.callAsyncJavaScript(
                "return location.pathname + ':' + typeof globalThis.__wsurfSiteGuard;", in: frame, contentWorld: BrowserPage.servicesWorld
            ) as? String == "/child:object")
            #expect(await waitUntil {
                (try? await page.evaluateJavaScript(
                    "document.getElementById('media')?.paused === false", in: frame, contentWorld: .defaultClient
                )) as? Bool == true
            }, "the iframe's media stayed paused")
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }

    /// Half a second of 8 kHz mono 16-bit silence: playable media without a codec dependency.
    private static func silentWAV() -> Data {
        let bytes = 8_000
        var data = Data("RIFF".utf8)
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + bytes))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Data("data".utf8))
        append(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }

    /// A credential context minted before A→B→A must not survive the restore, and every context record kept for the
    /// restored frame must belong to the restored document. Page state surviving the step (`globalThis`, the loader ID)
    /// is the evidence that Chromium restored from its cache rather than reloading; without it the test fails rather
    /// than passing on an ordinary reload.
    @Test(.boundedWebViews)
    func cachedHistoryRestoreRejectsEarlierCredentialContextsAndKeepsOnlyRestoredContexts() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/first": .html("<!doctype html><title>First</title>"),
            "/second": .html("<!doctype html><title>Second</title>"),
        ])
        var components = try #require(URLComponents(url: try server.url("/first"), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let firstURL = try #require(components.url)
        components.path = "/second"
        let secondURL = try #require(components.url)
        let profile = Profile(id: UUID(), name: "Cache credential regression", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.close() }

        func pathname(inContext uniqueID: String) async throws -> String? {
            let record = try #require(native.devTools.contextsByUniqueID[uniqueID])
            let response = try await native.devTools.command("Runtime.evaluate", params: native.devTools.address(record).merging([
                "expression": "location.pathname", "returnByValue": true,
            ]) { $1 })
            return try native.devTools.runtimeValue(response) as? String
        }

        do {
            page.load(URLRequest(url: firstURL))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let firstFrame = try #require(try await native.frames().first(where: \.isMainFrame))
            let earlier = try await page.credentialContext(for: firstFrame, operation: .get)
            try await page.validateCredentialContext(earlier)
            _ = try await page.evaluateJavaScript(
                "globalThis.cachedMarker = 'first-document';", in: nil, contentWorld: .defaultClient
            )

            page.load(URLRequest(url: secondURL))
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let secondFrame = try #require(try await native.frames().first(where: \.isMainFrame))
            try #require(secondFrame.documentID != firstFrame.documentID)
            // A context of the second document, so a restore that relabels what it finds would show up below.
            let secondExecutionContext = try await native.devTools.executionContextIdentity(
                for: secondFrame, world: PageAutomationGuard.world
            )
            // The first document's context ended with the A→B turnover; this one is live right up to the back step.
            let second = try await page.credentialContext(for: secondFrame, operation: .get)
            try await page.validateCredentialContext(second)

            page.goBack()
            try #require(await PageSettle.untilIdle(page, timeout: .seconds(30)))
            let survived = try await page.evaluateJavaScript(
                "globalThis.cachedMarker", in: nil, contentWorld: .defaultClient
            ) as? String
            let restored = try #require(try await native.frames().first(where: \.isMainFrame))
            try #require(
                survived == "first-document" && restored.documentID == firstFrame.documentID,
                "Chromium did not restore from its back/forward cache, so this fixture proves nothing about it"
            )

            await #expect(throws: (any Error).self) { try await page.validateCredentialContext(earlier) }
            await #expect(throws: (any Error).self) { try await page.validateCredentialContext(second) }
            let records = native.devTools.contextsByUniqueID.values.filter { $0.frameID == restored.chromiumID }
            #expect(!records.isEmpty, "No context was kept for the restored frame, so the rebind was not exercised")
            for record in records {
                #expect(record.documentID == restored.documentID)
                #expect(try await pathname(inContext: record.uniqueID) == "/first")
            }
            #expect(!records.contains { $0.uniqueID == secondExecutionContext })

            let fresh = try await page.credentialContext(for: restored, operation: .get)
            try await page.validateCredentialContext(fresh)
            let freshExecutionContext = try await native.devTools.executionContextIdentity(
                for: restored, world: PageAutomationGuard.world
            )
            #expect(try await pathname(inContext: freshExecutionContext) == "/first")
            #expect(try await page.evaluateJavaScript(
                "location.pathname", in: restored, contentWorld: PageAutomationGuard.world
            ) as? String == "/first")
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }
}
