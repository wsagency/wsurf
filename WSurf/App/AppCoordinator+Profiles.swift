// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import os

extension AppCoordinator {
    // MARK: - Profiles

    func switchProfile(to profile: Profile) async {
        await profileSwitches.run { [weak self] in
            await self?.performProfileSwitch(to: profile)
        }
    }

    private func performProfileSwitch(to profile: Profile) async {
        guard profile.id != profiles.current.id else { return }
        // Revoked synchronously, before the first suspension, so nothing issued to this profile outlives the switch.
        // Locked again at adoption: until then the old profile's settings are still on screen and can unlock it anew.
        let leaving = profiles.current.id
        CredentialManager.lock(profileID: leaving, reason: .profileSwitch)
        switchingTo = profile
        mcpServer.stop()
        defer {
            switchingTo = nil
            mcpServer.resume()
        }

        var timing = ProfileSwitchTiming()

        conversationVoice?.stop()
        conversationVoice = nil
        voiceInput.cancel()
        agentTurns.cancel()
        agentTurns.forgetEveryConversation()
        media.releaseControl()
        statusMessage = nil
        closePalette()
        if let held = peek.take(quietly: true) {
            browser.dismissPeekTab(held)
            await held.waitForRetirement()
        }
        timing.mark("quiesce")

        browser.saveBlocking()
        timing.mark("save session")

        let closingTabs = browser.tabs
        browser.closeAllTabs(saving: false)
        for tab in closingTabs {
            await tab.waitForRetirement()
        }
        timing.mark("close tabs")

        let database = profile.isPrivate ? nil : profile.makeDatabase()
        timing.mark("open database")

        applyProfileStores(profile, database: database)
        profiles.markCurrent(profile)
        CredentialManager.lock(profileID: leaving, reason: .profileSwitch)
        timing.mark("adopt stores")

        extensions.beginAdopting(profile: profile)
        WebViewPool.shared.installExtensionController(extensions.controller)
        timing.mark("extensions")

        browser.restoreSession()
        retainAgentMemory()
        browser.ensureActiveTab()
        timing.mark("restore session")

        show(notice: profile.name)
        timing.log(isPrivate: profile.isPrivate)

        await extensions.start()
    }

    func enterPrivateBrowsing() {
        guard !profiles.isPrivate else {
            openNewTab()
            return
        }
        Task { await switchProfile(to: profiles.privateBrowsing) }
    }

    func leavePrivateBrowsing() {
        guard profiles.isPrivate || privateSession != nil else { return }
        Task {
            if profiles.isPrivate {
                await switchProfile(to: profiles.profileToReturnTo)
            }
            await endPrivateSession()
        }
    }

    func applyProfileStores(_ profile: Profile, database prepared: AppDatabase? = nil) {
        ChromiumRuntime.shared.use(profile: profile)
        PaymentCardAutofill.shared.use(profileID: profile.id)
        ContactAutofill.shared.use(profile: profile)
        PasswordAutofill.shared.use(profile: profile)
        AutofillSaveCoordinator.shared.use(profileID: profile.id)
        let database: AppDatabase
        if profile.isPrivate {
            let session = privateSession ?? PrivateBrowsingSession(
                database: prepared ?? profile.makeDatabase(),
                dataStore: profile.makeDataStore()
            )
            privateSession = session
            database = session.database
            WebViewPool.shared.useDataStore(session.dataStore)
        } else {
            database = prepared ?? profile.makeDatabase()
            WebViewPool.shared.useDataStore(profile.makeDataStore())
        }
        let sitePermissions = SitePermissions.use(file: profile.permissionsFile)
        browser.adopt(
            database: database,
            sitePermissions: sitePermissions,
            privately: profile.isPrivate
        )
        conversationLog.adopt(database: database)
        PageZoomStore.use(file: profile.zoomFile)
        applyProfileSettings(profile)
        FaviconLoader.shared.persistsToDisk = !profile.isPrivate
        settings.forcesDarkAppearance = profile.isPrivate
    }

    private func applyProfileSettings(_ profile: Profile) {
        let owner = profile
        let defaults = ProfileSettingsStore.defaults(for: owner)

        settings.useSessionDefaults(defaults)
        LLMSettings.defaults = defaults
        ContentBlocker.shared.use(defaults: defaults)
        AgentActionPolicy.use(storage: defaults)
        FaviconLoader.shared.use(cacheDirectory: FaviconLoader.cacheDirectory(for: owner))
        configureEngines()
    }

    private func endPrivateSession() async {
        guard privateSession != nil else { return }
        ChromiumRuntime.shared.endPrivateSession()
        privateSession = nil
        browser.downloads.forgetPrivateDownloads()
        FaviconLoader.shared.forgetSessionOnlyIcons()
        await Profile.erase(profiles.privateBrowsing)
        Pipeline.log.notice("profile: private session ended")
    }

    func windowDidClose() async {
        if profiles.isPrivate {
            await switchProfile(to: profiles.profileToReturnTo)
        }
        await endPrivateSession()
    }
}

private struct ProfileSwitchTiming {
    private let start = ContinuousClock.now
    private var last = ContinuousClock.now
    private var phases: [String] = []

    mutating func mark(_ phase: String) {
        let now = ContinuousClock.now
        phases.append("\(phase) \(Self.milliseconds(from: last, to: now))ms")
        last = now
    }

    func log(isPrivate: Bool) {
        let total = Self.milliseconds(from: start, to: .now)
        let detail = phases.joined(separator: ", ")
        Pipeline.log.notice("profile: switched in \(total, privacy: .public)ms, private \(isPrivate, privacy: .public) — \(detail, privacy: .public)")
    }

    private static func milliseconds(
        from: ContinuousClock.Instant,
        to: ContinuousClock.Instant
    ) -> Int {
        let elapsed = (to - from).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}
