// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageActivityMonitorTests {
    private func loadedTab() async -> BrowserTab {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = TabWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            configuration: configuration
        )
        let permissions = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("PageActivityPermissions-\(UUID().uuidString).json")
        )
        let tab = BrowserTab(
            adopting: webView,
            opensBlank: false,
            sitePermissions: permissions
        )
        tab.loadHTML(
            """
            <!doctype html>
            <form id="profile">
              <input id="name" value="Ada">
              <button>Save</button>
            </form>
            """,
            baseURL: URL(string: "https://example.com/profile")
        )
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        return tab
    }

    @Test func editingAndResettingAFormUpdatesProtection() async throws {
        let tab = await loadedTab()

        try await tab.page.evaluateJavaScript(
            """
            const field = document.getElementById('name');
            field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
            field.value = 'Grace';
            field.dispatchEvent(new Event('input', { bubbles: true }));
            """
        )
        #expect(await waitUntil { tab.hasEditedForm })
        #expect(tab.hasEditedForm)
        #expect(!tab.canDiscardWebContent)

        try await tab.page.evaluateJavaScript("document.getElementById('profile').reset()")
        #expect(await waitUntil { !tab.hasEditedForm })
        #expect(!tab.hasEditedForm)
    }

    @Test func returningAFieldToItsOriginalValueClearsProtection() async throws {
        let tab = await loadedTab()

        try await tab.page.evaluateJavaScript(
            """
            const field = document.getElementById('name');
            field.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
            field.value = 'Grace';
            field.dispatchEvent(new Event('input', { bubbles: true }));
            """
        )
        #expect(await waitUntil { tab.hasEditedForm })

        try await tab.page.evaluateJavaScript(
            """
            const restoredField = document.getElementById('name');
            restoredField.value = 'Ada';
            restoredField.dispatchEvent(new Event('input', { bubbles: true }));
            """
        )
        #expect(await waitUntil { !tab.hasEditedForm })
        #expect(!tab.hasEditedForm)
    }

    /// Stands in for WebKit's own display capture state, which only a real screen share (and its TCC prompt) can set.
    private final class CapturingWebView: WKWebView {
        var state = WKMediaCaptureState.none

        @objc(_displayCaptureState) var displayCaptureState: Int {
            state.rawValue
        }

        func report(_ next: WKMediaCaptureState) {
            willChangeValue(forKey: "_displayCaptureState")
            state = next
            didChangeValue(forKey: "_displayCaptureState")
        }
    }

    /// WebKit pages keep their own `getDisplayMedia`: the tab learns about screen sharing from WebKit instead.
    @Test func webKitsDisplayCaptureStateProtectsTheTab() async throws {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CapturingWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        let tab = BrowserTab(adopting: webView, opensBlank: false)
        tab.loadHTML("<!doctype html><p>Call</p>", baseURL: URL(string: "https://example.com/call"))
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        let displayMedia = try await tab.page.evaluateJavaScript("""
            (() => {
              const open = navigator.mediaDevices?.getDisplayMedia;
              return typeof open === 'function' ? String(Function.prototype.toString.call(open).includes('[native code]')) : typeof open;
            })()
            """)
        #expect(displayMedia as? String == "true")
        #expect(!tab.processState.isSharingScreen)

        webView.report(.active)
        #expect(tab.processState.isSharingScreen)
        #expect(!tab.canDiscardWebContent)

        webView.report(.muted)
        #expect(tab.processState.isSharingScreen, "a paused share is still a share")

        webView.report(.none)
        #expect(!tab.processState.isSharingScreen)
    }
}
