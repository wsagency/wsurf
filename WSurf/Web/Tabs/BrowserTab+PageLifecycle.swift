// SPDX-FileCopyrightText: 2026 wsagency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

extension BrowserTab {
    func navigationStarted(_ navigation: PageNavigation?, url: URL?) {
        if !isLoadingErrorPage { isShowingError = false }
        noteNavigationStarted()
        provisionalNavigation = navigation
        refreshChrome()
        if let url {
            if !SystemPages.isStart(url), !isLoadingErrorPage { urlString = url.absoluteString }
            onNavigationStarted?(url)
        }
    }

    func navigationCommitted(_ navigation: PageNavigation?) {
        committedNavigation = navigation
        autofillSave.resetDismissalsForNavigation()
        if provisionalNavigation === navigation { provisionalNavigation = nil }
        noteDocumentChanged()
        noteHoveredLink(nil)
        clearPageActivity()
        if isShowingRealPage, !hasPresentedContent { coverUntilPresented() }
        holdPageColorUntilLoaded()
        refreshChrome()
        invalidateSessionState()
    }

    func navigationFinished(_ navigation: PageNavigation?) {
        guard !isClosed else { return }
        let wasRestore = isRestoring
        isRestoring = false
        finishReclaim()
        isLoadingErrorPage = false
        refreshChrome()
        invalidateSessionState()
        guard isShowingRealPage else {
            onNavigationFinished?(true)
            return
        }
        didPresentContent()
        refreshFavicon()
        releasePageColorHold()
        refreshPageColor(from: page)
        restoreScrollOffsetIfNeeded()
        onNavigationFinished?(wasRestore || isShowingError)
    }

    func navigationFailed(_ navigation: PageNavigation?, error: Error) {
        guard !isClosed else { return }
        if (error as? URLError)?.code != .cancelled { autofillSave.submissions.clear() }
        if provisionalNavigation === navigation { provisionalNavigation = nil }
        isRestoring = false
        finishReclaim()
        releasePageColorHold()
        refreshPageColor(from: page)
        if !ErrorPage.isSilent(error) {
            if isLoadingErrorPage {
                isLoadingErrorPage = false
                let failedPage = page
                Task { [weak self, weak failedPage] in
                    guard let self, !isClosed, let failedPage, page === failedPage else { return }
                    let alert = NSAlert()
                    alert.messageText = String(localized: "This page didn’t load")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    if let window = failedPage.window { await alert.beginSheetModal(for: window) }
                    else { alert.runModal() }
                }
                refreshChrome()
                return
            }
            let fallback = URL(string: urlString)
            if ErrorPage.failedURL(from: error, fallback: fallback) != nil {
                isShowingError = true
                isLoadingErrorPage = true
                ErrorPage.show(error, in: page, fallbackURL: fallback)
            }
        }
        refreshChrome()
    }

    /// Only safe GET navigation is reissued in another engine; submitted requests stay in their original engine.
    func permitsEngineNavigation(_ request: URLRequest, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let url = request.url,
              SitePermissions.origin(for: url).isEmpty == false,
              preferredEngine(for: url) != engine,
              (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else { return true }
        load(url, transition: pendingTransition)
        return false
    }

    func permitsChromiumNavigation(_ request: URLRequest, isMainFrame: Bool, userGesture: Bool, isRedirect: Bool) -> Bool {
        guard let url = request.url else { return false }
        if SystemPages.isSystem(url) { return false }
        if page.chromium?.htmlDocumentURL == url { return true }
        if !ExternalApp.staysInWebView(url) {
            if userGesture {
                let window = page.window
                Task { await ExternalApp.offerToOpen(url, in: window) }
            }
            return false
        }
        guard permitsEngineNavigation(request, isMainFrame: isMainFrame) else { return false }
        if isMainFrame { rememberScrollOffset() }
        return true
    }
}
