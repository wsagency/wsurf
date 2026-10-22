// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

/// The one delegate of the one engine: it owns the engine's state, hands each zone to the feature it belongs to and drops what no
/// running feature owns.
@MainActor
struct SyncRouterTests {
    private final class Saved {
        var router: SyncRouterState?
        weak var current: SyncRouter?
    }

    private final class Setup {
        let cloud = FakeSyncCloud()
        let personal = UUID()
        let saved = Saved()
        let host: FakeVaultHost
        let tabs: TabSync?
        let vaults: VaultSync?
        let router: SyncRouter
        let engine: FakeSyncEngine
        let directory = FileManager.default.temporaryDirectory.appending(path: "router-\(UUID().uuidString)", directoryHint: .isDirectory)

        init(tabs withTabs: Bool = true, vaults withVaults: Bool = true, state: SyncRouterState = SyncRouterState()) {
            host = FakeVaultHost(root: directory)
            let saved = saved
            tabs = withTabs
                ? TabSync(
                    installID: "install-router", device: DeviceInfo(name: "Router Mac", kind: .mac, appVersion: "0.1.7"), state: TabSyncState(),
                    persist: { _ in }
                )
                : nil
            vaults = withVaults
                ? VaultSync(
                    host: host, state: state.vaults, persist: { saved.current?.setVaults($0) }, excludedProfiles: [], debounce: .seconds(2)
                )
                : nil
            router = SyncRouter(state: state, persist: { saved.router = $0 }, tabs: tabs, vaults: vaults)
            saved.current = router
            engine = FakeSyncEngine(cloud: cloud, delegate: router)
            tabs?.reconcile(sharing: [personal])
            tabs?.attach(engine)
            vaults?.attach(engine)
        }

        func finish() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Another Mac that shares its tabs and syncs a vault, so both kinds of record are in the cloud.
    private func otherMac(in cloud: FakeSyncCloud, personal: UUID, directory: URL) async throws -> (zone: String, vault: UUID) {
        let device = SyncDevice(cloud: cloud, installID: "install-other", name: "Ana’s iPad")
        device.start(sharing: [personal])
        device.sync.share(SyncSamples.session(tabs: ["https://other.test/"]), profileID: personal, force: false)
        try await device.engine.sendNow()

        let mac = SimulatedMac(cloud: cloud, root: directory.appending(path: "other", directoryHint: .isDirectory))
        let vault = try mac.host.addVault(profile: personal, name: "Other")
        vault.add(SyncVaultFixtures.account())
        mac.start()
        try await mac.sync.enable(profileID: personal, vaultID: vault.vaultID)
        try await mac.pump()
        return (SyncZone.vault(profileID: personal, vaultID: vault.vaultID), vault.vaultID)
    }

    @Test func engineStateBelongsToTheRouterAndSurvivesARelaunch() async throws {
        let setup = Setup()
        defer { setup.finish() }

        try await setup.engine.fetchNow()

        let state = try #require(setup.saved.router?.engineState)
        #expect(setup.router.state.engineState == state)
        let relaunched = SyncRouter(state: SyncRouterState(engineState: state), persist: { _ in }, tabs: nil, vaults: nil)
        #expect(relaunched.state.engineState == state)
        let json = try JSONEncoder().encode(TabSyncState())
        #expect(String(decoding: json, as: UTF8.self).contains("engineState") == false, "tab sync keeps none of it")
    }

    @Test func eachZoneGoesToTheFeatureThatOwnsIt() async throws {
        let setup = Setup()
        defer { setup.finish() }
        let (zone, vaultID) = try await otherMac(in: setup.cloud, personal: setup.personal, directory: setup.directory)

        try await setup.engine.fetchNow()
        await setup.vaults?.settle()

        #expect(setup.tabs?.remoteSessions(profileID: setup.personal, fallbackLabel: "Device").count == 1)
        #expect(setup.vaults?.state.remote.keys.sorted() == [zone])
        #expect(setup.vaults?.remoteVaults(profileID: setup.personal).map(\.vaultID) == [vaultID])
        #expect(setup.tabs?.state.sessions.keys.contains(zone) == false)
        #expect(setup.saved.router?.vaults.remote.keys.sorted() == [zone], "the vault cache rides in the router's file")
    }

    @Test func recordsAreAnsweredByTheirOwnFeatureOnly() async throws {
        let setup = Setup()
        defer { setup.finish() }
        let tabRecord = SyncRecordID(zone: SyncZone.profile(setup.personal), name: "install-router")
        setup.tabs?.share(SyncSamples.session(tabs: ["https://mine.test/"]), profileID: setup.personal, force: false)

        #expect(setup.router.record(for: tabRecord)?.type == .deviceSession)
        #expect(setup.router.record(for: SyncRecordID(zone: SyncZone.vault(profileID: setup.personal, vaultID: UUID()), name: "vault")) == nil)
        #expect(setup.router.record(for: SyncRecordID(zone: "somewhere", name: "install-router")) == nil)
    }

    @Test func aFeatureThatIsNotRunningNeverSeesAnotherOnesRecords() async throws {
        let withoutVaults = Setup(vaults: false)
        defer { withoutVaults.finish() }
        let (zone, _) = try await otherMac(in: withoutVaults.cloud, personal: withoutVaults.personal, directory: withoutVaults.directory)

        try await withoutVaults.engine.fetchNow()

        #expect(withoutVaults.tabs?.remoteSessions(profileID: withoutVaults.personal, fallbackLabel: "Device").count == 1)
        #expect(withoutVaults.tabs?.state.sessions[zone] == nil && withoutVaults.saved.router?.vaults.remote.isEmpty != false)

        let withoutTabs = Setup(tabs: false)
        defer { withoutTabs.finish() }
        _ = try await otherMac(in: withoutTabs.cloud, personal: withoutTabs.personal, directory: withoutTabs.directory)

        try await withoutTabs.engine.fetchNow()

        #expect(withoutTabs.vaults?.state.remote.count == 1)
        #expect(withoutTabs.router.record(for: SyncRecordID(zone: SyncZone.profile(withoutTabs.personal), name: "install-router")) == nil)
    }

    @Test func anAccountChangeReachesBothFeatures() async throws {
        let setup = Setup()
        defer { setup.finish() }

        await setup.engine.simulateAccount(.signIn(user: "user-1"))

        #expect(setup.tabs?.state.accountUser == "user-1")
        #expect(setup.vaults?.state.accountUser == "user-1")
    }
}
