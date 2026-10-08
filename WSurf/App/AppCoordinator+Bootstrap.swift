// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import os
import WebKit

extension AppCoordinator {
    // MARK: - Launch

    func bootstrap() async {
        prepareBrowser(restoring: true)
    }

    func prepareBrowser(restoring: Bool, show: Bool = true, urls: [URL] = []) {
        guard !isBootstrapped, !isClosed else { return }
        isBootstrapped = true
        var timing = BootstrapTiming()
        Pipeline.log.notice("bootstrap: begin")
        if application == nil {
            OutputDucker.restoreAfterUncleanExit()
            BrowserSettings.application.applyAppearance()
            let menu = MainMenu(coordinator: self)
            menu.install()
            mainMenu = menu
        }
        applyProfileStores(profiles.current)
        timing.mark("profile and assistant")
        memoryPressure.onPressure = { [weak self] level in
            self?.browser.relieveMemoryPressure(level)
        }
        memoryPressure.start()
        prepareWindowWebServices()
        followSettings()
        timing.mark("web setup")
        if restoring {
            browser.restoreSession()
        }
        for url in urls.reversed() {
            browser.newTab(url: url, transition: .link)
        }
        browser.ensureActiveTab()
        retainAgentMemory()
        timing.mark("session")
        wireMedia()
        browser.onSpaceAnchorChanged = { [weak self] from, to in
            if self?.conversationSpaceID == from {
                self?.conversationVoice?.stop()
            }
            self?.agentTurns.reassignSpace(from: from, to: to)
        }
        browser.onLinkHovered = { [weak self] tab, url, modifiers, anchor in
            guard let self else { return }
            noteLinkModifiers(modifiers)
            linkPeek.hovered(url, flags: modifiers, tabID: tab.id, anchor: anchor, context: context)
        }
        browser.onOpenInPeek = { [weak self] tab, url, origin in
            self?.openPeek(url: url, from: tab, at: origin)
        }
        browser.onOpenInNewWindow = { [weak self] _, url, isPrivate in
            self?.openLinkInNewWindow(url, isPrivate: isPrivate)
        }
        browser.onSummarizeLink = { [weak self] tab, url, anchor in
            guard let self, let tab else { return }
            linkPeek.show(url, tabID: tab.id, anchor: anchor, context: context)
        }
        linkPeek.begin()
        if application == nil || application?.windows.count == 1 {
            onboarding.beginIfNeeded()
        }
        if onboarding.isPresented {
            prepareWindowBloom()
        }
        timing.mark("window preparation")
        showBrowser(activate: show)
        timing.mark("show window")
        if application == nil {
            mcpServer.resume()
        }
        if onboarding.isPresented {
            bloomWindowOpen()
        }
        if !AppDatabase.ownsSession {
            self.show(notice: String(localized: "Another copy of WSurf is running. Changes in this window won’t be saved."))
        }
        drainQueuedExternalURLs()
        timing.mark("post-window setup")
        if application == nil {
            updates.setChannel(settings.updateChannel)
            updates.start()
        }
        if application == nil || application?.windows.count == 1 {
            MoveToApplications.reregisterDefaultBrowserIfNeeded()
            Task { [weak self] in
                guard let self, await releaseNotes.shouldOpenForNewVersion(), !isClosed else { return }
                showReleaseNotes()
            }
        }
        timing.mark("updates")
        Task { [extensions] in
            await extensions.start()
            await extensions.updateInstalledIfDue()
        }
        activation.onPress = { [weak self] in
            guard let self, isKeyWindow, !onboarding.isPresented, microphoneIsReady() else { return }
            voiceInput.begin()
        }
        activation.onRelease = { [weak self] in
            guard let self, !onboarding.isPresented else { return }
            voiceInput.scheduleFinish()
        }
        activation.setSuspended(!isKeyWindow)
        activation.start()
        installKeyMonitors()
        timing.mark("services")
        timing.log()
    }

    func prepareWindowWebServices() {
        context.contentBlocker.refresh()
        if let application {
            application.prepareWebScripts(for: self)
        } else {
            context.webViewPool.configurePage = { [weak self] page in
                self?.media.install(in: page)
                GeolocationBridge.shared.install(in: page)
                NotificationBridge.shared.install(in: page)
            }
            GeolocationBridge.shared.tabResolver = { [weak self] page in
                self?.browser.tabs.first { $0.liveView === page }
            }
            NotificationBridge.shared.tabResolver = GeolocationBridge.shared.tabResolver
            PageClickWatcher.shared.onClick = { [weak self] page, point in
                guard let self, browser.tabs.contains(where: { $0.liveView === page })
                    || peek.tab?.liveView === page else { return }
                downloadFlights.noteClick(at: point)
            }
        }
        context.webViewPool.installExtensionController(extensions.controller)
        prepareWindowHost()
        installDownloadFlights()
    }

