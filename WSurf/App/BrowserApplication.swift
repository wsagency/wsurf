// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Observation
import WebKit

/// Native windows own selection and running tasks; contexts own profile data.
@MainActor
@Observable
final class BrowserApplication {
    static let shared = BrowserApplication()

    private(set) var windows: [AppCoordinator] = []
    private(set) var activeWindowID: UUID?
    private(set) var isTerminating = false
    private var privateSessionCleanups: [UUID: Task<Void, Never>] = [:]
    let updates = UpdateController()
    private var isReady = false
    private var queuedURLs: [URL] = []
    private var usedProfiles: [UUID: BrowserProfileContext] = [:]
    private var focusOrder: [UUID] = []
    private let defaults = BrowserMCPServer.appDefaults
    private static let lastWindowKey = "browser.lastFocusedWindow"
    private var mainMenu: MainMenu?

    init() {
        installSharedRouting()
    }

    var activeCoordinator: AppCoordinator? {
        windows.first { !$0.isClosed && $0.isKeyWindow }
            ?? windows.first { !$0.isClosed && $0.windowID == activeWindowID }
            ?? windows.last { !$0.isClosed }
    }

    var externalLinkTarget: AppCoordinator? {
        if let activeCoordinator, !activeCoordinator.profiles.isPrivate {
            return activeCoordinator
        }
        return focusOrder.reversed().compactMap { id in
            windows.first { !$0.isClosed && $0.windowID == id && !$0.profiles.isPrivate }
        }.first ?? windows.last { !$0.isClosed && !$0.profiles.isPrivate }
    }

    @ObservationIgnored lazy var mcpServer = BrowserMCPServer(
        defaults: BrowserMCPServer.appDefaults,
        target: { [weak self] in
            guard let coordinator = self?.activeCoordinator,
                  !coordinator.isClosed, coordinator.nativeWindow != nil,
                  !coordinator.profiles.isPrivate, !coordinator.isSwitchingProfile
            else { return nil }
            return coordinator.browser
        },
        available: { [weak self] browser in
            self?.windows.contains {
                $0.browser === browser && !$0.isClosed && $0.nativeWindow != nil
                    && !$0.profiles.isPrivate && !$0.isSwitchingProfile && !$0.agentTurns.isRunning
            } == true
        }
    )

    func bootstrap() async {
        guard !isReady else { return }
        OutputDucker.restoreAfterUncleanExit()
        BrowserSettings.application.applyAppearance()
        let menu = MainMenu(application: self)
        mainMenu = menu
        menu.install()
        updates.setChannel(BrowserSettings.application.updateChannel)
        updates.start()
        let lastWindowID = defaults.string(forKey: Self.lastWindowKey).flatMap(UUID.init(uuidString:))
        let catalog = ProfileStore.shared
        for profile in catalog.profiles {
            let context = BrowserProfileContext.shared(for: profile)
            for saved in BrowserModel.savedWindows(in: context.database).reversed() {
                var id = saved.id
                if id == BrowserModel.legacyWindowID || windows.contains(where: { $0.windowID == id }) {
                    let uniqueID = UUID()
                    guard BrowserModel.remapSavedWindow(in: context.database, from: id, to: uniqueID) else { continue }
                    id = uniqueID
                }
                newWindow(profile: profile, windowID: id, restoring: true)
            }
        }
        if windows.isEmpty {
            newWindow(profile: catalog.current)
        }
        if let profileID = catalog.launchProfileID,
           let profile = catalog.profiles.first(where: { $0.id == profileID }) {
            let window = windows.last { $0.profiles.current.id == profileID }
                ?? newWindow(profile: profile, show: false)
            window.showBrowser()
        } else if let lastWindowID, let window = windows.first(where: { $0.windowID == lastWindowID }) {
            window.showBrowser()
        }
        isReady = true
        let queued = queuedURLs
        queuedURLs.removeAll()
        openFromAnotherApp(queued)
        if CredentialExchangeCoordinator.shared.pendingToken != nil {
            showCredentialExchange()
        }
        mcpServer.resume()
    }

