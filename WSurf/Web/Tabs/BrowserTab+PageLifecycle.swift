// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

extension BrowserTab {
    func changeChromiumCapture(in view: BrowserPage, permission: WebPermission, revoke: Bool) {
        guard let chromium = view.chromium else { return }
        Task { [weak self, weak view] in
            do {
                if revoke {
                    try await chromium.revokeCapture(permission)
                } else {
                    try await chromium.restoreCapturePrompt(permission)
                }
            } catch {
                guard let self, let view, self.liveView === view else { return }
                // A failed revocation must not leave untracked live device access.
                if revoke {
                    await view.close()
                    restartPage()
                }
                let alert = NSAlert()
                alert.messageText = String(localized: "Could not change website device access")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = view.window {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    func navigationStarted(_ navigation: PageNavigation?, url: URL?) {
        if !isLoadingErrorPage {
            isShowingError = false
        }
        noteNavigationStarted()
        provisionalNavigation = navigation
        refreshChrome()
        if let url {
            if !SystemPages.isStart(url), !isLoadingErrorPage {
                urlString = url.absoluteString
            }
            onNavigationStarted?(url)
        }
    }

    func navigationCommitted(_ navigation: PageNavigation?) {
        committedNavigation = navigation
        autofillSave.resetDismissalsForNavigation()
        if provisionalNavigation === navigation {
            provisionalNavigation = nil
        }
        noteDocumentChanged()
        noteHoveredLink(nil)
        clearPageActivity()
        if isShowingRealPage, !hasPresentedContent {
            coverUntilPresented()
        }
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
        if (error as? URLError)?.code != .cancelled {
            autofillSave.submissions.clear()
        }
        if provisionalNavigation === navigation {
            provisionalNavigation = nil
        }
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
                    if let window = failedPage.window {
                        await alert.beginSheetModal(for: window)
                    } else {
                        alert.runModal()
                    }
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
        if SystemPages.isSystem(url) {
            return false
        }
        if page.chromium?.htmlDocumentURL == url {
            return true
        }
        if !ExternalApp.staysInWebView(url) {
            if userGesture {
                let window = page.window
                Task { await ExternalApp.offerToOpen(url, in: window) }
            }
            return false
        }
        guard permitsEngineNavigation(request, isMainFrame: isMainFrame) else { return false }
        if isMainFrame {
            rememberScrollOffset()
        }
        return true
    }

    func adopt(_ view: BrowserPage) {
        liveView = view
        engine = view.engine
        Self.applyObscuredInsets(to: view, isUnderTopBar: isUnderTopBar)
        fullscreenObservation = view.observe(\.isFullscreen, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                Self.applyObscuredInsets(to: view, isUnderTopBar: self?.isUnderTopBar ?? true)
            }
        }
        view.onNavigationStarted = { [weak self] navigation, url in self?.navigationStarted(navigation, url: url) }
        view.onNavigationCommitted = { [weak self] navigation in self?.navigationCommitted(navigation) }
        view.onNavigationFinished = { [weak self] navigation in self?.navigationFinished(navigation) }
        view.onNavigationFailed = { [weak self] navigation, error in self?.navigationFailed(navigation, error: error) }
        view.onContentProcessTerminated = { [weak self] in self?.contentProcessDidTerminate() }
        view.onHistoryChanged = { [weak self] in self?.refreshChrome() }
        view.onLinkHovered = { [weak self, weak view] url in
            guard let view else { return }
            self?.noteHoveredLink(url, modifiers: NSEvent.modifierFlags, at: TabNavigationDelegate.pointer(in: view))
        }
        if let native = view.webKit {
            let delegate = TabNavigationDelegate(tab: self)
            navigationDelegate = delegate
            native.navigationDelegate = delegate
            native.uiDelegate = delegate
            if let tabView = native as? TabWebView {
                tabView.onContextDownload = { [weak self] download, source in self?.onDownload?(download, source) }
                tabView.onPeekLink = { [weak self, weak view] url in
                    guard let view else { return }
                    self?.onOpenInPeek?(url, TabNavigationDelegate.pointer(in: view))
                }
                tabView.onSummarizeLink = { [weak self, weak view] url, anchor in
                    guard let view else { return }
                    self?.onSummarizeLink?(url, anchor ?? TabNavigationDelegate.pointer(in: view))
                }
                tabView.onZoomChanged = { [weak self] in self?.zoomDidChange() }
            }
        } else if let chromium = view.chromium {
            installChromiumCallbacks(on: chromium, in: view)
        }

        WebViewPool.shared.configurePage?(view)
        PageActivityMonitor.shared.install(in: view) { [weak self] signal in self?.notePageActivity(signal) }
        ScrollPositionMonitor.shared.install(in: view) { [weak self] y, url in
            self?.lastReportedScrollY = y
            self?.lastReportedScrollURL = url
        }
        FaviconWatcher.shared.install(in: view) { [weak self] in self?.declaredFaviconChanged() }
        PageClickWatcher.shared.install(in: view) { PageClickWatcher.shared.onClick?($0) }
        SiteContentGuard.shared.install(in: view, permissions: sitePermissions) { [weak self] url in self?.popups.note(url) }
        PaymentCardAutofill.shared.install(in: view)
        ContactAutofill.shared.install(in: view)
        PasswordAutofill.shared.install(in: view)
        AutofillSaveCoordinator.shared.install(in: view, session: autofillSave)
        installPageObservations(for: view)
        installPermissionCallbacks(for: view)
        permissions.pageChanged(url: view.url ?? (urlString.isEmpty ? nil : URL(string: urlString)))
        assistantAccess.pageChanged(url: view.url ?? (urlString.isEmpty ? nil : URL(string: urlString)))
        applySiteZoom()
        applySitePopups()
    }
    private func installPageObservations(for view: BrowserPage) {
        progressObservation = page.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? 1
            MainActor.assumeIsolated {
                self?.progress = value
            }
        }
        loadingObservation = page.observe(\.isLoading, options: [.new, .initial]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshChrome() }
        }
        addressObservation = page.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.pageDidChangeInPlace(view) }
        }
        titleObservation = page.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshChrome() }
        }
        backObservation = page.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshChrome() }
        }
        forwardObservation = page.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshChrome() }
        }
        secureContentObservation = page.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshSecurity() }
        }
        pageBackgroundObservation = view.observe(\.underPageBackgroundColor, options: [.new, .initial]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                self?.refreshCanvas(from: view)
                self?.measureBandUnderBar()
            }
        }
        guard let native = view.webKit else { return }
        cameraObservation = native.observe(\.cameraCaptureState, options: [.new, .initial]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.permissions.setLive(.camera, view.cameraCaptureState != .none) }
        }
        microphoneObservation = native.observe(\.microphoneCaptureState, options: [.new, .initial]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.permissions.setLive(.microphone, view.microphoneCaptureState != .none) }
        }
    }

    private func installPermissionCallbacks(for view: BrowserPage) {
        permissions.onRevoke = { [weak self, weak view] permission in
            guard let self, let view else { return }
            switch permission {
            case .camera:
                if let native = view.webKit {
                    native.setCameraCaptureState(.none)
                } else {
                    changeChromiumCapture(in: view, permission: permission, revoke: true)
                }
            case .microphone:
                if let native = view.webKit {
                    native.setMicrophoneCaptureState(.none)
                } else {
                    changeChromiumCapture(in: view, permission: permission, revoke: true)
                }
            case .location:
                onLocationRevoked?()
            case .notifications:
                break
            }
        }
        permissions.onPolicyChanged = { [weak self, weak view] permission, policy in
            guard let self, let view, self.liveView === view, view.chromium != nil,
                  permission == .camera || permission == .microphone, policy != .deny else { return }
            changeChromiumCapture(in: view, permission: permission, revoke: false)
        }
    }

    private func installChromiumCallbacks(on chromium: ChromiumPage, in view: BrowserPage) {
        chromium.navigationDecision = { [weak self, weak view] request, main, gesture, redirect, type, sourceURL in
            guard let self, let view, self.liveView === view else { return false }
            guard permitsChromiumNavigation(request, isMainFrame: main, userGesture: gesture, isRedirect: redirect) else { return false }
            let kind: AutofillSubmissionTracker.NavigationKind
            switch type {
            case .linkActivated:
                kind = .linkActivated
            case .backForward:
                kind = .backForward
            case .reload:
                kind = .reload
            case .formSubmitted:
                kind = .formSubmitted
            case .formResubmitted:
                kind = .formResubmitted
            case .other:
                kind = .other
            @unknown default:
                kind = .other
            }
            autofillSave.submissions.navigationRequested(isMainFrame: main, kind: kind, sourceURL: sourceURL)
            return true
        }
        chromium.openWindow = { [weak self, weak view] url, userGesture in
            guard let self, let view, self.liveView === view else { return }
            if popups.effective.blocks && !userGesture {
                popups.note(url)
                return
            }
            onOpenInNewTab?(url, userGesture)
        }
        chromium.onCloseRequested = { [weak self, weak view] in
            guard let self, let view, self.liveView === view else { return }
            onCloseRequested?()
        }
        chromium.permissionDecision = { [weak self, weak view, weak chromium] frame, wanted in
            guard let self, let view, let chromium, self.liveView === view,
                  SitePermissions.origin(for: frame.request.url) == permissions.origin,
                  (try? await chromium.isLive(frame: frame)) == true else { return false }
            for permission in wanted {
                guard await permissions.decide(permission) else { return false }
            }
            guard self.liveView === view, (try? await chromium.isLive(frame: frame)) == true else { return false }
            return true
        }
        chromium.captureChanged = { [weak self, weak view] camera, microphone in
            guard let self, let view, self.liveView === view else { return }
            permissions.setLive(.camera, camera)
            permissions.setLive(.microphone, microphone)
        }
        chromium.downloadDecision = { [weak self, weak view] download, name, completion in
            guard let self, let view, self.liveView === view, let handler = onChromiumDownload else {
                completion(.deny)
                return
            }
            handler(view, download, name, completion)
        }
        chromium.downloadProgress = { [weak self, weak view] download in
            guard let self, let view, self.liveView === view else { return }
            onChromiumDownloadProgress?(view, download)
        }
    }
    private func pageDidChangeInPlace(_ page: BrowserPage) {
        let previous = urlString
        // The start page is a surface over the tab, not a place it went.
        if !SystemPages.isStart(page.url) {
            permissions.pageChanged(url: page.url)
            assistantAccess.pageChanged(url: page.url)
        }
        applySiteZoom()
        applySitePopups()
        refreshChrome()
        guard urlString != previous else { return }
        refreshPageColor(from: page)
        refreshFavicon()
        measureBandUnderBar()
        invalidateSessionState()
        onSameDocumentNavigation?()
    }
    func contentProcessDidTerminate() {
        guard !isClosed else { return }
        isPlayingAudio = false
        onContentProcessTerminated?()
        if !processState.shouldReloadAfterUnexpectedTermination() {
            Pipeline.log.error("web content process died twice; leaving the tab alone")
            return
        }
        Pipeline.log.notice("web content process died; reloading the tab")
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        hasPresentedContent = false
        page.load(URLRequest(url: url))
    }

    func coverUntilPresented() {
        hasPresentedContent = false
        coverHold?.cancel()
        coverHold = nil
        awaitPresentation()
    }

    private func awaitPresentation() {
        guard page.window != nil else { return }
        guard let native = page.webKit else {
            uncover()
            return
        }
        if (native.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value == 0 {
            uncover()
            return
        }
        guard native.responds(to: Self.presentationUpdateSelector),
              let method = native.method(for: Self.presentationUpdateSelector)
        else {
            uncover()
            return
        }
        let done: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isArmingPresentation {
                    self.uncover()
                } else {
                    self.didPresentContent()
                }
            }
        }
        // This SPI returns void; invoke its block-taking IMP without perform's object-return ABI.
        typealias SchedulePresentationUpdate = @convention(c) (
            AnyObject,
            Selector,
            @convention(block) () -> Void
        ) -> Void
        let schedule = unsafeBitCast(method, to: SchedulePresentationUpdate.self)
        isArmingPresentation = true
        schedule(native, Self.presentationUpdateSelector, done)
        isArmingPresentation = false
    }

    func didPresentContent() {
        guard !hasPresentedContent else { return }
        guard presentedFrameWouldFlash else {
            uncover()
            return
        }
        if coverHold == nil {
            coverHold = Task { [weak self, presentationClock] in
                try? await presentationClock.sleep(for: Self.coverCeiling)
                guard !Task.isCancelled else { return }
                self?.uncover()
            }
        }
        awaitPresentation()
    }

    private func uncover() {
        guard !hasPresentedContent else { return }
        coverHold?.cancel()
        coverHold = nil
        hasPresentedContent = true
        refreshCanvas(from: page)
        refreshPageColor(from: page)
    }

    private var presentedFrameWouldFlash: Bool {
        Self.wouldFlash(
            painting: page.underPageBackgroundColor,
            inDark: page.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        )
    }
}
