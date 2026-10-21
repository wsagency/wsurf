// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

extension BrowserTab {
    func refreshCanvas(from page: BrowserPage) {
        canvasColor = isShowingRealPage && hasPresentedContent
            ? page.underPageBackgroundColor
            : nil
    }

    func documentFilename(for url: URL?) -> String? {
        url.flatMap { documentTitles[Self.documentURL($0)] }
    }

    func noteMainFrameResponse(_ response: URLResponse) {
        guard let url = response.url.map(Self.documentURL) else { return }
        if response.mimeType?.lowercased() == "application/pdf",
           let filename = response.suggestedFilename, !filename.isEmpty {
            documentTitles[url] = filename
        } else {
            documentTitles[url] = nil
        }
    }

    private static func documentURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    func refreshChrome() {
        isLoading = page.isLoading && isShowingRealPage && !stoppedNavigation
        canGoBackInWeb = page.canGoBack
        canGoForwardInWeb = page.canGoForward
        let displaced = committedURL
        committedURL = page.backForwardList.currentItem?.url
        let url = page.url
        if url?.absoluteString == "about:blank" {
            urlString = ""
            title = SystemPages.startTitle
            favicon = nil
        } else if let page = InternalPage(url: url) {
            urlString = url?.absoluteString ?? page.url.absoluteString
            title = page.title
            favicon = nil
        } else if SystemPages.isStart(url) {
            // Do not replace the title of a failed navigation still covering the start page.
            let leftOwnPage = InternalPage(url: URL(string: urlString)) != nil
            if urlString.isEmpty || leftOwnPage || (displaced != nil && displaced != committedURL) {
                urlString = ""
                title = SystemPages.startTitle
                favicon = nil
            }
        } else {
            if let url, !(isShowingError && page.chromium?.htmlDocumentURL == url) {
                urlString = url.absoluteString
            }
            if let pageTitle = page.title, !pageTitle.isEmpty {
                title = pageTitle
            } else if isShowingRealPage, extensionBaseURL == nil, !isRestoring {
                title = documentFilename(for: url) ?? Self.placeholderTitle
            }
        }
        refreshSecurity()
        refreshCanvas(from: page)
    }

    func refreshSecurity() {
        guard !isShowingError, let scheme = page.url?.scheme else {
            security = .none
            return
        }
        switch scheme {
        case "https":
            if page.isLoading {
                security = .pending
            } else {
                security = page.hasOnlySecureContent ? .secure : .mixed
            }
        case "http":
            security = .insecure
        default:
            security = .none
        }
    }

    func declaredFaviconChanged() {
        guard extensionBaseURL == nil, !isPrivate, !isShowingSystemPage else { return }
        guard let host = page.url?.host()?.lowercased() else { return }
        context.favicons.forget(host: host)
        refreshFavicon()
    }

    func refreshFavicon() {
        guard extensionBaseURL == nil, isMaterialised else { return }
        guard !isPrivate, !isShowingSystemPage else { return }
        guard let host = page.url?.host()?.lowercased() else { return }
        if host != faviconHost {
            faviconHost = host
            favicon = nil
        }
        if let cached = context.favicons.cached(for: host) {
            favicon = cached
            guard context.favicons.isGuessedIcon(for: host) else { return }
        }
        let view = page
        let favicons = context.favicons
        Task { [weak self, weak view] in
            guard let view else { return }
            let icon = await favicons.load(for: view)
            guard let self, !isClosed, let icon, liveView === view, view.url?.host()?.lowercased() == host else { return }
            favicon = icon
        }
    }
}
