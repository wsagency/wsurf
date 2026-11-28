// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import WebKit

extension BrowserTab {
    struct OpenerSignIn: Equatable {
        let engine: BrowserEngine
        let origin: String
    }

    /// The canonical HTTP(S) origin of this tab's current document, used to match same-site sign-in continuations.
    var signInOrigin: String {
        for candidate in [committedURL, liveView?.url, URL(string: urlString)] {
            let origin = SitePermissions.webOrigin(for: candidate)
            if !origin.isEmpty {
                return origin
            }
        }
        return ""
    }

    /// Whether navigating from `origin` to `destination` stays within the same sign-in session.
    /// Same-site pages (such as `calendar.google.com` and `meet.google.com`) and sign-in provider hops keep it;
    /// unrelated websites leave it so their own engine setting applies.
    static func continuesSignIn(from origin: String, to destination: String) -> Bool {
        guard !origin.isEmpty, !destination.isEmpty else { return false }
        return SitePermissions.webKitOnlyOrigins.contains(origin)
            || SitePermissions.webKitOnlyOrigins.contains(destination)
            || SitePermissions.site(for: origin) == SitePermissions.site(for: destination)
    }

    /// The sign-in session this tab can pass to a same-site tab or pop-up it opens.
    /// Covers both an active `signInEngine` chain and a WebKit page on a WebKit-only sign-in site
    /// whose session Chromium cannot share. Comparison tabs (`engineOverride`) and single-tab pins
    /// (`pinnedEngine`) without an active sign-in chain do not propagate across tabs.
    var openerSignInContext: OpenerSignIn? {
        guard engineOverride == nil else { return nil }
        let origin = signInOrigin
        guard !origin.isEmpty else { return nil }
        if let signInEngine {
            return OpenerSignIn(engine: signInEngine, origin: origin)
        }
        let currentEngine = loadedEngine ?? engine
        if currentEngine == .webKit,
           pinnedEngine?.origin != origin,
           SitePermissions.webKitOnlySites.contains(SitePermissions.site(for: origin)) {
            return OpenerSignIn(engine: .webKit, origin: origin)
        }
        return nil
    }

    /// The engine a newly opened tab in this window would choose for `origin` without a sign-in hold,
    /// single-tab pin, or comparison override.
    func newTabDefaultEngine(for origin: String) -> BrowserEngine {
        guard !origin.isEmpty else { return defaultEngineOverride ?? .webKit }
        if SitePermissions.webKitOnlyOrigins.contains(origin) {
            return .webKit
        }
        return defaultEngineOverride ?? sitePermissions.engine(for: origin)
    }

    /// The sign-in engine this tab passes to a newly opened tab or pop-up for `url` when `url` continues
    /// the session and its default engine without sign-in differs from the session's engine.
    func inheritedSignInEngine(for url: URL?) -> BrowserEngine? {
        guard let context = openerSignInContext,
              let destination = url.map(SitePermissions.webOrigin(for:)),
              Self.continuesSignIn(from: context.origin, to: destination),
              newTabDefaultEngine(for: destination) != context.engine
        else { return nil }
        return context.engine
    }

    /// Applies an opener's sign-in context for an initial destination URL.
    /// Promotes `signInEngine` only when the destination's engine without sign-in differs from the opener's
    /// session engine; when the destination already uses that engine (such as `www.google.com/url`), keeps
    /// `pendingOpenerSignIn` so a redirect to an external site still uses that site's engine while a
    /// redirect to a same-site origin configured for the other engine stays in the session.
    func applyOpenerSignIn(_ context: OpenerSignIn?, for url: URL?) {
        guard let context else { return }
        pendingOpenerSignIn = context
        resolveOpenerSignIn(for: url)
    }

    /// Resolves a deferred opener sign-in (`about:blank` pop-ups and same-site redirector hops)
    /// against an HTTP(S) destination.
    func resolveOpenerSignIn(for url: URL?) {
        guard let pending = pendingOpenerSignIn else { return }
        let destination = SitePermissions.webOrigin(for: url)
        guard !destination.isEmpty else { return }
        guard signInEngine == nil, engineOverride == nil,
              pinnedEngine?.origin != destination,
              loadedEngine == nil || loadedEngine == pending.engine,
              Self.continuesSignIn(from: pending.origin, to: destination) else {
            pendingOpenerSignIn = nil
            return
        }
        if preferredEngine(for: url, keepingSignIn: false) != pending.engine {
            pendingOpenerSignIn = nil
            signInEngine = pending.engine
            let isProviderFlow = SitePermissions.webKitOnlyOrigins.contains(pending.origin)
                || SitePermissions.webKitOnlyOrigins.contains(destination)
            inheritedSignInOrigin = isProviderFlow ? nil : destination
        } else {
            pendingOpenerSignIn = OpenerSignIn(engine: pending.engine, origin: destination)
        }
    }

