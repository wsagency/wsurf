// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Camera and microphone in a window of tabs, with WebKit's mock devices: no real device is used and no system permission is asked.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MediaCaptureTests {
    private static func mockCaptureWebView() throws -> WKWebView {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Key-value coding reaches the private `_setMockCaptureDevicesEnabled:` through this key.
        configuration.preferences.setValue(true, forKey: "mockCaptureDevicesEnabled")
        let webView = TabWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        try #require(webView.configuration.preferences.value(forKey: "mockCaptureDevicesEnabled") as? Bool == true)
        return webView
    }

    /// Asks for the microphone without waiting for the answer.
    private static func askForMicrophone(in page: BrowserPage) async throws {
        _ = try await page.evaluateJavaScript(
            "navigator.mediaDevices.getUserMedia({ audio: true }).then(s => { window.__mic = s; }); true"
        )
    }

    private static func isMicrophoneMuted(in page: BrowserPage) async throws -> Bool? {
        try await page.callAsyncJavaScript(
            "return window.__mic ? window.__mic.getAudioTracks()[0].muted : null;", in: nil, contentWorld: .page
        ) as? Bool
    }

    /// WebKit lets one page capture at a time and mutes the others, and it counts a tab WSurf keeps alive off screen (a favorite
    /// loading at launch, a parked tab) as visible. Granted at once, such a tab took the microphone from the tab in front, whose
    /// track went muted and silent: Meet's "muted by your system settings". It gets the microphone once it is shown.
    @Test func aTabOffScreenGetsTheMicrophoneOnlyOnceItIsShown() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/front": .html("<!doctype html><title>Front</title>"),
            "/back": .html("<!doctype html><title>Back</title>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let origin = SitePermissions.origin(for: try server.url("/front"))
        let store = SitePermissions(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaCapture-\(UUID().uuidString).json"))
        store.set(.allow, for: origin, .microphone)
        let model = BrowserModel(database: .temporary(), sitePermissions: store)
        let frontView = try Self.mockCaptureWebView()
        let backView = try Self.mockCaptureWebView()
        let front = model.newTab(activate: true, adopting: frontView)
        let back = model.newTab(activate: false, adopting: backView)
        try #require(model.activeTab === front)

        // Both pages in the window, as the active tab and a kept-alive one are.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        for tab in [back, front] {
            tab.page.frame = root.bounds
            tab.page.ignoresWindowOcclusion = true
            root.addSubview(tab.page)
        }
        window.orderBack(nil)
        defer {
            front.detach()
            back.detach()
            window.close()
        }
        _ = front.load(try server.url("/front"))
        _ = back.load(try server.url("/back"))
        try #require(await waitUntil {
            front.page.url?.path == "/front" && back.page.url?.path == "/back" && !front.page.isLoading && !back.page.isLoading
                && front.permissions.origin == origin && back.permissions.origin == origin
        })

        try await Self.askForMicrophone(in: front.page)
        try #require(await waitUntil { frontView.microphoneCaptureState == .active })

        try await Self.askForMicrophone(in: back.page)
        let backTookIt = await waitUntil(timeout: .seconds(2)) { backView.microphoneCaptureState != .none }
        #expect(!backTookIt, "a tab off screen got the microphone")
        #expect(frontView.microphoneCaptureState == .active)
        #expect(try await Self.isMicrophoneMuted(in: front.page) == false)

        model.activate(back)
        #expect(await waitUntil { backView.microphoneCaptureState == .active }, "a tab shown gets the microphone")
    }
}
