// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WSurfVault

@testable import WSurf
@testable import WSurfCore

extension ProfileSwitchTests {
    @Test func aDelayedProfileWithdrawalPreservesTheOtherMacsExplicitNewPublication() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, vaults in
            let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProfileStore(file: root.appending(path: "profiles.json"))
            let work = try #require(store.adopt(id: profile.id, name: "Work", symbol: "key", color: .blue))
            let vaultID = vaults[0].vaultID, zone = SyncZone.vault(profileID: work.id, vaultID: vaultID)
            let cloud = FakeSyncCloud(user: "synthetic-owner")
            let host = FakeVaultHost(root: work.supportDirectory.deletingLastPathComponent())
            let source = try host.addVault(profile: work.id, vault: vaultID)
            let launch = VaultRemovalLaunch()
            let sender = try launch.start(store, file: root.appending(path: "router.json"), cloud: cloud, host: host, discovery: true)
            let previous = CloudSync.shared
            CloudSync.shared = sender
            defer { sender.prepareToTerminate(); CloudSync.shared = previous }
            let sync = try #require(sender.vaults)
            try #require(await waitUntil { sync.engine != nil })
            let engine = try #require(launch.engine)
            try await sync.enable(profileID: work.id, vaultID: vaultID)
            await sync.settle()
            try await engine.sendNow()
            let copyStore = ProfileStore(file: root.appending(path: "Mac-B/profiles.json"))
            let copy = try #require(copyStore.adopt(id: work.id, name: "Work on B", symbol: "key", color: .blue))
            let other = VaultRemovalLaunch(), copyHost = FakeVaultHost(root: root.appending(path: "Mac-B/vaults"))
            let vault = try copyHost.addVault(profile: copy.id, vault: vaultID, dek: source.dek)
            vault.wrappers = source.wrappers
            let receiver = try other.start(copyStore, file: root.appending(path: "Mac-B/router.json"), cloud: cloud, host: copyHost, discovery: true)
            defer { receiver.prepareToTerminate() }
            let b = try #require(receiver.vaults)
            try #require(await waitUntil { b.engine != nil })
            let receiverEngine = try #require(other.engine)
            try await b.enable(profileID: copy.id, vaultID: vaultID)
            let off = try copyHost.addVault(profile: copy.id)
            try await b.enable(profileID: copy.id, vaultID: off.vaultID)
            try await receiverEngine.sendNow()
            try b.disable(profileID: copy.id, vaultID: off.vaultID)
            let pause = HostPause()
            engine.beforeProfileVaultZoneDelete = { target in
                guard target == zone else { return }
                try #require(cloud.names(in: zone).contains { $0.hasPrefix("withdrawal-") })
                await pause.wait()
            }
            defer { engine.beforeProfileVaultZoneDelete = nil; pause.release() }
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()), profiles: .selection(profile: .original(), catalog: store))
            let approved = try await CredentialErasureNote.warning(for: work).vaultRemovals
            try await coordinator.deleteProfile(work, confirmedVaults: approved).get()
            try #require(await waitUntil { sender.beat(); return pause.isWaiting })
            cloud.removeZoneSilently(zone)
            let item = syncAccounts(1)[0]
            vault.add(item)
            CloudSync.shared = receiver
            let application = BrowserApplication()
            let window = AppCoordinator(browser: BrowserModel(context: .shared(for: copy), windowID: UUID()), profiles: .selection(profile: copy, catalog: copyStore))
            application.register(window)
            window.prepareBrowser(restoring: false, show: false)
            window.showBrowser(activate: false)
            defer { window.closeWindow() }
            let title = String(localized: "Create New Instance")
            try #require(await waitUntil {
                receiver.beat()
                return button(title, in: window.nativeWindow?.attachedSheet?.contentView) != nil
            })
            try await b.settle()
            try await receiverEngine.sendNow()
            #expect(cloud.zones[zone] == nil)
            let target = try #require(button(title, in: window.nativeWindow?.attachedSheet?.contentView))
            target.performClick(nil)
            var published: String?
            try #require(await waitUntil {
                receiver.beat()
                await b.settle()
                try await receiverEngine.sendNow()
                for candidate in cloud.zones.keys where candidate != zone && cloud.names(in: candidate).contains(item.id.uuidString) {
                    published = candidate
                }
                return published != nil
            })
            let fresh = try #require(published)
            let before = try #require(cloud.records(in: fresh))
            pause.release()
            try #require(await waitUntil { sender.beat(); return store.vaultRemovals.isEmpty })
            #expect(cloud.records(in: fresh) == before && cloud.zones[zone] == nil)
            let record = try #require(cloud.record(.init(zone: fresh, name: item.id.uuidString)))
            #expect(try VaultSyncCodec.openItem(record.payload, accountID: item.id, key: source.syncKey).account == item)
            #expect(copyStore.profiles.filter { $0.id == work.id }.count == 1 && !b.isSyncing(profileID: copy.id, vaultID: off.vaultID))
        }
    }

    @Test func aDormantVaultFollowsTheNewInstanceThroughRestart() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json"), router = root.appending(path: "router.json")
        let store = ProfileStore(file: file), work = store.add(name: "Dormant Work")
        defer {
            try? FileManager.default.removeItem(at: work.supportDirectory)
            try? FileManager.default.removeItem(at: root)
        }
        let cloud = FakeSyncCloud(user: "synthetic-dormant-owner")
        let host = FakeVaultHost(root: work.supportDirectory.deletingLastPathComponent())
        let vault = try host.addVault(profile: work.id)
        let launch = VaultRemovalLaunch()
        let service = try launch.start(store, file: router, cloud: cloud, host: host, discovery: true)
        defer { service.prepareToTerminate() }
        let first = try #require(service.vaults)
        try #require(await waitUntil { first.engine != nil })
        try await first.enable(profileID: work.id, vaultID: vault.vaultID)
        await first.settle()
        let engine = try #require(launch.engine)
        try await engine.sendNow()
        service.setVaultDiscovery(false)
        let proof = CloudProfileInstance(.vaults, id: work.id, owner: cloud.user)
        try await engine.publishRetirement(proof)
        try #require(await waitUntil { service.beat(); return store.cloudLedger.pending[work.id] == proof })
        try await service.createNewInstance(of: work, retiring: proof)
        let fresh = try #require(store.cloudLedger.active[work.id]?[cloud.user])
        service.prepareToTerminate()

        let restored = ProfileStore(file: file), restart = VaultRemovalLaunch()
        let app = try restart.start(restored, file: router, cloud: cloud, host: host, discovery: false)
        defer { app.prepareToTerminate() }
        await app.checkProfileInstances()
        #expect(restored.cloudLedger.pending[work.id] == nil && restored.profiles.contains(work))
        app.setVaultDiscovery(true)
        let active = try #require(app.vaults), zone = SyncZone.vault(profileID: work.id, vaultID: vault.vaultID, instanceID: fresh)
        try #require(try await waitUntil {
            app.beat()
            await active.settle()
            try await restart.engine?.sendNow()
            return cloud.names(in: zone).contains(VaultSync.vaultRecordName)
        })
        // A Mac linked through Shared Spaces can subsequently retire this same new publication.
        let shared = CloudProfileInstance(.shared, id: fresh, owner: cloud.user)
        try await restart.engine?.publishRetirement(shared)
        await app.checkProfileInstances()
        #expect(restored.cloudLedger.pending[work.id] == shared)
        try await app.verifyDecision(shared, profile: work.id)
    }

    @Test(arguments: [false, true])
    func aFailedAccountLookupBeforeSendingKeepsTheLastEditLocal(quitting: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ProfileStore(file: root.appending(path: "profiles.json"))
        let work = store.add(name: "Work before send"), cloud = FakeSyncCloud(user: "synthetic-upload-owner")
        defer {
            try? FileManager.default.removeItem(at: work.supportDirectory)
            try? FileManager.default.removeItem(at: root)
        }
        let launch = VaultRemovalLaunch()
        let service = try launch.start(store, file: root.appending(path: "router.json"), cloud: cloud, host: FakeVaultHost(root: root), discovery: false)
        defer { service.prepareToTerminate() }
        let sharing = try #require(service.sharedSpaces)
        let id = try await sharing.publishProfile(work)
        try await sharing.refresh()
        let engine = try #require(launch.engine)
        let privateEdit = SharedSpaceItem(id: id, kind: .profile, profileID: id, title: "Unsent rename")
        sharing.catalog.stage(privateEdit, for: work.id)
        try #require(sharing.catalog.state.pending[privateEdit.recordID]?.item == privateEdit)
        let before = try #require(cloud.record(privateEdit.recordID))
        let old = CloudProfileInstance(.shared, id: id, owner: cloud.user)
        try await engine.publishRetirement(old)
        // The lookup for the retirement check fails, but the transport's following account lookup succeeds.
        if quitting {
            service.prepareToTerminate()
            await service.sendBeforeQuit()
            service.cancelTermination()
        } else {
            engine.duringAccountLookup = {
                engine.duringAccountLookup = nil
                throw URLError(.networkConnectionLost)
            }
            try await engine.sendNow()
        }
        #expect(cloud.record(privateEdit.recordID) == before)
        #expect(sharing.catalog.state.pending[privateEdit.recordID]?.item == privateEdit)
        await service.checkProfileInstances()
        #expect(store.cloudLedger.pending[work.id] == old)
    }
}
