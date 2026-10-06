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

struct ExtensionPageHost {
    let configuration: WKWebViewConfiguration
    let baseURL: URL
    let name: String
    let icon: NSImage?
}

enum PageSecurity: Equatable {
    case secure
    case pending
    case mixed
    case insecure
    case none
}

@MainActor
@Observable
final class BrowserTab: Identifiable {
    static let placeholderTitle = String(localized: "Start Page")

    let id: UUID
    let autofillSave = AutofillSaveSession()
    var pageTitle = BrowserTab.placeholderTitle
    var customTitle = ""

    var title: String {
        get { customTitle.isEmpty ? pageTitle : customTitle }
        set { pageTitle = newValue }
    }
    var urlString = ""
    var isLoading = false
    var favicon: NSImage?
    private var faviconHost = ""
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

    private var canGoBackInWeb = false
    private var canGoForwardInWeb = false

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
    private(set) var committedURL: URL?

    var isUnderTopBar = false {
        didSet {
            guard isUnderTopBar != oldValue, isMaterialised else { return }
            Self.applyObscuredInsets(to: page, isUnderTopBar: isUnderTopBar)
            measureBandUnderBar()
        }
    }

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

    private(set) var canvasColor: NSColor?

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

    private(set) var security: PageSecurity = .none

    enum InternalPage: String, Codable, CaseIterable {
        case history
        case downloads
        case releaseNotes
        case settings

        var title: String {
            switch self {
            case .settings:
                "Settings"
            case .history:
                "History"
            case .downloads:
                "Downloads"
            case .releaseNotes:
                "Release Notes"
            }
        }

        var symbol: String {
            switch self {
            case .settings:
                "gearshape"
            case .history:
                "clock"
            case .downloads:
                "arrow.down"
            case .releaseNotes:
                "doc.text"
            }
        }
    }

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

    var isAwayFromPin: Bool {
        guard let pinnedURL else { return false }
        return !urlString.isEmpty && urlString != pinnedURL.absoluteString
    }

    var isShowingPin: Bool {
        guard let pinnedURL else { return false }
        return urlString == pinnedURL.absoluteString
    }
    @ObservationIgnored var liveView: BrowserPage?
    @ObservationIgnored private var retiredView: BrowserPage?
    private var retirementGeneration = 0
    private var pageGeneration = 0
    let sitePermissions: SitePermissions
    private let profile: Profile
    private let dataStore: WKWebsiteDataStore
    var engine: BrowserEngine = .webKit
    @ObservationIgnored private var pendingNavigationTask: Task<PageNavigation?, Never>?
    @ObservationIgnored private var lastRequestedNavigation: PageNavigation?
    var hasActiveDownload: (() -> Bool)?
    @ObservationIgnored private var stoppedNavigation = false

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

    func preferredEngine(for url: URL?) -> BrowserEngine {
        guard extensionBaseURL == nil, let url else { return .webKit }
        let origin = SitePermissions.origin(for: url)
        guard !origin.isEmpty else { return .webKit }
        return sitePermissions.engine(for: origin)
    }

