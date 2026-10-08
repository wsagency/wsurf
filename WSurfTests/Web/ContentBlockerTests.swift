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
