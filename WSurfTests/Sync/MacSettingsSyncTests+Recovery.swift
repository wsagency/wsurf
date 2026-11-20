// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension MacSettingsSyncTests {
    @Test func lateZoneDeletionRechecksTheReplacementAndHonorsARealRemoval() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var values = ["choice": Data([1])]
        let sync = CloudSettingsSync(stateFile: root.appending(path: "settings"), read: { _, _ in values }, apply: { _, _, _, _ in })
        let cloud = FakeSyncCloud(), engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let old = try #require(sync.channel(.providers, localProfileID: nil))
        try await engine.sendNow()
        try await engine.fetchNow()
        cloud.deleteZone(old.zone, reason: .purged)
        try sync.disable(.providers, localProfileID: nil)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let fresh = try #require(sync.channel(.providers, localProfileID: nil))
        try #require(fresh.enrollment != old.enrollment)
        let id = SyncRecordID(zone: fresh.zone, name: MacSettingPayload(key: "choice", value: nil).recordName)
        // The fetch cursor still includes the old deletion even though the replacement already exists.
        try await engine.fetchNow()
        try #require(await waitUntil(timeout: .seconds(3)) { sync.ready.contains(fresh.zone) })
        #expect(sync.channel(.providers, localProfileID: nil)?.enrollment == fresh.enrollment)
        values["choice"] = Data([2])
        try sync.collectChanges()
        try await engine.sendNow()
        let stored = try #require(cloud.record(id))
        #expect(try JSONDecoder().decode(MacSettingPayload.self, from: stored.payload).value == Data([2]))

        cloud.deleteZone(fresh.zone, reason: .deleted)
        try await engine.fetchNow()
        try #require(await waitUntil { !sync.isEnabled(.providers, localProfileID: nil) })
        #expect(sync.record(for: id) == nil && cloud.records(in: fresh.zone) == nil)
    }

    @Test(arguments: [false, true])
    func deletionDuringAnIncompleteFirstBaselineIsRecheckedAfterRestart(recreated: Bool) async throws {
        let root = try lifecycleDirectory(), file = root.appending(path: "settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud(), key = MacSettingPayload(key: "server", value: Data([1]))
        let zone = "mac-prefs-providers", id = SyncRecordID(zone: zone, name: key.recordName)
        cloud.createZone(zone)
        _ = cloud.save(SyncRecord(id: id, type: .macSetting, schema: 1, payload: try JSONEncoder().encode(key)))
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in ["local": Data([2])] }, apply: { _, _, _, _ in })
        }
        let first = open(), engine = FakeSyncEngine(cloud: cloud)
        engine.delegate = first
        first.attach(engine)
        engine.unreadable = [id.name]
        await #expect(throws: (any Error).self) { try await first.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        let original = try #require(first.channel(.providers, localProfileID: nil))
        #expect(!original.fetched)
        cloud.deleteZone(zone, reason: .encryptedDataReset)
        engine.available = false
        try await engine.fetchNow()
        let local = SyncRecordID(zone: zone, name: MacSettingPayload(key: "local", value: nil).recordName)
        #expect(first.record(for: local) == nil)

        if recreated {
            cloud.createZone(zone)
        }
        let restored = open(), after = FakeSyncEngine(cloud: cloud)
        after.delegate = restored
        restored.attach(after)
        restored.beat()
        if recreated {
            // The new engine replays the old cursor and queues the edit after its verified reread.
            try #require(await waitUntil(timeout: .seconds(3)) { after.fetchAllCount >= 2 && restored.ready.contains(zone) })
            try await after.sendNow()
            #expect(cloud.record(local) != nil)
            #expect(restored.channel(.providers, localProfileID: nil)?.enrollment == original.enrollment)
        } else {
            try #require(await waitUntil(timeout: .seconds(3)) { !restored.isEnabled(.providers, localProfileID: nil) })
            #expect(cloud.records(in: zone) == nil)
        }
    }

    enum AccountOutage: CaseIterable {
        case verificationFailed, signedInBeforeRecovery, signedInAfterRecovery
    }

    @Test(arguments: AccountOutage.allCases, [false, true])
    func aVerifiedSignOutWhileTheCheckpointIsUnreadableRevokesPendingSends(observation: AccountOutage, restart: Bool) async throws {
        let root = try lifecycleDirectory(), directory = root.appending(path: "sync")
        let file = directory.appending(path: "settings"), files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? files.removeItem(at: root)
        }
        let cloud = FakeSyncCloud()
        var values = ["choice": Data([1])]
        func open() -> CloudSettingsSync {
            let defaults = UserDefaults(suiteName: root.appending(path: "revocation").path)!
            return CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { _, _, _, _ in }, resetDefaults: defaults)
        }
        let first = open(), engine = FakeSyncEngine(cloud: cloud)
        engine.delegate = first
        first.attach(engine)
        try await first.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await engine.sendNow()
        let previous = try #require(first.channel(.providers, localProfileID: nil))
        values["choice"] = Data([2])
        try first.collectChanges()
        let id = SyncRecordID(zone: previous.zone, name: MacSettingPayload(key: "choice", value: nil).recordName)
        _ = try #require(engine.handOut(id))
        let oldWrites = cloud.writeCount

        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        var interrupted: CloudSettingsSync? = open()
        let pending = FakeSyncEngine(cloud: cloud, delegate: interrupted)
        interrupted?.attach(pending)
        // The monitor starts by suspending trust. A failed lookup never reports a resolved sign-out.
        interrupted?.suspendAccount()
        if observation != .verificationFailed {
            #expect(throws: (any Error).self) { try interrupted?.accountDidResolve(nil) }
        }
        if observation == .signedInBeforeRecovery {
            #expect(throws: (any Error).self) { try interrupted?.accountDidResolve(cloud.user) }
        }
        #expect(interrupted?.record(for: id) == nil && pending.pending.isEmpty)
        if restart {
            interrupted = nil
            interrupted = open()
        }
        let recovered = try #require(interrupted)
        let resumed = FakeSyncEngine(cloud: cloud, delegate: recovered)
        recovered.attach(resumed)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if observation == .signedInAfterRecovery {
            resumed.available = false
            try recovered.accountDidResolve(nil)
            resumed.available = true
        }
        if observation != .signedInBeforeRecovery {
            try recovered.accountDidResolve(cloud.user)
        }
        recovered.beat()
        if observation != .verificationFailed {
            #expect(!recovered.isEnabled(.providers, localProfileID: nil))
            try await resumed.sendNow()
            #expect(cloud.writeCount == oldWrites)
            #expect(!open().isEnabled(.providers, localProfileID: nil))
            try await recovered.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            let fresh = try #require(recovered.channel(.providers, localProfileID: nil))
            #expect(fresh.enrollment != previous.enrollment)
            #expect(open().channel(.providers, localProfileID: nil)?.enrollment == fresh.enrollment)
        } else {
            try #require(await waitUntil { cloud.writeCount > oldWrites })
            #expect(recovered.channel(.providers, localProfileID: nil)?.enrollment == previous.enrollment)
        }
    }

    @Test(arguments: [false, true])
    func aRecoveredDirectoryWithoutACheckpointAllowsFreshConsent(retryBeforeChoosing: Bool) async throws {
        let files = FileManager.default, root = try lifecycleDirectory()
        let directory = root.appending(path: "sync"), file = directory.appending(path: "settings")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? files.removeItem(at: root)
        }
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        let clock = TestClock()
        let sync = CloudSettingsSync(stateFile: file, read: { _, _ in ["choice": Data([1])] }, apply: { _, _, _, _ in }, clock: clock)
        let cloud = FakeSyncCloud(), engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.onNeedsEngine = { sync.attach(engine) }
        try #require(sync.checkpointUnavailable)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if retryBeforeChoosing {
            try #require(await waitUntil { clock.pendingCount == 1 })
            clock.advance(by: .seconds(30))
            try #require(await waitUntil(timeout: .seconds(3)) { !sync.checkpointUnavailable })
            #expect(sync.notice == nil && !sync.needsEngine && cloud.zones.isEmpty)
        }
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await engine.sendNow()
        #expect(!sync.checkpointUnavailable && cloud.recordCount == 1)
    }
}
