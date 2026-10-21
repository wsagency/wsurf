// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The count line under the Input History entries. The string catalog holds the plural forms; these resolve them the way the page does.
@MainActor
struct InputHistoryFootnoteTests {
    private func footnote(_ retention: InputHistoryRetention, _ count: Int) -> String {
        String(localized: retention.footnote(entries: count))
    }

    @Test func oneEntryReadsInTheSingular() {
        #expect(footnote(.thirtyMinutes, 1) == "1 entry, each kept for 30 minutes")
        #expect(footnote(.oneWeek, 1) == "1 entry, each kept for 1 week")
        #expect(footnote(.untilDeleted, 1) == "1 entry, kept until you delete it")
    }

    @Test(arguments: [0, 2, 7, 500])
    func otherCountsReadInThePlural(count: Int) {
        #expect(footnote(.twoHours, count) == "\(count) entries, each kept for 2 hours")
        #expect(footnote(.untilDeleted, count) == "\(count) entries, kept until you delete them")
    }

    @Test func everyRetentionNamesItsOwnTime() {
        let lines = InputHistoryRetention.allCases.map { footnote($0, 3) }
        #expect(Set(lines).count == InputHistoryRetention.allCases.count)
    }
}
