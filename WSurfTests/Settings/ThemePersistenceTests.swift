// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Counts the writes of each key, so a test can tell one write from eighty.
nonisolated final class CountingDefaults: UserDefaults {
    private let lock = NSLock()
    private var written: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { written.append(defaultName) }
        super.set(value, forKey: defaultName)
    }

    func writeCount(of key: String) -> Int {
        lock.withLock { written.count(where: { $0 == key }) }
    }
}

/// A theme choice changes the setting at once and reaches the defaults on the next turn of the main run loop.
@MainActor
struct ThemePersistenceTests {
    private static let key = "appearance.themeID"

    private func withDefaults(_ test: (CountingDefaults) async throws -> Void) async throws {
        let name = "ThemePersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(CountingDefaults(suiteName: name))
        defer {
            BrowserSettings.flushAllPendingWrites()
            defaults.removePersistentDomain(forName: name)
        }
        try await test(defaults)
    }

    private func make(_ defaults: UserDefaults) -> BrowserSettings {
        BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
    }

    /// Chooses a theme on settings that are gone when this returns.
    private func choose(_ id: String, in defaults: UserDefaults) {
        let settings = make(defaults)
        settings.themeID = id
    }

    @Test func eightySwitchesInOneTurnWriteTheLastThemeOnce() async throws {
        try await withDefaults { defaults in
            let settings = make(defaults)
            let ids = ThemeCatalog.builtIn.map(\.id)
            let before = defaults.writeCount(of: Self.key)

            for _ in 0..<10 {
                for id in ids {
                    settings.themeID = id
                    #expect(settings.resolvedTheme.id == id, "the window follows each switch at once")
                }
            }
            #expect(defaults.writeCount(of: Self.key) == before, "nothing is written during the turn")

            try #require(await waitUntil { defaults.writeCount(of: Self.key) > before })
            #expect(defaults.writeCount(of: Self.key) == before + 1)
            #expect(defaults.string(forKey: Self.key) == ids.last)

            settings.themeID = "nord"
            try #require(await waitUntil { defaults.writeCount(of: Self.key) > before + 1 })
            #expect(defaults.writeCount(of: Self.key) == before + 2 && defaults.string(forKey: Self.key) == "nord")
        }
    }

    @Test func aSwitchIsVisibleAtOnceToTheSettingsThatMadeIt() async throws {
        try await withDefaults { defaults in
            let settings = make(defaults)

            settings.themeID = "gruvbox"

            #expect(settings.themeID == "gruvbox" && settings.selectedTheme.id == "gruvbox")
            #expect(settings.resolvedTheme.id == "gruvbox" && settings.previewedTheme.id == "gruvbox")
        }
    }

    @Test func anotherSettingsObjectNeverReadsAStaleTheme() async throws {
        try await withDefaults { defaults in
            let first = make(defaults)
            first.themeID = "gruvbox"
            #expect(defaults.string(forKey: Self.key) != "gruvbox", "the write is still pending")

            let second = make(defaults)

            #expect(second.themeID == "gruvbox" && second.selectedTheme.id == "gruvbox")
            #expect(defaults.string(forKey: Self.key) == "gruvbox")
            #expect(first.themeID == "gruvbox")
        }
    }

    @Test func aRestartSeesTheLatestThemeEvenWhenTheSettingsAreGone() async throws {
        try await withDefaults { defaults in
            choose("rosePine", in: defaults)

            #expect(defaults.string(forKey: Self.key) == "rosePine", "an object that goes away writes what it had pending")
            #expect(make(defaults).themeID == "rosePine")
        }
    }

    @Test func resigningActiveOrTerminatingWritesThePendingTheme() async throws {
        #expect(Set(BrowserSettings.flushingNotifications) == [
            NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification,
        ])
        for name in BrowserSettings.flushingNotifications {
            try await withDefaults { defaults in
                let center = NotificationCenter()
                let observers = BrowserSettings.flushWhenPosted(to: center)
                defer {
                    for observer in observers {
                        center.removeObserver(observer)
                    }
                }
                let settings = make(defaults)
                settings.themeID = "dracula"
                #expect(defaults.string(forKey: Self.key) != "dracula")

                center.post(name: name, object: nil)

                #expect(defaults.string(forKey: Self.key) == "dracula", "\(name.rawValue)")
                #expect(settings.themeID == "dracula")
            }
        }
    }

    @Test func aCrashLosesOnlyTheChoicesOfTheTurnItHappensIn() async throws {
        try await withDefaults { defaults in
            let settings = make(defaults)
            settings.themeID = "nord"
            try #require(await waitUntil { defaults.string(forKey: Self.key) == "nord" })

            settings.themeID = "dracula"
            settings.themeID = "gruvbox"

            // Were the process to end here, this is what the next launch reads: the last choice of an earlier turn.
            #expect(defaults.string(forKey: Self.key) == "nord")
            #expect(settings.themeID == "gruvbox")
            BrowserSettings.flushAllPendingWrites()
            #expect(defaults.string(forKey: Self.key) == "gruvbox")
        }
    }

    @Test func onlyTheThemeSelectionWaitsForTheNextTurn() async throws {
        try await withDefaults { defaults in
            let settings = make(defaults)

            settings.sidebarFontSize = 14
            settings.themeMaterial = .glass
            let saved = try #require(settings.saveTheme(named: "Mine"))

            func stored(_ key: String) -> String {
                String(decoding: defaults.data(forKey: key) ?? Data(), as: UTF8.self)
            }
            #expect(defaults.double(forKey: "appearance.sidebar.fontSize") == 14, "other settings are written at once")
            #expect(stored("appearance.themes.adjustments").contains("glass"))
            #expect(stored("appearance.themes.user").contains("Mine"))
            #expect(defaults.string(forKey: Self.key) != saved.id, "only the selection is deferred")
            #expect(make(defaults).selectedTheme == saved, "and a reader still gets the saved theme with its selection")
        }
    }

    @Test func settingsBoundToTheAppShareItsPendingChoice() async throws {
        try await withDefaults { defaults in
            let app = make(defaults)
            let sessionName = "ThemePersistenceTests-\(UUID().uuidString)"
            let sessionDefaults = try #require(CountingDefaults(suiteName: sessionName))
            defer { sessionDefaults.removePersistentDomain(forName: sessionName) }
            let window = BrowserSettings(defaults: sessionDefaults, application: app)

            window.themeID = "catppuccin"

            #expect(app.themeID == "catppuccin" && window.themeID == "catppuccin")
            #expect(window.resolvedTheme.id == "catppuccin" && app.resolvedTheme.id == "catppuccin")
            #expect(sessionDefaults.string(forKey: Self.key) == nil, "a window keeps no copy of the app's theme")
            #expect(make(defaults).themeID == "catppuccin")
        }
    }
}