    func engine(for configuration: Provider) -> any ModelProvider {
        modelProviders.resolve(configuration)
    }

    func configureEngines() {
        guard !isClosed else { return }
        LLMSettings.$scoped.withValue(modelSettings) {
            configureWindowEngines()
        }
    }

    func reloadAssistantConfiguration() {
        let windows = application?.windows.filter { !$0.isClosed && $0.context === context } ?? [self]
        windows.forEach { $0.configureEngines() }
    }

    private func configureWindowEngines() {
        let toolkit = AgentToolkit(
            browser: browser,
            media: media,
            log: conversationLog,
            questions: agentQuestions
        )
        agentTurns.onCancel = { [weak self] in self?.agentQuestions.abandon() }
        selectedProvider = ProviderCatalog.shared.provider(id: modelSettings.providerID) ?? ProviderCatalog.openAI
        selectedModel = modelSettings.model(for: selectedProvider)
        selectedEffort = ReasoningCatalog.resolve(
            modelSettings.reasoningEffort(for: selectedProvider),
            for: selectedProvider,
            model: selectedModel
        )

        let selected = modelProviders.resolve(selectedProvider)
        supportsReasoningEffort = selected.capabilities.contains(.reasoning)
        let onDeviceFallback = modelProviders.resolve(ProviderCatalog.appleOnDevice)
        let hostedFallback = modelProviders.resolve(ProviderCatalog.openAI)
        let decision = AgentProviderSelection.decide(
            selected: AgentProviderCandidate(
                configuration: selected.configuration,
                availability: selected.availability
            ),
            onDeviceFallback: AgentProviderCandidate(
                configuration: onDeviceFallback.configuration,
                availability: onDeviceFallback.availability
            ),
            hostedFallback: AgentProviderCandidate(
                configuration: hostedFallback.configuration,
                availability: hostedFallback.availability
            )
        )

        func use(_ provider: any ModelProvider) {
            let configuration = provider.configuration
            let built = provider.makeAgent(
                model: modelSettings.model(for: configuration),
                reasoningEffort: modelSettings.reasoningEffort(for: configuration),
                toolkit: toolkit,
                log: conversationLog
            )
            built.prepare()
            agentTurns.use(built)
            activeProvider = configuration
            isUsingSelectedProvider = configuration.id == selectedProvider.id
        }

        func unavailable() {
            agentTurns.use(nil)
            activeProvider = nil
            isUsingSelectedProvider = false
        }

        switch decision {
        case .use(let configuration, let notice):
            use(modelProviders.resolve(configuration))
            activeNotice = notice
        case .unavailable(let message):
            activeNotice = message
            unavailable()
        }
        statusMessage = selected.availability == .needsCredentials ? nil : activeNotice
        configureRemoteTools(for: activeProvider ?? selectedProvider)
        configureVoice()
        Pipeline.log.notice("Assistant engine configured")
        discoverContextWindow()
    }

    func followSettings() {
        let context = context
        let targets: () -> [AppCoordinator] = { [weak context, weak application, weak self] in
            guard let context else { return [] }
            return application?.windows.filter { !$0.isClosed && $0.context === context }
                ?? self.map { $0.isClosed ? [] : [$0] } ?? []
        }
        settings.onWebPreferencesChanged = {
            targets().forEach { $0.browser.applyWebSettings() }
        }
        media.isEnabled = settings.showsMediaPlayer
        applyPictureLending()
        sidePanel.setAvailable(settings.showsLyrics, for: .lyrics)
        updateWindowAppearance()
        browser.downloads.webViewProvider = {
            let windows = targets()
            guard let tab = (windows.first { $0.isKeyWindow } ?? windows.last)?.browser.activeTab,
                  tab.isMaterialised else { return nil }
            return tab.page.webKit
        }
        browser.downloads.onFinished = { filename in
            let windows = targets()
            (windows.first { $0.isKeyWindow } ?? windows.last)?
                .show(notice: String(localized: "Downloaded \(filename)"))
        }
        browser.downloads.onBegin = {
            targets().first { $0.isKeyWindow }?.downloadFlights.launch()
        }
    }

