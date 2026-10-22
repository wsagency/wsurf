// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct OnboardingModelTests {
    @Test func setupAdvancesOnceAndStaysCompleted() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(defaults: defaults)

        #expect(!model.isPresented)
        model.beginIfNeeded()
        #expect(model.step == .welcome)

        model.advance()
        #expect(model.step == .model)
        model.advance()
        #expect(model.step == .layout)
        model.advance()
        #expect(model.step == .extensions)
        model.advance()
        #expect(model.step == .bookmarks)
        model.advance()
        #expect(model.step == .finish)
        #expect(model.isLastStep)
        model.advance()
        #expect(!model.isPresented)

        let reopened = OnboardingModel(defaults: defaults)
        reopened.beginIfNeeded()
        #expect(!reopened.isPresented)
    }

    @Test func goingBackWalksToTheFirstStepAndStops() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(defaults: defaults)

        model.beginIfNeeded()
        for _ in OnboardingModel.Step.allCases.dropLast() {
            model.advance()
        }
        #expect(model.step == .finish)

        model.back()
        #expect(model.step == .bookmarks)
        model.back()
        #expect(model.step == .extensions)
        model.back()
        #expect(model.step == .layout)
        model.back()
        #expect(model.step == .model)
        model.back()
        #expect(model.step == .welcome)

        model.back()
        #expect(model.step == .welcome)
        #expect(model.isPresented)
    }

    @Test func onlyTheMiddleStepsCarryNavigation() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(defaults: defaults)

        model.beginIfNeeded()
        #expect(!model.showsNavigation)
        model.advance()
        #expect(model.step == .model)
        #expect(model.showsNavigation)
        model.advance()
        #expect(model.step == .layout)
        #expect(model.showsNavigation)
        model.advance()
        #expect(model.step == .extensions)
        #expect(model.showsNavigation)
        model.advance()
        #expect(model.step == .bookmarks)
        #expect(model.showsNavigation)
        model.advance()
        #expect(!model.showsNavigation)
    }

    @Test func finishingBeforeSetupDoesNotMarkItComplete() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(defaults: defaults)

        model.finish()
        model.beginIfNeeded()

        #expect(model.step == .welcome)
    }

    @Test func aLayoutChosenDuringSetupIsAppliedWhenItCompletes() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsSuite = AppDatabase.defaultsSuite("WSurf.OnboardingModelTests.settings.\(UUID().uuidString)")
        let settingsDefaults = UserDefaults(suiteName: settingsSuite)!
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
        let settings = BrowserSettings(defaults: settingsDefaults, appliesAppearanceGlobally: false)
        let model = OnboardingModel(defaults: defaults)

        model.beginIfNeeded()
        model.advance()
        model.advance()
        #expect(model.step == .layout)
        model.windowStyleChoice = .minimal
        #expect(settings.windowStyle == .standard)

        model.applyChoices(to: settings)
        #expect(settings.windowStyle == .minimal)
    }

    @Test func skippingWithoutChoosingKeepsStandard() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsSuite = AppDatabase.defaultsSuite("WSurf.OnboardingModelTests.settings.\(UUID().uuidString)")
        let settingsDefaults = UserDefaults(suiteName: settingsSuite)!
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
        let settings = BrowserSettings(defaults: settingsDefaults, appliesAppearanceGlobally: false)
        let model = OnboardingModel(defaults: defaults)

        model.beginIfNeeded()
        model.applyChoices(to: settings)

        #expect(settings.windowStyle == .standard)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = AppDatabase.defaultsSuite("WSurf.OnboardingModelTests.\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
