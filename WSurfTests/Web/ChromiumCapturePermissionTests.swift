// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Chromium answers `navigator.permissions.query` from its own permission state. Google Meet reads it and, while it says
/// `prompt`, waits for its own button, so WSurf's Allow has to reach that state. Queries only: no device is opened.
@MainActor
@Suite(.serialized)
struct ChromiumCapturePermissionTests {
    private static let query = """
        const state = async name => {
          try { return (await navigator.permissions.query({ name })).state; } catch (e) { return 'error:' + e.name; }
        };
        return (await state('camera')) + ',' + (await state('microphone'));
        """

    /// Camera, then microphone.
    private func expect(_ page: BrowserPage, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let state = try await page.callAsyncJavaScript(Self.query, in: nil, contentWorld: .page) as? String
        #expect(state == expected, sourceLocation: sourceLocation)
    }

    private func load(_ url: URL, in page: BrowserPage) async throws {
        page.load(URLRequest(url: url))
        try #require(await waitUntil { page.url == url && !page.isLoading })
    }

    private func show(_ page: BrowserPage) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        return window
    }

    @Test(.boundedWebViews)
    func aSiteSetToAllowReportsGrantedUntilTheAllowIsTaken() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Capture</title>"), "/again": .html("<!doctype html><title>Again</title>"),
        ])
        let otherServer = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Other</title>")])
        defer { withExtendedLifetime((server, otherServer)) {} }
        let url = try server.url("/")
        let againURL = try server.url("/again")
        let otherURL = try otherServer.url("/")
        let origin = SitePermissions.origin(for: url)
        let context = BrowserProfileContext(profile: Profile(id: UUID(), name: "Capture", symbol: "globe", color: .gray))
        let privateContext = BrowserProfileContext(profile: .privateBrowsing())
        try ChromiumRuntime.shared.ensureInitialized()
        let page = BrowserPage(chromium: ChromiumPage(context: context))
        let privatePage = BrowserPage(chromium: ChromiumPage(context: privateContext))
        let windows = [show(page), show(privatePage)]
        defer { windows.forEach { $0.close() } }

        context.sitePermissions.set(.allow, for: origin, .camera)
        context.sitePermissions.set(.allow, for: origin, .microphone)
        try await load(url, in: page)
        try await expect(page, "granted,granted")
        // Exact origin: the same host on another port was not allowed.
        try await load(otherURL, in: page)
        try await expect(page, "prompt,prompt")
        try await load(url, in: page)
        try await expect(page, "granted,granted")
        // A private window has a store of its own and is not allowed.
        try await load(url, in: privatePage)
        try await expect(privatePage, "prompt,prompt")

        // Taken back while the document is open: Ask reads prompt, Deny reads denied, without a reload.
        context.sitePermissions.set(.ask, for: origin, .camera)
        context.sitePermissions.set(.deny, for: origin, .microphone)
        try await expect(page, "prompt,denied")
        // The private window's own Allow does not reach the regular one.
        privateContext.sitePermissions.set(.allow, for: origin, .camera)
        privateContext.sitePermissions.set(.allow, for: origin, .microphone)
        try await expect(privatePage, "granted,granted")
        try await load(againURL, in: page)
        try await expect(page, "prompt,denied")

        // A grant Chromium still holds from an earlier run gives way to the store when a document loads.
        try ChromiumRuntime.shared.withContext(for: context) { raw in
            ChromiumInterop.withString(origin) { site in
                raw.pointee.set_content_setting?(raw, site, site, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, CEF_CONTENT_SETTING_VALUE_ALLOW)
            }
        }
        try await load(url, in: page)
        try await expect(page, "prompt,denied")

        // Clearing website data forgets the site's choices, and with them the grant.
        context.sitePermissions.set(.allow, for: origin, .camera)
        try await expect(page, "granted,denied")
        context.sitePermissions.removeEverything()
        try await expect(page, "prompt,prompt")

        await page.close()
        await privatePage.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        await privateContext.endPrivateSession()
    }
}
