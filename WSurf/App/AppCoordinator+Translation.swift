// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI
@preconcurrency import Translation

extension AppCoordinator {
    /// Translates `tab` to `target`, or to the first offered or the remembered language. In a private window this request is the
    /// person's consent to read the page; nothing reads it before.
    func translatePage(_ tab: BrowserTab, to target: Locale.Language? = nil) {
        guard tab.canTranslate else { return }
        if let target {
            tab.context.settings.translationTarget = target
        }
        let downloads = translationDownloads
        let chosen = target ?? tab.translation.targets.first ?? tab.context.settings.translationTarget
        Task {
            let started = await tab.translate(to: chosen) { model, source, target in
                await downloads.prepare(model, from: source, to: target)
            }
            // A newer request for the same tab answers for itself.
            guard !started, !tab.isClosed, !tab.translation.isActive else { return }
            show(notice: String(localized: "Translation Unavailable"))
        }
    }

    func showOriginal(_ tab: BrowserTab) {
        tab.translation.showOriginal(in: tab.liveView)
    }

    func toggleTranslation(_ tab: BrowserTab) {
        if tab.translation.isActive {
            showOriginal(tab)
        } else {
            translatePage(tab)
        }
    }

    /// Turning a language on also translates the page in front of the person, which is in that language.
    func setAlwaysTranslates(_ always: Bool, _ language: Locale.Language, in tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        tab.context.settings.setAlwaysTranslates(always, language)
        if always, !tab.translation.isActive {
            translatePage(tab)
        }
    }

    func openPreferredLanguages() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Asks the system to install a language pair. The system shows its own sheet and downloads the on-device model; requests for the
/// same pair share one sheet, and a request for another pair replaces a waiting one.
@MainActor
@Observable
final class TranslationDownloads {
    private(set) var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []

    func prepare(_ model: TranslationModel, from source: Locale.Language, to target: Locale.Language) async -> Bool {
        let key = "\(model)|\(TranslationLanguage.key(source))|\(TranslationLanguage.key(target))"
        if pending != key {
            finish(false)
            pending = key
            generation += 1
            configuration = model.configuration(from: source, to: target)
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func run(preparing: () async -> Bool) async {
        guard pending != nil else { return }
        let expected = generation
        let prepared = await preparing()
        guard generation == expected else { return }
        finish(prepared && !Task.isCancelled)
    }

    func abandon() {
        guard pending != nil else { return }
        generation += 1
        finish(false)
    }

    private func finish(_ prepared: Bool) {
        let resumed = waiters
        waiters = []
        pending = nil
        configuration = nil
        for waiter in resumed {
            waiter.resume(returning: prepared)
        }
    }
}

/// Hosts the system's language download sheet for one window.
struct TranslationDownloadHost: ViewModifier {
    let downloads: TranslationDownloads

    func body(content: Content) -> some View {
        content.translationTask(downloads.configuration) { session in
            await downloads.run {
                (try? await session.prepareTranslation()) != nil
            }
        }
        .onDisappear { downloads.abandon() }
    }
}