    @discardableResult
    func newWindow(
        profile: Profile? = nil,
        settingsOwner: Profile? = nil,
        windowID: UUID = UUID(),
        restoring: Bool = false,
        show: Bool = true,
        urls: [URL] = []
    ) -> AppCoordinator {
        let profile = profile ?? activeCoordinator?.profiles.current ?? ProfileStore.shared.current
        let owner = settingsOwner ?? activeCoordinator.map {
            $0.profiles.isPrivate ? $0.profiles.profileToReturnTo : $0.profiles.current
        } ?? ProfileStore.shared.current
        let context = BrowserProfileContext.shared(for: profile, settingsOwner: owner)
        let browser = BrowserModel(context: context, windowID: windowID)
        let selection = ProfileStore.selection(profile: profile)
        if profile.isPrivate {
            selection.markCurrent(owner)
            selection.markCurrent(profile)
        }
        let coordinator = AppCoordinator(browser: browser, profiles: selection)
        register(coordinator)
        coordinator.prepareBrowser(restoring: restoring, show: show, urls: urls)
        if show {
            focus(coordinator)
        }
        return coordinator
    }

    func register(_ coordinator: AppCoordinator) {
        guard !coordinator.isClosed, !windows.contains(where: { $0 === coordinator }) else { return }
        precondition(!windows.contains { $0.windowID == coordinator.windowID })
        coordinator.application = self
        windows.append(coordinator)
        remember(coordinator.context)
        configureExtensions(coordinator.extensions, profile: coordinator.profiles.current)
    }

    @discardableResult
    func ensureActiveWindow() -> AppCoordinator {
        activeCoordinator ?? newWindow(profile: ProfileStore.shared.current)
    }

    func showBrowser() {
        ensureActiveWindow().showBrowser()
    }

    func focus(_ coordinator: AppCoordinator) {
        guard !coordinator.isClosed, windows.contains(where: { $0 === coordinator }) else { return }
        activeWindowID = coordinator.windowID
        focusOrder.removeAll { $0 == coordinator.windowID }
        focusOrder.append(coordinator.windowID)
        if !coordinator.profiles.isPrivate, !AppDatabase.isRunningTests {
            defaults.set(coordinator.windowID.uuidString, forKey: Self.lastWindowKey)
        }
        coordinator.extensions.focus(browser: coordinator.browser)
        for window in windows {
            window.activation.setSuspended(window !== coordinator)
        }
    }

    func didClose(_ coordinator: AppCoordinator) {
        guard !isTerminating else { return }
        mcpServer.disconnect(browser: coordinator.browser)
        coordinator.extensions.unregister(browser: coordinator.browser)
        windows.removeAll { $0 === coordinator }
        focusOrder.removeAll { $0 == coordinator.windowID }
        if activeWindowID == coordinator.windowID {
            activeWindowID = focusOrder.last ?? windows.last?.windowID
        }
    }

    func openFromAnotherApp(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard isReady else {
            queuedURLs.append(contentsOf: urls)
            return
        }
        let target = externalLinkTarget ?? newWindow(profile: ProfileStore.shared.current)
        target.openFromAnotherApp(urls)
    }

    /// The system delivers an import from another app as an activity that carries only a token. Queueing it fetches
    /// nothing: the credential page asks for the profile, the unlock and the review first, and the import is bound
    /// to the profile whose page the user reviews it from. Before bootstrap finishes the token waits in the
    /// exchange coordinator and `bootstrap` shows it.
    @discardableResult
    func receiveCredentialExchange(_ activity: NSUserActivity) -> Bool {
        guard CredentialExchangeCoordinator.shared.receive(activity) else { return false }
        if isReady {
            showCredentialExchange()
        }
        return true
    }

    /// Opens the credential page in the window external links go to: never a private window, which keeps no vault.
    private func showCredentialExchange() {
        (externalLinkTarget ?? newWindow(profile: ProfileStore.shared.current)).openSettings(.autofill)
    }

