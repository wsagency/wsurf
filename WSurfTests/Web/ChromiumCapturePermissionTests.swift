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

    /// What Chromium holds for an origin: camera, then microphone.
    private func settings(_ origin: String, in raw: UnsafeMutablePointer<cef_request_context_t>) -> [cef_content_setting_values_t] {
        ChromiumInterop.withString(origin) { url in
            [CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC].map {
                raw.pointee.get_content_setting?(raw, url, url, $0) ?? CEF_CONTENT_SETTING_VALUE_NUM_VALUES
            }
        }
    }

    /// An Allow taken back while the profile had no Chromium context is gone from the next context before its first
    /// document, though nothing could be written in between. Each context is an in-memory profile today (CEF refuses
    /// `Profiles/<id>`), which a new context on the same cache path shares while an earlier one lives, as here. A disk
    /// profile, which also keeps values across launches, is the next test.
    @Test(.boundedWebViews)
    func aNewContextCarriesNoGrantFromAnEarlierOne() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Capture</title>")])
        let elsewhere = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Elsewhere</title>")])
        defer { withExtendedLifetime((server, elsewhere)) {} }
        let url = try server.url("/")
        let origin = SitePermissions.origin(for: url)
        let context = BrowserProfileContext(profile: Profile(id: UUID(), name: "Capture", symbol: "globe", color: .gray))
        try ChromiumRuntime.shared.ensureInitialized()
        context.sitePermissions.set(.allow, for: origin, .camera)
        context.sitePermissions.set(.allow, for: origin, .microphone)
        let page = BrowserPage(chromium: ChromiumPage(context: context))
        let window = show(page)
        defer { window.close() }
        try await load(url, in: page)
        try await expect(page, "granted,granted")
        // Held, so Chromium keeps this profile as it was while the next context starts.
        let held = try ChromiumRuntime.shared.withContext(for: context) { raw in
            ChromiumInterop.retain(UnsafeMutableRawPointer(raw))
            return raw
        }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(held)) }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        #expect(!ChromiumRuntime.shared.hasContext(contextID: context.contextID))

        context.sitePermissions.set(.ask, for: origin, .camera)
        context.sitePermissions.set(.ask, for: origin, .microphone)
        #expect(settings(origin, in: held) == [CEF_CONTENT_SETTING_VALUE_ALLOW, CEF_CONTENT_SETTING_VALUE_ALLOW])

        let next = BrowserPage(chromium: ChromiumPage(context: context))
        window.contentView = next
        try await load(try elsewhere.url("/"), in: next)
        try ChromiumRuntime.shared.withContext(for: context) { raw in
            #expect(settings(origin, in: raw) == settings("https://untouched.test", in: raw))
        }
        try await load(url, in: next)
        try await expect(next, "prompt,prompt")
        await next.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }

    /// On a disk profile Chromium keeps a camera value in its preferences, for the exact origin, across launches, whoever
    /// wrote it (WSurf, Chromium's own prompt, a file edited outside); `clearCapturePreferences`, which the first write to
    /// each context runs, empties those lists.
    @Test func clearingTheCaptureValuesEmptiesADiskProfile() async throws {
        try ChromiumRuntime.shared.ensureInitialized()
        // A direct child of the root, which CEF makes a disk profile.
        let path = ChromiumRuntime.shared.rootDirectory.appendingPathComponent("Capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        var native = cef_request_context_settings_t()
        native.size = MemoryLayout<cef_request_context_settings_t>.stride
        ChromiumInterop.setString(path.path, to: &native.cache_path)
        defer { ccef_string_clear(&native.cache_path) }
        let raw = try #require(cef_request_context_create_context(&native, nil))
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(raw)) }
        let site = "https://kept.test"
        try #require(await waitUntil { ChromiumRuntime.clearCapturePreferences(raw) })
        let untouched = settings("https://untouched.test", in: raw)
        ChromiumInterop.withString(site) { url in
            for type in [CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC] {
                raw.pointee.set_content_setting?(raw, url, url, type, CEF_CONTENT_SETTING_VALUE_ALLOW)
            }
        }
        #expect(settings(site, in: raw) == [CEF_CONTENT_SETTING_VALUE_ALLOW, CEF_CONTENT_SETTING_VALUE_ALLOW])
        #expect(settings("https://other.kept.test", in: raw) == untouched)
        #expect(ChromiumRuntime.clearCapturePreferences(raw))
        #expect(settings(site, in: raw) == untouched)
    }

    private nonisolated final class MediaCallbackRecord: @unchecked Sendable {
        var continued: [UInt32] = []
        var cancelled = 0
    }

    private func mediaCallback(_ record: MediaCallbackRecord) -> UnsafeMutablePointer<cef_media_access_callback_t> {
        let callback = ChromiumInterop.allocate(cef_media_access_callback_t.self, owner: record)
        callback.pointee.cont = { me, allowed in
            ChromiumInterop.owner(MediaCallbackRecord.self, of: me.map(UnsafeMutableRawPointer.init))?.continued.append(allowed)
        }
        callback.pointee.cancel = { me in
            ChromiumInterop.owner(MediaCallbackRecord.self, of: me.map(UnsafeMutableRawPointer.init))?.cancelled += 1
        }
        return callback
    }

    /// A media request WSurf cannot decide, with no client behind its handler or no frame, is cancelled here, never left to
    /// Chromium, whose own value may say Allow.
    @Test func aMediaRequestNobodyCanDecideIsCancelled() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let client = ChromiumClient(page: ChromiumPage(context: context))
        client.makePermissionHandler()
        let handler = try #require(client.permissionPointer)
        defer { client.close() }
        let request = try #require(handler.pointee.on_request_media_access_permission)
        let microphone = UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue)

        let ownerless = MediaCallbackRecord()
        #expect(request(nil, nil, nil, nil, microphone, mediaCallback(ownerless)) == 1)
        #expect(ownerless.cancelled == 1 && ownerless.continued.isEmpty)

        // The handler's own client, but no frame to decide for.
        let pageless = MediaCallbackRecord()
        #expect(request(handler, nil, nil, nil, microphone, mediaCallback(pageless)) == 1)
        #expect(pageless.cancelled == 1 && pageless.continued.isEmpty)
        await context.endPrivateSession()
    }
}
