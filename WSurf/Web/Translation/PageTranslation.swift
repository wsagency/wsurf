// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import OSLog
@preconcurrency import Translation

/// Translates one block's segments, returning the new text by node, or nil when the block could not be translated.
typealias PageTranslator = @MainActor ([PageTranslationSegment]) async -> [Int: String]?

/// One tab's translation: what its page is in, what it can be translated to, and the run that is replacing its text.
@MainActor
@Observable
final class PageTranslation {
    enum Phase: Equatable {
        case original
        case translating
        case translated
    }

    /// Blocks asked for per round trip. The first batch is what is on screen, so it is small enough to show quickly.
    static let batchSize = 6

    private(set) var phase: Phase = .original
    private(set) var target: Locale.Language?
    private(set) var detectedLanguage: Locale.Language?
    private(set) var hasDetected = false
    private(set) var targets: [Locale.Language] = []

    @ObservationIgnored private(set) var document = 0
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var detection: Task<Locale.Language?, Never>?

    var isActive: Bool {
        phase != .original
    }

    func documentChanged() {
        document += 1
        request += 1
        job?.cancel()
        job = nil
        detection?.cancel()
        detection = nil
        phase = .original
        target = nil
        detectedLanguage = nil
        hasDetected = false
        targets = []
    }

    func offer(_ targets: [Locale.Language]) {
        self.targets = targets
    }

    func detectLanguage(in page: BrowserPage) async -> Locale.Language? {
        if hasDetected {
            return detectedLanguage
        }
        if let detection {
            return await detection.value
        }
        let expected = document
        let task = Task { [weak page] () -> Locale.Language? in
            guard let page, let sample = await PageTranslationScript.sample(in: page) else { return nil }
            return await TranslationLanguage.detectInBackground(sample)
        }
        detection = task
        let language = await task.value
        guard document == expected else { return nil }
        detection = nil
        detectedLanguage = language
        hasDetected = language != nil
        return language
    }

    /// A same-document move (a single-page app changing its route) may show text in another language, so it is detected again,
    /// unless a translation is running, which keeps following the page's new content.
    func pageMoved() {
        guard !isActive else { return }
        document += 1
        detection?.cancel()
        detection = nil
        detectedLanguage = nil
        hasDetected = false
        targets = []
    }

    func begin(to target: Locale.Language) -> Int {
        request += 1
        job?.cancel()
        job = nil
        self.target = target
        phase = .translating
        return request
    }

    func isCurrent(_ request: Int) -> Bool {
        self.request == request
    }

    func abandon(_ request: Int, in page: BrowserPage?) {
        guard isCurrent(request) else { return }
        showOriginal(in: page)
    }

    /// Replaces the page's text block by block, nearest the viewport first, until the request is replaced, the document changes or
    /// the page stops answering. The page is held weakly, so a closed tab ends the run.
    func translate(_ request: Int, in page: BrowserPage, using translator: @escaping PageTranslator) {
        guard isCurrent(request), target != nil else { return }
        job = Task { [weak self, weak page] in
            // Bound only inside the `if`, so the run never keeps the page alive between round trips.
            var started: Int?
            if let page {
                started = await PageTranslationScript.start(in: page)
            }
            guard let token = started else {
                self?.abandon(request, in: nil)
                return
            }
            var translatedAny = false
            var failedAny = false
            while let self, let page, isCurrent(request), !Task.isCancelled {
                guard let batch = await PageTranslationScript.next(limit: Self.batchSize, token: token, in: page) else {
                    // The run ended or the page stopped answering. What is already translated stays.
                    finish(request, translatedAny: translatedAny, in: page)
                    return
                }
                var texts: [Int: String] = [:]
                for segments in batch.blocks {
                    guard isCurrent(request), !Task.isCancelled else { return }
                    guard let translated = await translator(segments) else {
                        failedAny = true
                        continue
                    }
                    texts.merge(translated) { $1 }
                }
                guard isCurrent(request), !Task.isCancelled else { return }
                if !texts.isEmpty {
                    await PageTranslationScript.apply(texts, in: page)
                    guard isCurrent(request) else { return }
                    translatedAny = true
                    if phase == .translating {
                        phase = .translated
                    }
                }
                // Nothing is waiting: the page as it is now has been read once. New content wakes the next call.
                if !batch.hasMore {
                    if failedAny, !translatedAny {
                        TranslationModel.log.notice("every block failed; showing the original")
                        abandon(request, in: page)
                        return
                    }
                    if phase == .translating {
                        phase = .translated
                    }
                }
            }
        }
    }

