// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct SiteSettingsIndexTests {
    private func store() -> SitePermissions {
        let file = URL.temporaryDirectory.appending(path: "SiteSettingsIndexTests-\(UUID().uuidString).json")
        return SitePermissions(storageURL: file)
    }

    private func entries(
        _ permissions: SitePermissions,
        grants: [(host: String, categories: [SensitiveAction.Category])] = [],
        exempt: Set<String> = []
    ) -> [SiteSettingsEntry] {
        SiteSettingsIndex.entries(permissions: permissions, grantsByHost: grants, exemptHosts: exempt)
    }

    @Test func aStoreWithNothingInItListsNoWebsites() {
        #expect(entries(store()).isEmpty)
    }

    @Test func oneWebsiteGathersItsThreeOriginKeyedRules() {
        let permissions = store()
        permissions.set(.allow, for: "https://example.com", .camera)
        permissions.setAssistantAccess(.control, for: "https://example.com")
        permissions.setKeepsActive(true, for: "https://example.com")

        let found = entries(permissions)
        #expect(found.count == 1)
        #expect(found[0].origin == "https://example.com")
        #expect(found[0].permissions[.camera] == .allow)
        #expect(found[0].assistantAccess == .control)
        #expect(found[0].keepsActive)
    }

    @Test func turningAutomaticPictureOffAloneStillGetsARow() {
        let permissions = store()
        permissions.setAllowsAutomaticPicture(false, for: "https://example.com")

        let found = entries(permissions)
        #expect(found.count == 1)
        #expect(found[0].origin == "https://example.com")
        #expect(found[0].blocksAutomaticPicture)
    }

    @Test func hostKeyedRulesReachTheirOriginRow() {
        let permissions = store()
        permissions.set(.allow, for: "https://www.example.com", .location)

        let found = entries(
            permissions,
            grants: [(host: "example.com", categories: [.purchase])],
            exempt: ["example.com"]
        )
        #expect(found.count == 1)
        #expect(found[0].allowsTrackers)
        #expect(found[0].assistantGrants == [.purchase])
    }

    @Test func aHostKeyedRuleAloneStillGetsARow() {
        let found = entries(store(), exempt: ["example.com"])
        #expect(found.count == 1)
        #expect(found[0].origin == "https://example.com")
        #expect(found[0].allowsTrackers)
    }

    @Test func aPortAndASchemeStayDifferentWebsites() {
        let permissions = store()
        permissions.set(.allow, for: "https://example.com", .camera)
        permissions.set(.deny, for: "https://example.com:8443", .camera)

        let found = entries(permissions)
        #expect(found.count == 2)
        #expect(Set(found.map(\.origin)) == ["https://example.com", "https://example.com:8443"])
    }

    @Test func websitesComeBackInReadingOrder() {
        let permissions = store()
        for host in ["https://zebra.com", "https://apple.com", "https://mango.com"] {
            permissions.setKeepsActive(true, for: host)
        }
        #expect(entries(permissions).map(\.displayName) == ["apple.com", "mango.com", "zebra.com"])
    }

    @Test func aWebsiteBackAtItsDefaultsLeavesTheList() {
        let permissions = store()
        permissions.set(.allow, for: "https://example.com", .camera)
        #expect(entries(permissions).count == 1)

        permissions.set(.ask, for: "https://example.com", .camera)
        #expect(entries(permissions).isEmpty)
    }

    @Test func savedAppChoicesAppearInWebsiteSettingsAndLeaveAfterRevocation() async {
        let file = URL.temporaryDirectory.appending(path: "SiteSettingsIndexTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let permissions = SitePermissions(storageURL: file)
        let slack = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        permissions.allowExternalApp(slack, for: "https://slack.com")
        let found = entries(permissions)
        #expect(found.map(\.origin) == ["https://slack.com"])
        #expect(found.first?.externalApps == [slack])
        permissions.removeExternalApps(for: "https://slack.com")
        #expect(entries(permissions).isEmpty)
        await permissions.waitForPendingSave()
    }

    @Test func theHostDropsTheSchemeAndTheWwwPrefix() {
        #expect(SiteSettingsIndex.host(of: "https://www.example.com") == "example.com")
        #expect(SiteSettingsIndex.host(of: "http://example.com:3000") == "example.com")
    }
}
