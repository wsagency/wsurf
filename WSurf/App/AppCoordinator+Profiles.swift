// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import os

extension AppCoordinator {
    // MARK: - Profiles

    func switchProfile(to profile: Profile) async {
        guard !isClosed else { return }
        if profile.isPrivate {
            requestNewWindow(isPrivate: true)
            return
        }
        await profileSwitches.run { [weak self] in
            await self?.performProfileSwitch(to: profile)
        }
    }

    private func performProfileSwitch(to profile: Profile) async {
        guard !isClosed, profile.id != profiles.current.id else { return }
        switchingTo = profile
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

        browser.markSessionClosed()
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

        applyProfileStores(profile)
        profiles.markCurrent(profile)
        application?.configureExtensions(extensions, profile: profile)
        timing.mark("adopt stores")

        prepareWindowWebServices()
        followSettings()
        updateWindowAppearance()
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