    var canReopenWindow: Bool {
        mostRecentlyClosedWindow() != nil
    }

    func reopenLastClosedWindow() {
        guard let (profile, saved) = mostRecentlyClosedWindow() else { return }
        var id = saved.id
        if windows.contains(where: { $0.windowID == id }) {
            let uniqueID = UUID()
            guard BrowserModel.remapSavedWindow(
                in: BrowserProfileContext.shared(for: profile).database, from: id, to: uniqueID
            ) else { return }
            id = uniqueID
        }
        newWindow(profile: profile, windowID: id, restoring: true)
    }

    private func mostRecentlyClosedWindow() -> (Profile, BrowserModel.SavedBrowserWindow)? {
        ProfileStore.shared.profiles.flatMap { profile in
            BrowserModel.savedWindows(in: BrowserProfileContext.shared(for: profile).database, includeClosed: true)
                .filter { $0.closedAt != nil }
                .map { (profile, $0) }
        }.max { ($0.1.closedAt ?? .distantPast) < ($1.1.closedAt ?? .distantPast) }
    }

    func coordinator(for page: BrowserPage) -> AppCoordinator? {
        windows.first { coordinator in
            !coordinator.isClosed && coordinator.context === page.context
                && (coordinator.browser.tabs.contains { $0.liveView === page }
                    || coordinator.peek.tab?.liveView === page)
        }
    }

    private func installSharedRouting() {
        GeolocationBridge.shared.tabResolver = { [weak self] page in
            self?.coordinator(for: page)?.browser.tabs.first { $0.liveView === page }
        }
        NotificationBridge.shared.tabResolver = GeolocationBridge.shared.tabResolver
        TabWebView.refreshHoverShield = { [weak self] in
            self?.windows.forEach { $0.applyHoverShield() }
        }
        PageClickWatcher.shared.onClick = { [weak self] page, point in
            self?.coordinator(for: page)?.downloadFlights.noteClick(at: point)
        }
        AutofillSuggestions.shared.openSettings = { [weak self] in
            self?.ensureActiveWindow().openSettings(.autofill)
        }
        let settings = BrowserSettings.application
        settings.onWebPreferencesChanged = { [weak self] in
            self?.windows.forEach { $0.browser.applyWebSettings() }
        }
        settings.onUpdateChannelChanged = { [weak self] channel in
            self?.updates.setChannel(channel)
        }
        settings.onLyricsChanged = { [weak self] enabled in
            self?.windows.forEach { $0.sidePanel.setAvailable(enabled, for: .lyrics) }
        }
        settings.onMediaPlayerChanged = { [weak self] enabled in
            self?.windows.forEach { $0.media.isEnabled = enabled }
        }
        settings.onAutomaticPictureInPictureChanged = { [weak self] _ in
            self?.windows.forEach { $0.applyPictureLending() }
        }
        settings.onVideoInPlayerChanged = { [weak self] _ in
            self?.windows.forEach { $0.applyPictureLending() }
        }
    }

