// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension SharedProfileLifecycleTests {
    @MainActor
    private final class Launch {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let cloud = FakeSyncCloud()
        let clock = TestClock()
        var engine: FakeSyncEngine?

        var list: URL {
            root.appending(path: "profiles.json")
        }

        var settingsFile: URL {
            root.appending(path: "iCloudMacSettings.json")
        }

        var spacesFile: URL {
            root.appending(path: "iCloudSharedSpaces.json")
        }

        func start(_ profiles: ProfileStore) throws -> CloudSync {
            let held = CloudTabsTests.Launch.entitlements
            let gate = CloudSyncGate.Inputs(
                tabsFlag: false, vaultFlag: false, isRunningTests: false, isStaged: false, ownsSession: true,
                entitlement: { held[$0] }, offersMacSync: true
            )
            let sync = CloudSync.start(
                gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: root.appending(path: "router.json"),
                profiles: profiles.profiles, profileStore: profiles, windows: { [] }, clock: clock, makeEngine: { delegate, state in
                    let engine = FakeSyncEngine(cloud: self.cloud, delegate: delegate, state: state)
                    self.engine = engine
                    return engine
                }
            )
            return try #require(sync)
        }
    }

    @Test func theHeartbeatResumesACatalogEnrollmentAfterTheMissingListReturns() async throws {
        let launch = Launch(), files = FileManager.default
        defer { try? files.removeItem(at: launch.root) }
        let previous = ProfileStore(file: launch.list)
        let work = previous.add(name: "Work")
        defer { SpaceStore.forget(work.id) }
        let host = CloudSharedSpaces(stateFile: launch.spacesFile, profileStore: previous, windows: { [] })
        let writer = FakeSyncEngine(cloud: launch.cloud, delegate: host.catalog)
        host.attach(writer)
        let id = try await host.publishProfile(work)
        let backup = launch.root.appending(path: "saved-profiles")
        try files.moveItem(at: launch.list, to: backup)
        let restarted = try launch.start(ProfileStore(file: launch.list))
        defer { restarted.prepareToTerminate() }
        try #require(await waitUntil(timeout: .seconds(2)) { launch.clock.pendingCount > 0 })
        #expect(launch.cloud.names(in: SharedCatalogCategory.profiles.zone).isEmpty)
        try files.moveItem(at: backup, to: launch.list)
        launch.clock.advance(by: restarted.heartbeatInterval)
        #expect(await waitUntil(timeout: .seconds(3)) { launch.cloud.names(in: SharedCatalogCategory.profiles.zone) == [id.uuidString] })
    }

    @Test(arguments: [false, true])
    func reopeningPersonalCannotReplaceAnAbsentListBeforeItsCatalogReturns(catalogReturnsAfterStartup: Bool) async throws {
        let launch = Launch(), files = FileManager.default
        defer { try? files.removeItem(at: launch.root) }
        let previous = ProfileStore(file: launch.list)
        let kept = previous.add(name: "Recovered")
        defer { SpaceStore.forget(kept.id) }
        let old = CloudSharedSpaces(stateFile: launch.spacesFile, profileStore: previous, windows: { [] })
        old.attach(FakeSyncEngine(cloud: launch.cloud, delegate: old.catalog))
        let cloudID = try await old.publishProfile(kept)
        let list = launch.root.appending(path: "list.saved"), catalog = launch.root.appending(path: "catalog.saved")
        try files.moveItem(at: launch.list, to: list)
        try files.moveItem(at: launch.spacesFile, to: catalog)
        let profiles = ProfileStore(file: launch.list)
        _ = ProfileStore.selection(profile: .original(), catalog: profiles)
        if !catalogReturnsAfterStartup {
            try files.moveItem(at: catalog, to: launch.spacesFile)
        }
        let app = try launch.start(profiles)
        defer { app.prepareToTerminate() }
        let restored = try #require(app.sharedSpaces)
        if catalogReturnsAfterStartup {
            try files.moveItem(at: catalog, to: launch.spacesFile)
        }
        await restored.refresh()
        #expect(launch.cloud.names(in: SharedCatalogCategory.profiles.zone).isEmpty)
        let added = profiles.add(name: "Added while waiting")
        try #require(!files.fileExists(atPath: launch.list.path))
        try files.moveItem(at: list, to: launch.list)
        await restored.refresh()
        #expect(ProfileStore(file: launch.list).profiles.map(\.id) == [Profile.originalID, kept.id, added.id])
        #expect(restored.links[kept.id]?.profile == cloudID)
        #expect(launch.cloud.names(in: SharedCatalogCategory.profiles.zone) == [cloudID.uuidString])
    }

    @Test func aFreshInstallCanSharePersonalAndAnExplicitNewProfile() async throws {
        let launch = Launch()
        try FileManager.default.createDirectory(at: launch.root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: launch.root) }
        let profiles = ProfileStore(file: launch.list)
        let app = try launch.start(profiles)
        defer { app.prepareToTerminate() }
        let spaces = try #require(app.sharedSpaces), settings = try #require(app.settingsSync)
        try await spaces.enable(.profiles, for: .original())
        let added = profiles.add(name: "New on this Mac")
        defer {
            BrowserProfileContext.forget(added.id)
            ProfileSettingsStore.forget(added.id)
            try? FileManager.default.removeItem(at: added.supportDirectory)
        }
        let id = try await spaces.publishProfile(added)
        settings.registerProfile?(added)
        try await settings.enable(.providers, localProfileID: added.id, cloudProfileID: id)
        try settings.disable(.providers, localProfileID: added.id)
        #expect(ProfileStore(file: launch.list).profiles.contains(added))
        #expect(!settings.isEnabled(.providers, localProfileID: added.id))
        #expect(spaces.links[added.id]?.profile == id)
    }

    @Test(arguments: [false, true])
    func aColdStartWaitsForTheProfileListBeforeDiscardingOrSendingNamedEdits(absent: Bool) async throws {
        let launch = Launch(), files = FileManager.default
        defer { try? files.removeItem(at: launch.root) }
        let previous = ProfileStore(file: launch.list)
        let live = previous.add(name: "Still here")
        let erased = Profile(id: UUID(), name: "Already erased", symbol: "person", color: .gray)
        defer {
            BrowserProfileContext.forget(live.id)
            ProfileSettingsStore.forget(live.id)
            try? files.removeItem(at: live.supportDirectory)
        }
        let site = "https://profile.example.test"
        let web = MacSettingPayload(key: "camera|" + site, value: try JSONEncoder().encode(PermissionPolicy.deny))
        let model = MacSettingPayload(key: "selection", value: try JSONEncoder().encode("custom.fixture"))
        let sites = SitePermissions(storageURL: live.permissionsFile)
        sites.set(.deny, for: site, .camera)
        await sites.waitForPendingSave()
        LLMSettings(defaults: ProfileSettingsStore.defaults(for: live)).providerID = "custom.fixture"

        var edited = false
        let seed = CloudSettingsSync(stateFile: launch.settingsFile, read: { category, _ in
            let payload = category == .websiteSettings ? web : model
            return edited ? [payload.key: try #require(payload.value)] : [:]
        }, apply: { _, _, _, _ in })
        let writer = FakeSyncEngine(cloud: launch.cloud, delegate: seed)
        seed.attach(writer)
        for profile in [live, erased] {
            for category in MacSettingsCategory.allCases {
                try await seed.enable(category, localProfileID: profile.id, cloudProfileID: profile.id)
            }
        }
        writer.offline = true
        edited = true
        try seed.collectChanges()
        let channels = Array(seed.state.channels.values)
        let old = CloudSharedSpaces(stateFile: launch.spacesFile, profiles: [live, erased], windows: { [] })
        let catalogEngine = FakeSyncEngine(cloud: launch.cloud, delegate: old.catalog)
        old.attach(catalogEngine)
        let keptID = try await old.publishProfile(live)
        let lostID = try await old.publishProfile(erased)
        let backup = launch.root.appending(path: "saved-profiles")
        try files.moveItem(at: launch.list, to: backup)
        if !absent {
            try files.createDirectory(at: launch.list, withIntermediateDirectories: false)
        }

        let profiles = ProfileStore(file: launch.list)
        let app = try launch.start(profiles)
        defer { app.prepareToTerminate() }
        _ = ProfileStore.selection(profile: .original(), catalog: profiles)
        let settings = try #require(app.settingsSync), spaces = try #require(app.sharedSpaces)
        // Explicit global consent can still be changed while the named profile list is unavailable.
        try await settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try settings.disable(.providers, localProfileID: nil)
        app.beat()
        let engine = try #require(launch.engine)
        for channel in channels {
            let payload = channel.category == .websiteSettings ? web : model
            engine.add([.saveRecord(SyncRecordID(zone: channel.zone, name: payload.recordName))])
        }
        try await engine.sendNow()
        let saved = try CloudSettingsSync.State.read(from: launch.settingsFile)
        for channel in channels {
            let payload = channel.category == .websiteSettings ? web : model
            #expect(saved.channels[channel.zone]?.enrollment == channel.enrollment)
            #expect(saved.channels[channel.zone]?.records[payload.key]?.pending == payload)
            #expect(launch.cloud.names(in: channel.zone).isEmpty)
        }
        #expect(launch.cloud.names(in: SharedCatalogCategory.profiles.zone).isEmpty)
        if absent {
            try #require(!files.fileExists(atPath: launch.list.path))
        } else {
            try files.removeItem(at: launch.list)
        }
        try files.moveItem(at: backup, to: launch.list)
        app.beat()
        await spaces.refresh()
        #expect(await waitUntil(timeout: .seconds(3)) {
            channels.filter { $0.localProfileID == live.id }.allSatisfy { !launch.cloud.names(in: $0.zone).isEmpty }
        })
        for channel in channels {
            let payload = channel.category == .websiteSettings ? web : model
            let id = SyncRecordID(zone: channel.zone, name: payload.recordName)
            if channel.localProfileID == live.id {
                let record = try #require(launch.cloud.record(id))
                let sent = try #require(MacSettingRecord.decode(record.payload, recordName: id.name))
                #expect(sent.setting == payload && sent.enrollment == channel.enrollment)
            } else {
                #expect(settings.state.channels[channel.zone] == nil && launch.cloud.record(id) == nil)
            }
        }
        #expect(spaces.links[live.id]?.profile == keptID && spaces.links[erased.id] == nil)
        #expect(launch.cloud.names(in: SharedCatalogCategory.profiles.zone) == [keptID.uuidString])
        #expect(engine.saveAttempts[lostID.uuidString] == nil)
    }

    @Test(arguments: [false, true])
    func returningSettingsKeepTheNamedEnrollmentAtTheFirstGlobalOptIn(profileListReturnsFirst: Bool) async throws {
        let launch = Launch(), files = FileManager.default
        defer { try? files.removeItem(at: launch.root) }
        let profiles = ProfileStore(file: launch.list)
        let work = profiles.add(name: "Work")
        defer {
            BrowserProfileContext.forget(work.id)
            ProfileSettingsStore.forget(work.id)
            try? files.removeItem(at: work.supportDirectory)
        }
        let savedModel = "custom.returned"
        let choice = MacSettingPayload(key: "selection", value: try JSONEncoder().encode(savedModel))
        var edits: [String: Data] = [:]
        let prior = CloudSettingsSync(stateFile: launch.settingsFile, read: { _, _ in edits }, apply: { _, _, _, _ in })
        let writer = FakeSyncEngine(cloud: launch.cloud, delegate: prior)
        prior.attach(writer)
        try await prior.enable(.providers, localProfileID: work.id, cloudProfileID: work.id)
        writer.offline = true
        edits[choice.key] = choice.value
        try prior.collectChanges()
        let channel = try #require(prior.channel(.providers, localProfileID: work.id))
        try #require(channel.records[choice.key]?.pending == choice)
        LLMSettings(defaults: ProfileSettingsStore.defaults(for: work)).providerID = savedModel

        let list = launch.root.appending(path: "list.saved"), settings = launch.root.appending(path: "settings.saved")
        try files.moveItem(at: launch.list, to: list)
        try files.moveItem(at: launch.settingsFile, to: settings)
        let app = try launch.start(ProfileStore(file: launch.list))
        defer { app.prepareToTerminate() }
        let restored = try #require(app.settingsSync)
        if profileListReturnsFirst {
            try files.moveItem(at: list, to: launch.list)
            app.beat()
            try files.moveItem(at: settings, to: launch.settingsFile)
        } else {
            try files.moveItem(at: settings, to: launch.settingsFile)
            app.beat()
            try files.moveItem(at: list, to: launch.list)
        }
        try await restored.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let saved = try CloudSettingsSync.State.read(from: launch.settingsFile)
        #expect(saved.channels[channel.zone]?.enrollment == channel.enrollment)
        #expect(restored.isEnabled(.providers, localProfileID: nil))
        app.beat()
        let id = SyncRecordID(zone: channel.zone, name: choice.recordName)
        #expect(await waitUntil(timeout: .seconds(3)) {
            guard let record = launch.cloud.record(id), let sent = MacSettingRecord.decode(record.payload, recordName: id.name) else { return false }
            return sent.setting == choice && sent.enrollment == channel.enrollment
        })
    }
}
