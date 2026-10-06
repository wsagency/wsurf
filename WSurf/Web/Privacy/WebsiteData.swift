// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

enum WebsiteData {
    enum Facet: String, CaseIterable, Identifiable, Hashable, Sendable {
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

    static let allTypes: Set<String> = Facet.allCases.reduce(into: Set<String>()) {
        $0.formUnion($1.types)
    }

    struct Entry: Identifiable, Equatable, Hashable, Sendable {
        let displayName: String
        let types: Set<String>
        let engine: BrowserEngine

        init(displayName: String, types: Set<String>, engine: BrowserEngine = .webKit) {
            self.displayName = displayName
            self.types = types
            self.engine = engine
        }

        var id: String {
            "\(engine.rawValue):\(displayName)"
        }

        var facets: [Facet] {
            Facet.facets(in: types)
        }

        var summary: String {
            let details = facets
                .map { String(localized: $0.listName) }
                .formatted(.list(type: .and, width: .narrow))
            let label = String(localized: engine.label)
            return details.isEmpty ? label : "\(label) · \(details)"
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

    static func entries(in store: WKWebsiteDataStore, profile: Profile) async throws -> [Entry] {
        let records = await store.dataRecords(ofTypes: allTypes)
        let webKit = records
            .map { Entry(displayName: $0.displayName, types: $0.dataTypes) }
            .filter { !$0.facets.isEmpty }
        let chromium = try await ChromiumRuntime.shared.websiteDataEntries(profile: profile)
        return (webKit + chromium).sorted {
            if $0.displayName == $1.displayName {
                return $0.engine.rawValue < $1.engine.rawValue
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func remove(
        _ entries: Set<Entry>,
        from store: WKWebsiteDataStore,
        profile: Profile
    ) async throws {
        guard !entries.isEmpty else { return }
        let webKitNames = Set(entries.lazy.filter { $0.engine.rawValue == BrowserEngine.webKit.rawValue }.map(\.displayName))
        if !webKitNames.isEmpty {
            let records = await store.dataRecords(ofTypes: allTypes)
                .filter { webKitNames.contains($0.displayName) }
            if !records.isEmpty {
                await store.removeData(ofTypes: allTypes, for: records)
            }
        }
        let chromiumNames = Set(entries.lazy.filter { $0.engine.rawValue == BrowserEngine.chromium.rawValue }.map(\.displayName))
        try await ChromiumRuntime.shared.removeWebsiteData(names: chromiumNames, profile: profile)
    }

    static func removeAll(
        from store: WKWebsiteDataStore,
        profile: Profile
    ) async throws {
        let records = await store.dataRecords(ofTypes: allTypes)
        if !records.isEmpty {
            await store.removeData(ofTypes: allTypes, for: records)
        }
        try await ChromiumRuntime.shared.clearData(
            profile: profile,
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
