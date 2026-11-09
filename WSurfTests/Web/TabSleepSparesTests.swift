// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// Which tabs Sleep inactive tabs may unload: "Favorites never sleep" (on by default) and "Pinned tabs never sleep" (off by
/// default) decide it for Favorites and pinned tabs, on both engines, for the idle sweep, memory pressure and Free Memory.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct TabSleepSparesTests {
    @Test func theOptionsDefaultToFavoritesSparedAndPinnedTabsNot() {
        let suite = AppDatabase.defaultsSuite("SleepSpares-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        var changes = 0
        settings.onSleepPolicyChanged = { changes += 1 }

        #expect(!settings.sleepsInactiveTabs, "sleeping stays off by default")
        #expect(settings.sleepSparesFavorites)
        #expect(!settings.sleepSparesPinned)

        settings.sleepSparesFavorites = false
        settings.sleepSparesPinned = true
        #expect(changes == 2, "a change reaches the window's sleep timer")
        let restored = BrowserSettings(defaults: defaults)
        #expect(!restored.sleepSparesFavorites)
        #expect(restored.sleepSparesPinned)
    }

    /// One tab of each kind, all idle for an hour, and what the sweep leaves loaded.
    struct Outcome {
        var plain = false
        var favorite = false
        var pinned = false
    }

    enum Route: CaseIterable {
        case idleSweep, criticalPressure, freeMemory
    }

    private func sleptTabs(
        engine: BrowserEngine, sparesFavorites: Bool, sparesPinned: Bool, route: Route
    ) async throws -> Outcome {
        var outcome = Outcome()
        try await LiveWindowRig.with(engine: engine) { rig in
            let settings = rig.browser.context.settings
            let wasFavorites = settings.sleepSparesFavorites
            let wasPinned = settings.sleepSparesPinned
            let wasSleeping = settings.sleepsInactiveTabs
            defer {
                settings.sleepSparesFavorites = wasFavorites
                settings.sleepSparesPinned = wasPinned
                settings.sleepsInactiveTabs = wasSleeping
            }
            settings.sleepSparesFavorites = sparesFavorites
            settings.sleepSparesPinned = sparesPinned
            settings.sleepsInactiveTabs = true

            let plain = try await rig.open("/still")
            let favorite = try await rig.open("/still")
            let pinned = try await rig.open("/still")
            favorite.isFavorite = true
            rig.browser.pin(pinned)
            try #require(pinned.isPinnedForProfile)
            _ = try await rig.open("/page")  // The tab in front, which never sleeps.
            for tab in [plain, favorite, pinned] {
                tab.lastForegroundAt = .now - .seconds(3600)
            }

            switch route {
            case .idleSweep:
                rig.browser.sleepIdleTabs(after: .seconds(60))
            case .criticalPressure:
                rig.browser.relieveMemoryPressure(.critical)
            case .freeMemory:
                rig.browser.freeMemory()
            }
            for tab in [plain, favorite, pinned] {
                await tab.waitForRetirement()
            }
            outcome = Outcome(plain: plain.isDeferred, favorite: favorite.isDeferred, pinned: pinned.isDeferred)
        }
        return outcome
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium], Route.allCases)
    func theDefaultsSleepPlainAndPinnedTabsAndKeepFavorites(engine: BrowserEngine, route: Route) async throws {
        let outcome = try await sleptTabs(engine: engine, sparesFavorites: true, sparesPinned: false, route: route)
        #expect(outcome.plain, "a plain tab sleeps")
        #expect(!outcome.favorite, "a Favorite stays loaded")
        #expect(outcome.pinned, "a pinned tab sleeps")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func sparingPinnedTabsKeepsThemLoaded(engine: BrowserEngine) async throws {
        let outcome = try await sleptTabs(engine: engine, sparesFavorites: true, sparesPinned: true, route: .idleSweep)
        #expect(outcome.plain)
        #expect(!outcome.favorite)
        #expect(!outcome.pinned, "Pinned tabs never sleep keeps it loaded")
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func notSparingFavoritesLetsThemSleep(engine: BrowserEngine) async throws {
        let outcome = try await sleptTabs(engine: engine, sparesFavorites: false, sparesPinned: false, route: .idleSweep)
        #expect(outcome.plain)
        #expect(outcome.favorite, "with Favorites never sleep off, a Favorite sleeps like any tab")
        #expect(outcome.pinned)
    }
}
