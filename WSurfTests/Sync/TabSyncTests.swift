// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
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
        a.start(sharing: [personal, other])
        b.start(sharing: [personal, other, unshared])
        try await publish(a, SyncSamples.session(tabs: ["https://a.test/"]))
        let payload = SyncSamples.session(tabs: ["https://b.test/"])
        try await publish(b, payload)
        try await publish(b, payload, profile: other)
        try await publish(b, payload, profile: unshared)
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

    @Test func aMissingEstablishedZoneStopsTheNextSessionSave() async throws {
        let cloud = FakeSyncCloud()
        let a = device(cloud, "install-a")
        a.start(sharing: [personal])
        try await publish(a, SyncSamples.session(tabs: ["https://old.test/"]))
        cloud.removeZoneSilently(personalZone)

        try await publish(a, SyncSamples.session(tabs: ["https://new.test/"]))

        await a.sync.refresh()
        #expect(a.box.ended == [personal] && cloud.zones[personalZone] == nil)
    }

    @Test func aFailedFirstZoneCreationCanRetryItsSessionSave() async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air")
        air.start(sharing: [personal])
        await air.sync.refresh()
        air.engine.losesZoneSaves = 2
        try await publish(air, SyncSamples.session(tabs: ["https://first.test/"]))
        #expect(cloud.record(air.id(in: personalZone)) != nil && air.box.ended.isEmpty)
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
        var deliver: (@MainActor () async -> Void)?
        a.engine.holdSendReceipt = { deliver = $0 }
        try await a.engine.sendNow()
        a.engine.holdSendReceipt = nil
        a.sync.reconcile(sharing: [])

        let accepted = try #require(deliver)
        await accepted()
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

    @Test(arguments: [false, true])
    func enablingAfterAnotherCategoryConsumedTheCursorReadsStationaryTabs(staleMirror: Bool) async throws {
        let cloud = FakeSyncCloud()
        let studio = device(cloud, "studio", name: "Mac Studio")
        studio.start(sharing: [personal, other])
        try await publish(studio, SyncSamples.session(tabs: ["https://stationary.test/"]))
        try await publish(studio, SyncSamples.session(tabs: ["https://unselected.test/"]), profile: other)
        let ownSession = SyncSamples.session(tabs: ["https://air.test/"])
        var old = TabSyncState()
        if staleMirror {
            old.accountUser = cloud.user
            old.devices["retired"] = MirroredDevice(info: studio.sync.device, modifiedAt: .distantPast)
            old.sessions[personalZone] = ["retired": MirroredSession(payload: ownSession, modifiedAt: .distantPast)]
        }
        let air = SyncDevice(cloud: cloud, installID: "air", state: old)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: nil, vaults: nil)
        air.engine.delegate = router
        try await air.engine.fetchNow()
        #expect(router.state.engineState != nil)
        let writes = cloud.writeCount

        router.routeTabs(to: air.sync)
        air.sync.reconcile(sharing: [personal])
        air.sync.attach(air.engine)
        air.sync.share(ownSession, profileID: personal, force: false)
        air.sync.share(ownSession, profileID: other, force: true)
        #expect(await waitUntil(timeout: .seconds(3)) { air.sync.state.sessions[personalZone]?["studio"] != nil })
        #expect(air.sync.state.accountUser == cloud.user)
        #expect(air.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").map(\.label) == ["Studio"])
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://stationary.test/")
        #expect(air.sync.state.devices["retired"] == nil && air.sync.state.sessions[personalZone]?["retired"] == nil)
        #expect(air.sync.state.sessions[SyncZone.profile(other)] == nil)
        #expect(cloud.writeCount == writes)
        await air.sync.refresh()
        await air.sync.refresh()
        #expect(air.engine.fetchAllCount == 2)
        try await air.engine.sendNow()
        let sent = try #require(cloud.record(air.id(in: personalZone)))
        #expect(try SessionCodec.decodeSession(sent.payload).windows == ownSession.windows)
        #expect(cloud.record(air.id(in: SyncZone.profile(other))) == nil)
    }

    @Test func rejoiningOfflineRetriesTheMissedSnapshotAndThenUsesIncrementalFetches() async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://before.test/"]))
        air.start(sharing: [personal])
        await air.sync.refresh()
        #expect(air.sync.state.sessions[personalZone]?["studio"] != nil)
        air.sync.reconcile(sharing: [])
        try await publish(studio, SyncSamples.session(tabs: ["https://while-paused.test/"]))
        try await air.engine.fetchNow() // The other categories continue advancing their shared cursor.
        let pausedReads = (air.engine.fetchCount, air.engine.fetchAllCount)
        await air.sync.refresh()
        #expect((air.engine.fetchCount, air.engine.fetchAllCount) == pausedReads)
        #expect(air.sync.state.sessions[personalZone] == nil)

        air.engine.offline = true
        air.sync.reconcile(sharing: [personal])
        await air.sync.refresh()
        #expect(air.sync.state.sessions[personalZone] == nil)
        air.engine.offline = false
        air.engine.unreadable = ["studio"]
        await air.sync.refresh()
        air.engine.unreadable = []
        await air.sync.refresh()
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://while-paused.test/")
        let reads = air.engine.fetchAllCount
        await air.sync.refresh()
        #expect(air.engine.fetchAllCount == reads)
    }

    @Test(arguments: [false, true])
    func changesDeliveredDuringTheBaselineWinEvenAtTheSameServerDate(delete: Bool) async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio", name: "Studio")
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://old.test/"]))
        try await air.engine.fetchNow()
        let held = HeldTabRead(air.engine)
        var delivered = false
        held.beforeReturn = { zone in
            guard zone == personalZone else { return }
            delivered = true
            if delete {
                cloud.deleteRecord(studio.id(in: personalZone))
                cloud.deleteRecord(studio.id(in: SyncZone.devices))
            } else {
                let updated = try #require(SessionCodec.encodeFitted(SyncSamples.session(tabs: ["https://new.test/"])))
                cloud.overwrite(studio.id(in: personalZone), payload: updated)
                cloud.overwrite(studio.id(in: SyncZone.devices), payload: try SessionCodec.encode(DeviceInfo(name: "Renamed", kind: .mac, appVersion: "1")))
            }
            try await air.engine.fetchNow()
        }
        air.sync.reconcile(sharing: [personal])
        air.sync.attach(held)
        await air.sync.refresh()
        #expect(delivered)
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == (delete ? nil : "https://new.test/"))
        #expect(air.sync.state.devices["studio"]?.info.name == (delete ? nil : "Renamed"))
    }

    @Test(arguments: [false, true])
    func anIncrementalFetchCannotDeliverIntoALaterOptIn(switchAccount: Bool) async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://previous.test/"]))
        let held = HeldTabRead(air.engine)
        air.sync.reconcile(sharing: [personal])
        air.sync.attach(held)
        await air.sync.refresh()
        let old = try #require(cloud.record(studio.id(in: personalZone)))
        held.duringIncremental = { receive in
            air.sync.reconcile(sharing: [])
            if switchAccount {
                cloud.switchUser("next-account")
                await air.engine.simulateAccount(.switchAccounts(user: cloud.user))
            } else {
                cloud.deleteRecord(old.id)
            }
            air.sync.reconcile(sharing: [personal])
            // The engine has already fetched these old responses when the person re-enrolls.
            await receive(.fetched(modified: [old], deleted: []))
            #expect(air.sync.state.sessions[personalZone]?["studio"] == nil)
            await receive(.zonesDeleted([personalZone: .deleted]))
        }
        await air.sync.refresh()
        #expect(air.box.ended == (switchAccount ? [nil] : []))
        #expect(air.sync.needsEngine)
        await air.sync.refresh()
        #expect(air.sync.state.sessions[personalZone]?["studio"] == nil)
    }

    enum OldFetch: CaseIterable { case beforeAttachment, priorEdit, priorDeletion, priorZoneRemoval }

    @Test(arguments: OldFetch.allCases)
    func sharedFetchCannotOverwriteAReenrollmentOrLoseALaterChange(old: OldFetch) async throws {
        let cloud = FakeSyncCloud(), studio = device(cloud, "studio"), air = device(cloud, "air")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://before.test/"]))
        let id = studio.id(in: personalZone)
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: nil, vaults: nil)
        air.engine.delegate = router
        if old != .beforeAttachment {
            router.routeTabs(to: air.sync)
            air.start(sharing: [personal])
            await air.sync.refresh()
        }
        switch old {
        case .beforeAttachment, .priorEdit:
            cloud.bump(id)
        case .priorDeletion:
            cloud.deleteRecord(id)
        case .priorZoneRemoval:
            cloud.deleteZone(personalZone, reason: .purged)
        }
        var observedBaseline = false
        air.engine.beforeFetchDelivery = {
            air.engine.beforeFetchDelivery = nil
            air.sync.reconcile(sharing: [])
            // A later write recreates the same ID, with the same server date.
            if old == .priorZoneRemoval {
                cloud.createZone(personalZone)
            }
            try await publish(studio, SyncSamples.session(tabs: ["https://baseline.test/"]))
            router.routeTabs(to: air.sync)
            air.start(sharing: [personal])
            observedBaseline = await waitUntil(timeout: .seconds(3)) {
                air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://baseline.test/"
            }
        }
        // Settings (or the automatic transport) starts this fetch independently of TabSync.refresh().
        try await air.engine.fetchNow()
        #expect(observedBaseline)
        #expect(air.box.ended.isEmpty)
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://baseline.test/")

        try await publish(studio, SyncSamples.session(tabs: ["https://later.test/"]))
        try await air.engine.fetchNow()
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://later.test/")
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.modifiedAt == cloud.now())
        cloud.deleteRecord(id)
        try await air.engine.fetchNow()
        #expect(air.sync.state.sessions[personalZone]?["studio"] == nil)
    }

    @Test(arguments: [false, true])
    func coalescedFetchAcrossReenrollmentRecoversLaterServerChanges(delete: Bool) async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://before.test/"]))
        let id = studio.id(in: personalZone)
        air.start(sharing: [personal])
        await air.sync.refresh()
        let oldFetch = router.beginFetch()
        air.sync.reconcile(sharing: [])
        try await publish(studio, SyncSamples.session(tabs: ["https://baseline.test/"]))
        air.sync.reconcile(sharing: [personal])
        await air.sync.refresh()
        // A later page advances the old fetch's cursor past a new write. The server can also change again before delivery.
        try await publish(studio, SyncSamples.session(tabs: ["https://coalesced.test/"]))
        let page = try #require(cloud.record(id))
        let latestURL: String?
        if delete {
            cloud.deleteRecord(id)
            latestURL = nil
        } else {
            try await publish(studio, SyncSamples.session(tabs: ["https://latest.test/"]))
            latestURL = "https://latest.test/"
        }
        await oldFetch(.fetched(modified: [page], deleted: []))
        #expect(await waitUntil(timeout: .seconds(3)) {
            air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == latestURL
        })
        let reads = air.engine.fetchAllCount
        await air.sync.refresh()
        #expect(air.engine.fetchAllCount == reads)
    }

    @Test(arguments: [false, true])
    func overlappingSharedFetchesCannotRestoreAnOlderRow(delete: Bool) async throws {
        let cloud = FakeSyncCloud(), studio = device(cloud, "studio"), air = device(cloud, "air")
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://old.test/"]))
        air.start(sharing: [personal])
        await air.sync.refresh()
        let id = studio.id(in: personalZone)
        cloud.bump(id)
        air.engine.beforeFetchDelivery = {
            air.engine.beforeFetchDelivery = nil
            if delete {
                cloud.deleteRecord(id)
            } else {
                try await publish(studio, SyncSamples.session(tabs: ["https://later.test/"]))
            }
            try await air.engine.fetchNow()
        }
        try await air.engine.fetchNow()
        #expect(await waitUntil(timeout: .seconds(3)) {
            air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == (delete ? nil : "https://later.test/")
        })
    }

    @Test func aNewBaselineDuringSharedFetchVerificationStillWins() async throws {
        let cloud = FakeSyncCloud(), studio = device(cloud, "studio"), air = device(cloud, "air")
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://old.test/"]))
        let old = try #require(cloud.record(studio.id(in: personalZone)))
        air.engine.unreadable = ["studio"]
        air.start(sharing: [personal])
        await air.sync.refresh()
        let deliver = router.beginFetch()
        try await publish(studio, SyncSamples.session(tabs: ["https://new.test/"]))
        air.engine.duringAccountLookup = {
            air.engine.duringAccountLookup = nil
            air.engine.unreadable = []
            await air.sync.refresh()
        }
        await deliver(.fetched(modified: [old], deleted: []))
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://new.test/")
    }

    enum Recheck: CaseIterable { case missing, survived, switchedAccount, freshOptIn, devicesGone }

    @Test(arguments: Recheck.allCases)
    func unresolvedZoneRemovalSurvivesBothCheckpointsAndPrecedesSends(recheck: Recheck) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabFile = directory.appending(path: "tabs.json"), routerFile = directory.appending(path: "router.json")
        let cloud = FakeSyncCloud(), studio = device(cloud, "studio"), air = device(cloud, "air")
        let zone = recheck == .devicesGone ? SyncZone.devices : personalZone
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://studio.test/"]))
        let tabs = TabSync(installID: "air", device: air.sync.device, state: .init()) {
            do { try JSONEncoder().encode($0).write(to: tabFile, options: .atomic) } catch { Issue.record(error) }
        }
        let router = SyncRouter(state: .init(), persist: {
            do { try JSONEncoder().encode($0).write(to: routerFile, options: .atomic) } catch { Issue.record(error) }
        }, tabs: tabs, vaults: nil)
        air.engine.delegate = router
        tabs.reconcile(sharing: [personal])
        tabs.attach(air.engine)
        await tabs.refresh()
        air.engine.available = false
        cloud.deleteZone(zone, reason: .purged)
        try await air.engine.fetchNow()
        if recheck == .survived {
            cloud.createZone(zone)
        }
        // A fresh model and engine restore both files; the database cursor is already past the deletion.
        let saved = try JSONDecoder().decode(TabSyncState.self, from: Data(contentsOf: tabFile))
        let checkpoint = try JSONDecoder().decode(SyncRouterState.self, from: Data(contentsOf: routerFile))
        let restored = SyncDevice(cloud: cloud, installID: "air", state: saved)
        let nextRouter = SyncRouter(state: checkpoint, persist: { _ in }, tabs: restored.sync, vaults: nil)
        let cursor = try #require(checkpoint.engineState)
        let engine = FakeSyncEngine(cloud: cloud, delegate: nextRouter, state: cursor)
        engine.available = false
        #expect(engine.pending.contains(.saveZone(zone)), "the old engine checkpoint carries a zone creation")
        restored.sync.reconcile(sharing: [personal])
        restored.sync.attach(engine)
        restored.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: personal, force: true)
        #expect(restored.sync.record(for: restored.id(in: personalZone)) == nil)
        try await engine.sendNow()
        #expect((cloud.zones[zone] != nil) == (recheck == .survived))
        #expect(restored.box.ended.isEmpty)
        restored.sync.attach(engine)
        restored.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: personal, force: true)
        #expect(engine.pending.isEmpty, "replay and a new local snapshot wait for the zone check")
        await restored.sync.refresh()
        engine.available = true
        try await engine.sendNow()
        #expect((cloud.zones[zone] != nil) == (recheck == .survived))
        #expect(cloud.record(restored.id(in: personalZone)) == nil)
        if recheck == .switchedAccount {
            cloud.switchUser("next-user")
        } else if recheck == .freshOptIn {
            restored.sync.reconcile(sharing: [])
            restored.sync.reconcile(sharing: [personal])
            restored.sync.share(SyncSamples.session(tabs: ["https://new-opt-in.test/"]), profileID: personal, force: true)
        }
        await restored.sync.refresh()
        try await engine.sendNow()
        switch recheck {
        case .missing, .devicesGone, .switchedAccount:
            #expect(restored.box.ended == (recheck == .missing ? [personal] : [nil]))
            #expect(cloud.zones[zone] == nil)
            #expect(cloud.record(restored.id(in: personalZone)) == nil)
        case .survived, .freshOptIn:
            #expect(restored.box.ended.isEmpty)
            let sent = try #require(cloud.record(restored.id(in: personalZone)))
            let url = try SessionCodec.decodeSession(sent.payload).windows.first?.nodes.first?.url
            #expect(url == (recheck == .survived ? "https://air.test/" : "https://new-opt-in.test/"))
        }
    }

    enum DuringTabRead: CaseIterable { case optOut, rejoin, signOut, switchUser, unavailable }

    @Test(arguments: DuringTabRead.allCases)
    func aSuspendedBaselineRequiresTheSameAccountAndUninterruptedOptIn(change: DuringTabRead) async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://previous.test/"]))
        try await air.engine.fetchNow()
        let held = HeldTabRead(air.engine)
        var interrupted = false
        held.beforeReturn = { zone in
            guard !interrupted, zone == personalZone else { return }
            interrupted = true
            switch change {
            case .optOut, .rejoin:
                air.sync.reconcile(sharing: [])
                if change == .rejoin {
                    air.engine.unreadable = ["studio"]
                    air.sync.reconcile(sharing: [personal])
                }
            case .signOut:
                await air.engine.simulateAccount(.signOut)
            case .switchUser:
                cloud.switchUser("different-account")
            case .unavailable:
                air.engine.available = false
            }
        }
        air.sync.reconcile(sharing: [personal])
        air.sync.attach(held)
        await air.sync.refresh()
        #expect(interrupted)
        #expect(air.sync.state.sessions[personalZone] == nil)
        #expect(air.sync.state.devices.isEmpty)
        if change == .switchUser {
            #expect(air.box.ended == [nil] && !air.sync.needsEngine)
        }
    }

    @Test(arguments: [false, true])
    func anUnverifiedZoneRemovalEndsSharingOnlyIfTheVerifiedZoneIsGone(removed: Bool) async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://retired.test/"]))
        air.start(sharing: [personal])
        await air.sync.refresh()
        air.engine.available = false
        if removed {
            cloud.deleteZone(personalZone, reason: .deleted)
            try await air.engine.fetchNow()
        } else {
            await air.sync.handle(.zonesDeleted([personalZone: .deleted]))
        }
        #expect(air.box.ended.isEmpty)
        air.engine.available = true
        await air.sync.refresh()
        #expect(air.box.ended == (removed ? [personal] : []))
        air.sync.share(SyncSamples.session(tabs: ["https://local.test/"]), profileID: personal, force: true)
        #expect((air.sync.record(for: air.id(in: personalZone)) == nil) == removed)
    }

    @Test func aRemovalWithoutAVerifiedOwnerCannotAuthorizeTheNextAccount() async throws {
        let cloud = FakeSyncCloud(user: "previous-user")
        let air = device(cloud, "air")
        air.engine.available = false
        air.start(sharing: [personal])
        cloud.deleteZone(personalZone, reason: .purged)
        try await air.engine.fetchNow()
        let bytes = try JSONEncoder().encode(#require(air.box.state))
        let saved = try JSONDecoder().decode(TabSyncState.self, from: bytes)
        #expect(saved.accountUser == nil)
        cloud.switchUser("different-user")
        cloud.createZone(personalZone)
        let restored = SyncDevice(cloud: cloud, installID: "air", state: saved)
        restored.start(sharing: [personal])
        restored.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: personal, force: true)
        await restored.sync.refresh()
        try await restored.engine.sendNow()
        #expect(restored.box.ended == [nil])
        #expect(cloud.recordCount == 0)
    }

    @Test func legacyCheckpointWithoutRemovalChecksStillReadsExistingDevices() async throws {
        let old = Data(#"{"accountUser":"user-1","seq":4,"ownSystemFields":{},"devices":{},"sessions":{}}"#.utf8)
        let state = try JSONDecoder().decode(TabSyncState.self, from: old)
        let cloud = FakeSyncCloud(), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://existing.test/"]))
        let air = SyncDevice(cloud: cloud, installID: "air", state: state)
        air.start(sharing: [personal])
        await air.sync.refresh()
        #expect(air.sync.state.seq == 4)
        #expect(air.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").map(\.id) == ["studio"])
    }

    @Test func optedOutIncrementalAndAnUnverifiedCheckpointCannotBecomeTheNewMirror() async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://start.test/"]))
        air.start(sharing: [personal])
        await air.sync.refresh()
        let old = try #require(cloud.record(studio.id(in: personalZone)))
        var stale = old
        stale.id.name = "previous-enrollment"
        air.engine.duringAccountLookup = {
            air.engine.duringAccountLookup = nil
            air.sync.reconcile(sharing: [])
            air.sync.reconcile(sharing: [personal])
        }
        await air.sync.handle(.fetched(modified: [stale], deleted: []))
        #expect(air.sync.state.sessions[personalZone]?["previous-enrollment"] == nil)
        await air.sync.refresh()

        try await publish(studio, SyncSamples.session(tabs: ["https://missed.test/"]))
        air.engine.available = false
        try await air.engine.fetchNow()
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://start.test/")
        air.engine.available = true
        await air.sync.refresh()
        #expect(air.sync.state.sessions[personalZone]?["studio"]?.payload.windows.first?.nodes.first?.url == "https://missed.test/")
    }
}

