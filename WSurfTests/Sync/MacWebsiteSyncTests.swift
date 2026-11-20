// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Synchronization
import Testing
import WebKit

@testable import WSurf

struct MacWebsiteSyncTests {
    @Test func hostZoomEditsAndResetsWakeSettingsSync() async {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zoom = PageZoomStore(file: folder.appending(path: "zoom"))
        let changes = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .init("wsurfMacSettingsDidChange"), object: nil, queue: nil) { note in
            if (note.object as? PageZoomStore) === zoom {
                changes.withLock { $0 += 1 }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        zoom.set(1.5, for: "zoom.test", defaultZoom: 1)
        zoom.set(1, for: "zoom.test", defaultZoom: 1)
        #expect(changes.withLock { $0 } == 2)
        await zoom.waitForPendingSave()
        #expect(PageZoomStore(file: folder.appending(path: "zoom")).level(for: "zoom.test") == nil)
    }

    @Test func lateRegisteredProfileReceivesOnlyItsOwnWebsiteSettings() async throws {
        let original = Profile.original()
        let extra = Profile(id: UUID(), name: "Fixture", symbol: "person", color: .gray)
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try MacSettingsFixture(profile: original, folder: folder.appending(path: "original"))
        let b = try MacSettingsFixture(profile: extra, folder: folder.appending(path: "new"))
        defer { a.cleanup(); b.cleanup() }
        let adapter = MacSettingsSyncAdapter(profiles: [original], catalog: a.catalog, stores: { $0.id == extra.id ? b.stores : a.stores },
                                             account: { "fixture-account" }, refreshWindows: { _, _, _ in })
        let key = "popups|https://one.test"
        let value = try JSONEncoder().encode(PopupPolicy.block)
        #expect(throws: (any Error).self) { try adapter.apply(value, key: key, for: .websiteSettings, profileID: extra.id) }
        adapter.register(extra)
        adapter.register(.privateBrowsing())
        try adapter.apply(value, key: key, for: .websiteSettings, profileID: extra.id)
        #expect(b.stores.permissions.popups(for: "https://one.test") == .block)
        #expect(a.stores.permissions.popups(for: "https://one.test") == nil)
        #expect(throws: (any Error).self) { try adapter.values(for: .providers, profileID: Profile.privateID) }
        await b.stores.permissions.waitForPendingSave()
    }

    @Test func declinedGrantPersistsUntilChangedLocallyOrResetByPeer() async throws {
        let profile = Profile.original()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let sites = fixture.stores.permissions
        let origin = "https://video.test", key = "camera|" + origin
        sites.set(.deny, for: origin, .camera)
        let value = try JSONEncoder().encode(PermissionPolicy.allow)
        try fixture.adapter.apply(value, key: key, for: .websiteSettings, profileID: profile.id)
        let proposal = try #require(sites.pendingSyncGrants[key])
        fixture.adapter.reviewWebsiteGrant(proposal, key: key, profileID: profile.id, allow: false)
        await sites.waitForPendingSave()
        let reopened = try MacSettingsFixture(profile: profile, folder: folder)
        defer { reopened.cleanup() }
        try reopened.adapter.apply(value, key: key, for: .websiteSettings, profileID: profile.id)
        #expect(reopened.stores.permissions.pendingSyncGrants[key]?.dismissed == true)
        reopened.adapter.reviewWebsiteGrant(proposal, key: key, profileID: profile.id, allow: true)
        #expect(reopened.stores.permissions.policy(for: origin, .camera) == .deny)
        let suspended = MacSettingsSyncAdapter(profiles: [profile], catalog: reopened.catalog, stores: { _ in reopened.stores },
                                              account: { nil }, refreshWindows: { _, _, _ in })
        #expect(throws: (any Error).self) { try suspended.values(for: .websiteSettings, profileID: profile.id) }
        #expect(try reopened.adapter.values(for: .websiteSettings, profileID: profile.id)[key] == value)
        try reopened.adapter.apply(nil, key: key, for: .websiteSettings, profileID: profile.id)
        #expect(reopened.stores.permissions.pendingSyncGrants[key] == nil)
        #expect(reopened.stores.permissions.policy(for: origin, .camera) == .ask)
        await reopened.stores.permissions.waitForPendingSave()
    }

    @Test func browserWebsiteDefaultsUseExplicitPerProfileValuesAndNormalSetters() async throws {
        let profile = Profile.original()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try MacSettingsFixture(profile: profile, folder: folder.appending(path: "studio"))
        let second = try MacSettingsFixture(profile: profile, folder: folder.appending(path: "air"))
        defer { first.cleanup(); second.cleanup() }
        let key = "webDefault|javascript"
        #expect(try first.adapter.values(for: .websiteSettings, profileID: profile.id)[key] == nil)
        let notified = Mutex(false)
        let observer = NotificationCenter.default.addObserver(forName: .wsurfMacSettingsDidChange, object: nil, queue: nil) { note in
            if (note.object as? BrowserSettings) === first.webSettings {
                notified.withLock { $0 = true }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        first.webSettings.javaScriptEnabled = false
        first.webSettings.autoplay = .block
        #expect(await waitUntil { notified.withLock { $0 } })
        let values = try first.adapter.values(for: .websiteSettings, profileID: profile.id)
        let js = try #require(values[key])
        let play = try #require(values["webDefault|autoplay"])
        var changes = 0
        second.webSettings.onWebPreferencesChanged = { changes += 1 }
        try second.adapter.apply(js, key: key, for: .websiteSettings, profileID: profile.id)
        try second.adapter.apply(play, key: "webDefault|autoplay", for: .websiteSettings, profileID: profile.id)
        #expect(!second.webSettings.javaScriptEnabled)
        #expect(second.webSettings.autoplay == .block)
        #expect(changes == 2)
        try second.adapter.apply(nil, key: key, for: .websiteSettings, profileID: profile.id)
        #expect(second.webSettings.javaScriptEnabled)
        #expect(try second.adapter.values(for: .websiteSettings, profileID: profile.id)[key] == nil)
        #expect(throws: (any Error).self) { try second.adapter.apply(js, key: "webDefault|autoplay", for: .websiteSettings, profileID: profile.id) }
        #expect(throws: (any Error).self) { try second.adapter.apply(js, key: "webDefault|certificateExceptions", for: .websiteSettings, profileID: profile.id) }
    }

    @Test func explicitAssistantGrantNeedsReviewEvenWhenDefaultAlreadyAllowsIt() async throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let sites = fixture.stores.permissions
        let site = "https://example.com", key = "assistant|" + site
        sites.setAssistantDefault(.control)
        try fixture.adapter.apply(JSONEncoder().encode(AssistantAccessPolicy.control), key: key, for: .websiteSettings, profileID: profile.id)
        sites.setAssistantDefault(.ask)
        #expect(sites.assistantAccess(for: site) == .ask)
        #expect(sites.assistantRecord(for: site) == nil)
        let proposal = try #require(sites.pendingSyncGrants[key])
        fixture.adapter.reviewWebsiteGrant(proposal, key: key, profileID: profile.id, allow: true)
        #expect(sites.assistantRecord(for: site) == .control)
        await sites.waitForPendingSave()
    }

    @Test func assistantResetNeedsConsentForTheDefaultThePersonSaw() async throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let sites = fixture.stores.permissions
        let site = "https://example.com", key = "assistant|" + site
        sites.setAssistantDefault(.readOnly)
        sites.setAssistantAccess(.deny, for: site)
        try fixture.adapter.apply(nil, key: key, for: .websiteSettings, profileID: profile.id)
        let original = try #require(sites.pendingSyncGrants[key])
        sites.setAssistantDefault(.control)
        fixture.adapter.reviewWebsiteGrant(original, key: key, profileID: profile.id, allow: true)
        #expect(sites.assistantAccess(for: site) == .deny)
        let updated = try #require(sites.pendingSyncGrants[key])
        fixture.adapter.reviewWebsiteGrant(updated, key: key, profileID: profile.id, allow: true)
        #expect(sites.assistantRecord(for: site) == nil)
        #expect(sites.assistantAccess(for: site) == .control)
        await sites.waitForPendingSave()
    }

    @Test func twoPopulatedMacsReceiveOnlyTypedWebsiteValuesAndReviewGrants() async throws {
        let profile = Profile.original()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try MacSettingsFixture(profile: profile, folder: folder.appending(path: "studio"))
        let b = try MacSettingsFixture(profile: profile, folder: folder.appending(path: "air"))
        defer { a.cleanup(); b.cleanup() }
        let url = "https://app.example.com:8443"
        a.stores.permissions.set(.allow, for: url, .camera)
        a.stores.permissions.setAssistantAccess(.control, for: url)
        a.stores.permissions.setEngine(.chromium, for: url)
        a.stores.zoom.set(1.5, for: "www.example.com", defaultZoom: 1)
        a.stores.blocker.setExempt(true, for: "www.example.com")
        b.stores.permissions.set(.deny, for: url, .camera)
        b.stores.permissions.setPopups(.block, for: "https://local.test")

        let records = try a.adapter.values(for: .websiteSettings, profileID: profile.id)
        for (key, value) in records {
            try b.adapter.apply(value, key: key, for: .websiteSettings, profileID: profile.id)
        }
        #expect(b.stores.permissions.policy(for: url, .camera) == .deny)
        #expect(b.stores.permissions.assistantAccess(for: url) == .ask)
        #expect(b.stores.permissions.engine(for: url) == .chromium)
        #expect(b.stores.permissions.engine(for: "https://app.example.com") == .webKit)
        #expect(b.stores.zoom.level(for: "www.example.com") == 1.5)
        #expect(b.stores.zoom.level(for: "example.com") == nil)
        #expect(b.stores.blocker.isExempt("example.com"))
        #expect(b.stores.permissions.popups(for: "https://local.test") == .block)
        #expect(b.stores.permissions.pendingSyncGrants.count == 2)
        let echoed = try b.adapter.values(for: .websiteSettings, profileID: profile.id)
        #expect(records.allSatisfy { echoed[$0.key] == $0.value })
        await b.stores.permissions.waitForPendingSave()
        let reopened = SitePermissions(storageURL: b.folder.appending(path: "sites"))
        #expect(reopened.pendingSyncGrants == b.stores.permissions.pendingSyncGrants)
        for (key, grant) in b.stores.permissions.pendingSyncGrants {
            b.adapter.reviewWebsiteGrant(grant, key: key, profileID: profile.id, allow: true)
        }
        #expect(b.stores.permissions.policy(for: url, .camera) == .allow)
        #expect(b.stores.permissions.assistantAccess(for: "https://sibling.example.com:8443") == .control)
        #expect(b.stores.permissions.assistantAccess(for: "https://sibling.example.com") == .ask)
        for key in records.keys {
            try b.adapter.apply(nil, key: key, for: .websiteSettings, profileID: profile.id)
        }
        #expect(b.stores.permissions.popups(for: "https://local.test") == .block)
        #expect(b.stores.permissions.policy(for: url, .camera) == .ask)
        #expect(b.stores.zoom.level(for: "www.example.com") == nil)
        #expect(throws: (any Error).self) { try b.adapter.values(for: .websiteSettings, profileID: nil) }
        #expect(throws: (any Error).self) { try b.adapter.values(for: .websiteSettings, profileID: Profile.privateID) }
        await a.stores.permissions.waitForPendingSave()
        await b.stores.permissions.waitForPendingSave()
        await a.stores.zoom.waitForPendingSave()
        await b.stores.zoom.waitForPendingSave()
        await b.stores.blocker.waitForPendingCompilation()
    }
}

@MainActor
struct MacSettingsFixture {
    let folder: URL
    let suite: String
    let webSettings: BrowserSettings
    let stores: MacSettingsStores
    let catalog: ProviderCatalog
    let adapter: MacSettingsSyncAdapter

    init(profile: Profile, folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = AppDatabase.defaultsSuite("MacSettingsTests.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = BrowserSettings(defaults: defaults)
        webSettings = settings
        settings.blocksTrackers = false
        let stores = MacSettingsStores(
            web: settings, permissions: SitePermissions(storageURL: folder.appending(path: "sites")),
            blocker: ContentBlocker(defaults: defaults, settings: settings, ruleStore: WKContentRuleListStore(url: folder.appending(path: "rules"))),
            zoom: PageZoomStore(file: folder.appending(path: "zoom")), models: LLMSettings(defaults: defaults)
        )
        self.stores = stores
        catalog = ProviderCatalog(defaults: defaults, keySharing: .init(defaults: defaults, local: .fixture(), cloud: .fixture()))
        adapter = MacSettingsSyncAdapter(profiles: [profile], catalog: catalog, stores: { _ in stores }, account: { "fixture-account" }, refreshWindows: { _, _, _ in })
    }

    func cleanup() {
        stores.models.defaults.removePersistentDomain(forName: suite)
    }
}
