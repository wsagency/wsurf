// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import os
import WebKit

final class TabNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?
    private var pendingMainFrameURL: URL?
    private var mainFrameActionGeneration = 0

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true {
            mainFrameActionGeneration &+= 1
        }
        if navigationAction.shouldPerformDownload {
            downloadSource = navigationAction.request.url
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url, SystemPages.isSystem(url) {
            decisionHandler(Self.reaches(url, by: navigationAction, in: tab) ? .allow : .cancel)
            return
        }
        if let url = navigationAction.request.url, !ExternalApp.staysInWebView(url) {
            let origin = requestingOrigin(for: navigationAction)
            let page = tab?.liveView
            let sourceFrame = page.flatMap {
                PageFrameRegistry.shared.sourceFrame(navigationAction.sourceFrame, in: $0)
            }
            let initialRedirect = sourceFrame == nil && tab?.committedNavigation == nil
                && navigationAction.sourceFrame.isMainFrame && navigationAction.targetFrame?.isMainFrame == true
                && !origin.isEmpty && navigationAction.responds(to: NSSelectorFromString("_isRedirect"))
                && navigationAction.value(forKey: "_isRedirect") as? Bool == true
            let actionGeneration = mainFrameActionGeneration
            decisionHandler(.cancel)
            let window = webView.window
            let document = tab?.committedNavigation
            Task { [weak self, weak tab, weak webView, weak page] in
                guard let self, let tab, !tab.isClosed, let webView, tab.liveView?.webKit === webView else { return }
                await ExternalApp.offerToOpen(url, from: origin, policy: tab.externalApps, in: window, isCurrent: {
                    guard let page else { return false }
                    if let sourceFrame {
                        guard await PageFrameRegistry.shared.isLive(sourceFrame, in: page) else { return false }
                    } else {
                        // A first HTTP redirect has no committed document token; bind its accepted request instead.
                        guard initialRedirect, self.mainFrameActionGeneration == actionGeneration else { return false }
                    }
                    return !tab.isClosed && tab.liveView?.webKit === webView
                        && tab.liveView === page && tab.committedNavigation === document
                })
            }
            return
        }
        if let tab, let onOpenInNewTab = tab.onOpenInNewTab,
           navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command)
               || navigationAction.buttonNumber == Self.middleButton,
           navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            onOpenInNewTab(url, navigationAction.modifierFlags.contains(.shift))
            return
        }
        if let tab, let onOpenInPeek = tab.onOpenInPeek,
           navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags == .shift,
           navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            onOpenInPeek(url, Self.pointer(in: webView))
            return
        }
        if let tab, navigationAction.targetFrame?.isMainFrame != false {
            pendingMainFrameURL = navigationAction.request.url
            tab.rememberScrollOffset()
            if let mapped = Self.transition(for: navigationAction.navigationType) {
                tab.noteTransition(mapped)
            }
        }
        if let tab, !tab.permitsEngineNavigation(
            navigationAction.request, isMainFrame: navigationAction.targetFrame?.isMainFrame == true
        ) {
            decisionHandler(.cancel)
            return
        }

        guard let tab, let base = tab.extensionBaseURL,
              let url = navigationAction.request.url,
              url.scheme != "about",
              url.scheme != base.scheme || url.host != base.host
        else {
            tab?.autofillSave.submissions.navigationRequested(navigationAction)
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        tab.onNavigationOutsideExtension?(url)
    }

    /// WebKit numbers the middle button 4, not NSEvent's 2.
    private static let middleButton = 4

    private func requestingOrigin(for action: WKNavigationAction) -> String {
        let frame: WKFrameInfo? = action.sourceFrame
        guard let frame else { return "" }
        let sourceOrigin = Self.frameOrigin(frame.securityOrigin)
        // Redirects retain the old source document for main frames and iframes.
        // Only main-frame redirect provenance is tracked by this delegate.
        let selector = NSSelectorFromString("_isRedirect")
        let isRedirect = action.responds(to: selector) ? action.value(forKey: "_isRedirect") as? Bool : nil
        if isRedirect == true {
            return frame.isMainFrame ? SitePermissions.webOrigin(for: pendingMainFrameURL) : ""
        }
        if isRedirect == nil {
            guard frame.isMainFrame else { return "" }
            if pendingMainFrameURL != nil, SitePermissions.webOrigin(for: pendingMainFrameURL) != sourceOrigin {
                return ""
            }
        }
        return sourceOrigin
    }

    private static func frameOrigin(_ origin: WKSecurityOrigin) -> String {
        guard ["http", "https"].contains(origin.protocol.lowercased()), !origin.host.isEmpty else { return "" }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 {
            components.port = origin.port
        }
        return SitePermissions.webOrigin(for: components.url)
    }

    private static func reaches(
        _ url: URL,
        by action: WKNavigationAction,
        in tab: BrowserTab?
    ) -> Bool {
        guard let tab else { return false }
        if action.navigationType == .backForward || action.navigationType == .reload
            || tab.isRestoring {
            return true
        }
        return tab.permitsSystemPage(url)
    }

    private static func transition(
        for type: WKNavigationType
    ) -> HistoryStore.Transition? {
        switch type {
        case .linkActivated:
            .link
        case .formSubmitted, .formResubmitted:
            .formSubmit
        case .backForward:
            .backForward
        case .reload:
            .reload
        case .other:
            nil
        @unknown default:
            nil
        }
    }

    // MARK: - Second windows

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let tab, let onNewWindow = tab.onNewWindow else { return nil }

        let view = TabWebView(frame: webView.frame, configuration: configuration)
        tab.context.settings.apply(to: view)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true

        let modifiers = navigationAction.modifierFlags
        let activate = !modifiers.contains(.command) || modifiers.contains(.shift)
        onNewWindow(view, activate)
        return view
    }

    func webViewDidClose(_ webView: WKWebView) {
        tab?.onCloseRequested?()
    }

    /// `WKUIDelegatePrivate`. WebKit tells the app itself, so these arrive even
    /// when the page cannot: spell them exactly or they never fire.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(
        _ webView: WKWebView,
        mouseDidMoveOverElement hitTestResult: NSObject?,
        withFlags flags: NSEvent.ModifierFlags,
        userInfo: Any?
    ) {
        var url: URL?
        if let hitTestResult,
           hitTestResult.responds(to: NSSelectorFromString("absoluteLinkURL")) {
            url = hitTestResult.value(forKey: "absoluteLinkURL") as? URL
        }
        tab?.noteHoveredLink(url, modifiers: flags, at: Self.pointer(in: webView))
    }

    static func pointer(in webView: NSView) -> CGPoint {
        guard let window = webView.window else { return .zero }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inView = webView.convert(inWindow, from: nil)
        guard !webView.isFlipped else { return inView }
        return CGPoint(x: inView.x, y: webView.bounds.height - inView.y)
    }

    @objc(_webView:hasVideoInPictureInPictureDidChange:)
    func webView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange isOut: Bool) {
        tab?.onPictureInPictureChanged?(isOut)
    }

    /// WebKit requires an on-screen destination before returning video from PiP.
    /// This callback lets the app restore a minimized window first.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        tab?.onPictureReturnExpected?()
    }

    // MARK: - Page dialogs

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        await PageDialogs.alert(message, from: frame, in: webView.window)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await PageDialogs.confirm(message, from: frame, in: webView.window)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText:
            String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await PageDialogs.prompt(prompt, defaultText: defaultText, from: frame, in: webView.window)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        guard let page = BrowserPage.from(webView) else { return nil }
        let selection = PageFileSelection.pending.object(forKey: page)
        let beforeObservation: String?
        if selection == nil {
            beforeObservation = nil
        } else {
            beforeObservation = await PageDriver.automationSnapshot(in: page)
        }
        if let selection {
            selection.requestedPanel = true
            guard !selection.isCompleted, selection.validate(), frame.isMainFrame,
                  frame.request.url == page.url,
                  SitePermissions.origin(for: frame.request.url) == selection.origin,
                  beforeObservation == selection.observationID else {
                selection.finish(nil)
                return nil
            }
        }
        let nativeParameters = PageFileSelection.Parameters(
            allowsMultipleSelection: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories
        )
        let files: [URL]?
        if let chooser = selection?.selectFiles {
            files = await chooser(nativeParameters)
        } else {
            files = await PageDialogs.chooseFiles(nativeParameters, in: webView.window) { panel in
                selection?.cancelPanel = { [weak panel] in panel?.cancel(nil) }
            }
        }
        if let selection {
            guard !selection.isCompleted, selection.validate(),
                  frame.request.url == page.url,
                  await PageDriver.automationSnapshot(in: page) == selection.observationID else {
                selection.finish(nil)
                return nil
            }
        }
        selection?.finish(files?.count)
        return files
    }

    // MARK: - The page's own print

    /// WebKit sends `window.print()` to this private selector. There is no
    /// public equivalent, so without it the call does nothing.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(
        _ webView: WKWebView,
        printFrame frame: Any,
        pdfFirstPageSize: CGSize,
        completionHandler: @escaping () -> Void
    ) {
        guard let page = BrowserPage.from(webView) else { completionHandler(); return }
        PagePrinting.begin(for: page, then: completionHandler)
    }

    // MARK: - Media capture

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard let tab else { return .deny }
        let wanted: [WebPermission]
        switch type {
        case .camera:
            wanted = [.camera]
        case .microphone:
            wanted = [.microphone]
        case .cameraAndMicrophone:
            wanted = [.camera, .microphone]
        @unknown default:
            return .deny
        }
        for permission in wanted {
            guard await tab.permissions.decide(permission) else { return .deny }
        }
        return .grant
    }

    // MARK: - Downloads

    // WebKit's PDF viewer supplies its current bytes, including edits, through
    // these private UI delegate selectors. Chromium retains its native downloads.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data,
        suggestedFilename: String,
        mimeType: String,
        originatingURL: URL?
    ) {
        guard let tab, !tab.isClosed, tab.liveView?.webKit === webView,
              let save = tab.onSaveDocument else { return }
        Task { await save(data, suggestedFilename, originatingURL, false) }
    }

    @objc(_webView:shouldAllowPDFAtURL:toOpenFromFrame:completionHandler:)
    func webView(
        _ webView: WKWebView,
        shouldAllowPDFAtURL fileURL: URL,
        toOpenFromFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        // Never open WebKit's read-only, temporary file in Preview.
        completionHandler(false)
        guard let tab, !tab.isClosed, tab.liveView?.webKit === webView,
              let save = tab.onSaveDocument else { return }
        let source = frame.request.url
        let filename = tab.documentFilename(for: source) ?? fileURL.lastPathComponent
        let window = webView.window
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: fileURL)
                }.value
                await save(data, filename, source, true)
            } catch {
                Pipeline.log.error("PDF: reading WebKit's temporary copy failed")
                await PageDialogs.alert(error.localizedDescription, from: frame, in: window)
            }
        }
    }

    private var downloadSource: URL?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            BrowserPage.from(webView)?.onMainFrameResponse?(navigationResponse.response)
        }
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            tab?.autofillSave.submissions.clear()
        }
        guard !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }
        downloadSource = navigationResponse.response.url
        decisionHandler(.download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        hand(download, source: navigationAction.request.url)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        hand(download, source: navigationResponse.response.url)
    }

    private func hand(_ download: WKDownload, source: URL?) {
        let origin = source ?? downloadSource
        downloadSource = nil
        tab?.onDownload?(download, origin)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let page = BrowserPage.from(webView) else { return }
        page.onNavigationStarted?(page.navigation(for: navigation), webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        pendingMainFrameURL = webView.url
    }

    // MARK: - Authentication

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch AuthChallenge.decision(
            for: space,
            previousFailureCount: challenge.previousFailureCount
        ) {
        case .evaluateServerTrust:
            switch await CertificateTrust.decide(
                for: challenge,
                allowsExceptions: tab?.context.settings.allowsCertificateExceptions ?? false,
                in: webView.window
            ) {
            case .useDefaultHandling:
                return (.performDefaultHandling, nil)
            case .proceed(let credential):
                return (.useCredential, credential)
            case .cancel:
                return (.cancelAuthenticationChallenge, nil)
            }
        case .useDefaultHandling:
            return (.performDefaultHandling, nil)
        case .rejectProtectionSpace:
            return (.rejectProtectionSpace, nil)
        case .promptForCredential:
            let credential = await AuthChallenge.requestCredential(
                for: space,
                previousFailures: challenge.previousFailureCount,
                in: webView.window
            )
            guard let credential else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, credential)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pendingMainFrameURL = nil
        guard let page = BrowserPage.from(webView) else { return }
        page.onNavigationCommitted?(page.navigation(for: navigation))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = BrowserPage.from(webView) else { return }
        page.onNavigationFinished?(page.navigation(for: navigation))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let page = BrowserPage.from(webView) else { return }
        page.onNavigationFailed?(page.navigation(for: navigation), error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let page = BrowserPage.from(webView) else { return }
        if tab?.provisionalNavigation === page.navigation(for: navigation) {
            pendingMainFrameURL = nil
        }
        page.onNavigationFailed?(page.navigation(for: navigation), error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.autofillSave.clear()
        tab?.contentProcessDidTerminate()
    }

}