    private func finish(_ request: Int, translatedAny: Bool, in page: BrowserPage) {
        guard isCurrent(request) else { return }
        if translatedAny {
            phase = .translated
        } else {
            abandon(request, in: page)
        }
    }

    func showOriginal(in page: BrowserPage?) {
        guard isActive else { return }
        request += 1
        job?.cancel()
        job = nil
        phase = .original
        target = nil
        guard let page else { return }
        Task { await PageTranslationScript.restore(in: page) }
    }
}

/// The installed on-device model a run uses. Nothing here reaches a network service: a missing language pack is offered through
/// the system's own download sheet, and only the language pair and the outcome are logged.
enum TranslationModel: Equatable {
    case fast
    case accurate

    static let log = Logger(subsystem: "io.wsagency.wsurf", category: "translation")

    static func choose(
        from source: Locale.Language,
        to target: Locale.Language,
        downloading prepare: ((TranslationModel, Locale.Language, Locale.Language) async -> Bool)?
    ) async -> TranslationModel? {
        let pair = "\(TranslationLanguage.key(source))>\(TranslationLanguage.key(target))"
        let fastStatus = await fast.status(from: source, to: target)
        if fastStatus == .installed {
            log.notice("\(pair, privacy: .public): fast model")
            return .fast
        }
        if await accurate.status(from: source, to: target) == .installed {
            if fastStatus == .supported, let prepare {
                Task { _ = await prepare(.fast, source, target) }
            }
            log.notice("\(pair, privacy: .public): accurate model, fast model not installed")
            return .accurate
        }
        guard fastStatus == .supported, let prepare else {
            log.notice("\(pair, privacy: .public): no model available")
            return nil
        }
        let prepared = await prepare(.fast, source, target)
        let installed = await fast.status(from: source, to: target) == .installed
        log.notice("\(pair, privacy: .public): download prepared=\(prepared) installed=\(installed)")
        return prepared && installed ? .fast : nil
    }

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        if #available(macOS 26.4, *) {
            return await LanguageAvailability(preferredStrategy: strategy).status(from: source, to: target)
        }
        return await LanguageAvailability().status(from: source, to: target)
    }

    func session(from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *) {
            return TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)
        }
        return TranslationSession(installedSource: source, target: target)
    }

    func configuration(from source: Locale.Language, to target: Locale.Language) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(source: source, target: target, preferredStrategy: strategy)
        }
        return TranslationSession.Configuration(source: source, target: target)
    }

    /// A translator over one session for a whole run, skipping blocks that are already in the target language.
    func translator(from source: Locale.Language, to target: Locale.Language) -> PageTranslator {
        let session = session(from: source, to: target)
        let skipper = TranslationLanguage.Skipper(source: source, target: target)
        return { segments in
            guard await !skipper.isAlreadyTarget(segments) else { return [:] }
            return await PageTranslationRuns.translate(segments, with: session)
        }
    }

    @available(macOS 26.4, *)
    private var strategy: TranslationSession.Strategy {
        self == .fast ? .lowLatency : .highFidelity
    }
}

/// Sends a block's segments as one request, so the model sees whole sentences, and puts the result back on the nodes it came from.
/// Each segment carries its node as a link; the model keeps links on the words they cover.
enum PageTranslationRuns {
    private static let scheme = "wsurf-node"

    static func translate(_ segments: [PageTranslationSegment], with session: TranslationSession) async -> [Int: String]? {
        let nodes = segments.map(\.node)
        if #available(macOS 26.4, *) {
            guard let response = try? await session.translate(request(for: segments)) else { return nil }
            return distribute(response.attributedTargetText, fallback: response.targetText, over: nodes)
        }
        guard let response = try? await session.translate(segments.map(\.text).joined()) else { return nil }
        return distribute(nil, fallback: response.targetText, over: nodes)
    }

    static func request(for segments: [PageTranslationSegment]) -> AttributedString {
        var request = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            part.link = URL(string: "\(scheme):\(segment.node)")
            request += part
        }
        return request
    }

    static func distribute(_ translated: AttributedString?, fallback: String, over nodes: [Int]) -> [Int: String] {
        guard let first = nodes.first else { return [:] }
        var texts = Dictionary(uniqueKeysWithValues: nodes.map { ($0, "") })
        guard let translated else {
            texts[first] = fallback
            return texts
        }
        var current = first
        for run in translated.runs {
            if let link = run.link, link.scheme == scheme, let node = Int(link.absoluteString.dropFirst(scheme.count + 1)),
               texts[node] != nil {
                current = node
            }
            texts[current, default: ""] += String(translated[run.range].characters)
        }
        return texts
    }
}
