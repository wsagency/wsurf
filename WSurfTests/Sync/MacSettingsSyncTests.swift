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

    @Test(arguments: [false, true])
    func accountSwitchDuringFirstReadRequiresFreshConsent(zoneExists: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let work = UUID()
        if zoneExists {
            let studio = Mac(cloud, root: root, values: ["popup/studio": Data([1])])
            try await studio.join(work)
            try await studio.engine.sendNow()
        }
        let air = Mac(cloud, root: root, values: ["engine/air": Data([2])])
        air.engine.afterFullZoneRead = {
            air.engine.afterFullZoneRead = nil
            cloud.switchUser("second")
        }
        do {
            try await air.join(work)
            Issue.record("The account changed while this Mac was joining")
        } catch CloudSettingsSync.Issue.changedAccount {}
        #expect(!air.sync.isEnabled(.websiteSettings, localProfileID: air.localID))
        #expect(air.values == ["engine/air": Data([2])])
        try await air.engine.sendNow()
        #expect(cloud.zones.isEmpty)
    }

    @Test func failedAccountVerificationSuspendsAnOutstandingSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let work = UUID()
        let key = "engine/site"
        let mac = Mac(cloud, root: root, values: [key: Data([1])])
        try await mac.join(work)
        let channel = try #require(mac.sync.channel(.websiteSettings, localProfileID: mac.localID))
        let id = SyncRecordID(zone: channel.zone, name: MacSettingPayload(key: key, value: nil).recordName)
        mac.engine.available = false
        await #expect(throws: (any Error).self) { try await mac.join(work) }
        #expect(mac.sync.record(for: id) == nil)
        #expect(mac.sync.isEnabled(.websiteSettings, localProfileID: mac.localID))
        mac.engine.available = true
        try await mac.join(work)
        #expect(mac.sync.record(for: id) != nil)
    }

    @Test func incomingChangeFromAnotherAccountWaitsForConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let work = UUID()
        let mac = Mac(cloud, root: root, values: [:])
        try await mac.join(work)
        cloud.switchUser("second")
        let other = Mac(cloud, root: root, values: ["engine/other": Data([2])])
        try await other.join(work)
        try await other.engine.sendNow()
        try await mac.engine.fetchNow()
        #expect(mac.values.isEmpty)
        #expect(!mac.sync.isEnabled(.websiteSettings, localProfileID: mac.localID))
    }

    @Test func firstAccountNotificationPreservesAnUnconfirmedOfflineChoice() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings")
        let profile = UUID(), cloud = FakeSyncCloud()
        var local = ["engine/site": Data([1])]
        func open() -> CloudSettingsSync {
            CloudSettingsSync(stateFile: file, read: { _, _ in local }, apply: { value, key, _, _ in local[key] = value })
        }
        let first = open()
        let offline = FakeSyncEngine(cloud: cloud, delegate: first)
        first.attach(offline)
        offline.offline = true
        await #expect(throws: (any Error).self) { try await first.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile) }
        local.removeAll()
        try first.collectChanges()
        let restored = open()
        let engine = FakeSyncEngine(cloud: cloud, delegate: restored)
        restored.attach(engine)
        try restored.accountDidResolve(cloud.user)
        #expect(restored.state.account == nil)
        let waiting = try #require(restored.channel(.websiteSettings, localProfileID: profile))
        #expect(waiting.records["engine/site"]?.pending == MacSettingPayload(key: "engine/site", value: nil))
        #expect(engine.pending.isEmpty && cloud.zones.isEmpty)
        try await restored.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile)
        try await engine.sendNow()
        #expect(restored.state.account == cloud.user)
        #expect(cloud.recordCount == 1)
        try restored.accountDidResolve("another-account")
        #expect(restored.state.channels.isEmpty)
    }

    @Test func automaticUploadChecksTheAccountBeforeSendingItsFirstRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let work = UUID()
        let studio = Mac(cloud, root: root, values: ["engine/studio": Data([1])])
        try await studio.join(work)
        cloud.switchUser("second")
        let next = Mac(cloud, root: root, values: [:])
        try await next.join(work)
        try await studio.engine.sendNow()
        let stored = cloud.zones.values.flatMap { $0.keys }
        #expect(stored.isEmpty)
        #expect(!studio.sync.isEnabled(.websiteSettings, localProfileID: studio.localID))
        #expect(studio.values == ["engine/studio": Data([1])])
    }

    @Test func anUnreadableWebsiteSettingDoesNotStopProviderUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var providers: [String: Data] = [:]
        let sync = CloudSettingsSync(
            stateFile: root.appendingPathComponent("settings"),
            read: { category, _ in category == .providers ? providers : [:] },
            apply: { value, key, category, _ in if category == .providers { providers[key] = value } })
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: sync)
        sync.onNeedsEngine = { sync.attach(engine) }
        let profile = UUID()
        try await sync.enable(.websiteSettings, localProfileID: profile, cloudProfileID: profile)
        try await sync.enable(.providers, localProfileID: nil, cloudProfileID: nil)
        let web = try #require(sync.channel(.websiteSettings, localProfileID: profile))
        let ai = try #require(sync.channel(.providers, localProfileID: nil))
        let choice = MacSettingPayload(key: "provider/choice", value: Data([3]))
        let invalid = SyncRecord(
            id: SyncRecordID(zone: web.zone, name: "new-format"), type: .macSetting, schema: 3, payload: Data())
        let valid = SyncRecord(
            id: SyncRecordID(zone: ai.zone, name: choice.recordName), type: .macSetting,
            schema: 1, payload: try JSONEncoder().encode(choice))
        await sync.handle(.fetched(modified: [invalid, valid], deleted: []))
        #expect(providers[choice.key] == choice.value)
        #expect(!sync.ready.contains(web.zone))
        #expect(sync.ready.contains(ai.zone))
    }

    @Test(arguments: [false, true])
    func incomingChangePreservesLocalEditBeforeNotification(deleted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let key = "engine/site"
        let mac = Mac(cloud, root: root, values: [key: Data([1])])
        try await mac.join(UUID())
        try await mac.engine.sendNow()
        try await mac.engine.fetchNow()
        let channel = try #require(mac.sync.channel(.websiteSettings, localProfileID: mac.localID))
        let update = MacSettingPayload(key: key, value: Data([2]))
        let id = SyncRecordID(zone: channel.zone, name: update.recordName)
        mac.values[key] = Data([3])
        if deleted {
            cloud.deleteRecord(id)
        } else {
            cloud.overwrite(id, payload: try JSONEncoder().encode(update))
        }
        try await mac.engine.fetchNow()
        let record = try #require(mac.sync.state.channels[channel.zone]?.records[key])
        #expect(mac.values[key] == Data([3]))
        #expect(record.pending?.value == Data([3]))
        #expect(record.conflict)
        try mac.sync.resolve(key, in: channel.zone, useCloud: false)
        try await mac.engine.sendNow()
        let saved = try #require(cloud.record(id))
        #expect(try JSONDecoder().decode(MacSettingPayload.self, from: saved.payload).value == Data([3]))
    }

    @Test(arguments: [false, true], [false, true])
    func oldReplyCannotCompleteTheNewAccountsEdit(newWasHandedOut: Bool, failed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud()
        let key = "engine/site"
        let mac = Mac(cloud, root: root, values: [key: Data([1])])
        let shared = UUID()
        try await mac.join(shared)
        let channel = try #require(mac.sync.channel(.websiteSettings, localProfileID: mac.localID))
        let id = SyncRecordID(zone: channel.zone, name: MacSettingPayload(key: key, value: nil).recordName)
        let old = try #require(mac.engine.handOut(id))
        cloud.switchUser("next")
        await mac.engine.simulateAccount(.switchAccounts(user: "next"))
        try await mac.join(shared)
        if newWasHandedOut {
            _ = try #require(mac.engine.handOut(id))
        }
        if failed {
            let failure = SyncFailedSave(id: id, failure: .zoneNotFound, attempted: old)
            await mac.sync.handle(.sent(saved: [], deleted: [], failed: [failure]))
        } else {
            await mac.sync.handle(.sent(saved: [old], deleted: [], failed: []))
        }
        let current = try #require(mac.sync.record(for: id))
        guard case .saved(let valid) = cloud.save(current) else {
            Issue.record("Expected to save the new account’s edit")
            return
        }
        await mac.sync.handle(.sent(saved: [valid], deleted: [], failed: []))
        #expect(mac.sync.record(for: id) == nil)
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
