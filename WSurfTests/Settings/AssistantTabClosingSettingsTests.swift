// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The closing-tabs choice: where it is kept, when it counts, and its words and search entry.
@MainActor
struct AssistantTabClosingSettingsTests {
    private func file() -> URL {
        AppDatabase.supportDirectory.appendingPathComponent("TabClosingSetting-\(UUID().uuidString).json")
    }

    @Test func askToCloseTabsIsTheDefault() {
        let store = SitePermissions(storageURL: file())

        #expect(store.assistantTabClosing == .ask)
        #expect(!store.allowsClosingTabsWithoutAsking)
    }

    @Test func allowClosingCountsOnlyUnderTheAllowControlDefault() {
        let store = SitePermissions(storageURL: file())
        store.setAssistantTabClosing(.allow)

        for policy in [AssistantAccessPolicy.ask, .readOnly] {
            store.setAssistantDefault(policy)
            #expect(!store.allowsClosingTabsWithoutAsking)
        }
        store.setAssistantDefault(.control)
        #expect(store.allowsClosingTabsWithoutAsking)
        store.setAssistantTabClosing(.ask)
        #expect(!store.allowsClosingTabsWithoutAsking)
    }

    @Test func theChoiceSurvivesARelaunch() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SitePermissions(storageURL: url)
        writer.setAssistantDefault(.control)
        writer.setAssistantTabClosing(.allow)
        await writer.waitForPendingSave()

        let reader = SitePermissions(storageURL: url)
        #expect(reader.assistantTabClosing == .allow)
        #expect(reader.allowsClosingTabsWithoutAsking)

        reader.setAssistantTabClosing(.ask)
        await reader.waitForPendingSave()
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("assistantTabClosing"))
        #expect(SitePermissions(storageURL: url).assistantTabClosing == .ask)
    }

    @Test func aValueThisBuildDoesNotKnowReadsAsAsk() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SitePermissions(storageURL: url)
        writer.setAssistantDefault(.control)
        writer.setAssistantTabClosing(.allow)
        await writer.waitForPendingSave()
        let edited = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"assistantTabClosing\":\"allow\"", with: "\"assistantTabClosing\":\"somethingNew\"")
        try edited.write(to: url, atomically: true, encoding: .utf8)

        let reader = SitePermissions(storageURL: url)
        #expect(reader.assistantTabClosing == .ask)
        #expect(reader.assistantDefault == .control)
    }

    @Test func aPrivateWindowAlwaysAsks() {
        let store = SitePermissions(storageURL: file(), persists: false)

        store.setAssistantDefault(.control)
        store.setAssistantTabClosing(.allow)

        #expect(store.assistantTabClosing == .ask)
        #expect(!store.allowsClosingTabsWithoutAsking)
    }

    @Test func theRowShowsOnlyForTheAllowControlDefaultInAnEverydayProfile() {
        #expect(TabClosingRow.appears(defaultAccess: .control, isPrivate: false))
        #expect(!TabClosingRow.appears(defaultAccess: .control, isPrivate: true))
        for policy in [AssistantAccessPolicy.ask, .readOnly, .deny] {
            #expect(!TabClosingRow.appears(defaultAccess: policy, isPrivate: false))
        }
    }

    @Test func theWordsMatchTheSettingsCopy() {
        #expect(String(localized: AssistantTabClosing.ask.label) == "Ask to close tabs")
        #expect(String(localized: AssistantTabClosing.allow.label) == "Allow closing tabs")
        let caption = String(localized: AssistantTabClosing.caption)
        #expect(caption.contains("Pinned tabs are never closed"))
        #expect(caption.contains("Developer access"))
    }

    @Test func theRowIsSearchable() {
        let entry = SettingsIndex.all.first { $0.id == "assistant.tabClosing" }
        #expect(entry?.category == .provider)
        #expect(SettingsIndex.search("closing tabs").contains { $0.id == "assistant.tabClosing" })
        #expect(SettingsIndex.search("ask to close tabs").contains { $0.id == "assistant.tabClosing" })
    }
}
