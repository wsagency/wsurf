// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Counting a profile's Chromium sites reads WSurf's own list of the origins its pages loaded. It opens no browser, so the Privacy
/// page does not wait for a renderer per site, and a person who has not used Chromium does not start it by opening that page.
/// CEF cannot be stopped in a process, so `isInitialized` can only be held to what it was; `hasContext` answers the same question
/// in any order of suites: a command on a profile creates its context, a count must not.
@MainActor
@Suite(.serialized)
struct ChromiumSiteCountTests {
    private let runtime = ChromiumRuntime.shared

    private func regularContext() -> (Profile, BrowserProfileContext) {
        let profile = Profile(id: UUID(), name: "Site count", symbol: "person", color: .gray)
        return (profile, BrowserProfileContext(profile: profile))
    }

    @Test func countingARegularProfilesSitesOpensNoBrowser() async throws {
        let (profile, context) = regularContext()
        let wasRunning = runtime.isInitialized
        for index in 0..<40 {
            runtime.recordOrigin(try #require(URL(string: "https://site\(index).example/page")), context: context)
        }

        let count = try await BrowsingData.siteCount(context: context)
        let entries = try await runtime.websiteDataEntries(context: context)

        #expect(count == 40)
        #expect(entries.map(\.displayName) == (0..<40).map { "https://site\($0).example" }.sorted())
        #expect(entries.allSatisfy { $0.engine == .chromium })
        #expect(!runtime.hasContext(contextID: context.contextID))
        #expect(runtime.isInitialized == wasRunning)
        await Profile.erase(profile)
    }

    @Test func aSiteCountsOnceWhateverPagesOrFramesLoadedIt() async throws {
        let (profile, context) = regularContext()
        let page = try #require(URL(string: "https://shop.example/cart"))
        runtime.recordOrigin(page, context: context)
        runtime.recordOrigin(try #require(URL(string: "https://shop.example/other")), context: context)
        runtime.recordOrigin(try #require(URL(string: "https://cdn.example/")), under: page, context: context)
        runtime.recordOrigin(try #require(URL(string: "https://cdn.example/")), under: page, context: context)
        runtime.recordOrigin(try #require(URL(string: "about:blank")), context: context)
        runtime.recordOrigin(try #require(URL(string: "file:///tmp/a.html")), context: context)

        #expect(try await BrowsingData.siteCount(context: context) == 2)
        #expect(!runtime.hasContext(contextID: context.contextID))
        await Profile.erase(profile)
    }

    @Test func aProfileWithNoRecordedSiteHasNoneAndOpensNoBrowser() async throws {
        let (profile, context) = regularContext()
        #expect(try await runtime.websiteDataEntries(context: context).isEmpty)
        #expect(!runtime.hasContext(contextID: context.contextID))
        await Profile.erase(profile)
    }

    @Test func countingAPrivateWindowsSitesOpensNoBrowser() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let wasRunning = runtime.isInitialized
        for index in 0..<5 {
            runtime.recordOrigin(try #require(URL(string: "https://private\(index).example/")), context: context)
        }

        #expect(try await BrowsingData.siteCount(context: context) == 5)
        #expect(!runtime.hasContext(contextID: context.contextID))
        #expect(runtime.isInitialized == wasRunning)
        await context.endPrivateSession()
    }
}
