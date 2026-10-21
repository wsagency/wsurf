// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// A vault's lease lasts the time chosen for that vault, counted from the unlock. Every case drives an injected clock, never wall time:
// the manager checks the lease against it on each use, so a vault is locked the moment the clock passes the deadline.

@MainActor
struct CredentialAutoLockTests {
    private typealias Vault = VaultManagerFixture.Standalone

    /// An unlocked vault over an injected clock. `stored` is the number written for the vault before the unlock, as a person (or a
    /// damaged preferences file) would have left it.
    private func withVault(stored: Int? = nil, _ body: (_ vault: Vault) async throws -> Void) async throws {
        let vault = try await VaultManagerFixture.standalone(unlocked: false)
        defer { ProfileSettingsStore.forget(vault.profile.id) }
        do {
            if let stored {
                ProfileSettingsStore.defaults(for: vault.profile).set(stored, forKey: CredentialAutoLock.key(for: vault.vault.vaultID))
            }
            try await VaultManagerFixture.unlock(vault.vault)
            try await body(vault)
        } catch {
            vault.manager.lock(reason: .manual)
            await vault.cleanup()
            throw error
        }
        vault.manager.lock(reason: .manual)
        await vault.cleanup()
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = AppDatabase.defaultsSuite("io.wsagency.wsurf.tests.autolock.\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    /// The lease is over: the vault refuses the next read and reports why it locked.
    private func expectTimedOut(_ vault: Vault) async {
        await #expect(throws: CredentialVaultError.expired) { _ = try await vault.manager.snapshot() }
        #expect(!vault.manager.isUnlocked)
        #expect(vault.manager.lastLockReason == .timeout)
    }

    private func unlockAgain(_ vault: Vault) async throws {
        try await VaultManagerFixture.unlock(vault.vault)
    }

    // MARK: The stored choice

    @Test(arguments: CredentialAutoLock.allCases)
    func everyChoiceIsStoredPerVaultAndReadBack(choice: CredentialAutoLock) {
        withDefaults { defaults in
            let (first, second) = (UUID(), UUID())

            CredentialAutoLock.store(choice, for: first, in: defaults)

            #expect(CredentialAutoLock.stored(for: first, in: defaults) == choice)
            // "When WSurf quits" is stored as 0, so a vault that was never set must not read it back.
            #expect(CredentialAutoLock.stored(for: second, in: defaults) == .fiveMinutes)
        }
    }

    @Test(arguments: [1, 59, 61, 301, 7_200, 86_400, -300, Int.max])
    func anUnlistedStoredNumberMeansFiveMinutes(value: Int) {
        withDefaults { defaults in
            let vault = UUID()
            defaults.set(value, forKey: CredentialAutoLock.key(for: vault))

            #expect(CredentialAutoLock.stored(for: vault, in: defaults) == .fiveMinutes)
        }
    }

    @Test func aStoredValueThatIsNotAWholeNumberMeansFiveMinutes() {
        withDefaults { defaults in
            let vault = UUID()
            let values: [Any] = ["900", 900.5, Data([1]), [900]]
            for value in values {
                defaults.set(value, forKey: CredentialAutoLock.key(for: vault))
                #expect(CredentialAutoLock.stored(for: vault, in: defaults) == .fiveMinutes, "\(value)")
            }
        }
    }

    @Test func eachTimedChoiceLastsItsNameAndQuitHasNoTimer() {
        let minutes = CredentialAutoLock.allCases.compactMap(\.lifetime).map { $0 / .seconds(60) }
        #expect(minutes == [1, 5, 15, 30, 60])
        #expect(CredentialAutoLock.whenWSurfQuits.lifetime == nil)
        #expect(CredentialAutoLock.allCases.last == .whenWSurfQuits)
        #expect(Set(CredentialAutoLock.allCases.map(\.label)).count == CredentialAutoLock.allCases.count)
    }

    // MARK: The lease

    @Test(arguments: [nil, 1, 7_200] as [Int?])
    func aMissingOrUnknownSettingLocksAfterFiveMinutes(stored: Int?) async throws {
        try await withVault(stored: stored) { vault in
            #expect(vault.manager.autoLock == .fiveMinutes)
            vault.clock.advance(by: .seconds(299))
            #expect(vault.manager.isUnlocked)
            vault.clock.advance(by: .seconds(1))
            await expectTimedOut(vault)
        }
    }

    @Test(arguments: CredentialAutoLock.allCases.filter { $0.lifetime != nil })
    func theChosenTimeLocksTheVault(choice: CredentialAutoLock) async throws {
        let lifetime = try #require(choice.lifetime)
        try await withVault(stored: choice.rawValue) { vault in
            vault.clock.advance(by: lifetime - .seconds(1))
            #expect(vault.manager.isUnlocked)
            _ = try await vault.manager.snapshot()

            vault.clock.advance(by: .seconds(1))

            await expectTimedOut(vault)
        }
    }

    @Test func usingTheVaultNeverExtendsTheLease() async throws {
        try await withVault(stored: CredentialAutoLock.fifteenMinutes.rawValue) { vault in
            vault.clock.advance(by: .seconds(14 * 60))
            try await VaultManagerFixture.save([VaultFixtures.account()], in: vault.vault)
            _ = try await vault.manager.snapshot()

            vault.clock.advance(by: .seconds(60))

            await expectTimedOut(vault)
        }
    }

    @Test(arguments: [CredentialLockReason.sleep, .screenLock, .termination, .profileSwitch, .manual])
    func whenWSurfQuitsNeverTimesOutButEveryLockEventStillLocks(reason: CredentialLockReason) async throws {
        try await withVault(stored: CredentialAutoLock.whenWSurfQuits.rawValue) { vault in
            vault.clock.advance(by: .seconds(30 * 24 * 3_600))
            #expect(vault.manager.isUnlocked)
            _ = try await vault.manager.snapshot()

            vault.manager.lock(reason: reason)

            #expect(!vault.manager.isUnlocked)
            #expect(vault.manager.lastLockReason == reason)
        }
    }

    @Test func lockAllLocksAVaultThatNeverTimesOut() async throws {
        // `exclusive`: a session-wide lock would otherwise lock the managers of every test running at the same time.
        try await VaultManagerFixture.exclusive {
            try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, vaults in
                try vaults[0].manager.setAutoLock(.whenWSurfQuits)
                vaults[0].manager.lock(reason: .manual)
                try await VaultManagerFixture.unlock(vaults[0])
                #expect(vaults[0].manager.isUnlocked)

                CredentialManager.lockAll(reason: .termination)

                #expect(!vaults[0].manager.isUnlocked)
                #expect(vaults[0].manager.lastLockReason == .termination)
            }
        }
    }

    @Test func thePendingUnlockStaysFiveMinutesWhateverTheSetting() async throws {
        try await withVault(stored: CredentialAutoLock.oneMinute.rawValue) { vault in
            // Unlocked once already at the start of the clock: lock it and open a new unlock that stays pending.
            vault.manager.lock(reason: .manual)
            let proof = vault.vault.proof

            // A passkey prompt open for 4 min 59 s still completes under a one-minute setting, and the minute starts at the unlock.
            let late = vault.manager.beginAccess()
            vault.clock.advance(by: .seconds(299))
            try await vault.manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: late)
            vault.clock.advance(by: .seconds(59))
            #expect(vault.manager.isUnlocked)
            vault.clock.advance(by: .seconds(1))
            await expectTimedOut(vault)

            // The unlock itself is bounded by five minutes, not by the setting.
            let expired = vault.manager.beginAccess()
            vault.clock.advance(by: .seconds(300))
            await #expect(throws: CredentialVaultError.expired) {
                try await vault.manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: expired)
            }
            #expect(!vault.manager.isUnlocked)
        }
    }

    // MARK: Changing the time

    @Test func aShorterTimeAppliesNowAtTheUnlockPlusTheNewTime() async throws {
        try await withVault(stored: CredentialAutoLock.oneHour.rawValue) { vault in
            vault.clock.advance(by: .seconds(10 * 60))

            try vault.manager.setAutoLock(.fifteenMinutes)

            vault.clock.advance(by: .seconds(4 * 60 + 59))
            #expect(vault.manager.isUnlocked)
            vault.clock.advance(by: .seconds(1))
            await expectTimedOut(vault)
        }
    }

    @Test func aTimeShorterThanTheTimeAlreadySpentLocksAtOnce() async throws {
        try await withVault(stored: CredentialAutoLock.oneHour.rawValue) { vault in
            vault.clock.advance(by: .seconds(20 * 60))

            try vault.manager.setAutoLock(.fifteenMinutes)

            #expect(!vault.manager.isUnlocked)
            #expect(vault.manager.lastLockReason == .timeout)
            #expect(vault.manager.autoLock == .fifteenMinutes)
        }
    }

    @Test func aLongerTimeWaitsForTheNextUnlock() async throws {
        try await withVault { vault in
            vault.clock.advance(by: .seconds(2 * 60))

            try vault.manager.setAutoLock(.oneHour)

            #expect(vault.manager.autoLock == .oneHour)
            vault.clock.advance(by: .seconds(3 * 60))
            await expectTimedOut(vault)

            try await unlockAgain(vault)
            vault.clock.advance(by: .seconds(59 * 60))
            #expect(vault.manager.isUnlocked)
            vault.clock.advance(by: .seconds(60))
            await expectTimedOut(vault)
        }
    }

    @Test func choosingWhenWSurfQuitsKeepsTheRunningLeaseAndTheNextOneHasNoTimer() async throws {
        try await withVault(stored: CredentialAutoLock.oneHour.rawValue) { vault in
            try vault.manager.setAutoLock(.whenWSurfQuits)
            vault.clock.advance(by: .seconds(59 * 60))
            #expect(vault.manager.isUnlocked)
            vault.clock.advance(by: .seconds(60))
            await expectTimedOut(vault)

            try await unlockAgain(vault)
            vault.clock.advance(by: .seconds(30 * 24 * 3_600))
            #expect(vault.manager.isUnlocked)
        }
    }

    @Test func choosingTheSameTimeAgainNeverRestartsTheLease() async throws {
        try await withVault { vault in
            vault.clock.advance(by: .seconds(4 * 60))

            try vault.manager.setAutoLock(.fiveMinutes)

            vault.clock.advance(by: .seconds(60))
            await expectTimedOut(vault)
        }
    }

    @Test func changingTheTimeNeedsTheVaultUnlocked() async throws {
        try await withVault { vault in
            let key = CredentialAutoLock.key(for: vault.vault.vaultID)
            let defaults = ProfileSettingsStore.defaults(for: vault.profile)
            vault.manager.lock(reason: .manual)

            #expect(throws: CredentialVaultError.unauthorized) { try vault.manager.setAutoLock(.oneHour) }

            #expect(vault.manager.autoLock == .fiveMinutes)
            #expect(defaults.object(forKey: key) == nil)

            // A lease that ran out is as closed as a lock: it cannot change the setting either.
            try await unlockAgain(vault)
            vault.clock.advance(by: .seconds(300))
            #expect(throws: CredentialVaultError.unauthorized) { try vault.manager.setAutoLock(.oneHour) }
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func theSettingIsPerVault() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            try vaults[0].manager.setAutoLock(.fifteenMinutes)

            let defaults = ProfileSettingsStore.defaults(for: profile)
            #expect(CredentialAutoLock.stored(for: vaults[0].vaultID, in: defaults) == .fifteenMinutes)
            #expect(CredentialAutoLock.stored(for: vaults[1].vaultID, in: defaults) == .fiveMinutes)
            #expect(CredentialAutoLock.key(for: vaults[0].vaultID) != CredentialAutoLock.key(for: vaults[1].vaultID))

            // The next unlock of each vault reads its own choice.
            for vault in vaults {
                vault.manager.lock(reason: .manual)
                try await VaultManagerFixture.unlock(vault)
            }
            #expect(vaults.map { $0.manager.autoLock } == [.fifteenMinutes, .fiveMinutes])
        }
    }

    // MARK: From the page

    @Test func choosingATimeOnThePageStoresItForThatVault() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let model = CredentialSettingsModel(profile: profile, manager: vaults[0].manager)
            #expect(model.autoLock == .fiveMinutes)

            model.setAutoLock(.oneHour)

            #expect(model.error == nil)
            #expect(model.autoLock == .oneHour)
            #expect(CredentialAutoLock.stored(for: vaults[0].vaultID, in: ProfileSettingsStore.defaults(for: profile)) == .oneHour)
        }
    }

    @Test func aLockedPageRefusesTheChoice() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, vaults in
            let model = CredentialSettingsModel(profile: profile, manager: vaults[0].manager)

            model.setAutoLock(.oneHour)

            #expect(model.error == String(localized: "Credentials are locked."))
            #expect(model.autoLock == .fiveMinutes)
        }
    }

    // MARK: Events and the lease

    @Test func aLeaseCanOnlyBeShortened() {
        let clock = TestClock()
        let start = clock.now
        let access = VaultAccess(profileID: UUID(), epoch: 1, deadline: start.advanced(by: .seconds(300)))

        access.beginLease(until: start.advanced(by: .seconds(900)))
        access.beginLease(until: start.advanced(by: .seconds(3_600)))
        #expect(access.deadline == start.advanced(by: .seconds(900)))

        access.shorten(to: start.advanced(by: .seconds(3_600)))
        #expect(access.deadline == start.advanced(by: .seconds(900)))

        access.shorten(to: start.advanced(by: .seconds(60)))
        #expect(access.isAuthorized(at: start.advanced(by: .seconds(59))))
        #expect(!access.isAuthorized(at: start.advanced(by: .seconds(60))))
    }

    @Test func lockEventsIncludeSleepDisplaySleepScreenLockUserSwitchAndQuit() {
        let events = CredentialLockEvent.all
        #expect(events.contains(.init(center: .workspace, name: NSWorkspace.willSleepNotification, reason: .sleep)))
        #expect(events.contains(.init(center: .workspace, name: NSWorkspace.screensDidSleepNotification, reason: .sleep)))
        #expect(events.contains(.init(center: .workspace, name: NSWorkspace.sessionDidResignActiveNotification, reason: .screenLock)))
        #expect(events.contains(.init(center: .distributed, name: Notification.Name("com.apple.screenIsLocked"), reason: .screenLock)))
        #expect(events.contains(.init(center: .application, name: NSApplication.willTerminateNotification, reason: .termination)))
        #expect(events.count == 5)
    }
}
