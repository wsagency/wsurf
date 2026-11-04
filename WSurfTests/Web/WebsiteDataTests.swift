// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Testing
import WebKit

@testable import WSurf

struct WebsiteDataTests {
    private func entry(_ name: String, _ types: Set<String>) -> WebsiteData.Entry {
        WebsiteData.Entry(displayName: name, types: types)
    }

    @Test func everyFacetClaimsAtLeastOneWebKitType() {
        for facet in WebsiteData.Facet.allCases {
            #expect(!facet.types.isEmpty)
        }
    }

    @Test func noTwoFacetsClaimTheSameWebKitType() {
        var seen: Set<String> = []
        for facet in WebsiteData.Facet.allCases {
            #expect(seen.isDisjoint(with: facet.types))
            seen.formUnion(facet.types)
        }
        #expect(seen == WebsiteData.allTypes)
    }

    @Test func aRecordIsDescribedByWhatItActuallyHolds() {
        let cookiesOnly = entry("example.com", [WKWebsiteDataTypeCookies])
        #expect(cookiesOnly.facets == [.cookies])

        let mixed = entry("example.com", [WKWebsiteDataTypeCookies, WKWebsiteDataTypeDiskCache])
        #expect(mixed.facets == [.cookies, .cache])
    }

    @Test func facetsComeBackInAFixedOrder() {
        let all = entry("example.com", WebsiteData.allTypes)
        #expect(all.facets == WebsiteData.Facet.allCases)
    }

    @Test func everyStorageFlavorReadsAsLocalStorage() {
        for type in [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases,
        ] {
            #expect(entry("example.com", [type]).facets == [.storage])
        }
    }

    @Test func aRecordWeCannotDescribeHasNoFacets() {
        #expect(entry("example.com", ["com.example.somethingElse"]).facets.isEmpty)
    }

    @Test func theSummaryNamesEveryFacetMidSentence() {
        let summary = entry("example.com", [WKWebsiteDataTypeCookies, WKWebsiteDataTypeDiskCache]).summary
        #expect(summary.contains("cookies"))
        #expect(summary.contains("cached files"))
    }

    @Test func engineTagKeepsDuplicateOriginsDistinct() {
        let webKit = WebsiteData.Entry(displayName: "example.com", types: [WKWebsiteDataTypeCookies], engine: .webKit)
        let chromium = WebsiteData.Entry(displayName: "example.com", types: [WKWebsiteDataTypeCookies], engine: .chromium)
        #expect(webKit.id != chromium.id)
        #expect(chromium.summary.contains("Chromium"))
    }

    @Test func searchMatchesTheStartOfANameOrOfAnyPartOfIt() {
        let github = entry("github.com", [WKWebsiteDataTypeCookies])
        #expect(WebsiteData.matches(github, query: "git"))
        #expect(WebsiteData.matches(github, query: "GITHUB"))
        #expect(WebsiteData.matches(github, query: "com"))
        #expect(!WebsiteData.matches(github, query: "figma"))

        let subdomain = entry("avatars.githubusercontent.com", [WKWebsiteDataTypeCookies])
        #expect(WebsiteData.matches(subdomain, query: "git"))
    }

    @Test func searchDoesNotMatchMidWord() {
        let digitalgov = entry("digitalgov.gov", [WKWebsiteDataTypeCookies])
        #expect(!WebsiteData.matches(digitalgov, query: "git"))
        #expect(WebsiteData.matches(digitalgov, query: "digital"))
    }

    @Test func anEmptyQueryMatchesEverything() {
        let github = entry("github.com", [WKWebsiteDataTypeCookies])
        #expect(WebsiteData.matches(github, query: ""))
        #expect(WebsiteData.matches(github, query: "   "))
    }

    @Test func theListKeepsDescribableSitesInNameOrder() async {
        let entries = await WebsiteData.entries(from: [
            .init(displayName: "zeta.com", types: [WKWebsiteDataTypeCookies]),
            .init(displayName: "Alpha.com", types: [WKWebsiteDataTypeDiskCache]),
            .init(displayName: "odd.com", types: ["com.example.somethingElse"]),
        ])
        #expect(entries.map(\.displayName) == ["Alpha.com", "zeta.com"])
        #expect(entries.first?.summary.contains("cached files") == true)
    }

    @Test func chromiumSitesJoinTheListInNameOrderAndStayDistinctFromWebKitOnes() async {
        let chromium = WebsiteData.Entry(displayName: "same.example", types: WebsiteData.allTypes, engine: .chromium)
        let entries = await WebsiteData.entries(
            from: [
                .init(displayName: "same.example", types: [WKWebsiteDataTypeCookies]),
                .init(displayName: "other.example", types: [WKWebsiteDataTypeCookies]),
            ],
            chromium: [chromium]
        )
        #expect(entries.map(\.displayName) == ["other.example", "same.example", "same.example"])
        #expect(entries.map(\.engine) == [.webKit, .chromium, .webKit])
        #expect(Set(entries.map(\.id)).count == 3)
    }

    // MARK: - Removing a site

