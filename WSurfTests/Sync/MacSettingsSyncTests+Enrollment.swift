// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension MacSettingsSyncTests {
    @Test(arguments: [false, true])
    func enablingWebsitesDoesNotConfirmWaitingProviderEnrollments(legacyCheckpoint: Bool) async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings"), profile = UUID(), cloud = FakeSyncCloud()
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in ["choice": Data([1])] }, apply: { _, _, _, _ in })
        }
        let first = open(), offline = FakeSyncEngine(cloud: cloud)
        first.attach(offline)
        offline.offline = true
        for id in [nil, profile] {
            await #expect(throws: (any Error).self) { try await first.enable(.providers, localProfileID: id, cloudProfileID: id) }
        }

        func writeLegacyCheckpoint() throws {
            var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var channels = try #require(saved["channels"] as? [String: [String: Any]])
            for zone in channels.keys {
                channels[zone]?["awaitingAccountConfirmation"] = nil
            }
            saved["channels"] = channels
            try JSONSerialization.data(withJSONObject: saved).write(to: file)
        }
        if legacyCheckpoint {
            try writeLegacyCheckpoint()
        }
        let online = open(), engine = FakeSyncEngine(cloud: cloud, delegate: online)
        online.attach(engine)
        try await online.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile)
        try await engine.sendNow()
        let web = try #require(online.channel(.websiteSettings, localProfileID: profile))
        let global = try #require(online.channel(.providers, localProfileID: nil))
        let models = try #require(online.channel(.providers, localProfileID: profile))
        let name = MacSettingPayload(key: "choice", value: nil).recordName
        #expect(cloud.record(SyncRecordID(zone: web.zone, name: name)) != nil)

        // Older checkpoints could already have an account and a healthy website baseline while both provider opt-ins were still unbound.
        if legacyCheckpoint {
            try writeLegacyCheckpoint()
        }
        let restarted = open(), retry = FakeSyncEngine(cloud: cloud)
        retry.delegate = restarted
        restarted.attach(retry)
        try restarted.accountDidResolve(cloud.user)
        restarted.beat()
        try #require(await waitUntil { restarted.ready.contains(web.zone) && retry.fetchCount > 0 })
        #expect(cloud.records(in: global.zone) == nil && cloud.records(in: models.zone) == nil)
        #expect(restarted.record(for: SyncRecordID(zone: global.zone, name: name)) == nil)
        #expect(restarted.channel(.providers, localProfileID: nil)?.needsConfirmation == true)
        try await restarted.confirmEnrollment(global)
        try await retry.sendNow()
        #expect(cloud.record(SyncRecordID(zone: global.zone, name: name)) != nil)
        #expect(cloud.records(in: models.zone) == nil)
        #expect(restarted.channel(.providers, localProfileID: profile)?.needsConfirmation == true)
        try await restarted.confirmEnrollment(models)
        try await retry.sendNow()
        #expect(cloud.record(SyncRecordID(zone: models.zone, name: name)) != nil)
    }

    @Test(arguments: [false, true])
    func unreadableCheckpointWithoutAJournalPreservesPendingEdits(anotherProfileIsErased: Bool) async throws {
        let files = FileManager.default, root = try lifecycleDirectory()
        let file = root.appending(path: "settings"), profile = UUID()
        defer {
            try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? files.removeItem(at: root)
        }
        let cloud = FakeSyncCloud(), site = MacSettingPayload(key: "engine/site", value: Data([1]))
        let clock = TestClock()
        var values = [site.key: Data([1])]
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { value, key, _, _ in values[key] = value }, clock: clock)
        }
        let first = open(), engine = FakeSyncEngine(cloud: cloud)
        engine.delegate = first
        first.attach(engine)
        try await first.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile)
        try await engine.sendNow()
        let enrolled = try #require(first.channel(.websiteSettings, localProfileID: profile))
        let id = SyncRecordID(zone: enrolled.zone, name: site.recordName)
        values.removeAll()
        try first.collectChanges()
        let checkpoint = try Data(contentsOf: file)
        #expect(!files.fileExists(atPath: file.appendingPathExtension("opt-outs").path))
        // The file cannot be read, but its parent permits an atomic replacement.
        try files.setAttributes([.posixPermissions: 0o200], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try Data(contentsOf: file) }
        let restored = open(), recovery = FakeSyncEngine(cloud: cloud)
        recovery.delegate = restored
        restored.onNeedsEngine = {
            restored.attach(recovery)
            // CloudSync starts its shared heartbeat whenever restored enrollments first need an engine.
            restored.beat()
        }
        restored.beat()
        #expect(restored.checkpointUnavailable && !restored.needsEngine)
        try #require(await waitUntil { clock.pendingCount == 1 })
        #expect(throws: (any Error).self) { try restored.collectChanges() }
        await #expect(throws: (any Error).self) { try await restored.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        #expect(restored.record(for: id) == nil && recovery.pending.isEmpty)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == checkpoint)
        if anotherProfileIsErased {
            // Profile erasure can be the first reader after access returns, before the local retry fires.
            try restored.forgetProfile(UUID())
        }
        clock.advance(by: .seconds(30))
        try #require(await waitUntil(timeout: .seconds(3)) {
            guard let record = cloud.record(id) else { return false }
            return try JSONDecoder().decode(MacSettingPayload.self, from: record.payload).value == nil
        })
        #expect(restored.channel(.websiteSettings, localProfileID: profile)?.enrollment == enrolled.enrollment)
        #expect(!restored.isEnabled(.providers, localProfileID: nil))
        #expect(!restored.checkpointUnavailable && clock.pendingCount == 0)
    }

    @Test func confirmationSuspendedDuringReenrollmentCannotApproveTheReplacement() async throws {
        let root = try lifecycleDirectory(), file = root.appending(path: "settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = CloudSettingsSync(stateFile: file, read: { _, _ in ["choice": Data([1])] }, apply: { _, _, _, _ in })
        let cloud = FakeSyncCloud(), engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        engine.offline = true
        await #expect(throws: (any Error).self) { try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        let old = try #require(sync.channel(.providers, localProfileID: nil))
        engine.offline = false
        var release: CheckedContinuation<Void, Never>?
        var replacement: Task<Void, Error>?
        engine.duringAccountLookup = {
            try sync.disable(.providers, localProfileID: nil)
            engine.duringAccountLookup = {
                engine.duringAccountLookup = nil
                await withCheckedContinuation { release = $0 }
            }
            replacement = Task { try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
            try #require(await waitUntil { release != nil })
        }
        defer { release?.resume() }
        await #expect(throws: CancellationError.self) { try await sync.confirmEnrollment(old) }
        await #expect(throws: CancellationError.self) { try await sync.confirmEnrollment(old) }
        let fresh = try #require(sync.channel(.providers, localProfileID: nil))
        #expect(fresh.enrollment != old.enrollment && fresh.needsConfirmation)
        #expect(sync.state.account == nil && cloud.zones.isEmpty)
        release?.resume()
        release = nil
        try await replacement?.value
        try await engine.sendNow()
        #expect(cloud.recordCount == 1)
    }

    @Test func aZoneDeletedDuringVerificationOnlyRemovesItsOriginalEnrollment() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = CloudSettingsSync(stateFile: root.appending(path: "settings"), read: { _, _ in ["value": Data([1])] }, apply: { _, _, _, _ in })
        let cloud = FakeSyncCloud(), engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        let profile = UUID()
        try await sync.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let old = try #require(sync.channel(.websiteSettings, localProfileID: profile))
        let provider = try #require(sync.channel(.providers, localProfileID: nil))
        var replacement: UUID?
        engine.duringAccountLookup = {
            engine.duringAccountLookup = nil
            try sync.disable(.websiteSettings, localProfileID: profile)
            try await sync.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile)
            replacement = sync.channel(.websiteSettings, localProfileID: profile)?.enrollment
        }
        await sync.handle(.zonesDeleted([old.zone: .deleted, provider.zone: .purged]))
        let current = try #require(replacement)
        #expect(current != old.enrollment)
        #expect(sync.channel(.websiteSettings, localProfileID: profile)?.enrollment == current)
        #expect(!sync.isEnabled(.providers, localProfileID: nil))
        try await engine.sendNow()
        let name = MacSettingPayload(key: "value", value: nil).recordName
        #expect(cloud.record(SyncRecordID(zone: old.zone, name: name)) != nil)
    }
}