    private func makePage(engine: BrowserEngine) -> BrowserPage {
        switch engine {
        case .webKit:
            BrowserPage(webKit: WebViewPool.shared.makeColdView(dataStore: dataStore), profile: profile)
        case .chromium:
            BrowserPage(chromium: ChromiumPage(profile: profile))
        }
    }
    var onNavigationStarted: ((URL) -> Void)?
    var onNavigationFinished: ((Bool) -> Void)?
    var onNavigationOutsideExtension: ((URL) -> Void)?
    var onNewWindow: ((WKWebView, Bool) -> Void)?
    var onOpenInNewTab: ((URL, Bool) -> Void)?
    var onOpenInPeek: ((URL, CGPoint) -> Void)?
    var onSummarizeLink: ((URL, CGPoint) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onPictureInPictureChanged: ((Bool) -> Void)?
    var onPictureReturnExpected: (() -> Void)?
    var onDownload: ((WKDownload, URL?) -> Void)?
    var onChromiumDownload: ((BrowserPage, CefDownload, String, @escaping (CefDownloadDecision) -> Void) -> Void)?
    var onChromiumDownloadProgress: ((BrowserPage, CefDownload) -> Void)?
    var onPageRetired: ((BrowserPage) -> Void)?
    var onLinkHovered: ((URL?, NSEvent.ModifierFlags, CGPoint) -> Void)?

    let extensionBaseURL: URL?
    let popups: TabPopupPolicy

    var navigationDelegate: TabNavigationDelegate?
    let permissions: TabPermissionCenter
    let assistantAccess: TabAssistantAccessCenter
    let find = FindSession()

    let isPrivate: Bool

    var progressObservation: NSKeyValueObservation?
    var loadingObservation: NSKeyValueObservation?
    var cameraObservation: NSKeyValueObservation?
    var microphoneObservation: NSKeyValueObservation?
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
        sitePermissions: SitePermissions = .shared
    ) {
        self.id = id
        self.sitePermissions = sitePermissions
        profile = privately ? .privateBrowsing() : ChromiumRuntime.shared.currentProfile
        dataStore = adopting?.configuration.websiteDataStore
            ?? extensionHost?.configuration.websiteDataStore ?? WebViewPool.shared.dataStore
        isPrivate = privately
        popups = TabPopupPolicy(store: sitePermissions)
        permissions = TabPermissionCenter(store: sitePermissions)
        assistantAccess = TabAssistantAccessCenter(store: sitePermissions)
        permissions.persistsAnswers = !privately
        assistantAccess.persistsAnswers = !privately
        let opensStartPage = opensBlank && adopting == nil && extensionHost == nil && !restoring
        if let adopting {
            // WebKit requires this exact view, with the opener's configuration attached.
            liveView = BrowserPage(webKit: adopting, profile: profile)
            extensionBaseURL = nil
        } else if let extensionHost {
            liveView = BrowserPage(webKit: WebViewPool.shared.makeView(configuration: extensionHost.configuration), profile: profile)
            extensionBaseURL = extensionHost.baseURL
            pageTitle = extensionHost.name
            favicon = extensionHost.icon
        } else {
            liveView = opensStartPage ? BrowserPage(webKit: WebViewPool.shared.acquire(), profile: profile) : nil
            extensionBaseURL = nil
        }
        if let liveView {
            adopt(liveView)
        }
        find.driver = .browserPage { [weak self] in self?.page }
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
        let state = sessionState
        let url = URL(string: urlString)
        guard state != nil || url != nil else { return }

        let outgoing = page
        retire(outgoing)
        stoppedNavigation = false

        // Keep the session and create a replacement view when the tab becomes visible.
        liveView = nil
        hasPresentedContent = false
        deferRestore(state: state, url: url)
        processState.markUnloaded()
    }

