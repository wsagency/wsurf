// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CefKit
import Foundation
import Observation
import os
import SwiftUI
import WebKit

@MainActor
@Observable
final class BrowserTab: Identifiable {
    static let placeholderTitle = String(localized: "New Page")

    let id: UUID
    let autofillSave = AutofillSaveSession()
    var pageTitle = BrowserTab.placeholderTitle
    var customTitle = ""
    var documentTitles: [URL: String] = [:]

    var title: String {
        get { customTitle.isEmpty ? pageTitle : customTitle }
        set { pageTitle = newValue }
    }
    var urlString = ""
    var isLoading = false
    var isFavorite = false
    var favicon: NSImage?
    var faviconHost = ""
    var progress: Double = 0
    var pageColor: NSColor?
    var isRestoring = false
    var isPlayingAudio = false
    var hasVideo = false
    var isPictureOut = false
    var isAgentWorking: Bool {
        processState.isAgentWorking
    }
    var isMuted = false
    /// True from the moment a tab opens in the background until it first comes on screen. It is not saved, so a
    /// restored, imported or reopened tab is never new.
    var isUnseen = false
    var hasNoPageYet: Bool {
        urlString.isEmpty && !isLoading
    }

    private(set) var hoveredLink: URL?

    func noteHoveredLink(
        _ url: URL?,
        modifiers: NSEvent.ModifierFlags = [],
        at anchor: CGPoint = .zero
    ) {
        onLinkHovered?(url, modifiers, anchor)
        guard hoveredLink != url else { return }
        hoveredLink = url
    }

    var canGoBackInWeb = false
    var canGoForwardInWeb = false

    var isShowingStartPage: Bool {
        SystemPages.isStart(committedURL)
    }

    var canGoBack: Bool {
        _ = canGoBackInWeb
        guard isMaterialised else { return false }
        return page.canGoBack
    }

    var canGoForward: Bool {
        _ = canGoForwardInWeb
        guard isMaterialised else { return false }
        return page.canGoForward
    }

    /// `urlString` may include a provisional navigation; this URL reflects the committed page.
    var committedURL: URL?

    var isControlledByMediaDock = false

    private(set) var preview: NSImage?

    func refreshPreview() {
        guard isMaterialised, isShowingRealPage, !isDeferred, page.window != nil else { return }
        let view = page
        Task { [weak self] in
            guard let image = try? await view.capture(width: 480) else { return }
            guard self?.liveView === view else { return }
            self?.preview = image
        }
    }

    var canvasColor: NSColor?

    /// Page background shown before the web view presents and during pull gestures.
    var surfaceColor: Color {
        canvasColor.map(Color.init(nsColor:)) ?? Theme.windowBackground
    }

    var hasPresentedContent = false
    static let presentationUpdateSelector = Selector(("_doAfterNextPresentationUpdate:"))
    static let coverCeiling: Duration = .milliseconds(400)
    @ObservationIgnored var presentationClock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored var coverHold: Task<Void, Never>?
    @ObservationIgnored var isArmingPresentation = false
    /// When this tab last stopped being in front, or was created. Monotonic, so time the Mac spends asleep counts as idle.
    @ObservationIgnored var lastForegroundAt = ContinuousClock.now
    /// When the person last used this tab, for the archive. Saved with the session, unlike `lastForegroundAt`.
    @ObservationIgnored var lastActiveAt = Date()

    var security: PageSecurity = .none

    var internalPage: InternalPage? {
        if let addressed = InternalPage(url: URL(string: urlString)) {
            return addressed
        }
        if isMaterialised, !isLoading, let standing = page.url {
            return InternalPage(url: standing)
        }
        return InternalPage(url: committedURL)
    }

    var isShowingSystemPage: Bool {
        internalPage != nil || isShowingStartPage
    }

    /// Only permit internal navigation to the `wsurf:` URL requested by the app.
    private var permittedSystemPage: URL?

