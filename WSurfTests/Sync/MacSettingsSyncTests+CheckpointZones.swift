// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
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

    enum MissingFileEvent: CaseIterable {
        case signedOut, purged, deleted
    }

    @Test(arguments: MissingFileEvent.allCases)
    func returningSettingsStillHonorAStopReceivedBeforeTheFileReturns(_ event: MissingFileEvent) async throws {
        let disk = try CheckpointZones(root: lifecycleDirectory())
        defer { disk.remove() }
        let first = try disk.launch()
        try await first.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await first.engine.fetchNow()
        let file = disk.root.appending(path: "settings-store/settings")
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let receiver = try disk.launch()
        switch event {
        case .signedOut:
            try receiver.settings.accountDidResolve(nil)
        case .purged, .deleted:
            disk.cloud.deleteZone(disk.zone, reason: event == .purged ? .purged : .deleted)
            if event == .purged {
                disk.cloud.createZone(disk.zone)
            }
            try await receiver.engine.fetchNow()
            try disk.expectCursorAtDeletion()
        }
        try original.write(to: file, options: .atomic)
        let restarted = try disk.launch()
        restarted.settings.beat()
        #expect(await waitUntil(timeout: .seconds(2)) { !restarted.settings.isEnabled(.providers, localProfileID: nil) })
        #expect(!(try disk.launch()).settings.isEnabled(.providers, localProfileID: nil))
    }

    @Test(arguments: [false, true])
    func aPendingOptOutWaitsForTheOriginalSettingsFile(damagedJournal: Bool) async throws {
        let root = try lifecycleDirectory(), files = FileManager.default
        defer { try? files.removeItem(at: root) }
        let file = root.appending(path: "settings"), held = root.appending(path: "held")
        let journal = file.appendingPathExtension("opt-outs")
        let work = UUID(), other = UUID(), cloud = FakeSyncCloud()
        let choice = MacSettingPayload(key: "selection", value: Data([7]))
        var values: [String: Data] = [:]
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { _, _, _, _ in })
        }
        let previous = open(), engine = FakeSyncEngine(cloud: cloud, delegate: previous)
        previous.attach(engine)
        for profile in [work, other] {
            try await previous.enable(.providers, localProfileID: profile, cloudProfileID: profile)
        }
        engine.offline = true
        values[choice.key] = choice.value
        try previous.collectChanges()
        let revoked = try #require(previous.channel(.providers, localProfileID: work))
        let retained = try #require(previous.channel(.providers, localProfileID: other))
        try #require(revoked.records[choice.key]?.pending == choice && retained.records[choice.key]?.pending == choice)

        try files.moveItem(at: file, to: held)
        try files.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try previous.disable(.providers, localProfileID: work) }
        try files.removeItem(at: file)
        try #require(files.fileExists(atPath: journal.path))
        if damagedJournal {
            try Data([0]).write(to: journal, options: .atomic)
        }
        let waiting = open()
        waiting.beat()
        #expect(!files.fileExists(atPath: file.path))
        #expect(files.fileExists(atPath: journal.path))
        try Data(contentsOf: held).write(to: file, options: .atomic)

        let reopened = open(), after = FakeSyncEngine(cloud: cloud, delegate: reopened)
        reopened.attach(after)
        let oldID = SyncRecordID(zone: revoked.zone, name: choice.recordName)
        let keptID = SyncRecordID(zone: retained.zone, name: choice.recordName)
        after.add([.saveRecord(oldID), .saveRecord(keptID)])
        reopened.beat()
        try await after.sendNow()
        #expect(!reopened.isEnabled(.providers, localProfileID: work))
        if damagedJournal {
            #expect(!reopened.isEnabled(.providers, localProfileID: other))
            #expect(cloud.record(keptID) == nil)
        } else {
            #expect(await waitUntil(timeout: .seconds(3)) {
                guard let record = cloud.record(keptID), let sent = MacSettingRecord.decode(record.payload, recordName: keptID.name) else { return false }
                return sent.setting == choice && sent.enrollment == retained.enrollment
            })
        }
        #expect(cloud.record(oldID) == nil)
    }

    @Test func aFailedCheckpointWriteKeepsTheEarlierZonePurge() async throws {
        let root = try lifecycleDirectory(), files = FileManager.default
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? files.removeItem(at: root)
        }
        let file = root.appending(path: "settings"), held = root.appending(path: "held")
        let cloud = FakeSyncCloud(), choice = MacSettingPayload(key: "model", value: Data([3]))
        var values: [String: Data] = [:]
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in values }, apply: { _, _, _, _ in })
        }
        let original = open(), first = FakeSyncEngine(cloud: cloud, delegate: original)
        original.attach(first)
        try await original.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        first.offline = true
        values[choice.key] = choice.value
        try original.collectChanges()
        let old = try #require(original.channel(.providers, localProfileID: nil))
        try #require(old.records[choice.key]?.pending == choice)
        try files.moveItem(at: file, to: held)
        let waiting = open(), second = FakeSyncEngine(cloud: cloud, delegate: waiting)
        waiting.attach(second)
        cloud.deleteZone(old.zone, reason: .purged)
        cloud.createZone(old.zone)
        try await second.fetchNow()
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let denied = await #expect(throws: CocoaError.self) {
            try await waiting.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        }
        #expect(denied?.code == .fileWriteNoPermission)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(!files.fileExists(atPath: file.path))
        try files.moveItem(at: held, to: file)

        let restarted = open(), after = FakeSyncEngine(cloud: cloud, delegate: restarted)
        restarted.attach(after)
        let id = SyncRecordID(zone: old.zone, name: choice.recordName)
        after.add([.saveRecord(id)])
        restarted.beat()
        try await after.sendNow()
        #expect(!restarted.isEnabled(.providers, localProfileID: nil))
        #expect(cloud.record(id) == nil)
        try await restarted.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await after.sendNow()
        let fresh = try #require(restarted.channel(.providers, localProfileID: nil))
        let record = try #require(cloud.record(id))
        #expect(fresh.enrollment != old.enrollment)
        #expect(MacSettingRecord.decode(record.payload, recordName: id.name)?.enrollment == fresh.enrollment)
    }

    @Test(arguments: [false, true])
    func restoringAnOldCheckpointCannotBorrowAReplacementEnrollment(denyConfirmation: Bool) async throws {
        let disk = try CheckpointZones(root: lifecycleDirectory())
        defer { disk.remove() }
        let first = try disk.launch()
        try await first.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await first.engine.fetchNow()
        let old = try #require(first.settings.channel(.providers, localProfileID: nil))
        try #require(old.records["local"]?.pending?.value == disk.value)
        let original = try Data(contentsOf: disk.file)
        try FileManager.default.removeItem(at: disk.file)
        let joining = try disk.launch()
        disk.cloud.deleteZone(disk.zone, reason: .purged)
        disk.cloud.createZone(disk.zone)
        try await joining.engine.fetchNow()
        try disk.expectCursorAtDeletion()

        disk.value = Data([2])
        if denyConfirmation {
            joining.engine.duringAccountLookup = {
                joining.engine.duringAccountLookup = nil
                let pending = try #require(try CloudSettingsSync.State.read(from: disk.file).channels[disk.zone])
                try #require(pending.enrollment != old.enrollment && pending.needsConfirmation)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: disk.file.deletingLastPathComponent().path)
            }
            let denied = await #expect(throws: CocoaError.self) {
                try await joining.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            }
            try #require(denied?.code == .fileWriteNoPermission)
            try disk.setAccessible(true)
        } else {
            try await joining.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        }
        let fresh = try #require(try CloudSettingsSync.State.read(from: disk.file).channels[disk.zone])
        try #require(fresh.enrollment != old.enrollment && fresh.needsConfirmation == denyConfirmation)
        let replacement = try Data(contentsOf: disk.file)

        disk.value = Data([1])
        try await disk.expectRevoked(afterRestoring: original)
        disk.value = Data([2])
        try replacement.write(to: disk.file, options: .atomic)
        let current = try disk.launch()
        let retained = try #require(current.settings.channel(.providers, localProfileID: nil))
        #expect(retained.enrollment == fresh.enrollment && retained.needsConfirmation == denyConfirmation)
        if denyConfirmation {
            try current.settings.accountDidResolve(disk.cloud.user)
            current.engine.add([.saveRecord(disk.localID)])
            try await current.engine.sendNow()
            #expect(disk.cloud.record(disk.localID) == nil)
            try await current.settings.confirmEnrollment(retained)
        }
        try current.settings.accountDidResolve(disk.cloud.user)
        try #require(await waitUntil(timeout: .seconds(3)) { disk.cloud.record(disk.localID) != nil })
        let saved = try #require(disk.cloud.record(disk.localID))
        let sent = try #require(MacSettingRecord.decode(saved.payload, recordName: saved.id.name))
        #expect(sent.enrollment == fresh.enrollment && sent.value == disk.value)
    }

    @Test(arguments: [false, true])
    func aLegacyZoneResetAllowsOnlyTheNewEnrollmentUntilTheNextPurge(restoreOldBeforePurge: Bool) async throws {
        let disk = try CheckpointZones(root: lifecycleDirectory())
        defer { disk.remove() }
        let original = try disk.launch()
        try await original.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let old = try Data(contentsOf: disk.file)
        let defaults = try #require(UserDefaults(suiteName: disk.root.appending(path: "recovery").path))
        defaults.set([disk.zone], forKey: disk.file.standardizedFileURL.path + ".zone-resets")
        try #require(defaults.synchronize())

        try await disk.expectRevoked(afterRestoring: old)
        let next = try disk.launch()
        try await next.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let fresh = try #require(next.settings.channel(.providers, localProfileID: nil))
        let permitted = try Data(contentsOf: disk.file)
        let reopened = try disk.launch()
        try #require(reopened.settings.channel(.providers, localProfileID: nil)?.enrollment == fresh.enrollment)
        if restoreOldBeforePurge {
            try await disk.expectRevoked(afterRestoring: old)
        }
        let receiver = try disk.launch()
        disk.cloud.deleteZone(disk.zone, reason: .encryptedDataReset)
        disk.cloud.createZone(disk.zone)
        try await receiver.engine.fetchNow()
        try disk.expectCursorAtDeletion()
        try await disk.expectRevoked(afterRestoring: permitted)
    }

    @Test(arguments: [SyncZoneDeletionReason.purged, .encryptedDataReset])
    func aDelayedResetRevokesOnlyTheMissingCheckpoint(reason: SyncZoneDeletionReason) async throws {
        let disk = try CheckpointZones(root: lifecycleDirectory())
        defer { disk.remove() }
        let seed = try disk.launch()
        try await seed.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        try await seed.engine.fetchNow()
        let old = try #require(seed.settings.channel(.providers, localProfileID: nil))
        try #require(old.records["local"]?.pending?.value == disk.value)
        let original = try Data(contentsOf: disk.file)
        try FileManager.default.removeItem(at: disk.file)

        disk.cloud.deleteZone(disk.zone, reason: reason)
        disk.cloud.createZone(disk.zone)
        let receiving = try disk.launch()
        disk.value = Data([2])
        var replacement: UUID?
        receiving.engine.beforeFetchDelivery = {
            receiving.engine.beforeFetchDelivery = nil
            try #require(!FileManager.default.fileExists(atPath: disk.file.path))
            try await receiving.settings.enable(.providers, localProfileID: nil, cloudProfileID: nil)
            let chosen = try #require(try CloudSettingsSync.State.read(from: disk.file).channels[disk.zone])
            try #require(!chosen.needsConfirmation && chosen.enrollment != old.enrollment)
            replacement = chosen.enrollment
        }
        try await receiving.engine.fetchNow()
        try disk.expectCursorAtDeletion()
        let fresh = try #require(replacement)
        try #require(receiving.settings.channel(.providers, localProfileID: nil)?.enrollment == fresh)
        let permitted = try Data(contentsOf: disk.file)
        try #require(try disk.launch().settings.channel(.providers, localProfileID: nil)?.enrollment == fresh)

        disk.value = Data([1])
        try await disk.expectRevoked(afterRestoring: original)
        disk.value = Data([2])
        try permitted.write(to: disk.file, options: .atomic)
        let restarted = try disk.launch()
        try #require(restarted.settings.channel(.providers, localProfileID: nil)?.enrollment == fresh)
        try restarted.settings.accountDidResolve(disk.cloud.user)
        try #require(await waitUntil(timeout: .seconds(3)) { disk.cloud.record(disk.localID) != nil })
        let record = try #require(disk.cloud.record(disk.localID))
        let sent = try #require(MacSettingRecord.decode(record.payload, recordName: disk.localID.name))
        #expect(sent.enrollment == fresh && sent.value == disk.value)
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

    var file: URL {
        directory.appending(path: "settings")
    }

    func expectRevoked(afterRestoring checkpoint: Data) async throws {
        let previousWrites = cloud.writeCount
        try checkpoint.write(to: file, options: .atomic)
        let restored = try launch()
        restored.engine.add([.saveRecord(localID)])
        try restored.settings.accountDidResolve(cloud.user)
        try await restored.engine.sendNow()
        try #require(await waitUntil(timeout: .seconds(3)) {
            !restored.settings.isEnabled(.providers, localProfileID: nil) || cloud.record(localID) != nil
        })
        #expect(!restored.settings.isEnabled(.providers, localProfileID: nil))
        #expect(cloud.record(localID) == nil && cloud.writeCount == previousWrites)
    }

    private var directory: URL {
        root.appending(path: "settings-store")
    }

    private var routerFile: URL {
        root.appending(path: "shared-engine")
    }

    func launch() throws -> (settings: CloudSettingsSync, router: SyncRouter, engine: FakeSyncEngine) {
        let settings = CloudSettingsSync(
            stateFile: file, read: { [self] _, _ in ["local": value] }, apply: { _, _, _, _ in },
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
