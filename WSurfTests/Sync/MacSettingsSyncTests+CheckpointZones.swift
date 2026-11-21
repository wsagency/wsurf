// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension MacSettingsSyncTests {
    enum CheckpointFault: CaseIterable {
        case unreadable, unwritable, recoveredBeforeDelivery
    }

    @Test(arguments: CheckpointFault.allCases, [false, true])
    func ordinaryDeletionDuringACheckpointOutageVerifiesTheZoneAfterRestart(fault: CheckpointFault, recreated: Bool) async throws {
        let disk = try CheckpointZones(root: lifecycleDirectory())
        defer { disk.remove() }
        let first = try disk.launch()
        let remote = MacSettingPayload(key: "remote", value: Data([1]))
        let remoteID = SyncRecordID(zone: disk.zone, name: remote.recordName)
        disk.cloud.createZone(disk.zone)
        _ = disk.cloud.save(SyncRecord(id: remoteID, type: .macSetting, schema: 1, payload: try JSONEncoder().encode(remote)))
        first.engine.unreadable = [remoteID.name]
        await #expect(throws: CloudSettingsSync.Issue.incomplete) { try await first.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
        let original = try #require(first.settings.channel(.providers, localProfileID: nil))
        try #require(!original.needsConfirmation && !original.fetched)
        try await first.engine.fetchNow()
        disk.cloud.deleteZone(disk.zone, reason: .deleted)
        try disk.setAccessible(false)
        let receiving = fault == .unwritable ? first : try disk.launch()
        #expect(receiving.settings.checkpointUnavailable == (fault != .unwritable))
        receiving.engine.available = false
        if fault == .recoveredBeforeDelivery {
            receiving.engine.beforeFetchDelivery = {
                receiving.engine.beforeFetchDelivery = nil
                try disk.setAccessible(true)
                try receiving.settings.collectChanges()
            }
        }
        try await receiving.engine.fetchNow()
        try disk.expectCursorAtDeletion()
        // The next launch must recover the deletion from Settings. The shared cursor is already past it.
        let next = try disk.launch()
        if recreated {
            disk.cloud.createZone(disk.zone)
        }
        try disk.setAccessible(true)
        try next.settings.collectChanges()
        let retry = try disk.launch()
        disk.value = Data([2])
        try retry.settings.collectChanges()
        retry.settings.beat()
        try #require(await waitUntil(timeout: .seconds(3)) { retry.engine.fetchCount > 0 && retry.engine.sendCount > 0 })
        let restored = try disk.launch()
        if recreated {
            #expect(restored.settings.channel(.providers, localProfileID: nil)?.enrollment == original.enrollment)
            #expect(disk.cloud.record(disk.localID) != nil)
        } else {
            #expect(!restored.settings.isEnabled(.providers, localProfileID: nil))
            #expect(disk.cloud.records(in: disk.zone) == nil)
            try await restored.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            try await restored.engine.sendNow()
            #expect(restored.settings.channel(.providers, localProfileID: nil)?.enrollment != original.enrollment)
            #expect(disk.cloud.record(disk.localID) != nil)
        }
    }

    enum OutageDelivery: CaseIterable {
        case beforeRecovery, afterRecovery, afterReenrollment, afterConfirmation
    }

    @Test(arguments: [SyncZoneDeletionReason.purged, .encryptedDataReset], OutageDelivery.allCases)
    func aFetchStartedWithAnUnreadableCheckpointOnlyPurgesItsOriginalConsent(reason: SyncZoneDeletionReason, timing: OutageDelivery) async throws {
        let disk = try CheckpointZones(root: lifecycleDirectory())
        defer { disk.remove() }
        let first = try disk.launch()
        if timing == .afterConfirmation {
            first.engine.offline = true
            await #expect(throws: (any Error).self) { try await first.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil) }
            first.engine.offline = false
        } else {
            try await first.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            try await first.engine.sendNow()
        }
        let original = try #require(first.settings.channel(.providers, localProfileID: nil))
        try await first.engine.fetchNow()
        disk.value = Data([2])
        try first.settings.collectChanges()
        disk.cloud.deleteZone(disk.zone, reason: reason)
        disk.cloud.createZone(disk.zone)
        try disk.setAccessible(false)
        let receiving = try disk.launch()
        try #require(receiving.settings.checkpointUnavailable)
        var fresh: UUID?
        receiving.engine.beforeFetchDelivery = {
            receiving.engine.beforeFetchDelivery = nil
            guard timing != .beforeRecovery else { return }
            try disk.setAccessible(true)
            switch timing {
            case .afterReenrollment:
                try receiving.settings.disable(.providers, localProfileID: nil)
                disk.value = Data([3])
                try await receiving.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            case .afterConfirmation:
                try receiving.settings.collectChanges()
                let pending = try #require(receiving.settings.channel(.providers, localProfileID: nil))
                try #require(pending.needsConfirmation)
                try await receiving.settings.confirmEnrollment(pending)
            case .afterRecovery:
                try receiving.settings.collectChanges()
                return
            case .beforeRecovery:
                return
            }
            fresh = try #require(receiving.settings.channel(.providers, localProfileID: nil)?.enrollment)
        }
        try await receiving.engine.fetchNow()
        try disk.expectCursorAtDeletion()
        try disk.setAccessible(true)
        let next = try disk.launch()
        if let fresh {
            if timing == .afterReenrollment {
                #expect(fresh != original.enrollment)
            }
            try #require(next.settings.channel(.providers, localProfileID: nil)?.enrollment == fresh)
            next.settings.beat()
            try #require(await waitUntil(timeout: .seconds(3)) { disk.cloud.record(disk.localID) != nil })
            let sent = try #require(disk.cloud.record(disk.localID))
            let decoded = try #require(MacSettingRecord.decode(sent.payload, recordName: sent.id.name))
            #expect(decoded.enrollment == fresh && decoded.value == disk.value)
            // A current reset outside the old fetch still revokes the confirmed replacement.
            await next.router.handle(.zonesDeleted([disk.zone: reason]))
            #expect(!next.settings.isEnabled(.providers, localProfileID: nil))
        } else {
            #expect(!next.settings.isEnabled(.providers, localProfileID: nil))
            #expect(disk.cloud.record(disk.localID) == nil)
        }
        #expect(!(try disk.launch()).settings.isEnabled(.providers, localProfileID: nil))
    }
}

