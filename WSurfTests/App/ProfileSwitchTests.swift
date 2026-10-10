// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

/// Switching profiles is the one move that takes the whole window apart and
/// puts it back: the tabs go, the stores are swapped, the session comes back
/// from another database. What must hold is that nothing of the old profile
/// survives into the new one.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ProfileSwitchTests {
    private func coordinator() -> AppCoordinator {
        AppCoordinator()
    }

    private func otherProfile(_ store: ProfileStore) -> Profile? {
        store.profiles.first { $0.id != store.current.id }
    }

    @Test func switchingToTheProfileYouAreInChangesNothing() async {
        let coordinator = coordinator()
        let current = coordinator.profiles.current
        let tab = coordinator.browser.newTab(url: URL(string: "https://example.com/"))

        await coordinator.switchProfile(to: current)

        #expect(coordinator.profiles.current.id == current.id)
        #expect(coordinator.browser.tabs.contains { $0 === tab }, "the session was left alone")
        #expect(!coordinator.isSwitchingProfile)
    }

    @Test func aSwitchClearsItsOwnStateWhenItIsDone() async {
        let coordinator = coordinator()
        guard let other = otherProfile(coordinator.profiles) else { return }

        await coordinator.switchProfile(to: other)

        #expect(coordinator.switchingTo == nil, "the switching state does not outlive the switch")
        #expect(!coordinator.isSwitchingProfile)
        coordinator.browser.cancelPendingSave()
    }

    @Test func theTabsOfTheProfileYouLeaveDoNotComeWithYou() async {
        let coordinator = coordinator()
        guard let other = otherProfile(coordinator.profiles) else { return }
        let left = coordinator.browser.newTab(url: URL(string: "https://leaving.example/"))

        await coordinator.switchProfile(to: other)

        #expect(!coordinator.browser.tabs.contains { $0 === left })
        #expect(coordinator.profiles.current.id == other.id)
        coordinator.browser.cancelPendingSave()
    }

    @Test func privateBrowsingIsItsOwnSessionAndLeavesNoTabsBehind() async {
        let coordinator = coordinator()
        let before = coordinator.profiles.current.id
        coordinator.browser.newTab(url: URL(string: "https://personal.example/"))

        coordinator.enterPrivateBrowsing()
        _ = await waitUntil { coordinator.profiles.isPrivate }

        let publicTabs = coordinator.browser.tabs.filter { !$0.isPrivate }.count
        #expect(coordinator.profiles.isPrivate)
        #expect(publicTabs == 0, "every tab in private browsing is private")

        coordinator.leavePrivateBrowsing()
        _ = await waitUntil { !coordinator.profiles.isPrivate }

        #expect(coordinator.profiles.current.id == before, "leaving goes back where it came from")
        coordinator.browser.cancelPendingSave()
    }

    @Test func aSwitchSaysWhichProfileItLandedIn() async {
        let coordinator = coordinator()
        guard let other = otherProfile(coordinator.profiles) else { return }

        await coordinator.switchProfile(to: other)

        #expect(coordinator.notice == other.name)
        coordinator.browser.cancelPendingSave()
    }

    /// Credential access issued to the profile being left is revoked as the switch starts; a switch to the
    /// profile you are already in changes nothing.
    @Test func leavingAProfileRevokesItsCredentialAccess() async throws {
        let coordinator = coordinator()
        let current = coordinator.profiles.current
        let access = try CredentialManager.forProfile(current).beginAccess()

        await coordinator.switchProfile(to: current)
        #expect(access.isAuthorized(at: ContinuousClock().now))

        coordinator.enterPrivateBrowsing()
        _ = await waitUntil { coordinator.profiles.isPrivate }
        #expect(coordinator.profiles.isPrivate)
        #expect(!access.isAuthorized(at: ContinuousClock().now))

        coordinator.leavePrivateBrowsing()
        _ = await waitUntil { !coordinator.profiles.isPrivate }
        coordinator.browser.cancelPendingSave()
    }

    /// Until the switch adopts the new profile the old one's settings are still on screen and can unlock it again.
    /// Access minted in that gap, after the first lock, must not outlive the switch.
    @Test func accessMintedMidSwitchDoesNotOutliveIt() async throws {
        @MainActor final class Minted { var access: VaultAccess? }
        let coordinator = coordinator()
        let manager = try CredentialManager.forProfile(coordinator.profiles.current)
        let minted = Minted()
        // `switchingTo` is set after the profile is locked and before anything is adopted.
        withObservationTracking {
            _ = coordinator.switchingTo
        } onChange: {
            MainActor.assumeIsolated { minted.access = manager.beginAccess() }
        }

        coordinator.enterPrivateBrowsing()
        _ = await waitUntil { coordinator.profiles.isPrivate && !coordinator.isSwitchingProfile }
        coordinator.leavePrivateBrowsing()
        _ = await waitUntil { !coordinator.profiles.isPrivate && !coordinator.isSwitchingProfile }
        coordinator.browser.cancelPendingSave()

        let access = try #require(minted.access, "the switch did not reach its mid-switch point")
        #expect(!access.isAuthorized(at: ContinuousClock().now))
    }
}