    /// Promotes a committed WebKit document on a WebKit-only sign-in site into an active same-site
    /// sign-in hold when navigating to a sibling origin whose default engine is not WebKit.
    func promoteSameSiteWebKitSignInIfNeeded(for url: URL, destination: String) {
        guard signInEngine == nil, engine == .webKit, engineOverride == nil,
              let source = committedURL.map(SitePermissions.webOrigin(for:)),
              !source.isEmpty, !destination.isEmpty, source != destination,
              pinnedEngine?.origin != source,
              pinnedEngine?.origin != destination,
              SitePermissions.webKitOnlySites.contains(SitePermissions.site(for: source)),
              SitePermissions.site(for: source) == SitePermissions.site(for: destination),
              preferredEngine(for: url) != .webKit else { return }
        signInEngine = .webKit
        inheritedSignInOrigin = SitePermissions.webKitOnlyOrigins.contains(destination) ? nil : destination
    }

    /// The flow's origins and the Chromium page to read their cookies from, when loading `url` in `desired` moves a sign-in from
    /// Chromium to a WebKit-only provider: this tab's Chromium page, or for a tab with no page yet (a Chromium page's pop-up,
    /// `seedSignInChain`) any live Chromium page of this profile.
    func chromiumSignInHandoff(to url: URL, engine desired: BrowserEngine) -> (origins: Set<String>, page: ChromiumPage?)? {
        guard desired == .webKit, extensionBaseURL == nil,
              SitePermissions.webKitOnlyOrigins.contains(SitePermissions.origin(for: url)) else { return nil }
        // Only the held flow's sites that Chromium served: a site this flow visited in WebKit has its fresh cookies there already.
        let origins = signInChain.origins(leadingTo: url, servedBy: .chromium, now: signInClock()).intersection(heldSignInChainOrigins)
        guard !origins.isEmpty else { return nil }
        if let chromium = liveView?.chromium {
            return (origins, chromium)
        }
        return liveView == nil && SiteCookies.livePage(context) != nil ? (origins, nil) : nil
    }

    /// A tab that a Chromium page opened for a WebKit-only provider continues that page's flow: its chain starts with the
    /// opener's, so the flow's cookies move to WebKit with it. Only within one profile.
    func seedSignInChain(from opener: BrowserTab, for url: URL) {
        guard opener.context === context, opener.loadedEngine == .chromium,
              SitePermissions.webKitOnlyOrigins.contains(SitePermissions.origin(for: url)) else { return }
        signInChain = opener.signInChain
        signInChain.note(opener.signInOrigin, engine: .chromium, now: signInClock())
    }

    @discardableResult
    func retire(_ outgoing: BrowserPage) -> Task<Void, Never> {
        leavingSignIn = nil
        pendingOpenerSignIn = nil
        inheritedSignInOrigin = nil
        coverHold?.cancel()
        coverHold = nil
        releaseCurrentDevelopment(reason: .engineReplaced)
        onPageRetired?(outgoing)
        retirementGeneration &+= 1
        let generation = retirementGeneration
        retiredView = outgoing
        if liveView === outgoing {
            liveView = nil
        }
        outgoing.stopLoading()
        outgoing.onNavigationStarted = nil
        outgoing.onNavigationCommitted = nil
        outgoing.onNavigationFinished = nil
        outgoing.onMainFrameResponse = nil
        outgoing.onNavigationFailed = nil
        outgoing.onContentProcessTerminated = nil
        outgoing.onHistoryChanged = nil
        outgoing.onNavigatedWithinDocument = nil
        outgoing.onLinkHovered = nil
        outgoing.dialogs = nil
        if let native = outgoing.webKit {
            native.navigationDelegate = nil
            native.uiDelegate = nil
            if let tabView = native as? TabWebView {
                tabView.onZoomChanged = nil
                tabView.onContextDownload = nil
                tabView.onOpenLinkInNewWindow = nil
                tabView.profileContext = nil
                tabView.onPeekLink = nil
                tabView.onSummarizeLink = nil
                tabView.canPickCredential = nil
                tabView.credentialRefusal = nil
                tabView.onPickCredential = nil
                tabView.showsPDF = nil
                tabView.onSavePDF = nil
            }
        }
        outgoing.chromium?.canPickCredential = nil
        outgoing.chromium?.credentialRefusal = nil
        outgoing.chromium?.onPickCredential = nil
        outgoing.chromium?.showsPDF = nil
        outgoing.chromium?.onSavePDF = nil
        outgoing.removeFromSuperview()
        progressObservation = nil
        loadingObservation = nil
        cameraObservation = nil
        microphoneObservation = nil
        displayCaptureObservation = nil
        pageBackgroundObservation = nil
        addressObservation = nil
        titleObservation = nil
        backObservation = nil
        forwardObservation = nil
        fullscreenObservation = nil
        secureContentObservation = nil
        permissions.onRevoke = nil
        navigationDelegate = nil
        let task = Task { [weak self] in
            await outgoing.close()
            guard let self, retirementGeneration == generation else { return }
            retirement = nil
            if engineSwitchTask == nil, retiredView === outgoing {
                retiredView = nil
                pageGeneration &+= 1
            }
        }
        retirement = task
        return task
    }

