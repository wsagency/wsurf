// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

@MainActor
struct MacSettingsSyncTests {
    private final class Mac {
        var values: [String: Data]
        let localID = UUID()
        let file: URL
        let engine: FakeSyncEngine
        lazy var sync = CloudSettingsSync(
            stateFile: file, read: { _, _ in self.values },
            apply: { value, key, _, _ in
                self.values[key] = value
            })

        init(_ cloud: FakeSyncCloud, root: URL, values: [String: Data]) {
            self.values = values
            file = root.appendingPathComponent(localID.uuidString)
            engine = FakeSyncEngine(cloud: cloud)
            engine.delegate = sync
            sync.onNeedsEngine = { [weak self] in
                guard let self else { return }
                sync.attach(engine)
            }
        }

        func join(_ sharedID: UUID) async throws {
            try await sync.enable(.websiteSettings, localProfileID: localID, cloudProfileID: sharedID)
        }
    }

    @Test func twoPopulatedMacsKeepDistinctSettingsAndReceiveResets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeSyncCloud()
        let work = UUID()
        let studio = Mac(cloud, root: directory, values: ["engine/site-a": Data([1])])
        let air = Mac(cloud, root: directory, values: ["popup/site-b": Data([2])])
        #expect(!studio.sync.needsEngine && !air.sync.needsEngine)
        try await studio.join(work)
        try await studio.engine.sendNow()
        try await air.join(work)
        try await air.engine.sendNow()
        try await studio.engine.fetchNow()
        #expect(air.values == studio.values && air.values.count == 2)
        studio.values["engine/site-a"] = nil
        try studio.sync.collectChanges()
        try await studio.engine.sendNow()
        try await air.engine.fetchNow()
        #expect(air.values == ["popup/site-b": Data([2])])
        #expect(cloud.zones.values.flatMap(\.keys).allSatisfy { !$0.contains("site-") })
    }

    @Test func differentChoicesAtFirstJoinCanBeResolvedAndAnOfflineResetIsRetained() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeSyncCloud()
        let shared = UUID()
        let key = "engine/site"
        let studio = Mac(cloud, root: directory, values: [key: Data([1])])
        let air = Mac(cloud, root: directory, values: [key: Data([2])])
        try await studio.join(shared)
        try await studio.engine.sendNow()
        try await air.join(shared)
        let channel = try #require(air.sync.channel(.websiteSettings, localProfileID: air.localID))
        #expect(channel.records[key]?.conflict == true)
        #expect(air.values[key] == Data([2]))
        try air.sync.resolve(key, in: channel.zone, useCloud: true)
        #expect(air.values[key] == Data([1]))
        air.engine.offline = true
        air.values[key] = nil
        try air.sync.collectChanges()
        let reopened = CloudSettingsSync(
            stateFile: air.file, read: { _, _ in air.values },
            apply: { value, name, _, _ in air.values[name] = value })
        let afterRestart = FakeSyncEngine(cloud: cloud, delegate: reopened)
        let id = SyncRecordID(zone: channel.zone, name: MacSettingPayload(key: key, value: nil).recordName)
        #expect(reopened.record(for: id) == nil)
        reopened.onNeedsEngine = { reopened.attach(afterRestart) }
        try await reopened.enable(.websiteSettings, localProfileID: air.localID, cloudProfileID: shared)
        try await afterRestart.sendNow()
        try await studio.engine.fetchNow()
        #expect(studio.values.isEmpty)
    }

    @Test(arguments: [false, true])
    func latestChoiceSurvivesAnInFlightSave(fetchedBeforeReply: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeSyncCloud()
        let work = UUID()
        let key = "engine/site"
        let original = Data([1])
        let studio = Mac(cloud, root: directory, values: [key: original])
        let air = Mac(cloud, root: directory, values: [:])
        try await studio.join(work)
        try await studio.engine.sendNow()
        try await air.join(work)
        let channel = try #require(studio.sync.channel(.websiteSettings, localProfileID: studio.localID))
        let id = SyncRecordID(zone: channel.zone, name: MacSettingPayload(key: key, value: original).recordName)

        studio.values[key] = Data([2])
        try studio.sync.collectChanges()
        let sending = try #require(studio.engine.handOut(id))
        studio.values[key] = original
        try studio.sync.collectChanges()
        guard case .saved(let earlier) = cloud.save(sending) else {
            Issue.record("Expected the earlier edit to reach iCloud")
            return
        }
        if fetchedBeforeReply {
            try await studio.engine.fetchNow()
        }
        await studio.sync.handle(.sent(saved: [earlier], deleted: [], failed: []))
        try await studio.engine.sendNow()
        try await air.engine.fetchNow()
        #expect(air.values[key] == original)
        #expect(studio.values[key] == original)
    }

    @Test func accountSwitchRequiresNewConsentForQueuedEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeSyncCloud()
        let mac = Mac(cloud, root: directory, values: ["engine/site-a": Data([1])])
        try await mac.join(UUID())
        let queued = try #require(
            mac.engine.pending.compactMap { change -> SyncRecordID? in
                if case .saveRecord(let id) = change {
                    return id
                }
                return nil
            }.first)
        cloud.switchUser("second")
        await mac.engine.simulateAccount(.switchAccounts(user: "second"))
        #expect(mac.sync.record(for: queued) == nil)
        #expect(!mac.sync.isEnabled(.websiteSettings, localProfileID: mac.localID))
        #expect(mac.values == ["engine/site-a": Data([1])])
    }
}
