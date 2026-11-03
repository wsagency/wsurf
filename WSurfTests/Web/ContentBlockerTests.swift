// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized)
struct ContentBlockerTests {
    @Test func privateRulesAreRemovedWithoutPersistingExceptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("private-rules-\(UUID())")
        let suiteName = AppDatabase.defaultsSuite("ContentBlockerTests.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try #require(WKContentRuleListStore(url: directory))
        let settings = BrowserSettings(defaults: defaults)
        let blocker = ContentBlocker(defaults: defaults, settings: settings, persists: false, ruleStore: store)
        blocker.setExempt(true, for: "private.example")
        await blocker.waitForPendingCompilation()

        #expect(blocker.ruleList != nil)
        #expect(blocker.isExempt("private.example"))
        let identifiers: [String]? = await store.availableIdentifiers()
        #expect(identifiers == [])
        #expect(defaults.stringArray(forKey: "content.blockerExceptions") == nil)
        await blocker.endPrivateSession()
    }

    @Test func privateCleanupCancelsCompilationAndClearsSessionState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("private-rules-\(UUID())")
        let suiteName = AppDatabase.defaultsSuite("ContentBlockerTests.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try #require(WKContentRuleListStore(url: directory))
        let blocker = ContentBlocker(
            defaults: defaults, settings: BrowserSettings(defaults: defaults), persists: false, ruleStore: store
        )
        blocker.setExempt(true, for: "private.example")
        #expect(await waitUntil(timeout: .seconds(5), tick: .milliseconds(1)) { blocker.isCompiling })
        await blocker.endPrivateSession()

        let identifiers: [String]? = await store.availableIdentifiers()
        #expect(identifiers == [])
        #expect(blocker.ruleList == nil)
        #expect(!blocker.isCompiling)
        #expect(blocker.exemptHosts.isEmpty)
    }

    // MARK: - The compiled list outlives the launch

    /// A store and defaults of the test's own, and a blocker as a launch makes one: the same two, a new object each time.
    private struct Launch {
        let store: WKContentRuleListStore
        let defaults: UserDefaults
        let directory: URL
        let suiteName: String

        func blocker(scope: String = "profile-a") -> ContentBlocker {
            ContentBlocker(
                defaults: defaults, settings: BrowserSettings(defaults: defaults), persists: true, ruleStore: store, scope: scope
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeLaunch() throws -> Launch {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("persistent-rules-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = AppDatabase.defaultsSuite("ContentBlockerTests.\(UUID())")
        return Launch(
            store: try #require(WKContentRuleListStore(url: directory)),
            defaults: try #require(UserDefaults(suiteName: suiteName)),
            directory: directory,
            suiteName: suiteName
        )
    }

    private func ready(_ blocker: ContentBlocker) async {
        blocker.refresh()
        await blocker.waitForPendingCompilation()
    }

    @Test func theRuleListNameIsTheSameInEveryLaunchAndChangesWithTheRules() throws {
        let plain = try #require(ContentBlocker.identifier(scope: "profile-a", exemptHosts: []))
        #expect(plain == ContentBlocker.identifier(scope: "profile-a", exemptHosts: []))
        #expect(plain.hasPrefix("WSurf.trackers.profile-a."))

        let exempt = try #require(ContentBlocker.identifier(scope: "profile-a", exemptHosts: ["b.example", "a.example"]))
        #expect(exempt == ContentBlocker.identifier(scope: "profile-a", exemptHosts: ["a.example", "b.example"]))
        #expect(exempt != plain, "another set of exceptions is another list")
        #expect(ContentBlocker.identifier(scope: "profile-b", exemptHosts: []) != plain, "and so is another profile's")

        // A dictionary's key order changes with every launch of the app, so the text that is hashed must not depend on it.
        let json = try #require(ContentBlocker.rulesJSON(exemptHosts: []))
        #expect(json.hasPrefix(#"[{"action":{"type":"block"},"trigger":{"#))
        #expect(plain == ContentBlocker.identifier(scope: "profile-a", rulesJSON: json))
    }

    @Test func aSecondLaunchUsesTheCompiledListInsteadOfCompilingAgain() async throws {
        let launch = try makeLaunch()
        defer { launch.cleanUp() }
        let name = try #require(ContentBlocker.identifier(scope: "profile-a", exemptHosts: []))

        let first = launch.blocker()
        await ready(first)
        #expect(first.compilations == 1)
        #expect(first.ruleList != nil)
        #expect(await launch.store.availableIdentifiers() == [name])

        let second = launch.blocker()
        await ready(second)
        #expect(second.compilations == 0, "the list of the first launch was found")
        #expect(second.ruleList != nil)
        #expect(await launch.store.availableIdentifiers() == [name], "and no second list was left")
    }

    @Test func aChangeOfTheRulesCompilesAgainAndRemovesTheListItReplaces() async throws {
        let launch = try makeLaunch()
        defer { launch.cleanUp() }
        let blocker = launch.blocker()
        await ready(blocker)
        #expect(blocker.compilations == 1)

        blocker.setExempt(true, for: "shop.example")
        await blocker.waitForPendingCompilation()

        #expect(blocker.compilations == 2)
        let changed = try #require(ContentBlocker.identifier(scope: "profile-a", exemptHosts: ["shop.example"]))
        #expect(await launch.store.availableIdentifiers() == [changed])

        let relaunched = launch.blocker()
        await ready(relaunched)
        #expect(relaunched.compilations == 0, "the exception is part of the rules a launch finds")
        #expect(relaunched.exemptHosts == ["shop.example"])
    }

    /// The lists that every launch of an earlier build left, under a random name, go. So do the profile's own lists for rules
    /// it no longer has. Another profile's list, and anything else in the store, stays.
    @Test func staleListsGoAndOtherListsStay() async throws {
        let launch = try makeLaunch()
        defer { launch.cleanUp() }
        let rules = #"[{"trigger":{"url-filter":"^https://never\\.example/"},"action":{"type":"block"}}]"#
        let legacy = ["WSurf.trackers.\(UUID().uuidString)", "WSurf.trackers.\(UUID().uuidString)"]
        let earlier = "WSurf.trackers.profile-a.0123456789abcdef01234567"
        let otherProfile = try #require(ContentBlocker.identifier(scope: "profile-b", exemptHosts: []))
        let foreign = "Other.list"
        for name in legacy + [earlier, otherProfile, foreign] {
            _ = try await launch.store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: rules)
        }

        let blocker = launch.blocker()
        await ready(blocker)

        let own = try #require(ContentBlocker.identifier(scope: "profile-a", exemptHosts: []))
        #expect(Set(await launch.store.availableIdentifiers() ?? []) == [own, otherProfile, foreign])
        #expect(blocker.ruleList != nil)
    }

    @Test(arguments: [
        ("WSurf.trackers.6F2D1E3A-5B7C-4D8E-9F01-23456789ABCD", true),
        ("WSurf.trackers.profile-a.0123456789abcdef01234567", true),
        ("WSurf.trackers.profile-a.ffffffffffffffffffffffff", false),
        ("WSurf.trackers.profile-b.0123456789abcdef01234567", false),
        ("WSurf.trackers.profile-ab.0123456789abcdef01234567", false),
        ("Other.list", false),
        ("WSurf.trackers.", false),
    ])
    func aListIsStaleWhenWSurfCompiledItForOtherRules(name: String, stale: Bool) {
        #expect(
            ContentBlocker.isStale(name, keeping: "WSurf.trackers.profile-a.ffffffffffffffffffffffff", scope: "profile-a") == stale
        )
    }
}

/// Both engines must treat a subresource from the page's own registrable domain as first party: WebKit through the
/// rule list's `third-party` load type, Chromium through `ChromiumTrackerPolicy`, and the count either way.
struct TrackerSiteTests {
    private let page = URL(string: "https://www.facebook.com/groups")

