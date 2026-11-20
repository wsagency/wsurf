// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension MacSettingsSyncTests {
    enum ResetTiming: CaseIterable {
        case otherMacRecreated, reenabledBeforeFetch, reenabledDuringFetch
    }

    @Test(arguments: [SyncZoneDeletionReason.purged, .encryptedDataReset], ResetTiming.allCases)
    func anExplicitResetRevokesOnlyTheEnrollmentPresentAtFetchStart(reason: SyncZoneDeletionReason, timing: ResetTiming) async throws {
        let root = try lifecycleDirectory(), file = root.appending(path: "settings")
        defer { try? FileManager.default.removeItem(at: root) }
        var values = ["choice": Data([1])]
        @MainActor func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { _, _, _, _ in })
        }
        let sync = open(), cloud = FakeSyncCloud()
        let router = SyncRouter(state: SyncRouterState(), persist: { _ in }, tabs: nil, vaults: nil, additional: [sync])
        let engine = FakeSyncEngine(cloud: cloud, delegate: router)
        sync.attach(engine)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let old = try #require(sync.channel(.providers, localProfileID: nil))
        try await engine.sendNow()
        try await engine.fetchNow()
        let id = SyncRecordID(zone: old.zone, name: MacSettingPayload(key: "choice", value: nil).recordName)
        values["choice"] = Data([2])
        try sync.collectChanges()
        let attempted = try #require(engine.handOut(id))
        cloud.deleteZone(old.zone, reason: reason)
        @MainActor func reenable() async throws {
            try sync.disable(.providers, localProfileID: nil)
            values["choice"] = Data([3])
            try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        }
        switch timing {
        case .otherMacRecreated:
            cloud.createZone(old.zone)
        case .reenabledBeforeFetch:
            try await reenable()
        case .reenabledDuringFetch:
            engine.beforeFetchDelivery = {
                engine.beforeFetchDelivery = nil
                try await reenable()
            }
        }
        let atStart = try #require(sync.channel(.providers, localProfileID: nil))
        try await engine.fetchNow()
        await router.handle(.sent(saved: [attempted], deleted: [], failed: []))
        if timing == .reenabledDuringFetch {
            let current = try #require(sync.channel(.providers, localProfileID: nil))
            #expect(current.enrollment != old.enrollment)
            try #require(await waitUntil { sync.ready.contains(current.zone) })
            #expect(open().channel(.providers, localProfileID: nil)?.enrollment == current.enrollment)
        } else {
            #expect(!sync.isEnabled(.providers, localProfileID: nil))
            #expect(!open().isEnabled(.providers, localProfileID: nil))
            sync.beat()
            try await engine.sendNow()
            #expect(cloud.record(id) == nil && sync.record(for: id) == nil)
            values["choice"] = Data([3])
            try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            #expect(sync.channel(.providers, localProfileID: nil)?.enrollment != atStart.enrollment)
        }
        try await engine.sendNow()
        let sent = try #require(cloud.record(id))
        let payload = try #require(MacSettingRecord.decode(sent.payload, recordName: id.name))
        #expect(payload.value == Data([3]))
        #expect(payload.enrollment == sync.channel(.providers, localProfileID: nil)?.enrollment)
    }

    @Test func aPurgedZoneCannotBeRecreatedByItsInterruptedFirstSend() async throws {
        let root = try lifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = CloudSettingsSync(stateFile: root.appending(path: "settings"), read: { _, _ in ["local": Data([5])] }, apply: { _, _, _, _ in })
        let router = SyncRouter(state: SyncRouterState(), persist: { _ in }, tabs: nil, vaults: nil, additional: [sync])
        let cloud = FakeSyncCloud(), engine = FakeSyncEngine(cloud: cloud, delegate: router)
        sync.attach(engine)
        engine.hangsOnSend = true
        let zone = "mac-prefs-providers"
        let joining = Task { try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        try #require(await waitUntil { engine.pending.contains(.saveZone(zone)) })
        cloud.createZone(zone)
        cloud.deleteZone(zone, reason: .purged)
        try await engine.fetchNow()
        await #expect(throws: (any Error).self) { try await joining.value }
        engine.hangsOnSend = false
        try await engine.sendNow()
        #expect(cloud.records(in: zone) == nil)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await engine.sendNow()
        #expect(cloud.recordCount == 1)
    }

    @Test func confirmingAPendingOptInDuringTheFetchPreservesFreshConsent() async throws {
        let root = try lifecycleDirectory(), file = root.appending(path: "settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = CloudSettingsSync(stateFile: file, read: { _, _ in ["choice": Data([4])] }, apply: { _, _, _, _ in })
        let cloud = FakeSyncCloud(), engine = FakeSyncEngine(cloud: cloud, delegate: sync)
        sync.attach(engine)
        engine.offline = true
        await #expect(throws: (any Error).self) { try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        let pending = try #require(sync.channel(.providers, localProfileID: nil))
        #expect(pending.needsConfirmation)
        engine.offline = false
        cloud.deleteZone(pending.zone, reason: .purged)
        engine.beforeFetchDelivery = {
            engine.beforeFetchDelivery = nil
            try await sync.confirmEnrollment(pending)
        }
        try await engine.fetchNow()
        try await engine.sendNow()
        #expect(sync.channel(.providers, localProfileID: nil)?.needsConfirmation == false)
        #expect(cloud.recordCount == 1)
    }

    @Test(arguments: [false, true])
    func aResetSurvivesAnInaccessibleCheckpointAndRestart(coldStart: Bool) async throws {
        let root = try lifecycleDirectory(), directory = root.appending(path: "sync"), files = FileManager.default
        let file = directory.appending(path: "settings")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? files.removeItem(at: root)
        }
        var choice = Data([1])
        @MainActor func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in ["choice": choice] }, apply: { _, _, _, _ in },
                              resetDefaults: UserDefaults(suiteName: root.appending(path: "recovery").path)!)
        }
        let first = open(), cloud = FakeSyncCloud(), other = UUID()
        let engine = FakeSyncEngine(cloud: cloud, delegate: first)
        first.attach(engine)
        try await first.enable(.websiteSettings, localProfileID: other, cloudProfileID: other)
        try await first.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await engine.sendNow()
        let original = try #require(first.channel(.providers, localProfileID: nil))
        let peer = try #require(first.channel(.websiteSettings, localProfileID: other))
        choice = Data([2])
        try first.collectChanges()
        cloud.deleteZone(original.zone, reason: .encryptedDataReset)
        cloud.createZone(original.zone)
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        if coldStart {
            let interrupted = open(), fetch = FakeSyncEngine(cloud: cloud)
            fetch.delegate = interrupted
            interrupted.attach(fetch)
            #expect(interrupted.checkpointUnavailable)
            try await fetch.fetchNow()
        } else {
            try await engine.fetchNow()
        }
        // The shared engine consumed the reset. On relaunch it need not deliver it again.
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restored = open(), next = FakeSyncEngine(cloud: cloud)
        next.delegate = restored
        restored.attach(next)
        #expect(!restored.isEnabled(.providers, localProfileID: nil))
        #expect(restored.channel(.websiteSettings, localProfileID: other)?.enrollment == peer.enrollment)
        try await restored.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let fresh = try #require(restored.channel(.providers, localProfileID: nil))
        #expect(fresh.enrollment != original.enrollment)
        #expect(open().channel(.providers, localProfileID: nil)?.enrollment == fresh.enrollment)
    }

    @Test(arguments: [false, true])
    func aUserDeletedZoneReadDropsOldEditsAndAllowsAFreshOptIn(incompleteAtRestart: Bool) async throws {
        let root = try lifecycleDirectory(), file = root.appending(path: "settings")
        defer { try? FileManager.default.removeItem(at: root) }
        var values = ["choice": Data([1])]
        @MainActor func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { _, _, _, _ in })
        }
        let sync = open(), cloud = FakeSyncCloud(), zone = "mac-prefs-providers"
        let backing = FakeSyncEngine(cloud: cloud, delegate: sync)
        let engine = UserDeletedZoneEngine(backing)
        cloud.createZone(zone)
        sync.attach(engine)
        let server = MacSettingPayload(key: "server", value: Data([8]))
        let id = SyncRecordID(zone: zone, name: server.recordName)
        _ = cloud.save(SyncRecord(id: id, type: .macSetting, schema: 1, payload: try JSONEncoder().encode(server)))
        if incompleteAtRestart {
            backing.unreadable = [id.name]
            await #expect(throws: CloudSettingsSync.Issue.incomplete) { try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        } else {
            try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            try await engine.sendNow()
        }
        let old = try #require(sync.channel(.providers, localProfileID: nil))
        values["choice"] = Data([2])
        try sync.collectChanges()
        let current: CloudSettingsSync
        let resumed: UserDeletedZoneEngine
        if incompleteAtRestart {
            // The full read is the first evidence of the purge after relaunch.
            cloud.removeZoneSilently(zone)
            current = open()
            resumed = UserDeletedZoneEngine(FakeSyncEngine(cloud: cloud, delegate: current))
            current.attach(resumed)
            current.beat()
        } else {
            current = sync
            resumed = engine
            cloud.deleteZone(zone, reason: .deleted)
            try await resumed.fetchNow()
        }
        try #require(await waitUntil(timeout: .seconds(3)) { !current.isEnabled(.providers, localProfileID: nil) })
        #expect(!open().isEnabled(.providers, localProfileID: nil))
        #expect(cloud.records(in: zone) == nil)
        try await current.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await resumed.sendNow()
        #expect(current.channel(.providers, localProfileID: nil)?.enrollment != old.enrollment)
        #expect(cloud.recordCount == 1)
    }
}

/// The real CloudKit read reports userDeletedZone when the owner removed a zone from Settings.
@MainActor
private final class UserDeletedZoneEngine: SyncEngine, SyncAccountIdentity {
    let backing: FakeSyncEngine

    init(_ backing: FakeSyncEngine) {
        self.backing = backing
    }

    func fetchAll(zone: String) async throws -> SyncZoneRead {
        do {
            return try await backing.fetchAll(zone: zone)
        } catch let error as URLError where error.code == .fileDoesNotExist {
            throw CKError(.userDeletedZone)
        }
    }

    func add(_ changes: [SyncChange]) {
        backing.add(changes)
    }

    func fetchNow() async throws {
        try await backing.fetchNow()
    }

    func sendNow() async throws {
        try await backing.sendNow()
    }

    func currentAccountUser() async throws -> String {
        try await backing.currentAccountUser()
    }

    func accountIsAvailable() async -> Bool {
        await backing.accountIsAvailable()
    }
}
