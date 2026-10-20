// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized)
struct InputHistorySettingsKeysTests {
    private func suite(_ names: inout [String]) throws -> UserDefaults {
        let name = AppDatabase.defaultsSuite("InputHistorySettingsKeysTests.\(UUID().uuidString)")
        names.append(name)
        return try #require(UserDefaults(suiteName: name))
    }

    private func forget(_ names: [String]) {
        for name in names {
            UserDefaults().removePersistentDomain(forName: name)
        }
    }

    @Test func isOffByDefaultKeepsThirtyMinutesAndExcludesNothing() throws {
        var names: [String] = []
        defer { forget(names) }
        let settings = BrowserSettings(defaults: try suite(&names))
        #expect(!settings.recordsInputHistory)
        #expect(settings.inputHistoryRetention == .thirtyMinutes)
        #expect(settings.inputHistoryExcludedSites.isEmpty)
        #expect(InputHistoryRetention.standard == .thirtyMinutes)
    }

    @Test func choicesPersistForTheirProfileAloneAndStayOutOfTheApplicationDefaults() throws {
        var names: [String] = []
        defer { forget(names) }
        let (app, work, personal) = (try suite(&names), try suite(&names), try suite(&names))

        let workSettings = BrowserSettings(defaults: app, sessionDefaults: work)
        workSettings.recordsInputHistory = true
        workSettings.inputHistoryRetention = .untilDeleted
        workSettings.inputHistoryExcludedSites = ["bank.example.test", "mail.example.test"]

        let reopened = BrowserSettings(defaults: app, sessionDefaults: work)
        #expect(reopened.recordsInputHistory)
        #expect(reopened.inputHistoryRetention == .untilDeleted)
        #expect(reopened.inputHistoryExcludedSites == ["bank.example.test", "mail.example.test"])

        let other = BrowserSettings(defaults: app, sessionDefaults: personal)
        #expect(!other.recordsInputHistory)
        #expect(other.inputHistoryRetention == .thirtyMinutes)
        #expect(other.inputHistoryExcludedSites.isEmpty)

        // The three keys are profile settings: none is written to the application-wide defaults.
        for key in [BrowserSettings.Key.inputHistory, BrowserSettings.Key.inputHistoryRetention, BrowserSettings.Key.inputHistoryExcludedSites] {
            #expect(BrowserSettings.sessionKeys.contains(key))
            #expect(app.object(forKey: key) == nil)
        }
    }

    @Test func anUnknownRetentionFallsBackToThirtyMinutes() throws {
        var names: [String] = []
        defer { forget(names) }
        let defaults = try suite(&names)
        defaults.set("forever", forKey: BrowserSettings.Key.inputHistoryRetention)
        #expect(BrowserSettings(defaults: defaults).inputHistoryRetention == .thirtyMinutes)
    }

    @Test func everyRetentionHasAnExpiryExceptUntilDeleted() {
        let expiries = InputHistoryRetention.allCases.map(\.milliseconds)
        #expect(expiries == [1_800_000, 7_200_000, 86_400_000, 604_800_000, nil])
        #expect(InputHistoryRetention.allCases.map(\.rawValue) == ["thirtyMinutes", "twoHours", "oneDay", "oneWeek", "untilDeleted"])
    }
}
