// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

/// Reads a watched page in a hidden WebKit view that is made for one reading and closed after it. The view is not a tab: it is
/// never shown, and no extension, connected app or assistant sees it. A watch reads without the person's sign-ins unless they
/// chose theirs for that watch. Sites set to Chromium are read with WebKit too: a hidden Chromium page needs a window.
@MainActor
enum PageWatchReader {
    /// Shared by every profile's center, so WSurf reads one watched page at a time.
    static let queue = PageWatchQueue()
    /// Hidden views open right now. One reading at a time keeps this at most one.
    private(set) static var openViews = 0

    static let webKitNote: LocalizedStringResource = "Watches read this page with WebKit. Your Chromium sign-ins are not used."

    private static let loadCeiling: Duration = .seconds(15)
    private static let quietCeiling: Duration = .seconds(2)
    private static let pressureHold: TimeInterval = 600
    private static var pressureUntil: Date?
    private static let pressure: MemoryPressureMonitor = {
        let monitor = MemoryPressureMonitor()
        monitor.onPressure = { level in
            if level == .critical {
                pressureUntil = Date() + pressureHold
            }
        }
        monitor.start()
        return monitor
    }()

    static func canWatch(_ url: URL) -> Bool {
        LinkPeekLoader.canPeek(url)
    }

    /// The site is set to Chromium, so its tabs use Chromium's sign-ins, which a watch cannot.
    static func readsWithWebKitInstead(_ url: URL, permissions: SitePermissions) -> Bool {
        permissions.engine(for: SitePermissions.origin(for: url)) == .chromium
    }

    /// Low Power Mode, or critical memory pressure in the last ten minutes. Scheduled checks wait; they are not failures.
    static var holdsReadings: Bool {
        _ = pressure
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }
        return pressureUntil.map { Date() < $0 } ?? false
    }

    static func read(_ watch: PageWatch, in context: BrowserProfileContext) async -> PageWatchReading? {
        guard canWatch(watch.url) else { return nil }
        await context.contentBlocker.waitForPendingCompilation()
        guard !Task.isCancelled else { return nil }
        let refusals = PageWatchRefusals()
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 720),
            configuration: configuration(for: watch.access, context: context)
        )
        context.settings.apply(to: view)
        view.customUserAgent = WebViewPool.safariUserAgent
        view.navigationDelegate = refusals
        view.uiDelegate = refusals
        let page = BrowserPage(webKit: view, context: context)
        openViews += 1
        let reading = await read(watch.url, in: page)
        await page.close()
        openViews -= 1
        return withExtendedLifetime(refusals) { reading }
    }

    static func configuration(for access: PageWatch.Access, context: BrowserProfileContext) -> WKWebViewConfiguration {
        let configuration = WebViewPool.makeConfiguration()
        // A new, empty store for every anonymous reading: no cookie or storage of the profile, nothing kept between readings.
        configuration.websiteDataStore = access == .signedIn ? context.dataStore : .nonPersistent()
        context.settings.apply(to: configuration)
        context.contentBlocker.apply(to: configuration.userContentController)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.inactiveSchedulingPolicy = .none
        return configuration
    }

    private static func read(_ url: URL, in page: BrowserPage) async -> PageWatchReading? {
        page.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        await PageSettle.untilIdle(page, timeout: loadCeiling)
        await PageSettle.untilQuiet(page, ceiling: quietCeiling)
        guard !Task.isCancelled, let landed = page.url, canWatch(landed),
              let value = try? await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String,
              page.url == landed,
              let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
              object["challenge"] as? Bool != true
        else { return nil }
        return PageWatchReading(
            title: object["title"] as? String ?? "",
            text: String((object["text"] as? String ?? "").prefix(PageWatch.snapshotLimit)),
            url: landed
        )
    }

    /// Runs in its own world, so the page's scripts cannot change what it returns.
    private static let script = #"""
    (() => {
      const root = document.querySelector('article')
        || document.querySelector('main')
        || document.querySelector('[role="main"]')
        || document.body;
      const lines = node => (node ? node.innerText : '')
        .split('\n')
        .map(line => line.replace(/\s+/g, ' ').trim())
        .filter(line => line.length > 0);
      let text = lines(root);
      if (text.join(' ').length < 240) text = lines(document.body);
      const challenge = !!document.querySelector(
        '#challenge-form, #challenge-running, #cf-challenge-running, .cf-browser-verification, [name="cf-turnstile-response"]'
      );
      return JSON.stringify({
        title: (document.title || '').replace(/\s+/g, ' ').trim(),
        text: text.join('\n').slice(0, 6000),
        challenge: challenge
      });
    })()
    """#
}

/// The hidden view asks nobody anything: no pop-ups, downloads, other apps, permission prompts, dialogs or file pickers.
@MainActor
final class PageWatchRefusals: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let webSchemes: Set<String> = ["http", "https"]
    private static let embeddedSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

    static func allows(_ url: URL?, inMainFrame: Bool) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return (inMainFrame ? webSchemes : embeddedSchemes).contains(scheme)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let inMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = !navigationAction.shouldPerformDownload
            && Self.allows(navigationAction.request.url, inMainFrame: inMainFrame)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }

    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        .deny
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        false
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        nil
    }
}

// MARK: - Live

extension PageWatchCenter {
    /// The center of a regular profile. It keeps its file and runs its schedule only in the copy of WSurf that owns the session,
    /// never in tests. A watch on a site whose assistant access is Deny is never read, and one set to Deny later stops. Pages are
    /// judged on this Mac only; a notice WSurf may not show is kept for the Watches tab.
    static func live(for context: BrowserProfileContext) -> PageWatchCenter {
        let persists = !context.profile.isPrivate && !AppDatabase.isRunningTests && AppDatabase.ownsSession
        let permissions = context.sitePermissions
        let profileID = context.profile.id
        let link = PageWatchCenterLink()
        let center = PageWatchCenter(
            file: persists ? context.profile.pageWatchesFile : nil,
            schedules: persists,
            queue: PageWatchReader.queue,
            fetch: { [weak context] watch in
                guard let context else { return nil }
                return await PageWatchReader.read(watch, in: context)
            },
            judge: { watch, reading in await PageWatchJudge.judge(watch, reading: reading) },
            classify: { _, pair in await PageWatchJudge.classify(pair) },
            // A change can always be told from the text; a condition without the on-device model is refused before it starts.
            canJudge: { true },
            notify: { watch, notice in
                Task { @MainActor in
                    let shown = await NotificationBridge.shared.announce(watch, notice, profileID: profileID)
                    if !shown {
                        link.center?.noteMissed(watch, notice)
                    }
                }
            },
            allows: { url in permissions.assistantAccess(for: SitePermissions.origin(for: url)) != .deny },
            canRead: { !PageWatchReader.holdsReadings }
        )
        link.center = center
        return center
    }
}

/// Lets the live notice closure reach the center it was made for without keeping it alive.
private final class PageWatchCenterLink {
    weak var center: PageWatchCenter?
}

extension Profile {
    var pageWatchesFile: URL {
        supportDirectory.appendingPathComponent("PageWatches.json")
    }
}
