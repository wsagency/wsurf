// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The Dock icon is a runtime override of the Dock tile. These cases own their settings and a throwaway defaults suite;
/// only `aboutAndOnboardingShowTheBundleIcon` sets the real override, and it clears it again.
@MainActor
struct DockIconTests {
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("DockIconTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }

    private func make(_ defaults: UserDefaults, appliesGlobally: Bool = false) -> BrowserSettings {
        BrowserSettings(defaults: defaults, appliesAppearanceGlobally: appliesGlobally)
    }

    /// Two Dock pictures are the same when their pixels are; nil is the bundle icon.
    private func same(_ left: NSImage?, _ right: NSImage?) -> Bool {
        left?.tiffRepresentation == right?.tiffRepresentation
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    @Test func dockIconChoicePersistsAndUnknownValuesFallBack() throws {
        try withDefaults { defaults in
            #expect(make(defaults).dockIcon == .standard, "a fresh install keeps the bundle icon")

            for name in ["anodized", "steel", "copper", "light", "dark", "mono"] {
                let choice = try #require(DockIconChoice(rawValue: name))
                make(defaults).dockIcon = choice
                #expect(defaults.string(forKey: "appearance.dockIcon") == name)
                #expect(make(defaults).dockIcon == choice)
            }

            defaults.set("rainbow", forKey: "appearance.dockIcon")
            #expect(make(defaults).dockIcon == .standard)
            defaults.removeObject(forKey: "appearance.dockIcon")
            #expect(make(defaults).dockIcon == .standard)
        }
    }

    @Test func resettingToDefaultsReturnsToTheBundleIcon() throws {
        try withDefaults { defaults in
            let settings = make(defaults)
            settings.dockIcon = .mono

            settings.resetToDefaults()

            #expect(settings.dockIcon == .standard)
            #expect(self.make(defaults).dockIcon == .standard)
        }
    }

    @Test func defaultDockIconClearsTheOverride() throws {
        try withDefaults { defaults in
            var shown: [NSImage?] = []
            let app = make(defaults, appliesGlobally: true)
            app.showsDockIcon = { shown.append($0) }

            app.dockIcon = .dark
            app.dockIcon = .mono
            app.dockIcon = .standard

            #expect(shown.count == 3)
            #expect(same(shown[0], DockIconChoice.dark.image) && same(shown[1], DockIconChoice.mono.image))
            #expect(shown[2] == nil, "Default clears the override")
            #expect(!same(shown[0], shown[1]))
        }
    }

    @Test func onlyTheAppWideSettingsTouchTheDock() throws {
        try withDefaults { defaults in
            var shown: [NSImage?] = []
            let app = make(defaults, appliesGlobally: true)
            app.showsDockIcon = { shown.append($0) }
            let other = make(defaults)
            other.showsDockIcon = { shown.append($0) }

            other.dockIcon = .light
            #expect(shown.isEmpty, "settings that do not apply globally leave the Dock alone")

            // A window bound to the app's settings (a private window) sets the app's choice.
            let sessionSuite = AppDatabase.defaultsSuite("DockIconTests-\(UUID().uuidString)")
            let sessionDefaults = try #require(UserDefaults(suiteName: sessionSuite))
            defer { sessionDefaults.removePersistentDomain(forName: sessionSuite) }
            let session = BrowserSettings(defaults: sessionDefaults, application: app)
            session.dockIcon = .dark
            #expect(shown.count == 1 && same(shown[0], DockIconChoice.dark.image) && app.dockIcon == .dark)
            #expect(sessionDefaults.string(forKey: "appearance.dockIcon") == nil)
        }
    }

    @Test func everyAlternateDockIconLoads() throws {
        var images: [Data] = []
        for choice in DockIconChoice.allCases where choice != .standard {
            let image = try #require(choice.image, "\(choice) is missing from the asset catalog")
            #expect(image.representations.contains { $0.pixelsWide >= 1024 && $0.pixelsHigh >= 1024 })
            images.append(try #require(image.tiffRepresentation))
        }
        #expect(images.count == 6 && Set(images).count == 6, "each metallic and flat finish has its own picture")
        #expect(DockIconChoice.standard.image == nil, "Default is the bundle icon, not an image of ours")
    }

    @Test func theBundleIconMatchesTheAnodizedArtwork() throws {
        let name = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String)
        let icon = try #require(Bundle.main.image(forResource: name))
        let retina = try #require(icon.representations.first { $0.pixelsWide == 1024 && $0.pixelsHigh == 1024 })
        let image = try #require(retina.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let compiled = NSBitmapImageRep(cgImage: image)
        let artworkURL = Self.root.appending(path: "WSurf/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
        let artwork = try #require(NSBitmapImageRep(data: Data(contentsOf: artworkURL)))

        // Sample the transparent corner, dark tile and both brushed metals at their original positions.
        for (x, y) in [(0, 0), (160, 160), (500, 300), (320, 670), (900, 730)] {
            let actual = try #require(compiled.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.cgColor.components)
            let expected = try #require(artwork.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.cgColor.components)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 2 / 255 }, "bundle artwork at (\(x), \(y))")
        }
    }

    @Test func theDockIconIsReappliedAtLaunch() throws {
        try withDefaults { defaults in
            make(defaults).dockIcon = .light
            var shown: [NSImage?] = []

            let launched = make(defaults, appliesGlobally: true)
            launched.showsDockIcon = { shown.append($0) }
            #expect(shown.isEmpty, "opening the settings changes nothing")
            launched.applyDockIcon()

            #expect(shown.count == 1 && same(shown[0], DockIconChoice.light.image))
        }
    }

    @Test func bootstrapAppliesTheStoredChoiceOnceRightAfterTheAppearance() throws {
        let lines = try source("WSurf/App/BrowserApplication.swift").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let appearance = try #require(lines.firstIndex(of: "BrowserSettings.application.applyAppearance()"))
        let next = lines[(appearance + 1)...].first { !$0.hasPrefix("//") }
        #expect(next == "BrowserSettings.application.applyDockIcon()")
        #expect(lines.count(where: { $0.contains("applyDockIcon()") }) == 1)

        let perWindow = try source("WSurf/App/AppCoordinator+Bootstrap.swift")
        #expect(!perWindow.contains("applyDockIcon"), "the icon belongs to the app, not to each window")
    }

    @Test func aboutAndOnboardingShowTheBundleIcon() throws {
        let readers = ["WSurf/Settings/SettingsView.swift", "WSurf/Onboarding/OnboardingIntro.swift", "WSurf/Onboarding/OnboardingScreens.swift"]
        for path in readers {
            let text = try source(path)
            #expect(text.contains("AppIcon.bundle") && !text.contains("applicationIconImage"), "\(path)")
        }
        let app = Self.root.appending(path: "WSurf")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        let touching = try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("applicationIconImage") }
            .map(\.lastPathComponent)
        #expect(touching == ["DockIcon.swift"], "only the Dock choice writes the application icon")

        // With another picture in the Dock, the helper still returns the icon in the bundle.
        let override = try #require(NSImage(named: NSImage.Name("NSFolder")))
        DockIconChoice.show(override)
        defer { DockIconChoice.show(nil) }
        let bundle = AppIcon.bundle
        #expect(bundle.size.width >= 128)
        #expect(!same(bundle, override))
    }

    @Test func theDockIconIsNotPartOfATheme() throws {
        try withDefaults { defaults in
            let settings = make(defaults)
            let theme = settings.selectedTheme
            let adjustments = settings.themeAdjustments

            settings.dockIcon = .mono

            #expect(settings.selectedTheme == theme && settings.themeAdjustments == adjustments)
            let saved = try #require(settings.saveTheme(named: "Mine"))
            let encoded = try JSONEncoder().encode(saved) + JSONEncoder().encode(ThemeAdjustment())
            #expect(!String(decoding: encoded, as: UTF8.self).lowercased().contains("dock"))
        }
    }
}
