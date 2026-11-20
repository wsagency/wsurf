// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension MacSettingsSyncTests {
    private func lifecycleDirectory() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test(arguments: [false, true])
    func enrollmentKeepsAResetAcrossRestartWhenBaselineIsDelayed(offline: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings")
        let local = UUID(), shared = UUID()
        let zone = MacSettingChannel(category: .websiteSettings, localProfileID: local, cloudProfileID: shared).zone
        let payload = MacSettingPayload(key: "engine/site", value: Data([1]))
        let id = SyncRecordID(zone: zone, name: payload.recordName)
        let cloud = FakeSyncCloud()
        cloud.createZone(zone)
        _ = cloud.save(SyncRecord(id: id, type: .macSetting, schema: 1, payload: try JSONEncoder().encode(payload)))
        var values = [payload.key: Data([1])]
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { value, key, _, _ in values[key] = value })
        }
        let first = open()
        let engine = FakeSyncEngine(cloud: cloud, delegate: first)
        first.attach(engine)
        engine.offline = offline
        engine.unreadable = [id.name]
        await #expect(throws: (any Error).self) { try await first.enable(.websiteSettings, localProfileID: local, cloudProfileID: shared) }
        #expect(first.record(for: id) == nil)
        let reopened = open()
        let enrolled = try #require(reopened.channel(.websiteSettings, localProfileID: local))
        #expect(enrolled.observed == values)
        #expect(enrolled.records[payload.key]?.pending == payload)
        #expect(!enrolled.fetched)
        values = [:]
        let retry = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(retry)
        try await reopened.enable(.websiteSettings, localProfileID: local, cloudProfileID: shared)
        let record = try #require(reopened.channel(.websiteSettings, localProfileID: local)?.records[payload.key])
        #expect(values.isEmpty)
        #expect(record.pending == MacSettingPayload(key: payload.key, value: nil))
        #expect(record.conflict)
        #expect(cloud.writeCount == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func failedLastOptOutCanBeRetriedWhileOffline(restart: Bool, erase: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings"), original = root.appending(path: "saved")
        let local = UUID()
        let payload = MacSettingPayload(key: "zoom/site", value: Data([1]))
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in [payload.key: Data([1])] }, apply: { _, _, _, _ in })
        }
        let sync = open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        try await sync.enable(.websiteSettings, localProfileID: local, cloudProfileID: UUID())
        let channel = try #require(sync.channel(.websiteSettings, localProfileID: local))
        let id = SyncRecordID(zone: channel.zone, name: payload.recordName)
        let files = FileManager.default
        try files.moveItem(at: file, to: original)
        try files.createDirectory(at: file, withIntermediateDirectories: false)
        func optOut() throws {
            if erase {
                try sync.forgetProfile(local)
            } else {
                try sync.disable(.websiteSettings, localProfileID: local)
            }
        }
        #expect(throws: (any Error).self) { try optOut() }
        #expect(sync.isTurningOff(.websiteSettings, localProfileID: local))
        #expect(!sync.isEnabled(.websiteSettings, localProfileID: local))
        #expect(sync.record(for: id) == nil)
        try await engine.sendNow()
        #expect(cloud.record(id) == nil)
        #expect(throws: (any Error).self) { try optOut() }
        try files.removeItem(at: file)
        try files.moveItem(at: original, to: file)
        engine.offline = true
        if restart {
            // The last successful state file still has the enrollment when the process exits.
            let recovered = open()
            #expect(!recovered.isEnabled(.websiteSettings, localProfileID: local))
            #expect(!recovered.hasPendingOptOuts)
        } else {
            sync.beat()
            #expect(!sync.hasPendingOptOuts)
        }
        #expect(!open().isEnabled(.websiteSettings, localProfileID: local))
    }

    @Test(arguments: [false, true])
    func aFailedChannelDoesNotStopAnotherProfilesEdits(localReadFails: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings"), local = UUID(), shared = UUID()
        let cloud = FakeSyncCloud()
        let provider = MacSettingPayload(key: "provider", value: Data([1]))
        var failing = false
        var websites: [String: Data] = [:]
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { category, _ in
                if category == .providers {
                    if failing && localReadFails {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    return [provider.key: Data([1])]
                }
                return websites
            }, apply: { _, _, _, _ in })
        }
        let first = open()
        let engine = FakeSyncEngine(cloud: cloud, delegate: first)
        first.attach(engine)
        try await first.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await first.enable(.websiteSettings, localProfileID: local, cloudProfileID: shared)
        try await engine.sendNow()
        let site = MacSettingPayload(key: "popup/site", value: Data([2]))
        let zone = try #require(first.channel(.websiteSettings, localProfileID: local)?.zone)
        let id = SyncRecordID(zone: zone, name: site.recordName)
        let reopened = open()
        let retry = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(retry)
        failing = true
        if !localReadFails {
            retry.unreadable = [provider.recordName]
        }
        websites[site.key] = site.value
        reopened.beat()
        #expect(await waitUntil(timeout: .seconds(3)) { cloud.record(id) != nil })
        #expect(reopened.notice != nil)
        #expect(reopened.channel(.providers, localProfileID: nil) != nil)
        #expect(reopened.ready.contains(zone))
        #expect(!reopened.ready.contains("mac-prefs-providers"))
        failing = false
        retry.unreadable = []
        reopened.beat()
        #expect(await waitUntil(timeout: .seconds(3)) { reopened.ready.contains("mac-prefs-providers") && reopened.notice == nil })
    }

    @Test(arguments: [false, true])
    func onlyTheForgottenProfilesChannelsAreRemoved(atStartup: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings")
        let removed = UUID(), kept = Profile(id: UUID(), name: "Fixture", symbol: "person", color: .gray)
        let cloud = FakeSyncCloud()
        let sync = CloudSettingsSync(stateFile: file, read: { _, _ in ["test": Data([1])] }, apply: { _, _, _, _ in })
        let engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        for category in MacSettingsCategory.allCases {
            try await sync.enable(category, localProfileID: removed, cloudProfileID: removed)
        }
        try await sync.enable(.websiteSettings, localProfileID: kept.id, cloudProfileID: kept.id)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let removedZones = sync.state.channels.values.filter { $0.localProfileID == removed }.map(\.zone)
        let name = MacSettingPayload(key: "test", value: nil).recordName
        if !atStartup {
            try sync.forgetProfile(removed)
            for zone in removedZones {
                #expect(sync.record(for: SyncRecordID(zone: zone, name: name)) == nil)
            }
            try sync.forgetProfile(removed)
        }
        // Construction alone must prune missing profiles, before an engine can be attached.
        let fixture = try MacSettingsFixture(profile: kept, folder: root.appending(path: "stores"))
        defer { fixture.cleanup() }
        let startup = CloudSettingsSync(stateFile: file, profiles: [kept], adapter: fixture.adapter)
        #expect(startup.state.channels.count == 2)
        #expect(!startup.hasPendingOptOuts)
        let reopened = CloudSettingsSync(stateFile: file, read: { _, _ in [:] }, apply: { _, _, _, _ in })
        #expect(reopened.isEnabled(.websiteSettings, localProfileID: kept.id))
        #expect(reopened.isEnabled(.providers, localProfileID: nil))
        for zone in removedZones {
            #expect(reopened.state.channels[zone] == nil)
            #expect(cloud.zones[zone] != nil)
        }
    }

    @Test func aFirstOfflineEnrollmentWaitsForAnExplicitAccountConfirmation() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings"), local = UUID()
        let cloud = FakeSyncCloud()
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in ["value": Data([1])] }, apply: { _, _, _, _ in })
        }
        let first = open()
        let offline = FakeSyncEngine(cloud: cloud, delegate: first)
        first.attach(offline)
        offline.offline = true
        await #expect(throws: (any Error).self) { try await first.enable(.websiteSettings, localProfileID: local, cloudProfileID: local) }

        let reopened = open()
        let engine = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(engine)
        reopened.beat()
        await reopened.handle(.fetched(modified: [], deleted: []))
        #expect(reopened.state.account == nil)
        #expect(reopened.ready.isEmpty)
        #expect(cloud.zones.isEmpty)
        reopened.beat(confirmingEnrollment: true)
        #expect(await waitUntil { cloud.recordCount == 1 })
        #expect(reopened.state.account == cloud.user)
    }

    @Test func offlineEnrollmentUnderAKnownAccountCannotMoveToAnotherAccount() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings"), local = UUID()
        let cloud = FakeSyncCloud()
        let sync = CloudSettingsSync(stateFile: file, read: { _, _ in ["value": Data([1])] }, apply: { _, _, _, _ in })
        let engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        engine.offline = true
        await #expect(throws: (any Error).self) { try await sync.enable(.websiteSettings, localProfileID: local, cloudProfileID: local) }
        #expect(sync.isEnabled(.websiteSettings, localProfileID: local))
        cloud.switchUser("second")
        engine.offline = false
        sync.beat()
        #expect(await waitUntil { sync.state.channels.isEmpty })
        #expect(cloud.zones.isEmpty)
    }

    @Test(arguments: [false, true])
    func aFailedPermissionClearStaysOffAcrossRestart(blockSettingsFile: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = UUID(), oldLink = UUID(), newLink = UUID()
        let file = root.appending(path: "settings"), backup = root.appending(path: "backup")
        let permissions = root.appending(path: "proposals"), files = FileManager.default
        let proposal = MacSettingPayload(key: "camera|https://fixture.test", value: Data([1]))
        let cloud = FakeSyncCloud()
        var refuseClear = false, providerValues: [String: Data] = [:]
        func clear(_ profile: UUID) throws {
            #expect(profile == local)
            if refuseClear {
                throw CocoaError(.fileWriteNoPermission)
            }
            if files.fileExists(atPath: permissions.path) {
                try files.removeItem(at: permissions)
            }
        }
        func open() -> CloudSettingsSync {
            CloudSettingsSync(
                stateFile: file, read: { category, _ in
                    if category == .providers {
                        return providerValues
                    }
                    guard files.fileExists(atPath: permissions.path) else { return [:] }
                    return [proposal.key: try Data(contentsOf: permissions)]
                }, apply: { _, _, _, _ in }, discardWebsiteApprovals: clear)
        }
        let original = open()
        let first = FakeSyncEngine(cloud: cloud, delegate: original)
        original.attach(first)
        try await original.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await original.enable(.websiteSettings, localProfileID: local, cloudProfileID: oldLink)
        try Data([1]).write(to: permissions)
        try original.collectChanges()
        let former = try #require(original.channel(.websiteSettings, localProfileID: local))
        let oldID = SyncRecordID(zone: former.zone, name: proposal.recordName)
        refuseClear = true
        if blockSettingsFile {
            try files.moveItem(at: file, to: backup)
            try files.createDirectory(at: file, withIntermediateDirectories: false)
        }
        #expect(throws: (any Error).self) { try original.disable(.websiteSettings, localProfileID: local) }
        #expect(original.isTurningOff(.websiteSettings, localProfileID: local))
        #expect(original.record(for: oldID) == nil)
        let recovered = open(), second = FakeSyncEngine(cloud: cloud)
        if blockSettingsFile {
            #expect(recovered.isTurningOff(.websiteSettings, localProfileID: local))
            try files.removeItem(at: file)
            try files.moveItem(at: backup, to: file)
        }
        second.delegate = recovered
        recovered.attach(second)
        #expect(recovered.isTurningOff(.websiteSettings, localProfileID: local))
        #expect(!recovered.isEnabled(.websiteSettings, localProfileID: local))
        await #expect(throws: (any Error).self) {
            try await recovered.enable(.websiteSettings, localProfileID: local, cloudProfileID: newLink)
        }
        #expect(throws: (any Error).self) { try recovered.forgetProfile(local) }
        providerValues["model"] = Data([2])
        recovered.beat()
        let provider = SyncRecordID(zone: "mac-prefs-providers", name: MacSettingPayload(key: "model", value: nil).recordName)
        #expect(await waitUntil(timeout: .seconds(3)) { cloud.record(provider) != nil })
        #expect(cloud.record(oldID) == nil)
        #expect(open().isTurningOff(.websiteSettings, localProfileID: local))
        refuseClear = false
        second.offline = true
        recovered.beat()
        #expect(!recovered.hasPendingOptOuts)
        #expect(!files.fileExists(atPath: permissions.path))
        let clean = open()
        let third = FakeSyncEngine(cloud: cloud, delegate: clean)
        clean.attach(third)
        try await clean.enable(.websiteSettings, localProfileID: local, cloudProfileID: newLink)
        let fresh = try #require(clean.channel(.websiteSettings, localProfileID: local))
        #expect(fresh.observed[proposal.key] == nil)
        try await third.sendNow()
        #expect(cloud.names(in: fresh.zone).isEmpty)
    }

    @Test func recoveryReadsTheOptOutJournalBeforeReusingAnOldCheckpoint() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = UUID(), file = root.appending(path: "settings"), saved = root.appending(path: "saved")
        let files = FileManager.default, journal = file.appendingPathExtension("opt-outs")
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in ["key": Data([1])] }, apply: { _, _, _, _ in })
        }
        let first = open(), cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: first)
        first.attach(engine)
        try await first.enable(.websiteSettings, localProfileID: local, cloudProfileID: local)
        try files.moveItem(at: file, to: saved)
        try files.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try first.disable(.websiteSettings, localProfileID: local) }
        let revoked = try Data(contentsOf: journal)
        try Data().write(to: journal)
        let reopened = open()
        // Both files become readable again after the restart.
        try files.removeItem(at: file)
        try files.moveItem(at: saved, to: file)
        try revoked.write(to: journal)
        let retry = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(retry)
        reopened.beat()
        #expect(!reopened.isEnabled(.websiteSettings, localProfileID: local))
        #expect(!open().isEnabled(.websiteSettings, localProfileID: local))
    }

    @Test func anotherWebsiteEnrollmentClearsProposalsLeftByAnEarlierVersion() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = UUID(), firstLink = UUID(), nextLink = UUID()
        let payload = MacSettingPayload(key: "camera|https://old.test", value: Data([1]))
        let file = root.appending(path: "settings")
        var disk: [String: Data] = [:]
        func open(discard: @escaping (UUID) -> Void) -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in disk }, apply: { _, _, _, _ in }, discardWebsiteApprovals: discard)
        }
        let cloud = FakeSyncCloud()
        let old = open { _ in } // An earlier adapter returned success after its permission-file write failed.
        let first = FakeSyncEngine(cloud: cloud, delegate: old)
        old.attach(first)
        try await old.enable(.websiteSettings, localProfileID: local, cloudProfileID: firstLink)
        disk[payload.key] = payload.value
        try old.disable(.websiteSettings, localProfileID: local)
        let reopened = open { _ in disk.removeAll() }
        let second = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(second)
        try await reopened.enable(.websiteSettings, localProfileID: local, cloudProfileID: nextLink)
        let channel = try #require(reopened.channel(.websiteSettings, localProfileID: local))
        #expect(disk.isEmpty)
        #expect(channel.observed.isEmpty)
        try await second.sendNow()
        #expect(cloud.names(in: channel.zone).isEmpty)
    }

    @Test func perZoneSampleLeavesOtherZonesDiskAndQueueAlone() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = UUID(), file = root.appending(path: "settings")
        var values: [String: Data] = [:], reads: [MacSettingsCategory] = []
        let sync = CloudSettingsSync(stateFile: file, read: { category, _ in
            reads.append(category)
            return values
        }, apply: { _, _, _, _ in })
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: sync)
        sync.attach(engine)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await sync.enable(.websiteSettings, localProfileID: local, cloudProfileID: local)
        let website = try #require(sync.channel(.websiteSettings, localProfileID: local))
        let previous = try Data(contentsOf: file)
        values["setting"] = Data([1])
        reads = []
        try sync.collectLocalChanges(in: website.zone)
        #expect(reads == [.websiteSettings])
        #expect(sync.channel(.websiteSettings, localProfileID: local)?.observed == values)
        #expect(sync.channel(.providers, localProfileID: nil)?.observed.isEmpty == true)
        #expect(try Data(contentsOf: file) == previous)
        #expect(engine.pending.isEmpty)
    }
}