    private func addCookies(for hosts: [String], to store: WKWebsiteDataStore) async throws {
        for host in hosts {
            let cookie = try #require(HTTPCookie(properties: [
                .domain: host, .path: "/", .name: "session", .value: "1",
            ]))
            await store.httpCookieStore.setCookie(cookie)
        }
    }

    private func cookieHosts(in store: WKWebsiteDataStore) async -> Set<String> {
        Set(await store.httpCookieStore.allCookies().map { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }

    @MainActor
    @Test func removingASiteDropsOnlyItsDataAndItsRowWithoutCountingAgain() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        try await addCookies(for: ["keep.example", "drop.example", "other.example"], to: context.dataStore)
        let snapshot = try await WebsiteData.snapshot(context: context)
        #expect(snapshot.entries.map(\.displayName) == ["drop.example", "keep.example", "other.example"])
        let drop = try #require(snapshot.entries.first { $0.displayName == "drop.example" })

        var chromiumCalls: [Set<String>] = []
        try await WebsiteData.remove([drop], of: snapshot, context: context) { chromiumCalls.append($0) }

        #expect(chromiumCalls.isEmpty)
        #expect(await cookieHosts(in: context.dataStore) == ["keep.example", "other.example"])
        #expect(snapshot.removing([drop]).entries.map(\.displayName) == ["keep.example", "other.example"])
        #expect(try await WebsiteData.snapshot(context: context).entries.map(\.displayName) == ["keep.example", "other.example"])
        await context.endPrivateSession()
    }

    @MainActor
    @Test func removingSeveralSitesDropsExactlyThoseSites() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        try await addCookies(for: ["a.example", "b.example", "c.example", "d.example"], to: context.dataStore)
        let snapshot = try await WebsiteData.snapshot(context: context)
        let chosen = Set(snapshot.entries.filter { ["a.example", "c.example"].contains($0.displayName) })
        #expect(chosen.count == 2)

        try await WebsiteData.remove(chosen, of: snapshot, context: context) { _ in }

        #expect(await cookieHosts(in: context.dataStore) == ["b.example", "d.example"])
        #expect(snapshot.removing(chosen).entries.map(\.displayName) == ["b.example", "d.example"])
        await context.endPrivateSession()
    }

    @MainActor
    @Test func removingAChromiumSiteClearsOnlyItsOriginAndTouchesNoWebKitData() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        try await addCookies(for: ["same.example"], to: context.dataStore)
        let webKit = try await WebsiteData.snapshot(context: context)
        let sameName = WebsiteData.Entry(displayName: "same.example", types: WebsiteData.allTypes, engine: .chromium)
        let origin = WebsiteData.Entry(displayName: "https://drop.example", types: WebsiteData.allTypes, engine: .chromium)
        let other = WebsiteData.Entry(displayName: "https://keep.example", types: WebsiteData.allTypes, engine: .chromium)
        let snapshot = WebsiteData.Snapshot(entries: webKit.entries + [sameName, origin, other], records: webKit.records)

        var chromiumCalls: [Set<String>] = []
        try await WebsiteData.remove([origin, sameName], of: snapshot, context: context) { chromiumCalls.append($0) }

        #expect(chromiumCalls == [["https://drop.example", "same.example"]])
        #expect(await cookieHosts(in: context.dataStore) == ["same.example"])
        let remaining = snapshot.removing([origin, sameName]).entries
        #expect(remaining.map(\.id) == ["webkit:same.example", "chromium:https://keep.example"])
        await context.endPrivateSession()
    }

    @MainActor
    @Test func removingAWebKitSiteLeavesTheChromiumSiteOfTheSameName() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        try await addCookies(for: ["same.example", "keep.example"], to: context.dataStore)
        let webKit = try await WebsiteData.snapshot(context: context)
        let chromium = WebsiteData.Entry(displayName: "same.example", types: WebsiteData.allTypes, engine: .chromium)
        let snapshot = WebsiteData.Snapshot(entries: webKit.entries + [chromium], records: webKit.records)
        let same = try #require(webKit.entries.first { $0.displayName == "same.example" })

        var chromiumCalls: [Set<String>] = []
        try await WebsiteData.remove([same], of: snapshot, context: context) { chromiumCalls.append($0) }

        #expect(chromiumCalls.isEmpty)
        #expect(await cookieHosts(in: context.dataStore) == ["keep.example"])
        #expect(snapshot.removing([same]).entries.map(\.id).contains("chromium:same.example"))
        #expect(!snapshot.removing([same]).entries.map(\.id).contains("webkit:same.example"))
        await context.endPrivateSession()
    }

    @MainActor
    @Test func aSiteThatAppearedAfterTheCountIsStillRemoved() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        try await addCookies(for: ["keep.example"], to: context.dataStore)
        let snapshot = try await WebsiteData.snapshot(context: context)
        try await addCookies(for: ["late.example"], to: context.dataStore)
        let late = WebsiteData.Entry(displayName: "late.example", types: [WKWebsiteDataTypeCookies])
        #expect(snapshot.records["late.example"] == nil)

        try await WebsiteData.remove([late], of: snapshot, context: context) { _ in }

        #expect(await cookieHosts(in: context.dataStore) == ["keep.example"])
        await context.endPrivateSession()
    }

    @MainActor
    @Test func removingNothingTouchesNothing() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        try await addCookies(for: ["keep.example"], to: context.dataStore)
        let snapshot = try await WebsiteData.snapshot(context: context)

        var chromiumCalls: [Set<String>] = []
        try await WebsiteData.remove([], of: snapshot, context: context) { chromiumCalls.append($0) }

        #expect(chromiumCalls.isEmpty)
        #expect(await cookieHosts(in: context.dataStore) == ["keep.example"])
        #expect(snapshot.removing([]).entries == snapshot.entries)
        await context.endPrivateSession()
    }
}
