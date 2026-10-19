// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CryptoKit
import Foundation

/// One page the person asked to be told about. Created only by the person (the page menu, or the assistant
/// after a consent prompt), never by an external app, so nothing here names a requester.
nonisolated struct PageWatch: Identifiable, Codable, Equatable, Sendable {
    /// Whose sign-ins a reading uses. `signedIn` is the person's explicit choice for this one watch.
    enum Access: String, Codable, Sendable {
        case anonymous
        case signedIn
    }

    let id: UUID
    let url: URL
    var title: String
    let condition: String
    let interval: TimeInterval
    let access: Access
    /// The time the person agreed to watch this page. A reading never happens before it.
    let created: Date
    var nextCheck: Date
    var lastChecked: Date?
    var fingerprint: String?
    var snapshot: String?
    var state: String?
    var failures = 0

    static let intervals: ClosedRange<TimeInterval> = 300...86_400
    static let lifetime: TimeInterval = 30 * 86_400
    static let failureLimit = 3
    static let limit = 20
    static let snapshotLimit = 6_000
    static let titleLimit = 300

    init(
        id: UUID,
        url: URL,
        title: String,
        condition: String,
        interval: TimeInterval,
        access: Access = .anonymous,
        created: Date,
        nextCheck: Date
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.condition = condition
        self.interval = interval
        self.access = access
        self.created = created
        self.nextCheck = nextCheck
    }

    var expires: Date {
        created + Self.lifetime
    }

    /// Three failed readings in a row. A paused watch stays in the list and keeps its place among the twenty,
    /// but nothing reads it until a check succeeds or its lifetime ends.
    var isPaused: Bool {
        failures >= Self.failureLimit
    }

    /// When the scheduler next has something to do with this watch.
    var nextWake: Date {
        isPaused ? expires : nextCheck
    }

    /// The interval the scheduler uses. A stored file that was edited by hand cannot make a watch read faster than allowed.
    var period: TimeInterval {
        Self.clamped(interval)
    }

    var place: String {
        guard let host = url.host() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isSamePage(_ landed: URL, _ watched: URL) -> Bool {
        func path(_ url: URL) -> String {
            let path = url.path()
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        func items(_ url: URL) -> Set<URLQueryItem> {
            Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        }
        return landed.host()?.lowercased() == watched.host()?.lowercased() && path(landed) == path(watched)
            && items(watched).isSubset(of: items(landed))
    }

    static func interval(minutes: Int) -> TimeInterval {
        clamped(TimeInterval(minutes) * 60)
    }

    private static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, intervals.lowerBound), intervals.upperBound)
    }
}

nonisolated struct PageWatchReading: Equatable, Sendable {
    let title: String
    let text: String
    var url: URL?

    var fingerprint: String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What the center is willing to keep, whatever the reader returned.
    func bounded() -> PageWatchReading {
        PageWatchReading(
            title: String(title.prefix(PageWatch.titleLimit)),
            text: String(text.prefix(PageWatch.snapshotLimit)),
            url: url
        )
    }
}

nonisolated struct PageWatchChange: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        let removed: String?
        let added: String?
    }

    let removed: [String]
    let added: [String]
    private let removedAnchors: [Int]
    private let addedAnchors: [Int]

    var isEmpty: Bool {
        removed.isEmpty && added.isEmpty
    }

    var pairs: [Pair] {
        let anchors = Set(removedAnchors + addedAnchors).sorted()
        return anchors.flatMap { anchor in
            let gone = zip(removedAnchors, removed).filter { $0.0 == anchor }.map(\.1)
            let new = zip(addedAnchors, added).filter { $0.0 == anchor }.map(\.1)
            return (0..<max(gone.count, new.count)).map { index in
                Pair(
                    removed: index < gone.count ? gone[index] : nil,
                    added: index < new.count ? new[index] : nil
                )
            }
        }
    }

    init(removed: [String], added: [String]) {
        self.removed = removed
        self.added = added
        removedAnchors = Array(repeating: 0, count: removed.count)
        addedAnchors = Array(repeating: 0, count: added.count)
    }

    init(from old: String, to new: String) {
        let difference = Self.segments(in: new).difference(from: Self.segments(in: old))
        var removed: [String] = []
        var removedAnchors: [Int] = []
        for case .remove(let offset, let element, _) in difference.removals {
            removedAnchors.append(offset - removed.count)
            removed.append(element)
        }
        var added: [String] = []
        var addedAnchors: [Int] = []
        for case .insert(let offset, let element, _) in difference.insertions {
            addedAnchors.append(offset - added.count)
            added.append(element)
        }
        self.removed = removed
        self.added = added
        self.removedAnchors = removedAnchors
        self.addedAnchors = addedAnchors
    }

    static func segments(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).flatMap { sentences(in: String($0)) }
    }

    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var ended = false
        for character in text {
            if ended, character.isWhitespace {
                sentences.append(current)
                current = ""
                ended = false
                continue
            }
            current.append(character)
            ended = ".!?…".contains(character)
        }
        sentences.append(current)
        return sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

nonisolated struct PageWatchVerdict: Equatable, Sendable {
    let met: Bool
    let state: String
    let message: String
}
