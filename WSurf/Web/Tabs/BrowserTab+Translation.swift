// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserTab {
    /// A loaded web page that is not an error page. WSurf's own pages, extension pages and local files are not translated.
    var canTranslate: Bool {
        guard isMaterialised, !isShowingError, let scheme = page.url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    var canToggleTranslation: Bool {
        translation.isActive || canTranslate
    }

    /// Detects the page's language after a load and offers translation when the person does not read it, translating at once
    /// when the profile always translates that language. A private window's page is never read unless the person asks for a
    /// translation, so it gets neither. Answers whether detection started.
    @discardableResult
    func offerTranslation() -> Bool {
        guard !isPrivate, canTranslate, !translation.isActive else { return false }
        let document = translation.document
        let settings = context.settings
        Task { [weak self] in
            var detected: Locale.Language?
            // A page often fills in its text after the load finishes; look again a few times before giving up.
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(1.5))
                }
                guard let self, translation.document == document, !isClosed, let page = liveView else { return }
                detected = await translation.detectLanguage(in: page)
                if detected != nil {
                    break
                }
            }
            guard let self, let source = detected, translation.document == document else { return }
            let candidates = TranslationLanguage.targets(for: source, preferring: settings.translationTargetID)
            let targets = await TranslationLanguage.translatable(candidates, from: source)
            guard translation.document == document, !isClosed else { return }
            translation.offer(targets)
            guard let target = targets.first, settings.alwaysTranslates(source) else { return }
            await translate(to: target, downloading: nil)
        }
        return true
    }

    /// A same-document move can show text in another language, so the offer is made again.
    func translationPageMoved() {
        guard !isLoading, !translation.isActive else { return }
        translation.pageMoved()
        offerTranslation()
    }

    /// Translates the page to `target`. `prepare` may show the system's language download sheet; without it, only installed
    /// languages are used. Answers whether a translation started: false when the page's language is unknown or already `target`,
    /// no model is available, or the page changed meanwhile.
    @discardableResult
    func translate(
        to target: Locale.Language,
        downloading prepare: ((TranslationModel, Locale.Language, Locale.Language) async -> Bool)?
    ) async -> Bool {
        guard canTranslate else { return false }
        // Held weakly: a download sheet can stay open while the tab closes.
        weak let current = liveView
        let request = translation.begin(to: target)
        var detected: Locale.Language?
        if let current {
            detected = await translation.detectLanguage(in: current)
        }
        guard let source = detected, translation.isCurrent(request), !TranslationLanguage.matches(source, target),
              let model = await TranslationModel.choose(from: source, to: target, downloading: prepare),
              translation.isCurrent(request), !isClosed, let page = current, liveView === page
        else {
            translation.abandon(request, in: liveView)
            return false
        }
        if translation.targets.isEmpty {
            translation.offer([target])
        }
        translation.translate(request, in: page, using: model.translator(from: source, to: target))
        return true
    }
}