extension MacSettingsSyncTests {
    @Test(arguments: [false, true])
    func forgettingWebsiteSettingsDiscardsOutstandingPermissionApprovals(erase: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Profile(id: UUID(), name: "Fixture", symbol: "person", color: .gray)
        let fixture = try MacSettingsFixture(profile: profile, folder: root)
        defer { fixture.cleanup() }
        let sync = CloudSettingsSync(stateFile: root.appending(path: "settings"), profiles: [profile], adapter: fixture.adapter)
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: sync)
        sync.attach(engine)
        try await sync.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: profile.id)
        let origin = "https://camera.test", key = "camera|" + origin
        let sites = fixture.stores.permissions
        sites.set(.deny, for: origin, .camera)
        try fixture.adapter.apply(try JSONEncoder().encode(PermissionPolicy.allow), key: key, for: .websiteSettings, profileID: profile.id)
        let old = try #require(sites.pendingSyncGrants[key])
        if erase {
            try sync.forgetProfile(profile.id)
        } else {
            try sync.disable(.websiteSettings, localProfileID: profile.id)
        }
        #expect(sites.pendingSyncGrants.isEmpty)
        await sites.waitForPendingSave()
        #expect(SitePermissions(storageURL: root.appending(path: "sites")).pendingSyncGrants.isEmpty)
        try await sync.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: UUID())
        fixture.adapter.reviewWebsiteGrant(old, key: key, profileID: profile.id, allow: true)
        #expect(sites.policy(for: origin, .camera) == .deny)
    }

    @Test(arguments: [false, true])
    func permissionFileFailureKeepsWebsiteSharingPausedAfterRelaunch(profileWasErased: Bool) async throws {
        let files = FileManager.default, root = try lifecycleDirectory()
        let stores = root.appending(path: "profile"), settings = root.appending(path: "settings")
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stores.path)
            try? files.removeItem(at: root)
        }
        let profile = Profile(id: UUID(), name: "Fixture", symbol: "person", color: .gray)
        let fixture = try MacSettingsFixture(profile: profile, folder: stores)
        defer { fixture.cleanup() }
        let sync = CloudSettingsSync(stateFile: settings, profiles: [profile], adapter: fixture.adapter)
        let cloud = FakeSyncCloud(), first = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(first)
        try await sync.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: UUID())
        let origin = "https://permission.test", key = "camera|" + origin
        let sites = fixture.stores.permissions, permissionFile = stores.appending(path: "sites")
        let allow = try JSONEncoder().encode(PermissionPolicy.allow)
        sites.set(.deny, for: origin, .camera)
        try fixture.adapter.apply(allow, key: key, for: .websiteSettings, profileID: profile.id)
        await sites.waitForPendingSave()
        let grant = try #require(SitePermissions(storageURL: permissionFile).pendingSyncGrants[key])

        // The channel checkpoint is writable. Only the atomic replacement of the permission file fails.
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stores.path)
        #expect(throws: (any Error).self) { try sync.disable(.websiteSettings, localProfileID: profile.id) }
        #expect(sync.isTurningOff(.websiteSettings, localProfileID: profile.id))
        #expect(sites.pendingSyncGrants.isEmpty)
        #expect(SitePermissions(storageURL: permissionFile).pendingSyncGrants[key] == grant)
        if profileWasErased {
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stores.path)
            try files.removeItem(at: stores)
            let adapter = MacSettingsSyncAdapter(profiles: [], catalog: fixture.catalog, stores: { _ in
                Issue.record("A removed profile has no permission store to open")
                return fixture.stores
            })
            let pruned = CloudSettingsSync(stateFile: settings, profiles: [], adapter: adapter)
            #expect(!pruned.hasPendingOptOuts)
            #expect(!files.fileExists(atPath: stores.path))
            return
        }
        let fresh = try MacSettingsFixture(profile: profile, folder: stores)
        defer { fresh.cleanup() }
        let reopened = CloudSettingsSync(stateFile: settings, profiles: [profile], adapter: fresh.adapter)
        let second = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(second)
        #expect(reopened.isTurningOff(.websiteSettings, localProfileID: profile.id))
        let link = UUID()
        await #expect(throws: (any Error).self) { try await reopened.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: link) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stores.path)
        reopened.beat()
        #expect(!reopened.hasPendingOptOuts)
        let saved = SitePermissions(storageURL: permissionFile)
        #expect(saved.pendingSyncGrants.isEmpty && saved.policy(for: origin, .camera) == .deny)
        try await reopened.enable(.websiteSettings, localProfileID: profile.id, cloudProfileID: link)
        #expect(reopened.channel(.websiteSettings, localProfileID: profile.id)?.observed[key] != allow)
        fresh.adapter.reviewWebsiteGrant(grant, key: key, profileID: profile.id, allow: true)
        #expect(fresh.stores.permissions.policy(for: origin, .camera) == .deny)
    }
}
