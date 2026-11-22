// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import os
import WSurfCore

extension AppCoordinator {
    // MARK: - Profiles

    func deleteProfile(_ profile: Profile, confirmedVaults: Set<VaultProfileRemoval>? = nil, scope: ProfileDeletionScope = .confirmed([])) async -> Result<Void, Error> {
        await profiles.remove(profile, confirmedVaults: confirmedVaults, releaseWindows: {
            if let application {
                await application.prepareToRemove(profile: profile)
            } else {
                await leaveErasedProfile(profile)
            }
        }, scope: scope)
    }

    func leaveErasedProfile(_ profile: Profile) async {
        await profileSwitches.run { [weak self] in
            guard let self, !isClosed, context.profile.id == profile.id, let replacement = profiles.profiles.first else { return }
            await performProfileSwitch(to: replacement, landingIn: nil, rememberOnlyIfFrontmost: true)
        }
    }

    /// `spaceID` is the space of `profile` to show once the switch is done, as choosing a space of another profile asks.
    func switchProfile(to profile: Profile, landingIn spaceID: UUID? = nil) async {
        guard !isClosed else { return }
        if profile.isPrivate {
            requestNewWindow(isPrivate: true)
            return
        }
        if spaceID == nil, reopenSharedProfileWindow(profile) {
            return
        }
        await profileSwitches.run { [weak self] in
            await self?.performProfileSwitch(to: profile, landingIn: spaceID)
        }
    }

    private func performProfileSwitch(to requested: Profile, landingIn spaceID: UUID?, rememberOnlyIfFrontmost: Bool = false) async {
        guard !isClosed, profiles.profiles.contains(where: { $0.id == requested.id }) else { return }
        guard requested.id != context.profile.id else {
            if let spaceID {
                browser.switchSpace(to: spaceID)
            }
            return
        }
        // Revoked synchronously, before the first suspension, so nothing issued to the profile being left outlives the
        // switch. Locked again at adoption: until then that profile's settings are still on screen and can unlock it anew.
        let leaving = context.profile.id
        CredentialManager.lock(profileID: leaving, reason: .profileSwitch)
        switchingTo = requested
        mcpServer.disconnect(browser: browser)
        defer { switchingTo = nil }

        var timing = ProfileSwitchTiming()

        conversationVoice?.stop()
        conversationVoice = nil
        voiceInput.cancel()
        agentTurns.cancel()
        agentTurns.forgetEveryConversation()
        media.releaseControl()
        statusMessage = nil
        closePalette()
        let oldContext = context
        closePeekImmediately()
        timing.mark("quiesce")

        if oldContext.profile.isPrivate || profiles.verifiedProfiles?.contains(where: { $0.id == leaving }) != false {
            browser.markSessionClosed()
        }
        timing.mark("save session")

        extensions.unregister(browser: browser)
        let closingTabs = browser.tabs
        browser.closeAllTabs(saving: false)
        for tab in closingTabs {
            await tab.waitForRetirement()
        }
        guard !isClosed else { return }
        if oldContext.profile.isPrivate {
            if let application {
                application.endPrivateSession(oldContext)
            } else {
                await oldContext.endPrivateSession()
                guard !isClosed else { return }
            }
        }
        timing.mark("close tabs")

        // Another window can erase the destination while the departing tabs finish closing.
        let profile = profiles.profiles.first { $0.id == requested.id } ?? .original()
        applyProfileStores(profile)
        let remember = !rememberOnlyIfFrontmost || application == nil || application?.activeCoordinator === self
        profiles.markCurrent(profile, remember: remember)
        CredentialManager.lock(profileID: leaving, reason: .profileSwitch)
        application?.configureExtensions(extensions, profile: profile)
        timing.mark("adopt stores")

        prepareWindowWebServices()
        followSettings()
        updateWindowAppearance()
        timing.mark("extensions")

        browser.restoreSession()
        retainAgentMemory()
        if let spaceID {
            browser.switchSpace(to: spaceID)
        }
        if browser.activeTabID == nil {
            browser.newTab()
        }
        timing.mark("restore session")

        show(notice: profile.name)
        timing.log(isPrivate: profile.isPrivate)

        await extensions.start()
        Task { [weak self] in await self?.offerLegacyPasswordImport() }
    }

    func enterPrivateBrowsing() {
        requestNewWindow(isPrivate: true)
    }

    func applyProfileStores(_ profile: Profile) {
        let owner = profile.isPrivate ? profiles.profileToReturnTo : profile
        if context.profile.id != profile.id {
            browser.context = .shared(for: profile, settingsOwner: owner)
        }
        linkPeek.forget()
        browser.adopt(database: context.database, sitePermissions: context.sitePermissions, privately: profile.isPrivate)
        agentTurns.adopt(context: context)
        browser.adoptSpaces(from: context.spaces)
        privateSession = profile.isPrivate
            ? PrivateBrowsingSession(database: context.database, dataStore: context.dataStore)
            : nil
        configureEngines()
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
