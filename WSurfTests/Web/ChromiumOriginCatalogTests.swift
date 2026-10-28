// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// A regular profile's list of the origins its Chromium pages loaded (`origins.json`) is kept in memory and written only when it
/// has something new, a moment after the navigation. What clears or erases Chromium data reads the kept list and still reaches the
/// disk. No browser is needed: this is the list alone.
@MainActor
@Suite(.serialized)
struct ChromiumOriginCatalogTests {
    private let runtime = ChromiumRuntime.shared

    private struct Seed: Encodable {
        var origins: [String: Date]
        var frames: [String: Set<String>]?
    }

    private struct Stored: Decodable {
        var origins: [String: Date]
        var frames: [String: Set<String>]?
    }

    private func newProfile() -> (Profile, BrowserProfileContext) {
        let profile = Profile(id: UUID(), name: "Origin catalog", symbol: "person", color: .gray)
        return (profile, BrowserProfileContext(profile: profile))
    }

    private func file(_ profile: Profile) -> URL {
        runtime.catalogDirectory(profileID: profile.id).appendingPathComponent("origins.json")
    }

    private func exists(_ profile: Profile) -> Bool {
        FileManager.default.fileExists(atPath: file(profile).path)
    }

    private func stored(_ profile: Profile) throws -> Stored {
        try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file(profile)))
    }

    /// Leaves a file as an earlier run would have, before the profile's first navigation reads it.
    private func seed(_ profile: Profile, _ seed: Seed, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: runtime.catalogDirectory(profileID: profile.id), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(seed).write(to: file(profile))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file(profile).path)
        }
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test func newSitesAreWrittenTogetherAfterAShortWait() async throws {
        let (profile, context) = newProfile()
        for index in 0..<3 {
            runtime.recordOrigin(try url("https://wait\(index).example/"), context: context)
        }
        #expect(!exists(profile))

        #expect(await waitUntil(timeout: .seconds(15)) { exists(profile) })
        #expect(Set(try stored(profile).origins.keys) == ["https://wait0.example", "https://wait1.example", "https://wait2.example"])
        await Profile.erase(profile)
    }

    @Test func flushingWritesWhatWaits() async throws {
        let (profile, context) = newProfile()
        let page = try url("https://shop.example/cart")
        runtime.recordOrigin(page, context: context)
        runtime.recordOrigin(try url("https://cdn.example/lib.js"), under: page, context: context)
        runtime.flushOriginCatalogs()

        let catalog = try stored(profile)
        #expect(Set(catalog.origins.keys) == ["https://shop.example", "https://cdn.example"])
        #expect(catalog.frames == ["https://cdn.example": ["https://shop.example"]])
        await Profile.erase(profile)
    }

    @Test func aSiteAlreadyListedIsNotWrittenAgain() async throws {
        let (profile, context) = newProfile()
        let page = try url("https://shop.example/cart")
        runtime.recordOrigin(page, context: context)
        runtime.recordOrigin(try url("https://cdn.example/"), under: page, context: context)
        runtime.flushOriginCatalogs()
        try FileManager.default.removeItem(at: file(profile))

        runtime.recordOrigin(try url("https://shop.example/checkout"), context: context)
        runtime.recordOrigin(try url("https://cdn.example/other"), under: try url("https://shop.example/checkout"), context: context)
        runtime.flushOriginCatalogs()
        #expect(!exists(profile))

        // The next new site writes the whole list, the known ones too.
        runtime.recordOrigin(try url("https://news.example/"), context: context)
        runtime.flushOriginCatalogs()
        #expect(Set(try stored(profile).origins.keys) == ["https://shop.example", "https://cdn.example", "https://news.example"])
        await Profile.erase(profile)
    }

    @Test func aFrameUnderAnotherTopLevelSiteIsWritten() async throws {
        let (profile, context) = newProfile()
        let cdn = try url("https://cdn.example/")
        runtime.recordOrigin(cdn, under: try url("https://shop.example/"), context: context)
        runtime.flushOriginCatalogs()
        try FileManager.default.removeItem(at: file(profile))

        runtime.recordOrigin(cdn, under: try url("https://news.example/"), context: context)
        runtime.flushOriginCatalogs()
        #expect(try stored(profile).frames == ["https://cdn.example": ["https://shop.example", "https://news.example"]])
        await Profile.erase(profile)
    }

    @Test func aListFromAnEarlierRunIsKeptAndExtended() async throws {
        let (profile, context) = newProfile()
        try seed(profile, Seed(origins: ["https://old.example": Date(), "https://older.example": Date()]))
        runtime.recordOrigin(try url("https://new.example/"), context: context)
        runtime.flushOriginCatalogs()

        #expect(Set(try stored(profile).origins.keys) == ["https://old.example", "https://older.example", "https://new.example"])
        #expect(try await runtime.websiteDataEntries(context: context).map(\.displayName)
            == ["https://new.example", "https://old.example", "https://older.example"])
        await Profile.erase(profile)
    }

    @Test func aFileOlderThanADayIsRefreshedByTheNextNavigation() async throws {
        let (profile, context) = newProfile()
        let longAgo = Date(timeIntervalSinceNow: -2 * 86_400)
        try seed(profile, Seed(origins: ["https://old.example": longAgo]), modified: longAgo)
        runtime.recordOrigin(try url("https://old.example/page"), context: context)
        runtime.flushOriginCatalogs()

        let refreshed = try #require(try stored(profile).origins["https://old.example"])
        #expect(refreshed.timeIntervalSinceNow > -60)
        await Profile.erase(profile)
    }

    @Test func erasingAProfileDropsWhatWaitsToBeWritten() async throws {
        let (profile, context) = newProfile()
        runtime.recordOrigin(try url("https://wait.example/"), context: context)
        try await runtime.erase(profile: profile)
        runtime.flushOriginCatalogs()

        #expect(!exists(profile))
        #expect(try await runtime.websiteDataEntries(context: context).isEmpty)
        await Profile.erase(profile)
    }
}