extension TabSyncTests {
    enum ZoneAfterRejoin: CaseIterable { case removed, userDeleted, recreated }

    @Test(arguments: ZoneAfterRejoin.allCases)
    func lateZonePageVerifiesTheRejoinedZoneBeforePublishing(outcome: ZoneAfterRejoin) async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air"), studio = device(cloud, "studio")
        studio.start(sharing: [personal])
        try await publish(studio, SyncSamples.session(tabs: ["https://studio.test/"]))
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: air.sync, vaults: nil)
        air.engine.delegate = router
        let held = HeldTabRead(air.engine)
        held.userDeletedZone = outcome == .userDeleted
        air.sync.reconcile(sharing: [personal])
        air.sync.attach(held)
        await air.sync.refresh()
        // A second database page in the same fetch cycle arrives after the new enrollment saw Studio.
        air.engine.beforeFetchDelivery = {
            air.engine.beforeFetchDelivery = nil
            air.sync.reconcile(sharing: [])
            air.sync.reconcile(sharing: [personal])
            await air.sync.refresh()
            #expect(air.sync.remoteSessions(profileID: personal, fallbackLabel: "Device").map(\.id) == ["studio"])
            cloud.deleteZone(personalZone, reason: .deleted)
            if outcome == .recreated {
                cloud.createZone(personalZone)
            }
            air.engine.available = false
            try await air.engine.fetchNow()
        }
        try await air.engine.fetchNow()
        #expect(!router.allowsZoneCreation(personalZone))
        air.sync.share(SyncSamples.session(tabs: ["https://air.test/"]), profileID: personal, force: true)
        try await air.engine.sendNow()
        air.engine.available = true
        await air.sync.refresh()
        try await air.engine.sendNow()
        #expect(air.box.ended == (outcome == .recreated ? [] : [personal]))
        #expect((cloud.zones[personalZone] != nil) == (outcome == .recreated))
        #expect((cloud.record(air.id(in: personalZone)) != nil) == (outcome == .recreated))
    }

    @Test func aPageFromBeforeFirstOptInChecksTheZoneBeforeItsFirstCreation() async throws {
        let cloud = FakeSyncCloud(), air = device(cloud, "air")
        let router = SyncRouter(state: .init(), persist: { _ in }, tabs: nil, vaults: nil)
        air.engine.delegate = router
        cloud.createZone(personalZone)
        cloud.deleteZone(personalZone, reason: .deleted)
        air.engine.beforeFetchDelivery = {
            air.engine.beforeFetchDelivery = nil
            air.engine.available = false
            router.routeTabs(to: air.sync)
            air.start(sharing: [personal])
        }
        try await air.engine.fetchNow()
        #expect(!router.allowsZoneCreation(personalZone))
        try await air.engine.sendNow()
        #expect(cloud.zones[personalZone] == nil)
        air.engine.available = true
        await air.sync.refresh()
        try await publish(air, SyncSamples.session(tabs: ["https://first.test/"]))
        #expect(air.box.ended.isEmpty)
        #expect(cloud.record(air.id(in: personalZone)) != nil)
    }
}