    func prepareWebScripts(for coordinator: AppCoordinator) {
        remember(coordinator.context)
        coordinator.context.webViewPool.configurePage = { [weak self] page in
            page.installScript(MediaCenter.frameScriptSource, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            page.addScriptMessageHandler(name: MediaCenter.frameScriptHandlerName, in: .page) { [weak self] message in
                guard let body = message.body as? String else { return }
                self?.coordinator(for: message.page)?.media.receiveScriptMessage(
                    body, from: message.page, isMainFrame: message.frameInfo.isMainFrame
                )
            }
            GeolocationBridge.shared.install(in: page)
            NotificationBridge.shared.install(in: page)
        }
    }

    func prepareToTerminate() {
        isTerminating = true
        // Every profile's vault, synchronously and before anything below can suspend. A cancelled termination leaves them
        // locked: unlocking again is one explicit user action, never an implicit one.
        CredentialManager.lockAll(reason: .termination)
        mcpServer.stop()
        for coordinator in windows {
            coordinator.stopAgent()
            coordinator.voiceInput.cancel()
            coordinator.browser.saveBlocking()
            coordinator.conversationLog.saveBlocking()
        }
    }

    func cancelTermination() {
        isTerminating = false
        mcpServer.resume()
    }

    func endPrivateSession(_ context: BrowserProfileContext) {
        guard context.profile.isPrivate, privateSessionCleanups[context.contextID] == nil else { return }
        privateSessionCleanups[context.contextID] = Task { [weak self] in
            await context.endPrivateSession()
            self?.privateSessionCleanups[context.contextID] = nil
        }
    }

    func clearDataOnQuitIfNeeded() async throws {
        // Preflight all persistent contexts before deleting any data or closing private pages.
        for context in usedProfiles.values where context.settings.clearsDataOnQuit {
            try ChromiumRuntime.shared.preflightClearData(context: context, kinds: [.cookies, .cache], since: .distantPast)
        }
        for coordinator in windows where coordinator.profiles.isPrivate {
            coordinator.closePeekImmediately()
            coordinator.browser.closeAllTabs(saving: false)
            coordinator.conversationLog.clearAll()
            endPrivateSession(coordinator.context)
        }
        for cleanup in Array(privateSessionCleanups.values) {
            await cleanup.value
        }
        for context in usedProfiles.values where context.settings.clearsDataOnQuit {
            let tabs = windows.filter { $0.context === context }.flatMap { $0.browser.tabs }
            try await BrowsingData.clearEverything(
                history: context.history,
                tabs: tabs, context: context
            )
        }
    }

    var hasDataToClearOnQuit: Bool {
        !privateSessionCleanups.isEmpty || windows.contains { $0.profiles.isPrivate }
            || usedProfiles.values.contains { $0.settings.clearsDataOnQuit }
    }

    func closePagesForTermination() async {
        for coordinator in windows {
            coordinator.media.releaseControl()
            coordinator.media.unwatch()
            coordinator.closePeekImmediately()
            let tabs = coordinator.browser.tabs
            coordinator.browser.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
        }
        await ChromiumRuntime.shared.shutdown()
    }

    func finishTermination() {
        for context in usedProfiles.values {
            context.downloads.clearOnQuitIfNeeded(context.settings.downloadRetention)
        }
    }

    private func remember(_ context: BrowserProfileContext) {
        if !context.profile.isPrivate {
            usedProfiles[context.profile.id] = context
        }
    }

    func forgetProfile(_ id: UUID) {
        usedProfiles[id] = nil
    }

    func configureExtensions(_ manager: ExtensionManager, profile: Profile) {
        manager.onOpenWindow = { [weak self, weak manager] configuration in
            guard let self, let manager,
                  let source = windows.first(where: { !$0.isClosed && $0.extensions === manager }) else { return nil }
            let owner = source.profiles.isPrivate ? source.profiles.profileToReturnTo : profile
            let coordinator = newWindow(
                profile: configuration.shouldBePrivate ? .privateBrowsing() : owner,
                settingsOwner: owner, show: configuration.shouldBeFocused
            )
            let initialTabs = coordinator.browser.tabs
            var hasRequestedTab = !configuration.tabURLs.isEmpty
            for url in configuration.tabURLs.reversed() {
                coordinator.openNewTab(url: url)
            }
            for adapter in configuration.tabs.compactMap({ $0 as? ExtensionTabAdapter }) {
                guard let oldOwner = adapter.browser, let tab = adapter.tab else { continue }
                if coordinator.browser.adoptTab(tab, from: oldOwner) {
                    hasRequestedTab = true
                }
            }
            if hasRequestedTab {
                for tab in initialTabs {
                    coordinator.browser.close(tab, recordForReopening: false)
                }
            }
            return coordinator.extensions.adapter(for: coordinator.browser)
        }
    }
}