    func permitSystemPage(_ url: URL?) {
        permittedSystemPage = SystemPages.isSystem(url) ? url : nil
    }

    func permitsSystemPage(_ url: URL) -> Bool {
        permittedSystemPage == url
    }

    // MARK: - The pin

    var pinnedURL: URL?
    var pinnedTitle = ""
    /// The profile pin this tab is the window's page for. Nil when the tab is not part of the profile's pins.
    var pinID: UUID?

    @ObservationIgnored var liveView: BrowserPage? {
        didSet {
            loadedEngine = liveView?.engine
            releaseInvalidDevelopment()
            dialogs.cancelAll()
        }
    }
    private(set) var loadedEngine: BrowserEngine?
    @ObservationIgnored var retiredView: BrowserPage?
    var retirementGeneration = 0
    var pageGeneration = 0 {
        didSet { releaseInvalidDevelopment() }
    }
    @ObservationIgnored var developmentOwner: DevelopmentOwner?
    let sitePermissions: SitePermissions
    let context: BrowserProfileContext
    private let dataStore: WKWebsiteDataStore
    var engine: BrowserEngine = .webKit
    @ObservationIgnored var pendingNavigationTask: Task<PageNavigation?, Never>?
    @ObservationIgnored var lastRequestedNavigation: PageNavigation?
    var hasActiveDownload: (() -> Bool)?
    @ObservationIgnored var stoppedNavigation = false

    var isMaterialised: Bool {
        liveView != nil
    }

    var page: BrowserPage {
        _ = pageGeneration
        if let liveView {
            return liveView
        }
        if let retiredView {
            return retiredView
        }
        engine = preferredEngine(for: deferredURL ?? URL(string: urlString))
        let view = makePage(engine: engine)
        adopt(view)
        return view
    }

    var engineOverride: BrowserEngine?  // A tab opened to compare engines: wins over the site's setting, never written to it.
    var signInEngine: BrowserEngine?  // Holds a Google sign-in's redirect chain in WebKit (`noteNavigation`).
    func preferredEngine(for url: URL?) -> BrowserEngine {
        guard extensionBaseURL == nil else { return .webKit }
        guard engineOverride == nil, let url else { return engineOverride ?? .webKit }
        let origin = SitePermissions.origin(for: url)
        guard !origin.isEmpty else { return .webKit }
        return signInEngine ?? sitePermissions.engine(for: origin)
    }

