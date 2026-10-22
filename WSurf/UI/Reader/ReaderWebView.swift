// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI
import WebKit

/// Shows the article in one WebKit view, whichever engine the tab's page uses. The view is wrapped in a `BrowserPage` so that
/// printing and Find treat it like any page.
struct ReaderWebView: NSViewRepresentable {
    let session: ReaderSession
    let article: ReaderArticle
    /// The profile of the tab. Its data store is the view's, so a private tab's article loads its images privately.
    let profile: BrowserProfileContext
    let typeface: ReaderAppearance.Typeface
    let palette: ReaderAppearance.Palette
    let textSize: Int
    let onOpenLink: (URL, _ activate: Bool) -> Void

    func makeCoordinator() -> ReaderPageController {
        ReaderPageController()
    }

    func makeNSView(context: Context) -> BrowserPage {
        let webView = ReaderPageController.makeWebView(dataStore: profile.dataStore)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        let page = BrowserPage(webKit: webView, context: profile)
        session.presentedPage = page
        update(context.coordinator)
        return page
    }

    func updateNSView(_ page: BrowserPage, context: Context) {
        update(context.coordinator)
    }

    static func dismantleNSView(_ page: BrowserPage, coordinator: ReaderPageController) {
        if coordinator.session?.presentedPage === page {
            coordinator.session?.presentedPage = nil
        }
        coordinator.webView?.navigationDelegate = nil
        Task { await page.close() }
    }

    private func update(_ controller: ReaderPageController) {
        controller.session = session
        controller.onOpenLink = onOpenLink
        controller.show(article, appearance: .init(typeface: typeface, palette: palette, textSize: textSize))
    }
}

/// What Reader's view does with a navigation. Only the document Reader loads itself is allowed, once. A link is never followed in
/// this view; it is handed to the browser instead, and a link inside the article scrolls.
nonisolated enum ReaderNavigation {
    nonisolated enum Decision: Equatable {
        case allow
        case cancel
        case scroll(toFragment: String)
        /// Open `url` in a new tab, in front when `activate`.
        case open(URL, activate: Bool)

        /// The view itself navigates only for `allow`.
        var policy: WKNavigationActionPolicy {
            self == .allow ? .allow : .cancel
        }
    }

    private static let middleButton = 4

    static func decision(
        for url: URL?,
        type: WKNavigationType,
        inSubframe: Bool,
        article: URL?,
        acceptsFirstLoad: Bool,
        modifiers: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) -> Decision {
        guard !inSubframe else { return .cancel }
        if acceptsFirstLoad, type == .other {
            return .allow
        }
        guard type == .linkActivated, let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .cancel
        }
        if let article, let fragment = url.fragment(), !fragment.isEmpty,
           BrowserTab.withoutFragment(url.absoluteString) == BrowserTab.withoutFragment(article.absoluteString) {
            return .scroll(toFragment: fragment)
        }
        let inBackground = modifiers.contains(.command) || buttonNumber == middleButton
        return .open(url, activate: !inBackground || modifiers.contains(.shift))
    }
}

@MainActor
final class ReaderPageController: NSObject, WKNavigationDelegate {
    struct Appearance: Equatable {
        let typeface: ReaderAppearance.Typeface
        let palette: ReaderAppearance.Palette
        let textSize: Int
    }

    weak var webView: WKWebView?
    weak var session: ReaderSession?
    var onOpenLink: ((URL, Bool) -> Void)?

    private var article: ReaderArticle?
    private var appearance: Appearance?
    private(set) var isLoaded = false
    private var acceptsNextLoad = false

    /// A view that runs no JavaScript of the article's and plays nothing by itself. The article's HTML is untrusted: the page's
    /// content security policy is the second barrier, this is the first.
    static func makeWebView(dataStore: WKWebsiteDataStore) -> WKWebView {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func show(_ next: ReaderArticle, appearance nextAppearance: Appearance) {
        guard let webView else { return }
        if article != next {
            article = next
            appearance = nextAppearance
            isLoaded = false
            acceptsNextLoad = true
            let html = ReaderPage.html(
                for: next,
                typeface: nextAppearance.typeface,
                palette: nextAppearance.palette,
                textSize: nextAppearance.textSize
            )
            webView.loadHTMLString(html, baseURL: next.url)
            return
        }
        if appearance != nextAppearance {
            appearance = nextAppearance
            if isLoaded {
                applyAppearance()
            }
        }
    }

    /// Runs `script` in the view's own world. The page's JavaScript stays off; scripts WSurf runs itself are not the page's.
    private func run(_ script: String) {
        webView?.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: nil)
    }

    private func applyAppearance() {
        guard let appearance else { return }
        run(ReaderPage.appearanceScript(
            typeface: appearance.typeface,
            palette: appearance.palette,
            textSize: appearance.textSize
        ))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let decision = ReaderNavigation.decision(
            for: navigationAction.request.url,
            type: navigationAction.navigationType,
            inSubframe: navigationAction.targetFrame?.isMainFrame == false,
            article: article?.url,
            acceptsFirstLoad: acceptsNextLoad,
            modifiers: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber
        )
        decisionHandler(decision.policy)
        switch decision {
        case .allow:
            acceptsNextLoad = false
        case .cancel:
            break
        case .scroll(let fragment):
            scroll(toFragment: fragment)
        case .open(let url, let activate):
            onOpenLink?(url, activate)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        // A choice made while the page loaded.
        applyAppearance()
    }

    private func scroll(toFragment fragment: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [fragment], options: []),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        run("""
        (() => {
          const id = \(encoded)[0];
          const el = document.getElementById(id) || document.getElementsByName(id)[0];
          if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' });
        })()
        """)
    }
}
