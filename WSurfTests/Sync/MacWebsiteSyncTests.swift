// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Synchronization
import Testing
import WebKit
import WSurfCore

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

    @Test func receivedWebsiteEditsAndResetsSurviveImmediateDiskReopen() async throws {
        let profile = Profile.original()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let host = "edited.test", origin = "https://edited.test"
        let zoomFile = folder.appending(path: "zoom"), sitesFile = folder.appending(path: "sites")
        let zoom = fixture.stores.zoom, sites = fixture.stores.permissions
        let camera = "camera|" + origin
        func receive(_ value: Data?, _ key: String) throws {
            try fixture.adapter.apply(value, key: key, for: .websiteSettings, profileID: profile.id)
        }
        zoom.set(1.25, for: host, defaultZoom: 1)
        sites.set(.deny, for: origin, .camera)
        await zoom.waitForPendingSave()
        await sites.waitForPendingSave()
        // These older writes may still be queued when the channel receives the newer revision.
        zoom.set(2, for: "local.test", defaultZoom: 1)
        sites.setPopups(.block, for: "https://local.test")
        try receive(JSONEncoder().encode(1.5), "zoom|" + host)
        try receive(JSONEncoder().encode(PermissionPolicy.allow), camera)
        func checkDisk(zoomLevel: CGFloat?, proposed: Bool) {
            let reopened = SitePermissions(storageURL: sitesFile)
            #expect(PageZoomStore(file: zoomFile).level(for: host) == zoomLevel)
            #expect(PageZoomStore(file: zoomFile).level(for: "local.test") == 2)
            #expect(reopened.popups(for: "https://local.test") == .block)
            #expect(reopened.pendingSyncGrants[camera]?.value == (proposed ? PermissionPolicy.allow.rawValue : nil))
            #expect(reopened.policy(for: origin, .camera) == (proposed ? .deny : .ask))
        }
        checkDisk(zoomLevel: 1.5, proposed: true)
        try receive(nil, "zoom|" + host)
        try receive(nil, camera)
        checkDisk(zoomLevel: nil, proposed: false)
        await zoom.waitForPendingSave()
        await sites.waitForPendingSave()
        checkDisk(zoomLevel: nil, proposed: false)
    }

    private func openProviderSync(_ mac: MacSettingsFixture, profile: Profile, cloud: FakeSyncCloud) async throws -> (CloudSettingsSync, FakeSyncEngine) {
        let sync = CloudSettingsSync(stateFile: mac.folder.appending(path: "settings"), profiles: [profile], adapter: mac.adapter)
        let engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        return (sync, engine)
    }

    @Test func aLocalOnlyProviderEditPreservesTheSharedDefinitionUntilExplicitRemoval() async throws {
        let profile = Profile.original(), root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try MacSettingsFixture(profile: profile, folder: root.appending(path: "studio"))
        let air = try MacSettingsFixture(profile: profile, folder: root.appending(path: "air"))
        defer { studio.cleanup(); air.cleanup() }
        let cloud = FakeSyncCloud()
        var shared = ProviderCatalog.newCustom()
        shared.name = "Shared"
        shared.baseURL = URL(string: "https://ai.example.test/v1")
        studio.catalog.save(shared)
        let (sender, studioEngine) = try await openProviderSync(studio, profile: profile, cloud: cloud)
        try await studioEngine.sendNow()
        let (receiver, airEngine) = try await openProviderSync(air, profile: profile, cloud: cloud)
        #expect(air.catalog.provider(id: shared.id)?.baseURL == shared.baseURL)

        var local = shared
        local.name = "Queued public edit"
        studio.catalog.save(local)
        try sender.collectChanges()
        local.baseURL = URL(string: "https://ai.example.test/v1?tenant=private-fixture")
        studio.catalog.save(local)
        try sender.collectChanges()
        try await studioEngine.sendNow()
        try await airEngine.fetchNow()
        #expect(air.catalog.provider(id: shared.id)?.baseURL == shared.baseURL)
        let key = "custom|" + shared.id
        let id = SyncRecordID(zone: "mac-prefs-providers", name: MacSettingPayload(key: key, value: nil).recordName)
        let row = try #require(cloud.record(id))
        let definition = try #require(MacSettingRecord.decode(row.payload, recordName: id.name)?.value)
        #expect(try JSONSerialization.jsonObject(with: definition) as? [String: String] == ["name": "Shared", "endpoint": "https://ai.example.test/v1"])

        let (reopened, restartedEngine) = try await openProviderSync(studio, profile: profile, cloud: cloud)
        shared.name = "Edited on Air"
        air.catalog.save(shared)
        try receiver.collectChanges()
        try await airEngine.sendNow()
        try await restartedEngine.fetchNow()
        #expect(studio.catalog.provider(id: shared.id)?.baseURL == local.baseURL)
        studio.catalog.remove(local)
        try reopened.collectChanges()
        try await restartedEngine.sendNow()
        try await airEngine.fetchNow()
        #expect(air.catalog.provider(id: shared.id) == nil)
    }

    enum ProviderBaseline: CaseIterable {
        case known, firstRead, removedByPeer, resetByStudio
    }

    @Test(arguments: [false, true], [false, true])
    func leavingAPrivateEndpointPreservesTheFinalChoiceAcrossAnOutstandingPublicSave(
        initiallyShared: Bool, replyBeforeChoice: Bool
    ) async throws {
        try await checkOutstandingSave(initiallyShared: initiallyShared, replyBeforeChoice: replyBeforeChoice, upgrade: false)
    }

    @Test(arguments: [false, true], [false, true])
    func anOfflineChoiceSurvivesReopeningAnOlderProviderCheckpoint(
        initiallyShared: Bool, replyBeforeChoice: Bool
    ) async throws {
        try await checkOutstandingSave(initiallyShared: initiallyShared, replyBeforeChoice: replyBeforeChoice, upgrade: true)
    }

    private func checkOutstandingSave(
        initiallyShared: Bool, replyBeforeChoice: Bool, upgrade: Bool
    ) async throws {
        let profile = Profile.original(), root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try MacSettingsFixture(profile: profile, folder: root.appending(path: "studio"))
        let air = try MacSettingsFixture(profile: profile, folder: root.appending(path: "air"))
        defer { studio.cleanup(); air.cleanup() }
        let cloud = FakeSyncCloud()
        let original = URL(string: "https://one.example.test/v1")
        var definition = ProviderCatalog.newCustom()
        definition.name = "Fixture"
        definition.baseURL = original
        if initiallyShared {
            studio.catalog.save(definition)
        }
        var (sender, engine) = try await openProviderSync(studio, profile: profile, cloud: cloud)
        try await engine.sendNow()
        let (peer, peerEngine) = try await openProviderSync(air, profile: profile, cloud: cloud)
        let key = "custom|" + definition.id
        let initialValue = try studio.adapter.values(for: .providers, profileID: nil)[key]
        let id = SyncRecordID(zone: "mac-prefs-providers", name: MacSettingPayload(key: key, value: nil).recordName)
        definition.baseURL = URL(string: "https://two.example.test/v1")
        studio.catalog.save(definition)
        try sender.collectChanges()
        let submitted = try #require(engine.handOut(id))
        definition.baseURL = URL(string: "https://two.example.test/v1?tenant=private-fixture")
        studio.catalog.save(definition)
        try sender.collectChanges()
        guard case .saved(let accepted) = cloud.save(submitted) else {
            Issue.record("Expected the outstanding public save to reach iCloud")
            return
        }
        let reply = SyncEvent.sent(saved: [accepted], deleted: [], failed: [])
        if replyBeforeChoice {
            await sender.handle(reply)
        }
        if upgrade {
            // Older checkpoints kept the sampled public value while the catalog held the private URL.
            var checkpoint = sender.state
            let previous = try #require(checkpoint.channels[id.zone]?.records[key])
            var legacy = MacSettingChannel.Record(server: previous.server, fields: previous.fields, modified: previous.modified)
            if !replyBeforeChoice {
                legacy.inFlight = try #require(MacSettingRecord.decode(submitted.payload, recordName: id.name)).setting
            }
            checkpoint.channels[id.zone]?.observed[key] = initialValue
            checkpoint.channels[id.zone]?.records[key] = legacy
            let file = studio.folder.appending(path: "settings")
            try JSONEncoder().encode(checkpoint).write(to: file, options: .atomic)
        }
        if initiallyShared {
            definition.baseURL = original
            studio.catalog.save(definition)
        } else {
            studio.catalog.remove(definition)
        }
        if upgrade {
            (sender, engine) = try await openProviderSync(studio, profile: profile, cloud: cloud)
        } else {
            try sender.collectChanges()
            if !replyBeforeChoice {
                await sender.handle(reply)
            }
        }
        try await engine.sendNow()
        try await peerEngine.fetchNow()
        let expected = initiallyShared ? original : nil
        #expect(studio.catalog.provider(id: definition.id)?.baseURL == expected)
        #expect(air.catalog.provider(id: definition.id)?.baseURL == expected)
        #expect(peer.channel(.providers, localProfileID: nil)?.records[key]?.server?.value == sender.channel(.providers, localProfileID: nil)?.observed[key])
    }

    @Test(arguments: ProviderBaseline.allCases, [true, false])
    func anOlderQueuedProviderResetCannotDeleteAPrivateEditOnUpgrade(baseline: ProviderBaseline, wasSending: Bool) async throws {
        let profile = Profile.original(), root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try MacSettingsFixture(profile: profile, folder: root.appending(path: "studio"))
        let air = try MacSettingsFixture(profile: profile, folder: root.appending(path: "air"))
        defer { studio.cleanup(); air.cleanup() }
        let file = studio.folder.appending(path: "settings")
        let cloud = FakeSyncCloud()
        var provider = ProviderCatalog.newCustom()
        provider.name = "Shared"
        provider.baseURL = URL(string: "https://ai.example.test/v1")
        air.catalog.save(provider)
        let peer = CloudSettingsSync(stateFile: air.folder.appending(path: "settings"), profiles: [profile], adapter: air.adapter)
        let peerEngine = FakeSyncEngine(cloud: cloud, delegate: peer)
        peer.attach(peerEngine)
        try await peer.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await peerEngine.sendNow()
        let key = "custom|" + provider.id
        let original = try #require(air.adapter.values(for: .providers, profileID: nil)[key])

        // An older offline capture saw the provider disappear from its list of shareable definitions.
        var channel = try #require(peer.channel(.providers, localProfileID: nil))
        channel.enrollment = UUID()
        if baseline == .firstRead {
            channel.records[key]?.server = nil
            channel.records[key]?.fields = nil
        }
        channel.collect([:])
        let reset = MacSettingPayload(key: key, value: nil)
        #expect(channel.records[key]?.pending == reset)
        if wasSending {
            channel.records[key]?.inFlight = reset
        }
        var checkpoint = peer.state
        checkpoint.channels[channel.zone] = channel
        try JSONEncoder().encode(checkpoint).write(to: file, options: .atomic)
        if baseline == .removedByPeer {
            air.catalog.remove(provider)
            try peer.collectChanges()
            try await peerEngine.sendNow()
        } else if baseline == .resetByStudio {
            let id = SyncRecordID(zone: channel.zone, name: reset.recordName)
            var resetRecord = try #require(cloud.record(id))
            resetRecord.payload = try MacSettingRecord(reset, enrollment: channel.enrollment).encoded()
            guard case .saved = cloud.save(resetRecord) else {
                Issue.record("Expected the old Studio reset to reach iCloud")
                return
            }
            try await peerEngine.fetchNow()
        }
        provider.baseURL = URL(string: "https://ai.example.test/v1?tenant=private-fixture")
        studio.catalog.save(provider)
        let reopened = try MacSettingsFixture(profile: profile, folder: studio.folder, makeDefaults: { _ in UserDefaults(suiteName: studio.suite) })
        defer { reopened.cleanup() }
        let sync = CloudSettingsSync(stateFile: file, profiles: [profile], adapter: reopened.adapter)
        let engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await engine.sendNow()
        try await peerEngine.fetchNow()
        let repaired = try #require(sync.channel(.providers, localProfileID: nil)?.records[key])
        #expect(repaired.pending == nil && !repaired.conflict)
        let removed = baseline == .removedByPeer || (baseline == .resetByStudio && !wasSending)
        #expect(repaired.server?.value == (removed ? nil : original))
        let sharedURL = removed ? nil : "https://ai.example.test/v1"
        #expect(air.catalog.provider(id: provider.id)?.baseURL?.absoluteString == sharedURL)
        #expect(reopened.catalog.provider(id: provider.id)?.baseURL == provider.baseURL)

        provider.baseURL = URL(string: "https://new.example.test/v1")
        reopened.catalog.save(provider)
        try sync.collectChanges()
        try await engine.sendNow()
        try await peerEngine.fetchNow()
        #expect(air.catalog.provider(id: provider.id)?.baseURL == provider.baseURL)
    }

    @Test func checkpointAndZoomReopenTogetherWithoutRepublishingTheOldValue() async throws {
        let profile = Profile.original(), root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = try MacSettingsFixture(profile: profile, folder: root.appending(path: "studio"))
        let receiver = try MacSettingsFixture(profile: profile, folder: root.appending(path: "air"))
        defer { sender.cleanup(); receiver.cleanup() }
        func open(_ fixture: MacSettingsFixture) -> CloudSettingsSync {
            CloudSettingsSync(stateFile: fixture.folder.appending(path: "checkpoint"),
                              read: fixture.adapter.values(for:profileID:), apply: fixture.adapter.apply(_:key:for:profileID:))
        }
        let host = "common.test", key = "zoom|" + host, sharedID = UUID()
        sender.stores.zoom.set(1.25, for: host, defaultZoom: 1)
        receiver.stores.zoom.set(1.25, for: host, defaultZoom: 1)
        receiver.stores.zoom.set(2, for: "local.test", defaultZoom: 1)
        await receiver.stores.zoom.waitForPendingSave()
        let cloud = FakeSyncCloud(), studio = open(sender), air = open(receiver)
        let studioEngine = FakeSyncEngine(cloud: cloud, delegate: studio), airEngine = FakeSyncEngine(cloud: cloud, delegate: air)
        studio.attach(studioEngine)
        air.attach(airEngine)
        try await studio.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: sharedID)
        try await studioEngine.sendNow()
        try await air.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: sharedID)
        try await airEngine.sendNow()
        sender.stores.zoom.set(1.5, for: host, defaultZoom: 1)
        try studio.collectChanges()
        try await studioEngine.sendNow()
        let zone = try #require(air.channel(.websiteSettings, localProfileID: profile.id)?.zone)
        let payload = MacSettingPayload(key: key, value: try JSONEncoder().encode(1.5))
        let record = try #require(cloud.record(SyncRecordID(zone: zone, name: payload.recordName)))

        // The receiver may exit directly after saving its channel checkpoint, without yielding for local writes.
        try air.receive(record)
        try air.save()
        let reopened = try MacSettingsFixture(profile: profile, folder: receiver.folder)
        defer { reopened.cleanup() }
        let restored = open(reopened)
        #expect(reopened.stores.zoom.level(for: host) == 1.5)
        #expect(reopened.stores.zoom.level(for: "local.test") == 2)
        try restored.collectChanges()
        let recovered = try #require(restored.channel(.websiteSettings, localProfileID: profile.id))
        #expect(recovered.records[key]?.server == payload)
        #expect(recovered.records[key]?.pending == nil)
    }

    @Test func unwritableWebsiteFilesRefuseCheckpointAndRetryTheSameValue() async throws {
        let profile = Profile.original()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let zoom = folder.appending(path: "zoom"), sites = folder.appending(path: "sites")
        let key = "camera|https://failure.test"
        let level = try JSONEncoder().encode(1.75), grant = try JSONEncoder().encode(PermissionPolicy.allow)
        func receive(_ value: Data, _ key: String) throws {
            try fixture.adapter.apply(value, key: key, for: .websiteSettings, profileID: profile.id)
        }
        for file in [zoom, sites] {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        }
        #expect(throws: (any Error).self) { try receive(level, "zoom|failure.test") }
        #expect(throws: (any Error).self) { try receive(grant, key) }
        #expect(fixture.stores.zoom.level(for: "failure.test") == nil)
        #expect(fixture.stores.permissions.pendingSyncGrants[key] == nil)
        for file in [zoom, sites] {
            try FileManager.default.removeItem(at: file)
        }
        try receive(level, "zoom|failure.test")
        try receive(grant, key)
        #expect(PageZoomStore(file: zoom).level(for: "failure.test") == 1.75)
        #expect(SitePermissions(storageURL: sites).pendingSyncGrants[key]?.value == PermissionPolicy.allow.rawValue)
        await fixture.stores.zoom.waitForPendingSave()
        await fixture.stores.permissions.waitForPendingSave()
    }

    @Test func localEditsCannotBeCollectedUntilTheirDiskWritesSucceed() async throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let files = FileManager.default
        defer { try? files.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let zoom = folder.appending(path: "zoom"), sites = folder.appending(path: "sites")
        let origin = "https://local.test"
        for file in [zoom, sites] {
            try files.createDirectory(at: file, withIntermediateDirectories: false)
        }
        fixture.stores.zoom.set(1.75, for: "local.test", defaultZoom: 1)
        fixture.stores.permissions.set(.deny, for: origin, .camera)
        await fixture.stores.zoom.waitForPendingSave()
        await fixture.stores.permissions.waitForPendingSave()
        func capture() throws -> [String: Data] {
            try fixture.adapter.values(for: .websiteSettings, profileID: profile.id)
        }
        #expect(throws: (any Error).self) { try capture() }
        try files.removeItem(at: zoom)
        #expect(throws: (any Error).self) { try capture() }
        try files.removeItem(at: sites)
        #expect(try capture()["zoom|local.test"] == JSONEncoder().encode(1.75))
        #expect(PageZoomStore(file: zoom).level(for: "local.test") == 1.75)
        #expect(SitePermissions(storageURL: sites).policy(for: origin, .camera) == .deny)
    }

    @Test func unreadableInitialSnapshotsCannotBePublishedOrReplacedByIncomingEdits() throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let zoom = folder.appending(path: "zoom"), sites = folder.appending(path: "sites")
        let broken = Data(#"{"preserve.test":2,"defaults":"incompatible"}"#.utf8)
        try broken.write(to: zoom)
        try broken.write(to: sites)
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        func receive(_ data: Data, _ key: String) throws {
            try fixture.adapter.apply(data, key: key, for: .websiteSettings, profileID: profile.id)
        }
        let level = try JSONEncoder().encode(1.5), policy = try JSONEncoder().encode(PopupPolicy.block)
        #expect(throws: (any Error).self) { try fixture.adapter.values(for: .websiteSettings, profileID: profile.id) }
        #expect(throws: (any Error).self) { try receive(level, "zoom|new.test") }
        #expect(throws: (any Error).self) { try receive(policy, "popups|https://new.test") }
        #expect(try Data(contentsOf: zoom) == broken)
        #expect(try Data(contentsOf: sites) == broken)
        try JSONEncoder().encode(["preserve.test": 2.0]).write(to: zoom)
        try files.removeItem(at: sites)
        let recoveredSites = SitePermissions(storageURL: sites)
        try recoveredSites.applyDurably { $0.set(.deny, for: "https://preserve.test", .camera) }
        try receive(level, "zoom|new.test")
        try receive(policy, "popups|https://new.test")
        #expect(PageZoomStore(file: zoom).level(for: "preserve.test") == 2)
        #expect(SitePermissions(storageURL: sites).policy(for: "https://preserve.test", .camera) == .deny)
    }

    @Test func aFailedApprovalClearIsRetriedFromDiskAfterRestart() throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let files = FileManager.default
        defer { try? files.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        let file = folder.appending(path: "sites"), saved = folder.appending(path: "saved")
        let origin = "https://fixture.test", key = "camera|" + origin
        let deny = try JSONEncoder().encode(PermissionPolicy.deny), allow = try JSONEncoder().encode(PermissionPolicy.allow)
        try fixture.adapter.apply(deny, key: key, for: .websiteSettings, profileID: profile.id)
        try fixture.adapter.apply(allow, key: key, for: .websiteSettings, profileID: profile.id)
        var fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        fields["otherWebsitePreference"] = ["keep": true]
        try JSONSerialization.data(withJSONObject: fields).write(to: file, options: .atomic)
        // Atomic replacement needs a writable directory even when the existing settings are readable.
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect { try fixture.adapter.discardWebsiteApprovals(profileID: profile.id) } throws: { error in
            (error as? CocoaError)?.code == .fileWriteNoPermission
        }
        #expect(fixture.stores.permissions.pendingSyncGrants.isEmpty)
        #expect(SitePermissions(storageURL: file).pendingSyncGrants[key] != nil)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try files.moveItem(at: file, to: saved)
        try files.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try fixture.adapter.discardWebsiteApprovals(profileID: profile.id) }
        #expect(fixture.stores.permissions.pendingSyncGrants.isEmpty)
        let restarted = try MacSettingsFixture(profile: profile, folder: folder)
        defer { restarted.cleanup() }
        #expect(throws: (any Error).self) { try restarted.adapter.discardWebsiteApprovals(profileID: profile.id) }
        try files.removeItem(at: file)
        try files.moveItem(at: saved, to: file)
        #expect(SitePermissions(storageURL: file).pendingSyncGrants[key] != nil)
        try restarted.adapter.discardWebsiteApprovals(profileID: profile.id)
        let cleared = SitePermissions(storageURL: file)
        #expect(cleared.pendingSyncGrants.isEmpty && cleared.policy(for: origin, .camera) == .deny)
        let remaining = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(remaining["otherWebsitePreference"] as? [String: Bool] == ["keep": true])
        try files.removeItem(at: folder)
        try restarted.adapter.discardWebsiteApprovals(profileID: profile.id)
        #expect(!files.fileExists(atPath: folder.path))
    }

    @Test(arguments: [true, false])
    func clearingAClosedProfilesApprovalsCreatesNoBrowserContextOrErasedStore(registered: Bool) throws {
        let profile = Profile(id: UUID(), name: "Closed fixture", symbol: "person", color: .gray)
        let adapter = MacSettingsSyncAdapter(profiles: registered ? [profile] : [])
        try #require(AppDatabase.isRunningTests)
        let files = FileManager.default
        defer { try? files.removeItem(at: profile.supportDirectory) }
        try adapter.discardWebsiteApprovals(profileID: profile.id)
        #expect(!files.fileExists(atPath: profile.supportDirectory.path))
        try files.createDirectory(at: profile.permissionsFile, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try adapter.discardWebsiteApprovals(profileID: profile.id) }
        try files.removeItem(at: profile.permissionsFile)
        let stored = SitePermissions(storageURL: profile.permissionsFile)
        try stored.applyDurably { $0.setSyncGrant(.init(account: "fixture", value: "allow"), for: "camera|https://fixture.test") }
        try adapter.discardWebsiteApprovals(profileID: profile.id)
        #expect(SitePermissions(storageURL: profile.permissionsFile).pendingSyncGrants.isEmpty)
        adapter.register(profile)
        #expect(throws: (any Error).self) { try adapter.values(for: .providers, profileID: profile.id) }
        #expect(BrowserProfileContext.existing(for: profile.id) == nil)
    }

    @Test func receivedPreferencesAreInTheProfilePlistAtEachCheckpoint() throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try MacSettingsFixture(profile: profile, folder: folder)
        defer { fixture.cleanup() }
        try #require(fixture.suite.hasPrefix("/"))
        let plist = URL(filePath: fixture.suite + ".plist")
        func persisted() throws -> [String: Any] {
            let data = try Data(contentsOf: plist)
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        func apply(_ data: Data?, _ key: String, _ category: MacSettingsCategory, _ id: UUID?) throws {
            try fixture.adapter.apply(data, key: key, for: category, profileID: id)
        }
        try apply(JSONEncoder().encode(false), "webDefault|javascript", .websiteSettings, profile.id)
        #expect(try persisted()[BrowserSettings.Key.javaScript] as? Bool == false)
        try apply(nil, "webDefault|javascript", .websiteSettings, profile.id)
        #expect(try persisted()[BrowserSettings.Key.javaScript] == nil)
        try apply(JSONEncoder().encode(true), "trackers|fixture.test", .websiteSettings, profile.id)
        #expect(try persisted()["content.blockerExceptions"] as? [String] == ["fixture.test"])
        try apply(nil, "trackers|fixture.test", .websiteSettings, profile.id)
        #expect(try persisted()["content.blockerExceptions"] as? [String] == [])

        let provider = "custom.fixture"
        try apply(JSONEncoder().encode(provider), "selection", .providers, profile.id)
        #expect(try persisted()["llm.provider"] as? String == provider)
        try apply(nil, "selection", .providers, profile.id)
        #expect(try persisted()["llm.provider"] == nil)
        let definition = try JSONEncoder().encode(["name": "Fixture", "endpoint": "https://provider.test/v1"])
        try apply(definition, "custom|" + provider, .providers, nil)
        func catalogIDs() throws -> [String] {
            let data = try #require(try persisted()["llm.customProviders"] as? Data)
            return try JSONDecoder().decode([Provider].self, from: data).map(\.id)
        }
        #expect(try catalogIDs() == [provider])
        try apply(nil, "custom|" + provider, .providers, nil)
        #expect(try catalogIDs().isEmpty)
    }

    @Test func failedPreferenceFlushCannotBeCheckpointedAsALocalEdit() throws {
        let profile = Profile.original(), root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try MacSettingsFixture(profile: profile, folder: root, makeDefaults: FlushControlledDefaults.init(suiteName:))
        defer { fixture.cleanup() }
        let defaults = try #require(fixture.stores.models.defaults as? FlushControlledDefaults)
        var refreshed = false
        let adapter = MacSettingsSyncAdapter(profiles: [profile], catalog: fixture.catalog, stores: { _ in fixture.stores },
                                             refreshWindows: { _, _, _ in refreshed = true })
        defaults.refuseFlush = true
        let value = try JSONEncoder().encode("custom.fixture")
        #expect(throws: (any Error).self) { try adapter.apply(value, key: "selection", for: .providers, profileID: profile.id) }
        #expect(throws: (any Error).self) { try adapter.values(for: .providers, profileID: profile.id) }
        #expect(refreshed)
        defaults.refuseFlush = false
        #expect(try adapter.values(for: .providers, profileID: profile.id)["selection"] == value)
    }

    @Test func settingsDetachmentPrecedesProfileDeletionAndFailureKeepsTheProfile() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let catalogFile = folder.appending(path: "profiles"), stateFile = folder.appending(path: "sync")
        let store = ProfileStore(file: catalogFile)
        let profile = store.add(name: "Remove"), other = store.add(name: "Keep")
        store.markCurrent(profile)
        store.setLaunchProfile(profile.id)
        let marker = folder.appending(path: "profile-data")
        let contents = Data("Synthetic profile".utf8)
        try contents.write(to: marker)
        func reopenSync() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: stateFile, read: { _, _ in [:] }, apply: { _, _, _, _ in })
        }
        let sync = reopenSync()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: sync)
        sync.attach(engine)
        for id in [profile.id, other.id] {
            try await sync.enable(.providers, localProfileID: id, cloudProfileID: id)
        }

        var prepared = 0, erased = 0
        func remove(_ target: Profile) async -> Result<Void, Error> {
            await store.remove(target, beforeErasing: {
                prepared += 1
                #expect(store.currentID == profile.id)
                #expect(!reopenSync().isEnabled(.providers, localProfileID: profile.id))
                // A second window can enable the channel while the first is switching profiles.
                do {
                    try await sync.enable(.providers, localProfileID: profile.id, cloudProfileID: profile.id)
                } catch { Issue.record(error) }
            }, settingsSync: sync, eraseData: { removed in
                #expect(removed.id == profile.id && prepared == 1)
                erased += 1
                try? files.removeItem(at: marker)
            })
        }
        _ = await remove(.original())
        _ = await remove(.privateBrowsing())
        let saved = folder.appending(path: "saved-sync")
        try files.moveItem(at: stateFile, to: saved)
        try files.createDirectory(at: stateFile, withIntermediateDirectories: false)
        let failure = await remove(profile)
        if case .success = failure { Issue.record("Profile deletion accepted a failed settings write") }
        #expect(prepared == 0 && erased == 0)
        #expect(try Data(contentsOf: marker) == contents)
        let reopened = ProfileStore(file: catalogFile)
        #expect(reopened.currentID == profile.id && reopened.launchProfileID == profile.id)
        #expect(reopened.profiles.contains { $0.id == profile.id })

        try files.removeItem(at: stateFile)
        try files.moveItem(at: saved, to: stateFile)
        let parkedCatalog = folder.appending(path: "saved-profiles")
        try files.moveItem(at: catalogFile, to: parkedCatalog)
        try files.createDirectory(at: catalogFile, withIntermediateDirectories: false)
        let unwritableCatalog = await store.remove(profile, settingsSync: sync, eraseData: { _ in erased += 1 })
        if case .success = unwritableCatalog { Issue.record("Profile erasure accepted an unwritable catalog") }
        #expect(store.profiles.contains { $0.id == profile.id })
        #expect(erased == 0)
        #expect(try Data(contentsOf: marker) == contents)
        try files.removeItem(at: catalogFile)
        try files.moveItem(at: parkedCatalog, to: catalogFile)
        try await remove(profile).get()
        #expect(prepared == 1 && erased == 1)
        #expect(!files.fileExists(atPath: marker.path))
        let remaining = ProfileStore(file: catalogFile)
        #expect(remaining.profiles.map(\.id) == [Profile.originalID, other.id])
        #expect(remaining.currentID == Profile.originalID && remaining.launchProfileID == nil)
        #expect(!reopenSync().isEnabled(.providers, localProfileID: profile.id))
        #expect(reopenSync().isEnabled(.providers, localProfileID: other.id))
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
        let reopened = try MacSettingsFixture(profile: profile, folder: folder)
        defer { reopened.cleanup() }
        #expect(reopened.stores.permissions.pendingSyncGrants[key]?.dismissed == true)
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

    init(profile: Profile, folder: URL, makeDefaults: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = AppDatabase.defaultsSuite("MacSettingsTests.\(UUID())")
        let defaults = try #require(makeDefaults(suite))
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

private nonisolated final class FlushControlledDefaults: UserDefaults, @unchecked Sendable {
    private let refused = Mutex(false)
    var refuseFlush: Bool {
        get { refused.withLock { $0 } }
        set { refused.withLock { $0 = newValue } }
    }

    override func synchronize() -> Bool {
        !refuseFlush && super.synchronize()
    }
}