@MainActor
private final class CheckpointZones {
    let root: URL
    let cloud = FakeSyncCloud()
    let zone = "mac-prefs-providers"
    var value = Data([1])

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    var localID: SyncRecordID {
        SyncRecordID(zone: zone, name: MacSettingPayload(key: "local", value: nil).recordName)
    }

    private var directory: URL {
        root.appending(path: "settings-store")
    }

    private var routerFile: URL {
        root.appending(path: "shared-engine")
    }

    func launch() throws -> (settings: CloudSettingsSync, router: SyncRouter, engine: FakeSyncEngine) {
        let settings = CloudSettingsSync(
            stateFile: directory.appending(path: "settings"), read: { [self] _, _ in ["local": value] }, apply: { _, _, _, _ in },
            resetDefaults: UserDefaults(suiteName: root.appending(path: "recovery").path)!)
        let state: SyncRouterState
        do {
            state = try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: routerFile))
        } catch CocoaError.fileReadNoSuchFile {
            state = SyncRouterState()
        }
        let router = SyncRouter(state: state, persist: { [routerFile] checkpoint in
            do { try JSONEncoder().encode(checkpoint).write(to: routerFile, options: .atomic) } catch { Issue.record(error) }
        }, tabs: nil, vaults: nil, additional: [settings])
        let engine = FakeSyncEngine(cloud: cloud, delegate: router, state: state.engineState)
        settings.attach(SettingsZoneReadEngine(engine, missing: .zoneNotFound))
        return (settings, router, engine)
    }

    func expectCursorAtDeletion() throws {
        let router = try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: routerFile))
        let bytes = try #require(router.engineState)
        let saved = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try #require(saved["cursor"] as? Int == cloud.clock)
    }

    func setAccessible(_ accessible: Bool) throws {
        let checkpointFile = directory.appending(path: "settings")
        let previous = accessible ? nil : try Data(contentsOf: checkpointFile)
        try FileManager.default.setAttributes([.posixPermissions: accessible ? 0o700 : 0], ofItemAtPath: directory.path)
        if let previous {
            let read = #expect(throws: CocoaError.self) { _ = try Data(contentsOf: checkpointFile) }
            let write = #expect(throws: CocoaError.self) { try previous.write(to: checkpointFile, options: .atomic) }
            #expect(read?.code == .fileReadNoPermission && write?.code == .fileWriteNoPermission)
        }
    }

    func remove() {
        try? setAccessible(true)
        try? FileManager.default.removeItem(at: root)
    }
}
