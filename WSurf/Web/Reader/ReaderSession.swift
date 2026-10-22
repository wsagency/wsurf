// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// One tab's Reader: whether its page holds an article, and the article while Reader is shown. A new page starts a new
/// `generation`, so an answer about an earlier page is dropped.
@MainActor
@Observable
final class ReaderSession {
    enum Availability: Equatable {
        case unknown
        case available
        case unavailable
    }

    private(set) var availability = Availability.unknown
    private(set) var isActive = false
    private(set) var isOpening = false
    private(set) var article: ReaderArticle?
    private(set) var generation = 0

    /// The article's own translation. The website's page keeps the tab's `PageTranslation`; while Reader is shown, Translate Page
    /// acts on the article's view and this one.
    let translation = PageTranslation()

    @ObservationIgnored var driver: ReaderDriver?
    /// The page that shows the article while Reader is on screen. Print, Find and Translate Page act on it. A new view starts from
    /// the article as extracted, so whatever was translated in the old one is gone.
    @ObservationIgnored weak var presentedPage: BrowserPage? {
        didSet {
            if presentedPage !== oldValue {
                translation.documentChanged()
                // The sentence being read is marked in the view that is gone, and the text comes from it.
                stopListening()
            }
        }
    }
    /// This tab's listener, with its own on-device voice. It is made when Reader first needs it, so a tab that never reads aloud
    /// has no speech synthesizer. Tests put one in.
    @ObservationIgnored var speaker: ReaderListener?
    @ObservationIgnored var retryDelay: Duration = .milliseconds(1500)
    @ObservationIgnored private var probing: Int?

    var isAvailable: Bool {
        isActive || availability == .available
    }

    /// Ends Reader and forgets what was known about the page. Every navigation, a closed tab, a profile switch and the end of a
    /// private session come here.
    func pageChanged() {
        stopListening()
        generation &+= 1
        availability = .unknown
        isOpening = false
        isActive = false
        article = nil
        translation.documentChanged()
    }

    func probe() async {
        guard let driver, availability == .unknown, probing != generation else { return }
        let generation = generation
        probing = generation
        defer {
            if probing == generation {
                probing = nil
            }
        }
        var readerable = await driver.probe()
        if !readerable {
            try? await Task.sleep(for: retryDelay)
            guard self.generation == generation, availability == .unknown else { return }
            readerable = await driver.probe()
        }
        if !readerable {
            guard self.generation == generation, availability == .unknown else { return }
            readerable = await driver.watch()
        }
        guard self.generation == generation, availability == .unknown else { return }
        availability = readerable ? .available : .unavailable
    }

    func extract() async -> ReaderArticle? {
        guard let driver else { return nil }
        let generation = generation
        let extracted = await driver.extract()
        guard self.generation == generation else { return nil }
        if extracted != nil {
            availability = .available
        }
        return extracted
    }

    @discardableResult
    func open() async -> Bool {
        guard !isActive, !isOpening else { return isActive }
        isOpening = true
        let generation = generation
        let extracted = await extract()
        guard self.generation == generation else { return false }
        isOpening = false
        guard let extracted else {
            availability = .unavailable
            return false
        }
        article = extracted
        isActive = true
        return true
    }

    /// The article is not kept: the next time Reader opens, the page is read again.
    func close() {
        stopListening()
        isActive = false
        article = nil
        translation.documentChanged()
    }

    func toggle() {
        if isActive {
            close()
        } else {
            Task { await open() }
        }
    }

    // MARK: Reading aloud

    var listener: ReaderListener {
        if let speaker {
            return speaker
        }
        let made = ReaderListener(output: AppleSpeechOutput())
        speaker = made
        return made
    }

    /// Reads the article aloud from its headline, or pauses what is being read, or resumes it.
    func toggleListening() {
        guard isActive else { return }
        switch listener.state {
        case .idle:
            listen()
        case .playing, .paused:
            listener.togglePause()
        }
    }

    func listen() {
        guard isActive, let article else { return }
        let blocks = (article.title.isEmpty ? [] : [ReaderPage.titleBlock]) + Array(article.blocks.indices)
        listener.mark = { [weak self] spot in self?.mark(spot) }
        listener.start(blocks: blocks) { [weak self] block in await self?.passage(block) }
    }

    func stopListening() {
        speaker?.stop()
    }

    /// Reading, paused or not, as far as the menu is concerned. Asking does not make a listener.
    var isListening: Bool {
        speaker.map { $0.state != .idle } ?? false
    }

    private func mark(_ spot: ReaderSpeech.Spot?) {
        guard let page = presentedPage else { return }
        Task { [weak page] in
            guard let page else { return }
            await ReaderSpeech.mark(spot, in: page)
        }
    }

    /// The block as the article's view shows it, so a translated article is read translated.
    private func passage(_ block: Int) async -> ReaderSpeech.Passage? {
        guard isActive, let article else { return nil }
        var shown: String?
        if let page = presentedPage {
            shown = await ReaderSpeech.shownText(ofBlock: block, in: page)
        }
        var original: String?
        if block == ReaderPage.titleBlock {
            original = article.title
        } else if article.blocks.indices.contains(block) {
            original = article.blocks[block]
        }
        return ReaderSpeech.passage(
            shown: shown, original: original,
            translatedTo: translation.isActive ? translation.target : nil,
            articleLanguage: article.language
        )
    }
}