    @discardableResult
    private func retire(_ outgoing: BrowserPage) -> Task<Void, Never> {
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
        outgoing.onNavigationFailed = nil
        outgoing.onContentProcessTerminated = nil
        outgoing.onHistoryChanged = nil
        outgoing.onLinkHovered = nil
        if let native = outgoing.webKit {
            native.navigationDelegate = nil
            native.uiDelegate = nil
            if let tabView = native as? TabWebView {
                tabView.onZoomChanged = nil
                tabView.onContextDownload = nil
                tabView.onPeekLink = nil
                tabView.onSummarizeLink = nil
            }
        }
        outgoing.removeFromSuperview()
        progressObservation = nil
        loadingObservation = nil
        cameraObservation = nil
        microphoneObservation = nil
        pageBackgroundObservation = nil
        addressObservation = nil
        titleObservation = nil
        backObservation = nil
        forwardObservation = nil
        fullscreenObservation = nil
        secureContentObservation = nil
        permissions.onRevoke = nil
        permissions.onPolicyChanged = nil
        navigationDelegate = nil
        let task = Task { [weak self] in
            await outgoing.close()
            guard let self, retirementGeneration == generation else { return }
            retirement = nil
            if engineSwitchTask == nil {
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

    func stopLoading() {
        pendingNavigationTask?.cancel()
        page.stopLoading()
        stoppedNavigation = true
        isLoading = false
    }

    func noteNavigationStarted() {
        stoppedNavigation = false
    }

    func reload() {
        let wasStopped = stoppedNavigation
        if wasStopped && page.isLoading && extensionBaseURL == nil
            && URL(string: urlString) != nil {
            restartPage()
            return
        }
        stoppedNavigation = false
        if let url = URL(string: urlString),
           page.backForwardList.currentItem == nil || (wasStopped && url != committedURL) {
            load(url, transition: .reload)
            return
        }
        if page.reload() == nil, extensionBaseURL == nil {
            restartPage()
        }
    }

    /// Recreate an unresponsive page in its selected engine and existing profile.
    func restartPage() {
        guard !isClosed, extensionBaseURL == nil, let url = URL(string: urlString) else { return }
        pendingNavigationTask?.cancel()
        pendingNavigationTask = Task { [weak self] in
            guard let self else { return nil }
            onContentProcessTerminated?()
            guard await replaceEngine(with: engine, force: true), !Task.isCancelled else { return nil }
            return loadDirect(url)
        }
    }

    @ObservationIgnored private var retirement: Task<Void, Never>?
    @ObservationIgnored private var engineSwitchTask: Task<Bool, Never>?

    func switchEngine(to engine: BrowserEngine) async -> Bool {
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

    private func replaceEngine(with engine: BrowserEngine, force: Bool = false) async -> Bool {
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
        retiredView = nil
        liveView = nil
        self.engine = engine
        stoppedNavigation = false
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
        return true
    }

    var onLocationRevoked: (() -> Void)?

    var onSameDocumentNavigation: (() -> Void)?

    var onContentProcessTerminated: (() -> Void)?

    private(set) var isClosed = false

    func detach() {
        guard !isClosed else { return }
        isClosed = true
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
        onOpenInPeek = nil
        onSummarizeLink = nil
        onCloseRequested = nil
        onPictureInPictureChanged = nil
        onPictureReturnExpected = nil
        onDownload = nil
        onLinkHovered = nil
        onSameDocumentNavigation = nil
        onContentProcessTerminated = nil
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

    private var zoomHost = ""

    func applySiteZoom() {
        let host = SystemPages.isSystem(page.url)
            ? ""
            : page.url?.host()?.lowercased() ?? ""
        guard host != zoomHost else { return }
        zoomHost = host
        let remembered = host.isEmpty ? nil : PageZoomStore.shared.level(for: host)
        page.pageZoom = remembered ?? BrowserSettings.shared.pageZoom
        zoomChanges &+= 1
    }

    fileprivate func recordSiteZoom() {
        guard !isPrivate, !zoomHost.isEmpty else { return }
        PageZoomStore.shared.set(page.pageZoom, for: zoomHost)
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

    private(set) var pendingTransition: HistoryStore.Transition = .typed

    func noteTransition(_ transition: HistoryStore.Transition) {
        pendingTransition = transition
    }

    /// A new tab is still on its way to the start page; two navigations race.
    private func stopUncommittedStartPage() {
        guard committedURL == nil, SystemPages.isStart(page.url) else { return }
        page.stopLoading()
    }

    @discardableResult
    func load(_ url: URL, transition: HistoryStore.Transition = .typed) -> PageNavigation? {
        guard !isClosed else { return nil }
        pendingNavigationTask?.cancel()
        pendingTransition = transition
        let desired = preferredEngine(for: url)
        let previous = urlString
        urlString = url.absoluteString
        if liveView.map({ $0.engine != desired }) == true || retirement != nil || engineSwitchTask != nil {
            lastRequestedNavigation = nil
            pendingNavigationTask = Task { [weak self] in
                guard let self else { return nil }
                if liveView.map({ $0.engine != desired }) == true
                    && (hasEditedForm || isAgentWorking || isPlayingAudio || isSharingScreen
                        || !permissions.live.isEmpty || hasActiveDownload?() == true) {
                    guard await ConfirmAlert.destructive(
                        "Switch rendering engine?",
                        detail: "This reloads the website and may end active work, media, or downloads.",
                        verb: "Switch Engine"
                    ) else {
                        if !Task.isCancelled {
                            urlString = previous
                        }
                        return nil
                    }
                }
                guard !Task.isCancelled, await replaceEngine(with: desired), !Task.isCancelled else { return nil }
                let result = loadDirect(url)
                lastRequestedNavigation = result
                return result
            }
            return nil
        }
        let result = loadDirect(url)
        lastRequestedNavigation = result
        return result
    }

    private func loadDirect(_ url: URL) -> PageNavigation? {
        discardDeferredSession()
        autofillSave.clear()
        stopUncommittedStartPage()
        permitSystemPage(url)
        if url.isFileURL {
            return page.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return page.load(URLRequest(url: url))
    }

    func waitForPendingNavigation() async -> PageNavigation? {
        guard let task = pendingNavigationTask else { return lastRequestedNavigation }
        return await task.value
    }

    func loadHTML(_ html: String, baseURL: URL?) {
        guard !isClosed else { return }
        pendingNavigationTask?.cancel()
        autofillSave.clear()
        discardDeferredSession()
        if retirement != nil || engineSwitchTask != nil {
            pendingNavigationTask = Task { [weak self] in
                guard let self else { return nil }
                if let pending = engineSwitchTask {
                    _ = await pending.value
                }
                await waitForRetirement()
                guard !isClosed, !Task.isCancelled else { return nil }
                stopUncommittedStartPage()
                let result = page.loadHTMLString(html, baseURL: baseURL)
                lastRequestedNavigation = result
                return result
            }
            return
        }
        stopUncommittedStartPage()
        lastRequestedNavigation = page.loadHTMLString(html, baseURL: baseURL)
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

    private func discardDeferredSession() {
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

    func refreshCanvas(from page: BrowserPage) {
        canvasColor = isShowingRealPage && hasPresentedContent
            ? page.underPageBackgroundColor
            : nil
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
            title = Self.placeholderTitle
            favicon = nil
        } else if let page = InternalPage(url: url) {
            urlString = url?.absoluteString ?? page.url.absoluteString
            title = page.title
            favicon = nil
        } else if SystemPages.isStart(url) {
            // The start page takes the row's name back only over a page that had one.
            let leftOwnPage = InternalPage(url: URL(string: urlString)) != nil
            if leftOwnPage || (displaced != nil && displaced != committedURL) {
                urlString = ""
                title = Self.placeholderTitle
                favicon = nil
            }
        } else {
            if let url, !(isShowingError && page.chromium?.htmlDocumentURL == url) {
                urlString = url.absoluteString
            }
            if let pageTitle = page.title, !pageTitle.isEmpty {
                title = pageTitle
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

    var isShowingError = false
    var isLoadingErrorPage = false

    func declaredFaviconChanged() {
        guard extensionBaseURL == nil, !isPrivate, !isShowingSystemPage else { return }
        guard let host = page.url?.host()?.lowercased() else { return }
        FaviconLoader.shared.forget(host: host)
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
        if let cached = FaviconLoader.shared.cached(for: host) {
            favicon = cached
            guard FaviconLoader.shared.isGuessedIcon(for: host) else { return }
        }
        Task { [weak self] in
            guard let self else { return }
            let icon = await FaviconLoader.shared.load(for: page)
            guard let icon, page.url?.host()?.lowercased() == host else { return }
            favicon = icon
        }
    }
}

extension BrowserTab: Equatable {
    nonisolated static func == (lhs: BrowserTab, rhs: BrowserTab) -> Bool {
        lhs === rhs
    }
}