/// Returns the snapshot taken before the injected event, even if that event cancels the read.
@MainActor
final class HeldTabRead: SyncEngine, SyncAccountIdentity {
    let base: FakeSyncEngine
    var beforeReturn: ((String) async throws -> Void)?
    var duringIncremental: ((SyncFetchDelivery) async throws -> Void)?
    var userDeletedZone = false

    init(_ base: FakeSyncEngine) {
        self.base = base
    }
    func add(_ changes: [SyncChange]) {
        base.add(changes)
    }
    func sendNow() async throws {
        try await base.sendNow()
    }
    func fetchNow() async throws {
        if let duringIncremental {
            self.duringIncremental = nil
            let receive = try #require(base.delegate?.beginFetch())
            try await duringIncremental(receive)
        } else {
            try await base.fetchNow()
        }
    }
    func accountIsAvailable() async -> Bool {
        await base.accountIsAvailable()
    }
    func currentAccountUser() async throws -> String {
        try await base.currentAccountUser()
    }

    func fetchAll(zone: String) async throws -> SyncZoneRead {
        let snapshot: SyncZoneRead
        do {
            snapshot = try await base.fetchAll(zone: zone)
        } catch let error as URLError where userDeletedZone && error.code == .fileDoesNotExist {
            throw CKError(.userDeletedZone)
        }
        try await beforeReturn?(zone)
        return snapshot
    }
}
