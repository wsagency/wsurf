// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The Notification API a page sees is WSurf's, not WebKit's. What the page
/// is told about its permission has to match what the browser actually
/// stored, because that string is the whole gate: a page that believes it is
/// granted will go on to post.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct NotificationBridgeTests {
    private let origin = "https://notify.example"

    /// The same shim the pool installs, in a view of this test's own: the
    /// pool is only loaded with scripts once the app has bootstrapped.
    private func page(policy: PermissionPolicy) async -> (BrowserTab, BrowserPage) {
        let permissions = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("wsurf-notify-\(UUID().uuidString).json")
        )
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            configuration: configuration
        )
        let tab = BrowserTab(
            adopting: webView, opensBlank: false, sitePermissions: permissions
        )
        let page = tab.page
        permissions.set(policy, for: origin, .notifications)
        tab.permissions.pageChanged(url: URL(string: origin))
        NotificationBridge.shared.tabResolver = { candidate in
            guard tab.isMaterialised, tab.page === candidate else { return nil }
            return tab
        }
        NotificationBridge.shared.install(in: page)
        page.loadHTMLString(
            "<!doctype html><title>Notify</title><body>hi</body>",
            baseURL: URL(string: origin)
        )
        _ = await PageSettle.untilIdle(page, timeout: .seconds(10))
        await diagnose(page)
        return (tab, page)
    }
    private func diagnose(_ page: BrowserPage) async {
        let js = """
            (function () {
              var d = Object.getOwnPropertyDescriptor(window, 'Notification');
              return JSON.stringify({send: typeof globalThis.__wsurfSend,
                notify: typeof globalThis.__wsurfNotify,
                notification: typeof window.Notification,
                permission: window.Notification && window.Notification.permission,
                configurable: d && d.configurable, writable: d && d.writable,
                getter: d && typeof d.get, setter: d && typeof d.set,
                text: String(window.Notification).slice(0, 80)});
            })();
            """
        let state = (try? await page.evaluateJavaScript(js)) as? String ?? "<javascript-error>"
        let scripts = page.webKit?.configuration.userContentController.userScripts ?? []
        let registered = scripts.enumerated().map { index, script in
            let hasBridge = script.source.contains("WSurf message handler unavailable")
            let hasNotification = script.source.contains("WSurfNotification")
            let kind = hasBridge && hasNotification
                ? "notification-atomic"
                : hasNotification ? "notification"
                : hasBridge ? "bridge"
                : "other"
            return "\(index):\(kind):\(script.source.count):main=\(script.isForMainFrameOnly)"
        }.joined(separator: ",")
        print("[NotificationBridge diagnostics] js=\(state)")
        print("[NotificationBridge diagnostics] scripts=\(scripts.count) \(registered)")
    }

    private func permissionSeenByThePage(_ page: BrowserPage) async -> String? {
        var seen: String?
        _ = await waitUntil {
            seen = (try? await page.evaluateJavaScript("Notification.permission")) as? String
            return seen != nil && seen != "default"
        }
        return seen
    }
    @Test func thePageIsGivenWSurfsOwnNotificationApi() async {
        let (tab, webView) = await page(policy: .ask)
        defer { NotificationBridge.shared.tabResolver = nil; tab.detach() }

        let kind = (try? await webView.evaluateJavaScript("typeof Notification")) as? String
        let requester = (try? await webView.evaluateJavaScript(
            "typeof Notification.requestPermission"
        )) as? String

        #expect(kind == "function")
        #expect(requester == "function")
    }

    @Test func aWebsiteYouHaveAllowedIsToldItIsGranted() async {
        let (tab, webView) = await page(policy: .allow)
        defer { NotificationBridge.shared.tabResolver = nil; tab.detach() }

        #expect(await permissionSeenByThePage(webView) == "granted")
    }

    @Test func aWebsiteYouHaveRefusedIsToldSo() async {
        let (tab, webView) = await page(policy: .deny)
        defer { NotificationBridge.shared.tabResolver = nil; tab.detach() }

        #expect(await permissionSeenByThePage(webView) == "denied")
    }

    /// Until the person answers, the page is told nothing either way — the
    /// default that makes a well-behaved site ask rather than post.
    @Test func aWebsiteYouHaveNotAnsweredForIsToldNothingYet() async {
        let (tab, webView) = await page(policy: .ask)
        defer { NotificationBridge.shared.tabResolver = nil; tab.detach() }

        let seen = (try? await webView.evaluateJavaScript("Notification.permission")) as? String
        #expect(seen == "default")
    }

    /// A refused website asking again is answered from what was stored, with
    /// no prompt: the refusal is the answer.
    @Test func askingAgainAfterARefusalIsAnsweredWithoutAskingYou() async {
        let (tab, webView) = await page(policy: .deny)
        defer { NotificationBridge.shared.tabResolver = nil; tab.detach() }

        _ = try? await webView.evaluateJavaScript(
            "Notification.requestPermission().then(function (v) { window.__answer = v })"
        )

        var answer: String?
        let settled = await waitUntil {
            answer = (try? await webView.evaluateJavaScript("window.__answer")) as? String
            return answer != nil
        }

        #expect(settled)
        #expect(answer == "denied")
        #expect(tab.permissions.live.isEmpty, "a refusal never turns anything on")
    }

}