    func waitForRetirement() async {
        if let retirement {
            await retirement.value
        }
    }

    func switchEngine(to engine: BrowserEngine, authorized: (@MainActor () -> Bool)? = nil) async -> Bool {
        if let authorized {
            return await switchEngineWhileAuthorized(to: engine, authorized: authorized)
        }
        while let pending = engineSwitchTask {
            _ = await pending.value
        }
        guard !isClosed, extensionBaseURL == nil else { return false }
        guard liveView?.engine != engine else { return true }
        let url = URL(string: urlString) ?? liveView?.url
        guard await replaceEngine(with: engine), !Task.isCancelled else { return false }
        if let url, urlString == url.absoluteString {
            lastRequestedNavigation = loadDirect(url)
        }
        return true
    }

    func switchEngineWhileAuthorized(
        to engine: BrowserEngine, destination: URL? = nil, authorized: @escaping @MainActor () -> Bool
    ) async -> Bool {
        while let pending = engineSwitchTask {
            let completed = await PageReply<Bool>.awaiting(within: .seconds(15)) { reply in
                Task {
                    _ = await pending.value
                    reply.finish(true)
                }
            }
            guard completed == true, authorized() else { return false }
        }
        if let retirement {
            let completed = await PageReply<Bool>.awaiting(within: .seconds(15)) { reply in
                Task {
                    await retirement.value
                    reply.finish(true)
                }
            }
            guard completed == true else { return false }
        }
        guard !isClosed, !Task.isCancelled, extensionBaseURL == nil, authorized(),
              engineSwitchTask == nil, retirement == nil else { return false }
        let url = destination ?? URL(string: urlString) ?? liveView?.url
        guard engine != .chromium || !SitePermissions.webKitOnlyOrigins.contains(SitePermissions.origin(for: url)) else { return false }
        guard liveView?.engine != engine else { return true }
        // Retiring and installing must be one Main Actor turn. Awaiting close after detaching the live page would let
        // Take Over land while the user's page is already gone.
        if let outgoing = liveView {
            retire(outgoing)
        }
        finishEngineInstallation(engine)
        if destination == nil, let url, urlString == url.absoluteString {
            lastRequestedNavigation = loadDirect(url, authorized: authorized)
        }
        return true
    }

    func replaceEngine(with engine: BrowserEngine, force: Bool = false) async -> Bool {
        while let pending = engineSwitchTask {
            _ = await pending.value
        }
        guard !isClosed, !Task.isCancelled else { return false }
        if !force, let liveView, liveView.engine == engine {
            return true
        }
        let task = Task { [weak self] in
            guard let self else { return false }
            defer { engineSwitchTask = nil }
            return await installEngine(engine)
        }
        engineSwitchTask = task
        return await task.value
    }

    private func installEngine(_ engine: BrowserEngine) async -> Bool {
        if let outgoing = liveView {
            await retire(outgoing).value
        } else if let retirement {
            await retirement.value
        }
        guard !isClosed else { return false }
        finishEngineInstallation(engine)
        return true
    }

    private func finishEngineInstallation(_ engine: BrowserEngine) {
        retiredView = nil
        liveView = nil
        self.engine = engine
        stoppedNavigation = false
        awaitsVisit = false
        provisionalNavigation = nil
        committedNavigation = nil
        isRestoring = false
        isLoading = false
        progress = 0
        hasPresentedContent = false
        isShowingError = false
        isPlayingAudio = false
        hasVideo = false
        isPictureOut = false
        committedURL = nil
        zoomHost = ""
        clearPageActivity()
        invalidateSessionState()
        processState.finishReload()
        releasePageColorHold()
        permissions.pageChanged(url: nil)
        assistantAccess.pageChanged(url: nil)
        adopt(makePage(engine: engine))
        pageGeneration &+= 1
        notifyDocumentCommitted()
    }
}
