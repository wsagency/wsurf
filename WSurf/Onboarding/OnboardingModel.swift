// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome
        case model
        case layout
        case extensions
        case bookmarks
        case finish
    }

    enum ModelChoice {
        case onDevice
        case remote
    }

    private static let completedKey = "onboarding.completed"

    private let defaults: UserDefaults

    private(set) var step: Step?

    var modelChoice: ModelChoice = .onDevice

    /// The layout picked during setup; nil until the person picks one.
    var windowStyleChoice: BrowserWindowStyle?

    private(set) var handedOverToSystemSettings = false

    /// Whether WSurf already opens web links for the system; the Set as Default button is disabled then.
    private(set) var isDefaultBrowser = false

    private(set) var hasPlayedIntro = false

    /// What asks the system whether WSurf is the default browser. A test passes its own so it never reads LaunchServices.
    private let defaultBrowserCheck: () -> Bool
    /// What asks the system to make WSurf the default. A test passes a counter, so none reaches LaunchServices.
    private let defaultBrowserRequest: @MainActor () async -> DefaultBrowser.Outcome

    init(
        defaults: UserDefaults = .standard,
        defaultBrowserCheck: @escaping () -> Bool = { DefaultBrowser.isCurrent },
        defaultBrowserRequest: @escaping @MainActor () async -> DefaultBrowser.Outcome = { await DefaultBrowser.request() }
    ) {
        self.defaults = defaults
        self.defaultBrowserCheck = defaultBrowserCheck
        self.defaultBrowserRequest = defaultBrowserRequest
    }

    var isPresented: Bool {
        step != nil
    }

    var isLastStep: Bool {
        step == Step.allCases.last
    }

    var showsNavigation: Bool {
        guard let step else { return false }
        return step != .welcome && step != .finish
    }

    func beginIfNeeded() {
        guard !defaults.bool(forKey: Self.completedKey), step == nil else { return }
        step = .welcome
    }

    func advance() {
        guard let step else { return }
        if let next = Step(rawValue: step.rawValue + 1) {
            self.step = next
        } else {
            finish()
        }
    }

    func back() {
        guard let step, let previous = Step(rawValue: step.rawValue - 1) else { return }
        self.step = previous
    }

    func markIntroPlayed() {
        hasPlayedIntro = true
    }

    func finish() {
        guard step != nil else { return }
        defaults.set(true, forKey: Self.completedKey)
        step = nil
    }

    /// Applies the setup choices to the settings. Called once, when setup ends: skipping without choosing keeps
    /// Standard, and installs that already completed setup never see the step.
    func applyChoices(to settings: BrowserSettings) {
        if let windowStyleChoice {
            settings.windowStyle = windowStyleChoice
        }
    }

    /// The Set as Default button is enabled until WSurf is the default browser.
    var canRequestDefaultBrowser: Bool {
        !isDefaultBrowser
    }

    func requestDefaultBrowser() {
        guard canRequestDefaultBrowser else { return }
        Task {
            handedOverToSystemSettings = await defaultBrowserRequest() == .handedOverToSystemSettings
            refreshDefaultBrowser()
        }
    }

    func refreshDefaultBrowser() {
        isDefaultBrowser = defaultBrowserCheck()
    }
}
