// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import WebKit

enum WebsiteData {
    nonisolated enum Facet: String, CaseIterable, Identifiable, Hashable, Sendable {
        case cookies
        case storage
        case serviceWorkers
        case cache

        var id: String {
            rawValue
        }

        var label: LocalizedStringResource {
            switch self {
            case .cookies:
                "Cookies"
            case .storage:
                "Local storage"
            case .serviceWorkers:
                "Background scripts"
            case .cache:
                "Cached files"
            }
        }

        var listName: LocalizedStringResource {
            switch self {
            case .cookies:
                "cookies"
            case .storage:
                "local storage"
            case .serviceWorkers:
                "background scripts"
            case .cache:
                "cached files"
            }
        }

        var types: Set<String> {
            switch self {
            case .cookies:
                [WKWebsiteDataTypeCookies]
            case .storage:
                [
                    WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeSessionStorage,
                    WKWebsiteDataTypeIndexedDBDatabases,
                    WKWebsiteDataTypeWebSQLDatabases,
                ]
            case .serviceWorkers:
                [WKWebsiteDataTypeServiceWorkerRegistrations]
            case .cache:
                [
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeFetchCache,
                    WKWebsiteDataTypeOfflineWebApplicationCache,
                ]
            }
        }

        static func facets(in types: Set<String>) -> [Facet] {
            allCases.filter { !$0.types.isDisjoint(with: types) }
        }
    }

    nonisolated static let allTypes: Set<String> = Facet.allCases.reduce(into: Set<String>()) {
        $0.formUnion($1.types)
    }

    /// One site as the list shows it. What the row says about it is worked out once, here, not each time the row is drawn.
    nonisolated struct Entry: Identifiable, Equatable, Hashable, Sendable {
        let displayName: String
        let types: Set<String>
        let engine: BrowserEngine
        let facets: [Facet]
        let summary: String
        let id: String

        init(displayName: String, types: Set<String>, engine: BrowserEngine = .webKit) {
            self.displayName = displayName
            self.types = types
            self.engine = engine
            id = "\(engine.rawValue):\(displayName)"
            facets = Facet.facets(in: types)
            let details = facets
                .map { String(localized: $0.listName) }
                .formatted(.list(type: .and, width: .narrow))
            let label = String(localized: engine.label)
            summary = details.isEmpty ? label : "\(label) · \(details)"
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.displayName == rhs.displayName && lhs.types == rhs.types && lhs.engine.rawValue == rhs.engine.rawValue
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(displayName)
            hasher.combine(types)
            hasher.combine(engine.rawValue)
        }
    }

    /// What the list needs of one WebKit record, so the entries can be built and sorted away from the main actor.
    nonisolated struct RecordSummary: Sendable {
        let displayName: String
        let types: Set<String>
    }

    /// The sites on the page and the WebKit records behind them, kept from the count so that removing a site does not count again.
    /// ponytail: data a site writes after the count is not in its records; reopening the page counts again.
    struct Snapshot {
        let entries: [Entry]
        /// WebKit's records by site name. Chromium sites have none: they are removed by origin.
        let records: [String: [WKWebsiteDataRecord]]

        init(entries: [Entry], records: [String: [WKWebsiteDataRecord]] = [:]) {
            self.entries = entries
            self.records = records
        }

        /// The snapshot without `removed`, and only those: a Chromium site and a WebKit site of the same name are two entries.
        func removing(_ removed: Set<Entry>) -> Snapshot {
            let ids = Set(removed.map(\.id))
            let webKitNames = Set(removed.lazy.filter { $0.engine == .webKit }.map(\.displayName))
            return Snapshot(
                entries: entries.filter { !ids.contains($0.id) },
                records: records.filter { !webKitNames.contains($0.key) }
            )
        }
    }

    /// The sites the page lists: every WebKit record that holds something describable and every Chromium site, by name.
    @concurrent
    nonisolated static func entries(from records: [RecordSummary], chromium: [Entry] = []) async -> [Entry] {
        let webKit = records
            .map { Entry(displayName: $0.displayName, types: $0.types) }
            .filter { !$0.facets.isEmpty }
        return (webKit + chromium)
            .map { ($0, $0.displayName) }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.engine.rawValue < $1.0.engine.rawValue
                }
                return $0.1.localizedStandardCompare($1.1) == .orderedAscending
            }
            .map(\.0)
    }

    static func snapshot(context: BrowserProfileContext) async throws -> Snapshot {
        let records = await context.dataStore.dataRecords(ofTypes: allTypes)
        let chromium = try await ChromiumRuntime.shared.websiteDataEntries(context: context)
        let summaries = records.map { RecordSummary(displayName: $0.displayName, types: $0.dataTypes) }
        return Snapshot(
            entries: await entries(from: summaries, chromium: chromium),
            records: Dictionary(grouping: records, by: \.displayName)
        )
    }

    /// The sites alone, for a caller that only counts them (`BrowsingData.siteCount`).
    static func entries(context: BrowserProfileContext) async throws -> [Entry] {
        try await snapshot(context: context).entries
    }

    /// Removes `entries` and nothing else: the WebKit records the snapshot holds for their names and the Chromium origins they name.
    /// A site the snapshot holds no record for (its data came after the count) is looked up now, so it is still removed.
    static func remove(_ entries: Set<Entry>, of snapshot: Snapshot, context: BrowserProfileContext) async throws {
        try await remove(entries, of: snapshot, context: context) {
            try await ChromiumRuntime.shared.removeWebsiteData(names: $0, context: context)
        }
    }

    /// `removeChromium` is given the origins to clear, and is not called when no Chromium site is among `entries`.
    static func remove(
        _ entries: Set<Entry>,
        of snapshot: Snapshot,
        context: BrowserProfileContext,
        removeChromium: (Set<String>) async throws -> Void
    ) async throws {
        guard !entries.isEmpty else { return }
        let webKitNames = Set(entries.lazy.filter { $0.engine == .webKit }.map(\.displayName))
        var records = webKitNames.flatMap { snapshot.records[$0] ?? [] }
        let uncounted = webKitNames.filter { snapshot.records[$0] == nil }
        if !uncounted.isEmpty {
            records += await context.dataStore.dataRecords(ofTypes: allTypes).filter { uncounted.contains($0.displayName) }
        }
        if !records.isEmpty {
            await context.dataStore.removeData(ofTypes: allTypes, for: records)
        }
        let chromiumNames = Set(entries.lazy.filter { $0.engine == .chromium }.map(\.displayName))
        if !chromiumNames.isEmpty {
            try await removeChromium(chromiumNames)
        }
    }

    static func removeAll(context: BrowserProfileContext) async throws {
        let records = await context.dataStore.dataRecords(ofTypes: allTypes)
        if !records.isEmpty {
            await context.dataStore.removeData(ofTypes: allTypes, for: records)
        }
        try await ChromiumRuntime.shared.clearData(
            context: context,
            kinds: [.cookies, .cache],
            since: Date(timeIntervalSince1970: 0)
        )
    }

    static func matches(_ entry: Entry, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let name = entry.displayName.lowercased()
        return name.hasPrefix(needle)
            || name.split(separator: ".").contains { $0.hasPrefix(needle) }
    }
}
