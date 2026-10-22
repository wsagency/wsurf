// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

/// The model against a fake account: what a device publishes, what it lists of the others, and what it does when the account
/// or the server takes something away.
@MainActor
struct TabSyncTests {
    private let personal = UUID()
    private let other = UUID()
    private let unshared = UUID()

    private var personalZone: String {
        SyncZone.profile(personal)
    }

    private func device(_ cloud: FakeSyncCloud, _ installID: String, name: String = "Ana’s MacBook Air") -> SyncDevice {
        SyncDevice(cloud: cloud, installID: installID, name: name)
    }

    /// Shares `payload` for `profile` and sends it.
    private func publish(_ device: SyncDevice, _ payload: DeviceSessionPayload, profile: UUID? = nil, force: Bool = false) async throws {
        device.sync.share(payload, profileID: profile ?? personal, force: force)
        try await device.engine.sendNow()
    }

    @Test func sharingSavesOneSessionRecordInTheProfileZone() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        let payload = SyncSamples.session(tabs: ["https://a.test/"], favorites: ["https://fav.test/"])

        try await publish(a, payload)

        let record = try #require(cloud.record(a.id(in: personalZone)))
        var expected = payload
        expected.seq = 1
        #expect(personalZone == "p-" + personal.uuidString)
        #expect(record.type == .deviceSession)
        #expect(cloud.names(in: personalZone) == ["install-a"])
        #expect(try SessionCodec.decodeSession(record.payload) == expected)
    }

    @Test func unchangedSessionIsNotSentAgainUnlessForced() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        let payload = SyncSamples.session(tabs: ["https://a.test/"])
        let id = a.id(in: personalZone)
        try await publish(a, payload)
        let first = try #require(cloud.tag(of: id))

        try await publish(a, payload)
        #expect(cloud.tag(of: id) == first)

        try await publish(a, payload, force: true)
        #expect(cloud.tag(of: id) == first + 1)
        #expect(try SessionCodec.decodeSession(#require(cloud.record(id)).payload).seq == 2)
    }

    @Test func deviceRecordExistsOnlyWhileAProfileIsShared() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [])
        try await a.engine.sendNow()
        #expect(cloud.recordCount == 0)

        a.sync.reconcile(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        let deviceRecord = try #require(cloud.record(a.id(in: SyncZone.devices)))
        #expect(deviceRecord.type == .device)
        #expect(try SessionCodec.decodeDevice(deviceRecord.payload) == a.sync.device)

        a.sync.reconcile(sharing: [])
        try await a.engine.sendNow()
        #expect(cloud.recordCount == 0)
        #expect(a.sync.state.publishedDevice == nil)
    }

    @Test func otherDevicesAppearInTheirProfileOnly() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a", name: "Ana’s MacBook Air")
        let b = device(cloud, "install-b", name: "Ana’s MacBook Pro")
        a.start(sharing: [personal])
        b.start(sharing: [personal, other])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        let payload = SyncSamples.session(tabs: ["https://b.test/"])
        try await publish(b, payload)
        try await publish(b, payload, profile: other)
        try await a.engine.fetchNow()

        let inPersonal = a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device")
        let inOther = a.sync.remoteSessions(profileID: other, fallbackLabel: "Device")

        #expect(inPersonal.map(\.id) == ["install-b"])
        #expect(inPersonal.first?.label == "Pro")
        #expect(inPersonal.first?.deviceName == "Ana’s MacBook Pro")
        #expect(inPersonal.first?.payload.windows.first?.nodes.first?.url == "https://b.test/")
        #expect(inPersonal.first?.lastSeen == cloud.now())
        #expect(inOther.map(\.id) == ["install-b"])
        #expect(a.sync.remoteSessions(profileID: unshared, fallbackLabel: "Device").isEmpty)
    }

    @Test func sessionWithoutItsDeviceIsNotListed() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await a.engine.fetchNow()
        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").count == 1)

        cloud.deleteRecord(b.id(in: SyncZone.devices))
        try await a.engine.fetchNow()

        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").isEmpty)
    }

    @Test func ownRecordsAreNeverListed() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))

        try await a.engine.fetchNow()

        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").isEmpty)
        #expect(a.sync.state.devices.isEmpty)
        #expect(a.sync.state.sessions.isEmpty)
        #expect(a.sync.state.ownSystemFields[personalZone] == cloud.record(a.id(in: personalZone))?.systemFields)
    }

    @Test func staleChangeTagIsRetriedOnTheServerRecord() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        let id = a.id(in: personalZone)
        try await publish(a, SyncSamples.session(tabs: ["https://old.test/"]))
        cloud.bump(id)

        try await publish(a, SyncSamples.session(tabs: ["https://new.test/"]))

        let held = try SessionCodec.decodeSession(#require(cloud.record(id)).payload)
        #expect(held.windows.first?.nodes.first?.url == "https://new.test/")
        #expect(cloud.tag(of: id) == 3)
    }

    @Test func missingZoneIsCreatedAndTheSaveRetried() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://old.test/"]))
        cloud.removeZoneSilently(personalZone)

        try await publish(a, SyncSamples.session(tabs: ["https://new.test/"]))

        let held = try SessionCodec.decodeSession(#require(cloud.record(a.id(in: personalZone))).payload)
        #expect(held.windows.first?.nodes.first?.url == "https://new.test/")
    }

    @Test func deletedOwnRecordIsSavedAgain() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        let id = a.id(in: personalZone)
        try await publish(a, SyncSamples.session(tabs: ["https://old.test/"]))
        cloud.deleteRecord(id)

        try await publish(a, SyncSamples.session(tabs: ["https://new.test/"]))

        let held = try SessionCodec.decodeSession(#require(cloud.record(id)).payload)
        #expect(held.windows.first?.nodes.first?.url == "https://new.test/")
    }

    @Test func stoppingSharingDeletesOnlyThisDevicesRecord() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))

        a.sync.reconcile(sharing: [])
        try await a.engine.sendNow()

        #expect(cloud.names(in: personalZone) == ["install-b"])
        #expect(cloud.names(in: SyncZone.devices) == ["install-b"])
        #expect(a.sync.state.ownSystemFields.isEmpty)
    }

    @Test func recordStillOnItsWayWhenSharingStopsIsRemoved() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        try await a.engine.sendNow()
        a.sync.share(SyncSamples.session(tabs: ["https://a.test/"]), profileID: personal, force: false)
        let request = try #require(a.sync.record(for: a.id(in: personalZone)))
        // The server applies the save, and sharing stops before the answer arrives.
        guard case .saved(let stored) = cloud.save(request) else {
            Issue.record("the server refused the first save")
            return
        }
        a.sync.reconcile(sharing: [])

        await a.sync.handle(.sent(saved: [stored], deleted: [], failed: []))
        try await a.engine.sendNow()

        #expect(cloud.names(in: personalZone).isEmpty)
        #expect(a.engine.pending.isEmpty)
    }

    @Test func signOutDropsMirroredDataAndKeepsLocalSessions() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await a.engine.fetchNow()
        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").count == 1)

        await a.engine.simulateAccount(.signOut)

        let saved = try #require(a.box.state)
        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").isEmpty)
        #expect(saved.devices.isEmpty && saved.sessions.isEmpty && saved.ownSystemFields.isEmpty && saved.publishedDevice == nil)
        #expect(a.sync.accountAvailable == false)
        #expect(a.box.ended.isEmpty)
        #expect(a.sync.needsEngine)
    }

    @Test func signingBackInToTheSameAccountResumesSharing() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        let id = a.id(in: personalZone)
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        let before = try #require(cloud.tag(of: id))
        await a.engine.simulateAccount(.signOut)
        #expect(a.sync.state.ownSystemFields.isEmpty)

        await a.engine.simulateAccount(.signIn(user: cloud.user))
        try await a.engine.sendNow()

        #expect(cloud.names(in: personalZone) == ["install-a"])
        #expect(cloud.names(in: SyncZone.devices) == ["install-a"])
        #expect(try #require(cloud.tag(of: id)) > before)
        #expect(try SessionCodec.decodeSession(#require(cloud.record(id)).payload).windows.first?.nodes.first?.url == "https://a.test/")
        #expect(a.sync.accountAvailable == true)
        #expect(a.sync.state.ownSystemFields[personalZone] == cloud.record(id)?.systemFields)
    }

    @Test func differentAccountEndsSharingAndUploadsNothing() async throws {
        let cloud = FakeSyncCloud(user: "user-1")
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await a.engine.fetchNow()

        cloud.switchUser("user-2")
        await a.engine.simulateAccount(.switchAccounts(user: "user-2"))
        a.sync.share(SyncSamples.session(tabs: ["https://again.test/"]), profileID: personal, force: true)
        try await a.engine.sendNow()
        try await a.engine.fetchNow()

        #expect(a.box.ended == [nil])
        #expect(cloud.recordCount == 0)
        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").isEmpty)
        #expect(a.sync.state.accountUser == "user-2")
        #expect(!a.sync.needsEngine)
    }

    @Test(arguments: SyncZoneDeletionReason.allCases)
    func removedZoneEndsSharingForItsProfile(reason: SyncZoneDeletionReason) async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        try await a.engine.fetchNow()
        let writes = cloud.writeCount

        cloud.deleteZone(personalZone, reason: reason)
        try await a.engine.fetchNow()
        a.sync.share(SyncSamples.session(tabs: ["https://after.test/"]), profileID: personal, force: true)
        try await a.engine.sendNow()

        #expect(a.box.ended == [personal])
        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").isEmpty)
        #expect(a.sync.state.ownSystemFields[personalZone] == nil)
        #expect(cloud.zones[personalZone] == nil)
        #expect(cloud.writeCount == writes)
    }

    @Test func removedDevicesZoneEndsAllSharing() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        try await a.engine.fetchNow()

        cloud.deleteZone(SyncZone.devices, reason: .purged)
        try await a.engine.fetchNow()

        #expect(a.box.ended == [nil])
        #expect(a.sync.state.devices.isEmpty)
        #expect(a.sync.state.publishedDevice == nil)
        #expect(a.sync.state.ownSystemFields[SyncZone.devices] == nil)
        #expect(cloud.zones[SyncZone.devices] == nil)
    }

    @Test func mirrorSurvivesRelaunchWithoutFetching() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await a.engine.fetchNow()
        let saved = try #require(a.box.state)

        let relaunched = TabSync(installID: "install-a", device: a.sync.device, state: saved, persist: { _ in })

        let listed = relaunched.remoteSessions(profileID: personal, fallbackLabel: "Device")
        #expect(listed.map(\.id) == ["install-b"])
        #expect(listed.first?.label == "iPad")
        #expect(relaunched.state == saved)
    }

    @Test func recordProviderAnswersOnlyForOwnRecords() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let foreign = SyncRecordID(zone: personalZone, name: "install-b")
        let anywhere = SyncRecordID(zone: "somewhere", name: "install-a")
        #expect(a.sync.record(for: a.id(in: SyncZone.devices)) == nil)

        a.start(sharing: [personal])
        a.sync.share(SyncSamples.session(tabs: ["https://a.test/"]), profileID: personal, force: false)

        #expect(a.sync.record(for: a.id(in: SyncZone.devices))?.type == .device)
        #expect(a.sync.record(for: a.id(in: personalZone))?.type == .deviceSession)
        #expect(a.sync.record(for: a.id(in: SyncZone.profile(unshared))) == nil)
        #expect(a.sync.record(for: foreign) == nil)
        #expect(a.sync.record(for: anywhere) == nil)
    }

    @Test func undecodableRemotePayloadIsIgnored() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        try await a.engine.fetchNow()

        cloud.overwrite(b.id(in: personalZone), payload: Data("not a session".utf8))
        try await a.engine.fetchNow()

        let listed = a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device")
        #expect(listed.first?.payload.windows.first?.nodes.first?.url == "https://b.test/")
    }

    @Test func garbageFromADeviceNeverListedLeavesNothing() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        let b = device(cloud, "install-b", name: "Ana’s iPad")
        a.start(sharing: [personal])
        b.start(sharing: [personal])
        try await publish(b, SyncSamples.session(tabs: ["https://b.test/"]))
        cloud.overwrite(b.id(in: personalZone), payload: Data("not a session".utf8))

        try await a.engine.fetchNow()

        #expect(a.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").isEmpty)
        #expect(a.sync.state.sessions.isEmpty)
    }
}
