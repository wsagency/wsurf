// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized)
struct ContentBlockerTests {
    @Test func privateRulesAreRemovedWithoutPersistingExceptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("private-rules-\(UUID())")
        let suiteName = "ContentBlockerTests.\(UUID())"
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
        let suiteName = "ContentBlockerTests.\(UUID())"
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
