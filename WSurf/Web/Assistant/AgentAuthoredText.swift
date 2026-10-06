// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

@MainActor
enum AgentAuthoredText {
    private struct Record {
        weak var page: BrowserPage?
        let host: String?
    }

    private static var records: [ObjectIdentifier: Record] = [:]

    static func record(in page: BrowserPage) {
        records = records.filter { $0.value.page != nil }
        records[ObjectIdentifier(page)] = Record(page: page, host: page.url?.host())
    }

    static func isPresent(in page: BrowserPage) -> Bool {
        guard let record = records[ObjectIdentifier(page)] else { return false }
        return record.page === page && record.host == page.url?.host()
    }

    static func clear(in page: BrowserPage) {
        records.removeValue(forKey: ObjectIdentifier(page))
    }
}
