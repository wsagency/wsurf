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

    @ObservationIgnored var driver: ReaderDriver?
    /// The page that shows the article while Reader is on screen. Print and Find act on it.
    @ObservationIgnored weak var presentedPage: BrowserPage?
    @ObservationIgnored var retryDelay: Duration = .milliseconds(1500)
    @ObservationIgnored private var probing: Int?

    var isAvailable: Bool {
        isActive || availability == .available
    }

    /// Ends Reader and forgets what was known about the page. Every navigation, a closed tab, a profile switch and the end of a
    /// private session come here.
    func pageChanged() {
        generation &+= 1
        availability = .unknown
        isOpening = false
        isActive = false
        article = nil
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
        isActive = false
        article = nil
    }

    func toggle() {
        if isActive {
            close()
        } else {
            Task { await open() }
        }
    }
}