    func makePage(engine: BrowserEngine) -> BrowserPage {
        switch engine {
        case .webKit:
            BrowserPage(webKit: context.webViewPool.makeColdView(dataStore: dataStore), context: context)
        case .chromium:
            BrowserPage(chromium: ChromiumPage(context: context))
        }
    }
    var onNavigationStarted: ((URL) -> Void)?
    var onNavigationFinished: ((Bool) -> Void)?
    var onNavigationOutsideExtension: ((URL) -> Void)?
    var onNewWindow: ((WKWebView, Bool) -> Void)?
    var onOpenInNewTab: ((URL, Bool) -> Void)?
    var onOpenInNewWindow: ((URL, Bool) -> Void)?
    var onOpenInChromium: ((URL) -> Void)?
    var onOpenInPeek: ((URL, CGPoint) -> Void)?
    var onSummarizeLink: ((URL, CGPoint) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onPictureInPictureChanged: ((Bool) -> Void)?
    var onPictureReturnExpected: (() -> Void)?
    var onDownload: ((WKDownload, URL?) -> Void)?
    var onSaveDocument: ((Data, String, URL?, Bool) async -> Void)?
    var onChromiumDownload: ((BrowserPage, CefDownload, String, @escaping (CefDownloadDecision) -> Void) -> Void)?
    var onChromiumDownloadProgress: ((BrowserPage, CefDownload) -> Void)?
    var onPageRetired: ((BrowserPage) -> Void)?
    var onLinkHovered: ((URL?, NSEvent.ModifierFlags, CGPoint) -> Void)?

    let extensionBaseURL: URL?
    let popups: TabPopupPolicy
    let externalApps: TabExternalAppPolicy

    var navigationDelegate: TabNavigationDelegate?
    let permissions: TabPermissionCenter
    let assistantAccess: TabAssistantAccessCenter
    let find = FindSession()
    let translation = PageTranslation()
    let reader = ReaderSession()
    /// Whether this tab is the one in front. Only that tab asks its page for an article, so a window of background tabs does not
    /// scan them all. The model answers; a tab without one is never in front.
    @ObservationIgnored var isFrontTab: () -> Bool = { false }
    let dialogs = PageDialogQueue()

    let isPrivate: Bool

    var progressObservation: NSKeyValueObservation?
    var loadingObservation: NSKeyValueObservation?
    var cameraObservation: NSKeyValueObservation?
    var microphoneObservation: NSKeyValueObservation?
    var displayCaptureObservation: DisplayCaptureObservation?
    var pageBackgroundObservation: NSKeyValueObservation?
    var addressObservation: NSKeyValueObservation?
    var titleObservation: NSKeyValueObservation?
    var backObservation: NSKeyValueObservation?
    var forwardObservation: NSKeyValueObservation?
    var fullscreenObservation: NSKeyValueObservation?
    var secureContentObservation: NSKeyValueObservation?
    let processState = TabProcessState()
    var provisionalNavigation: PageNavigation?
    var committedNavigation: PageNavigation?

    init(
        id: UUID = UUID(),
        extensionHost: ExtensionPageHost? = nil,
        adopting: WKWebView? = nil,
        restoring: Bool = false,
        opensBlank: Bool = true,
        privately: Bool = false,
        sitePermissions: SitePermissions? = nil,
        context: BrowserProfileContext? = nil
    ) {
        let context = context ?? .shared(for: privately ? .privateBrowsing() : .original())
        precondition(!privately || context.profile.isPrivate)
        let sitePermissions = sitePermissions ?? context.sitePermissions
        self.id = id
        self.sitePermissions = sitePermissions
        self.context = context
        dataStore = adopting?.configuration.websiteDataStore
            ?? extensionHost?.configuration.websiteDataStore ?? context.dataStore
        isPrivate = context.profile.isPrivate
        popups = TabPopupPolicy(store: sitePermissions, settings: context.settings)
        externalApps = TabExternalAppPolicy(store: sitePermissions, isPrivate: isPrivate)
        permissions = TabPermissionCenter(store: sitePermissions)
        assistantAccess = TabAssistantAccessCenter(store: sitePermissions)
        permissions.persistsAnswers = !isPrivate
        assistantAccess.persistsAnswers = !isPrivate
        let opensStartPage = opensBlank && adopting == nil && extensionHost == nil && !restoring
        if opensStartPage {
            pageTitle = SystemPages.startTitle
        }
        if let adopting {
            // WebKit requires this exact view, with the opener's configuration attached.
            liveView = BrowserPage(webKit: adopting, context: context)
            extensionBaseURL = nil
        } else if let extensionHost {
            liveView = BrowserPage(webKit: context.webViewPool.makeView(configuration: extensionHost.configuration), context: context)
            extensionBaseURL = extensionHost.baseURL
            pageTitle = extensionHost.name
            favicon = extensionHost.icon
        } else {
            liveView = opensStartPage ? BrowserPage(webKit: context.webViewPool.acquire(), context: context) : nil
            extensionBaseURL = nil
        }
        if let liveView {
            adopt(liveView)
        }
        find.driver = .browserPage { [weak self] in self?.shownPage }
        reader.driver = .page { [weak self] in self?.liveView }
        assistantAccess.onPolicyChanged = { [weak self] in self?.releaseInvalidDevelopment() }
        if opensStartPage {
            permitSystemPage(SystemPages.start)
            page.load(URLRequest(url: SystemPages.start))
        }
    }

    // MARK: - Discarding

    var canDiscardWebContent: Bool {
        guard !isDeferred, intrinsicProtectionReason == nil else { return false }
        return !urlString.isEmpty
    }

    var intrinsicProtectionReason: TabProtectionReason? {
        processState.protectionReason(
            isPrivate: isPrivate,
            isExtensionPage: extensionBaseURL != nil,
            hasDeviceAccess: !permissions.live.isEmpty,
            hasMediaPlayback: isControlledByMediaDock || isPlayingAudio
        )
    }

    var hasEditedForm: Bool {
        processState.hasEditedForm
    }
    var isSharingScreen: Bool {
        processState.isSharingScreen
    }

    func setAgentWorking(_ isWorking: Bool) {
        processState.setAgentWorking(isWorking)
    }

    func setExternalAutomationWorking(_ isWorking: Bool) {
        processState.isExternalAutomationWorking = isWorking
    }

    func notePageActivity(_ signal: PageActivitySignal) {
        processState.notePageActivity(signal)
    }

    func clearPageActivity() {
        processState.clearPageActivity()
    }

    func discardWebContent() {
        guard canDiscardWebContent else { return }
        unloadUntilShown()
    }

    /// Drops the web view and keeps the session; a replacement view is made when the tab is shown.
    func unloadUntilShown() {
        guard let outgoing = liveView else { return }
        let state = sessionState
        let url = URL(string: urlString)
        guard state != nil || url != nil else { return }

        retire(outgoing)
        stoppedNavigation = false

        // Keep the session and create a replacement view when the tab becomes visible.
        liveView = nil
        hasPresentedContent = false
        deferRestore(state: state, url: url)
        processState.markUnloaded()
    }

    @ObservationIgnored var retirement: Task<Void, Never>?
    @ObservationIgnored var engineSwitchTask: Task<Bool, Never>?

    var onLocationRevoked: (() -> Void)?

    var onSameDocumentNavigation: (() -> Void)?

    var onContentProcessTerminated: (() -> Void)?
    /// Whether the model lets a tab whose web-content process died wait unloaded until it is shown:
    /// not the active tab, not visible in a split, not a favorite, and not otherwise protected from
    /// unloading. An unwired tab answers no, which keeps the immediate reload.
    var mayUnloadAfterTermination: (() -> Bool)?

    private(set) var isClosed = false

    func detach() {
        guard !isClosed else { return }
        isClosed = true
        releaseCurrentDevelopment(reason: .tabClosed)
        translation.documentChanged()
        reader.pageChanged()
        pendingNavigationTask?.cancel()
        coverHold?.cancel()
        onChromiumDownload = nil
        onChromiumDownloadProgress = nil
        hasActiveDownload = nil
        onNavigationStarted = nil
        onNavigationFinished = nil
        onNavigationOutsideExtension = nil
        onNewWindow = nil
        onOpenInNewTab = nil
        onOpenInNewWindow = nil
        onOpenInChromium = nil
        onOpenInPeek = nil
        onSummarizeLink = nil
        onCloseRequested = nil
        onPictureInPictureChanged = nil
        onPictureReturnExpected = nil
        onDownload = nil
        onSaveDocument = nil
        onLinkHovered = nil
        onSameDocumentNavigation = nil
        onContentProcessTerminated = nil
        mayUnloadAfterTermination = nil
        onLocationRevoked = nil
        if let view = liveView {
            retire(view)
        }
        liveView = nil
    }

    // MARK: - Page colour

    var holdsPageColor = false
    var isMeasuringBand = false
    var needsBandRemeasure = false

    // MARK: - Zoom

    private(set) var zoomChanges = 0

    func zoomDidChange() {
        zoomChanges &+= 1
        recordSiteZoom()
    }

    // MARK: - Per-site zoom

    var zoomHost = ""

    func applySiteZoom() {
        let host = SystemPages.isSystem(page.url)
            ? ""
            : page.url?.host()?.lowercased() ?? ""
        guard host != zoomHost else { return }
        zoomHost = host
        let remembered = host.isEmpty ? nil : context.pageZoom.level(for: host)
        page.pageZoom = remembered ?? context.settings.pageZoom
        zoomChanges &+= 1
    }

    fileprivate func recordSiteZoom() {
        guard !isPrivate, !zoomHost.isEmpty else { return }
        context.pageZoom.set(page.pageZoom, for: zoomHost, defaultZoom: context.settings.pageZoom)
    }

    // MARK: - Scroll return

    var lastReportedScrollY: Double = 0
    var lastReportedScrollURL: URL?
    private var scrollReturns = ScrollReturnMemory()

    func rememberScrollOffset() {
        scrollReturns.remember(lastReportedScrollY, leaving: lastReportedScrollURL?.absoluteString)
    }

    func noteDocumentChanged() {
        lastReportedScrollY = 0
        lastReportedScrollURL = nil
        if isShowingRealPage {
            find.pageChanged()
        }
    }

    func restoreScrollOffsetIfNeeded() {
        guard pendingTransition == .backForward,
              let stored = scrollReturns.offset(returningTo: page.url?.absoluteString)
        else { return }
        lastReportedScrollY = stored
        lastReportedScrollURL = page.url
        page.evaluateJavaScript(Self.restoreScrollScript(to: stored), completionHandler: nil)
    }

    var pendingTransition: HistoryStore.Transition = .typed

    func noteTransition(_ transition: HistoryStore.Transition) {
        pendingTransition = transition
    }

    // MARK: - Deferred restore

    private(set) var isDeferred = false
    var reclaimState: TabReclaimState {
        processState.reclaimState
    }

    private var deferredState: Data?
    private var deferredURL: URL?

    func deferRestore(state: Data?, url: URL?) {
        guard state != nil || url != nil else { return }
        deferredState = state
        deferredURL = url
        isDeferred = true
    }

    private var cachedSessionState: Data?
    private var hasFreshSessionState = false

    private(set) var sessionStateGeneration = 1

    var sessionState: Data? {
        if isDeferred {
            return deferredState
        }
        guard isMaterialised else {
            return cachedSessionState
        }
        if !hasFreshSessionState {
            cachedSessionState = page.interactionState as? Data
            hasFreshSessionState = true
        }
        return cachedSessionState
    }

    func invalidateSessionState() {
        hasFreshSessionState = false
        sessionStateGeneration &+= 1
    }

    func realizeDeferredSession() {
        guard isDeferred else { return }
        let state = deferredState
        let url = deferredURL
        processState.beginReload()
        clearDeferredSession()
        invalidateSessionState()
        isRestoring = true
        if let retirement {
            pendingNavigationTask?.cancel()
            pendingNavigationTask = Task { [weak self] in
                await retirement.value
                guard let self, !isClosed, !Task.isCancelled else { return nil }
                return restoreDeferredState(state, url: url)
            }
        } else {
            lastRequestedNavigation = restoreDeferredState(state, url: url)
        }
    }

    private func restoreDeferredState(_ state: Data?, url: URL?) -> PageNavigation? {
        permitSystemPage(url)
        if let url {
            urlString = url.absoluteString
        }
        if let state, BrowserPage.canRestore(state, using: preferredEngine(for: url)) {
            page.interactionState = state
            return nil
        }
        if let url {
            return loadDirect(url)
        }
        isRestoring = false
        return nil
    }

    func discardDeferredSession() {
        clearDeferredSession()
        processState.finishReload()
    }

    private func clearDeferredSession() {
        isDeferred = false
        deferredState = nil
        deferredURL = nil
    }

    func finishReclaim() {
        processState.finishReload()
    }

    var isShowingError = false
    var isLoadingErrorPage = false
}