    func reloadBrowserConfiguration() {
        let windows = application?.windows.filter { !$0.isClosed && $0.context === context } ?? [self]
        windows.forEach {
            $0.browser.applyWebSettings()
            $0.updateWindowAppearance()
        }
    }

    private func discoverContextWindow() {
        guard let provider = activeProvider, !provider.isOnDevice else { return }
        let context = context
        let settings = context.modelSettings
        let model = settings.model(for: provider)
        guard !model.isEmpty, settings.discoveredContextWindow(for: provider, model: model) == nil else { return }
        Task { [weak self] in
            guard let window = await LLMSettings.$scoped.withValue(settings, operation: {
                await ProviderContextProbe().effectiveWindow(
                    for: provider, model: model, apiKey: CredentialStore.key(for: provider)
                )
            }), window != settings.discoveredContextWindow(for: provider, model: model) else { return }
            settings.setDiscoveredContextWindow(window, for: provider, model: model)
            Pipeline.log.notice("Model context window discovered")
            guard let self, !isClosed, self.context === context else { return }
            reloadAssistantConfiguration()
        }
    }

    // MARK: - Key monitors

    private func installKeyMonitors() {
        installEscapeHandler()
        installTabSwitchHandler()
        installDownloadFlights()
    }

    private func installDownloadFlights() {
        downloadFlights.watchClicks { [weak self] in self?.nativeWindow }
        browser.downloads.apply(settings.downloadRetention)
    }

    private func installTabSwitchHandler() {
        guard tabSwitchMonitor == nil else { return }
        noteLinkModifiers(NSEvent.modifierFlags)
        tabSwitchMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isKeyWindow else { return }
                self.controlChanged(isDown: event.modifierFlags.contains(.control), at: event.timestamp)
                self.noteLinkModifiers(event.modifierFlags)
            }
            return event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controlChanged(isDown: false, at: ProcessInfo.processInfo.systemUptime)
                self?.noteLinkModifiers([])
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isKeyWindow else { return }
                self.noteLinkModifiers(NSEvent.modifierFlags)
            }
        }
    }

    func noteLinkModifiers(_ flags: NSEvent.ModifierFlags) {
        let wanted = flags.intersection([.command, .shift])
        guard wanted != linkModifiers else { return }
        linkModifiers = wanted
    }

    private func controlChanged(isDown: Bool, at timestamp: TimeInterval) {
        guard isDown else {
            controlDownAt = nil
            browser.endTabSwitching()
            return
        }
        if controlDownAt == nil {
            controlDownAt = timestamp
        }
    }

    private func installEscapeHandler() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var claimed = false
            MainActor.assumeIsolated {
                claimed = self?.handleKey(event) ?? false
            }
            return claimed ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isKeyWindow else { return false }
        if let responder = nativeWindow?.firstResponder, responder is NSText {
            return false
        }
        if peek.isOpen,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "o" {
            keepPeek()
            return true
        }
        guard event.keyCode == 53 else { return false }
        return handleEscape()
    }

    private func handleEscape() -> Bool {
        guard isKeyWindow else { return false }
        if let responder = nativeWindow?.firstResponder, responder is NSText {
            return false
        }
        if onboarding.isPresented {
            onboarding.finish()
            return true
        }
        if isProfileSwitcherOpen {
            isProfileSwitcherOpen = false
            return true
        }
        if closePeek() {
            return true
        }
        let closedInspector = sidePanel.close()
        if conversationVoice?.isActive == true || state == .listening || state == .executing {
            voiceInput.cancel()
            stopAgent()
            return true
        }
        if isAgentSpeaking {
            speech.stopSpeaking()
            return true
        }
        if let tab = browser.activeTab, tab.isLoading {
            tab.stopLoading()
            return true
        }
        return closedInspector
    }
}

private struct BootstrapTiming {
    private let start = ContinuousClock.now
    private var last: ContinuousClock.Instant?
    private var phases: [String] = []

    mutating func mark(_ phase: String) {
        let now = ContinuousClock.now
        phases.append("\(phase) \((now - (last ?? start)).milliseconds)ms")
        last = now
    }

    func log() {
        let total = (ContinuousClock.now - start).milliseconds
        let detail = phases.joined(separator: ", ")
        Pipeline.log.notice("bootstrap: done in \(total, privacy: .public)ms, \(detail, privacy: .public)")
    }
}