    @Test func chromiumAllowsTrackersFromTheSameSiteAndBlocksOtherSites() {
        let policy = ChromiumTrackerPolicy(blocksTrackers: true, exemptHosts: [], topLevelURL: page)
        #expect(!policy.shouldBlock(URL(string: "https://facebook.com/tr?id=1")!))
        #expect(!policy.shouldBlock(URL(string: "http://www.facebook.com:8080/tr?id=1")!))
        #expect(policy.shouldBlock(URL(string: "https://www.google-analytics.com/collect")!))
        #expect(!policy.shouldBlock(URL(string: "https://facebook.com.evil.example/tr")!))

        policy.updateTopLevelURL(URL(string: "https://example.com"))
        #expect(policy.shouldBlock(URL(string: "https://facebook.com/tr")!))
    }

    @Test func chromiumComparesSitesUnderAMultiLabelSuffix() {
        let policy = ChromiumTrackerPolicy(
            blocksTrackers: true, exemptHosts: [], topLevelURL: URL(string: "https://news.criteo.co.uk")
        )
        // A different registrable domain under the same public suffix stays third party.
        #expect(policy.shouldBlock(URL(string: "https://static.criteo.com/js/ld.js")!))
    }

    @Test func webKitRulesBlockOnlyThirdPartyLoads() throws {
        let json = try #require(ContentBlocker.rulesJSON(exemptHosts: []))
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let trackerRules = rules.prefix(TrackerList.domains.count)
        #expect(trackerRules.count == TrackerList.domains.count)
        for rule in trackerRules {
            let trigger = try #require(rule["trigger"] as? [String: Any])
            #expect(trigger["load-type"] as? [String] == ["third-party"])
        }
    }

    @Test func trackerCountSkipsTheSameSite() {
        #expect(TrackerList.matchingDomains(in: ["https://facebook.com/tr?id=1"], topLevelURL: page).isEmpty)
        #expect(TrackerList.matchingDomains(in: ["http://www.facebook.com/tr?id=1"], topLevelURL: page).isEmpty)
        let found = TrackerList.matchingDomains(
            in: ["https://www.google-analytics.com/collect", "https://facebook.com.evil.example/tr"],
            topLevelURL: page
        )
        #expect(found == ["google-analytics.com"])
        #expect(
            TrackerList.matchingDomains(in: ["https://facebook.com/tr"], topLevelURL: URL(string: "https://example.com"))
                == ["facebook.com"]
        )
    }
}
