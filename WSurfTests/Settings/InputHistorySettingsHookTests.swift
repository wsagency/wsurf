// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What changing an Input History setting does beyond saving it.
@MainActor
@Suite(.serialized)
struct InputHistorySettingsHookTests {
    @Test func resettingSettingsSwitchesRecordingOffAndRestoresTheDefaults() throws {
        let name = AppDatabase.defaultsSuite("InputHistorySettingsHookTests.\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = BrowserSettings(defaults: defaults)
        settings.recordsInputHistory = true
        settings.inputHistoryRetention = .untilDeleted
        settings.inputHistoryExcludedSites = ["bank.example.test"]

        settings.resetToDefaults()

        #expect(!settings.recordsInputHistory)
        #expect(settings.inputHistoryRetention == .standard)
        #expect(settings.inputHistoryExcludedSites.isEmpty)
        #expect(!BrowserSettings(defaults: defaults).recordsInputHistory)
    }

    @Test func aNewRetentionMovesTheEntriesOfItsOwnProfileOnly() async throws {
        try await VaultManagerFixture.exclusive {
            let harness = InputHistoryHarness()
            let (mine, other) = (harness.makeProfile(), harness.makeProfile())
            let context = BrowserProfileContext.shared(for: mine)
            defer {
                BrowserProfileContext.forget(mine.id)
                ProfileSettingsStore.forget(mine.id)
                harness.cleanUp()
            }
            try await harness.seed(mine, ["one"])
            try await harness.seed(other, ["two"])

            context.settings.inputHistoryRetention = .oneDay
            context.settings.applyInputHistoryRetention(to: [mine, other], history: harness.history)
            await harness.history.drain(profileID: mine.id)
            await harness.history.drain(profileID: other.id)

            try await harness.history.unlock(mine)
            try await harness.history.unlock(other)
            let moved = try #require(harness.history.unlocked[mine.id]?.first)
            #expect(try #require(moved.expiresAt).timeIntervalSince(moved.createdAt) == 24 * 60 * 60)
            let untouched = try #require(harness.history.unlocked[other.id]?.first)
            #expect(try #require(untouched.expiresAt).timeIntervalSince(untouched.createdAt) == 30 * 60)
        }
    }
}
