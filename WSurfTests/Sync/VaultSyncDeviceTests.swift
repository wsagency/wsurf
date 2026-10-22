// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
import WSurfCore

@testable import WSurf
@testable import WSurfVault

// Vault sync through the real stores and managers (spec amendment 2026-10-22): two Macs of one profile id, over one fake cloud. Mac A is
// a hand-built store in its own folder; Mac B is the profile in the process-wide registry, where the app's own adoption runs. The
// passkeys are stubs that answer with the proof a test chooses, and the sync's hooks are called by the test unless a test installs
// `CloudSync.shared`. Serial: real stores, the manager registry and the process-wide `CloudSync.shared`.

/// A vault synced between two Macs. A made it; B adds it with the same passkey.
@MainActor
private final class Pair {
    let cloud = FakeSyncCloud()
    let profile: Profile
    /// The unlock passkey both Macs answer with: the same credential and the same PRF output.
    let proof: VaultUnlockProof
    let vaultID: UUID
    let envA: VaultTestEnvironment
    let storeA: ProfileVaultStore
    let managerA: CredentialManager
    let passkeysA: VaultPasskeys
    let passkeysB = VaultPasskeys()
    let clockA = TestClock()
    let clockB = TestClock()
    let syncA: VaultSync
    let syncB: VaultSync
    let engineA: FakeSyncEngine
    let engineB: FakeSyncEngine
    private(set) var managerB: CredentialManager?

    private init(
        profile: Profile, proof: VaultUnlockProof, vaultID: UUID, envA: VaultTestEnvironment, storeA: ProfileVaultStore,
        managerA: CredentialManager, passkeysA: VaultPasskeys
    ) {
        self.profile = profile
        self.proof = proof
        self.vaultID = vaultID
        self.envA = envA
        self.storeA = storeA
        self.managerA = managerA
        self.passkeysA = passkeysA
        passkeysA.adopt(proof)
        passkeysB.adopt(proof)
        let hostA = CredentialVaultSyncHost(
            profiles: { [profile] in [profile] },
            manager: { _, id in id == vaultID ? managerA : nil },
            directory: { _ in envA.directory }
        )
        syncA = VaultSync(host: hostA, state: VaultSyncAppState(), persist: { _ in }, excludedProfiles: [], clock: clockA)
        syncB = VaultSync(
            host: CredentialVaultSyncHost(profiles: { [profile] in [profile] }), state: VaultSyncAppState(), persist: { _ in },
            excludedProfiles: [], clock: clockB
        )
        engineA = FakeSyncEngine(cloud: cloud, delegate: syncA)
        engineB = FakeSyncEngine(cloud: cloud, delegate: syncB)
        syncA.attach(engineA)
        syncB.attach(engineB)
    }

    /// Mac A with its vault created and unlocked; Mac B with an empty profile in the registry.
    static func make() async throws -> Pair {
        let profile = try await VaultManagerFixture.newProfile("Sync")
        let env = try VaultTestEnvironment.make()
        let store = ProfileVaultStore(profileID: profile.id, directory: env.directory, defaults: env.defaults)
        let proof = VaultFixtures.proof(1)
        let lease = VaultAccess(profileID: profile.id, epoch: 1, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
        let vaultID = try await store.createVault(name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: lease))
        let passkeys = VaultPasskeys()
        let manager = VaultManagerFixture.manager(profileID: profile.id, vaultID: vaultID, store: store, passkeys: passkeys)
        try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())
        return Pair(profile: profile, proof: proof, vaultID: vaultID, envA: env, storeA: store, managerA: manager, passkeysA: passkeys)
    }

    func cleanup() async {
        // Close the sync databases before their folders go.
        syncA.profileErased(profile.id)
        syncB.profileErased(profile.id)
        await storeA.close()
        envA.cleanUp()
        await VaultManagerFixture.cleanup(profile)
    }

    // MARK: Entries

    func account(_ name: String, password: String = "pw") -> CredentialAccount {
        VaultFixtures.account(username: name, password: password, origin: "https://\(name).test")
    }

    /// Replaces the vault's entries with `accounts`.
    func save(_ accounts: [CredentialAccount], in manager: CredentialManager) async throws {
        let epoch = try #require(manager.authorizationEpoch)
        let revision = try await manager.snapshot().revision
        _ = try await manager.commit(accounts, expectedRevision: revision, authorizedEpoch: epoch)
    }

    func edit(_ manager: CredentialManager, _ id: UUID, _ change: (inout CredentialAccount) -> Void) async throws {
        let epoch = try #require(manager.authorizationEpoch)
        let snapshot = try await manager.snapshot()
        var accounts = snapshot.accounts
        let index = try #require(accounts.firstIndex { $0.id == id })
        change(&accounts[index])
        _ = try await manager.commit(accounts, expectedRevision: snapshot.revision, authorizedEpoch: epoch, changing: [id])
    }

    func accounts(_ manager: CredentialManager) async throws -> [UUID: CredentialAccount] {
        Dictionary(try await manager.snapshot().accounts.map { ($0.id, $0) }) { first, _ in first }
    }

    // MARK: Sync

    var statusA: VaultSyncStatus {
        syncA.status(profileID: profile.id, vaultID: vaultID)
    }

    var statusB: VaultSyncStatus {
        syncB.status(profileID: profile.id, vaultID: vaultID)
    }

    func enableA() async throws {
        try await syncA.enable(profileID: profile.id, vaultID: vaultID)
        try await pump()
    }

    func pump() async throws {
        for _ in 0..<5 {
            await syncA.settle()
            try await engineA.sendNow()
            await syncA.settle()
            await syncB.settle()
            try await engineB.sendNow()
            await syncB.settle()
        }
    }

    func converge() async throws {
        for _ in 0..<5 {
            try await pump()
            try await engineA.fetchNow()
            await syncA.settle()
            try await engineB.fetchNow()
            await syncB.settle()
        }
        try await pump()
    }

    /// The person wrote to a vault: the debounce passes and the sync produces.
    func wrote(_ sync: VaultSync, _ clock: TestClock) async {
        sync.noteWrite(profileID: profile.id, vaultID: vaultID)
        _ = await waitUntil { clock.pendingCount > 0 }
        clock.advance(by: .seconds(2))
        for _ in 0..<20 {
            await Task.yield()
        }
        await sync.settle()
    }

    /// What the app does for "Add to This Mac…": the passkey assertion, the adoption, then the sync.
    func addToB() async throws {
        try await engineB.fetchNow()
        await syncB.settle()
        let remote = try #require(syncB.remoteVaults(profileID: profile.id).first)
        let added = try await CredentialManager.adoptSyncedVault(
            profile: profile, remote: remote, in: VaultManagerFixture.anchor(), native: passkeysB.native
        )
        #expect(added == vaultID)
        await syncB.adopted(profileID: profile.id, vaultID: added)
        managerB = try CredentialManager.forVault(profile, vaultID: added, native: passkeysB.native)
    }

    func unlockB() async throws {
        let manager = try #require(managerB)
        try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())
        syncB.vaultUnlocked(profileID: profile.id, vaultID: vaultID)
        await syncB.settle()
    }
}

private func withPair(_ body: (Pair) async throws -> Void) async throws {
    let pair = try await Pair.make()
    do {
        try await body(pair)
    } catch {
        await pair.cleanup()
        throw error
    }
    await pair.cleanup()
}

@MainActor
@Suite(.serialized)
struct VaultSyncDeviceTests {
    // MARK: Two Macs, one passkey

    @Test func samePasskeyUnlocksAndConvergesBothWays() async throws {
        try await withPair { pair in
            let held = [pair.account("one"), pair.account("two")]
            try await pair.save(held, in: pair.managerA)
            try await pair.enableA()

            try await pair.addToB()
            #expect(pair.statusB == .waitingForUnlock(2))
            try await pair.unlockB()
            try await pair.pump()
            let managerB = try #require(pair.managerB)

            let onB = try await pair.accounts(managerB)
            #expect(Set(onB.keys) == Set(held.map(\.id)) && onB.values.allSatisfy { $0.password == "pw" })
            #expect(pair.passkeysB.assertions.count == 1, "one prompt to add the vault")
            #expect(managerB.lastKeyCheck != nil && managerB.lastKeyCheck == pair.managerA.lastKeyCheck, "the same key on both Macs")
            #expect(pair.statusB == .synced && pair.statusA == .synced)

            // B changes the password: A has it, and its History has the old one as a change from another device.
            let target = held[0].id
            try await pair.edit(managerB, target) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.converge()
            #expect(try await pair.accounts(pair.managerA)[target]?.password == "from B")
            let history = try await pair.managerA.revisionLog()[target] ?? []
            #expect(history.contains { $0.cause == CredentialChangeCause.sync })

            // A deletes it: it is in B's Trash, with the account.
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let revision = try await pair.managerA.snapshot().revision
            _ = try await pair.managerA.delete(.account(target), expectedRevision: revision, authorizedEpoch: epoch)
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            #expect(try await pair.accounts(managerB)[target] == nil)
            #expect(try await managerB.trashPage(after: nil).items.contains { $0.ownerID == target })
            #expect(try await pair.accounts(managerB).count == 1 && pair.statusB == .synced)
        }
    }

    @Test func differentPRFLeavesTheMacLockedAndUndamaged() async throws {
        try await withPair { pair in
            try await pair.save([pair.account("one")], in: pair.managerA)
            try await pair.enableA()
            // B already holds an unlocked vault, which authorizes the new one.
            let made = try await VaultManagerFixture.make(profile: pair.profile, passkeys: pair.passkeysB, vaults: [.unlocked])
            try await pair.engineB.fetchNow()
            await pair.syncB.settle()
            let remote = try #require(pair.syncB.remoteVaults(profileID: pair.profile.id).first)
            let other = VaultUnlockProof(credentialID: pair.proof.credentialID, prfInput: pair.proof.prfInput, prf: SymmetricKey(size: .bits256))
            pair.passkeysB.answer = other
            let before = VaultManagerFixture.image(of: pair.profile.supportDirectory)
            var reported: String?

            do {
                _ = try await CredentialManager.adoptSyncedVault(
                    profile: pair.profile, remote: remote, in: VaultManagerFixture.anchor(), native: pair.passkeysB.native
                )
            } catch CredentialManagerError.syncKeyDiffers(let keyCheck) {
                reported = keyCheck
            }

            #expect(reported == CredentialVaultCrypto.keyCheck(prf: other.prf, credentialID: other.credentialID))
            #expect(reported != pair.managerA.lastKeyCheck)
            // SQLite rewrites its shared-memory index (`-shm`) whenever a connection reads; it holds no data.
            @MainActor func image() -> [String: Data] {
                VaultManagerFixture.image(of: pair.profile.supportDirectory).filter { !$0.key.hasSuffix("-shm") }
            }
            #expect(image() == before.filter { !$0.key.hasSuffix("-shm") }, "not one byte of the store changed")
            let store = try CredentialManager.store(for: pair.profile)
            #expect(try await store.listing().count == 1 && made.vaults[0].manager.isUnlocked, "its other vault still unlocks")
            #expect(pair.statusB == .off)
        }
    }

    @Test func aVaultIsNeverAddedToAnotherProfileThanItsZoneNames() async throws {
        try await withPair { pair in
            try await pair.save([pair.account("one")], in: pair.managerA)
            try await pair.enableA()
            try await pair.engineB.fetchNow()
            await pair.syncB.settle()
            let remote = try #require(pair.syncB.remoteVaults(profileID: pair.profile.id).first)
            let stranger = try await VaultManagerFixture.newProfile("Stranger")
            defer { Task { await VaultManagerFixture.cleanup(stranger) } }
            let before = VaultManagerFixture.image(of: stranger.supportDirectory)

            for wrong in [stranger, Profile.privateBrowsing()] {
                do {
                    _ = try await CredentialManager.adoptSyncedVault(
                        profile: wrong, remote: remote, in: VaultManagerFixture.anchor(), native: pair.passkeysB.native
                    )
                    Issue.record("a vault was added to a profile its zone does not name")
                } catch CredentialManagerError.syncedVaultOfAnotherProfile {
                    // Refused before any prompt, so it is never mistaken for a key that differs.
                }
            }

            #expect(pair.passkeysB.assertions.isEmpty)
            #expect(VaultManagerFixture.image(of: stranger.supportDirectory) == before)
            #expect(pair.syncB.remoteVaults(profileID: stranger.id).isEmpty, "the card for that profile lists nothing")
        }
    }

    @Test func addingAProfileKeepsTheIDOfTheZone() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProfileStore(file: file)
        let zone = UUID()

        let adopted = store.adopt(id: zone, name: "  Work  ", symbol: "no.such.symbol", color: .teal)

        #expect(adopted?.id == zone && adopted?.name == "Work" && adopted?.symbol == "person" && adopted?.color == .teal)
        #expect(store.profiles.contains { $0.id == zone })
        #expect(store.adopt(id: zone, name: "Again", symbol: "person", color: .gray) == nil, "never twice")
        #expect(store.adopt(id: Profile.originalID, name: "Original", symbol: "person", color: .gray) == nil)
        #expect(store.adopt(id: Profile.privateID, name: "Private", symbol: "person", color: .gray) == nil)
        let long = store.adopt(id: UUID(), name: String(repeating: "n", count: 200), symbol: "briefcase", color: .gray)
        #expect(long?.name.count == 64 && long?.symbol == "briefcase")
        #expect(ProfileStore(file: file).profiles.contains { $0.id == zone }, "kept for the next launch")
    }

    // MARK: What stays on each Mac

    @Test func historyTrashAndPurgeStayPerMac() async throws {
        try await withPair { pair in
            let held = [pair.account("one"), pair.account("two")]
            try await pair.save(held, in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            let target = held[0].id

            let epoch = try #require(pair.managerA.authorizationEpoch)
            let revision = try await pair.managerA.snapshot().revision
            _ = try await pair.managerA.delete(.account(target), expectedRevision: revision, authorizedEpoch: epoch)
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            let onA = try await pair.managerA.trashPage(after: nil).items.map(\.id)
            let onB = try await managerB.trashPage(after: nil).items
            #expect(onA.count == 1 && onB.count == 1)

            // Emptying A's Trash is A's alone: nothing live changed, so nothing is sent, and B keeps its copy.
            let writes = pair.cloud.writeCount
            _ = try await pair.managerA.purge(entryIDs: onA, emptyAll: false, in: VaultManagerFixture.anchor())
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()

            #expect(try await pair.managerA.trashPage(after: nil).items.isEmpty)
            #expect(try await managerB.trashPage(after: nil).items.count == 1)
            #expect(pair.cloud.writeCount == writes)
            #expect(try await pair.accounts(managerB).count == 1 && pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    @Test func syncNeverPromptsOrExtendsTheLease() async throws {
        try await withPair { pair in
            let target = pair.account("one")
            try await pair.save([target], in: pair.managerA)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let deadline = try pair.managerA.currentAccess().deadline
            let assertions = pair.passkeysA.assertions.count

            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            try await pair.edit(managerB, target.id) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.converge()

            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == "from B")
            #expect(pair.passkeysA.assertions.count == assertions, "sync asked A for no passkey")
            #expect(pair.passkeysB.assertions.count == 1, "B was asked once, to add the vault")
            #expect(pair.managerA.authorizationEpoch == epoch)
            #expect(try pair.managerA.currentAccess().deadline == deadline, "no lease was extended or shortened")
        }
    }

    @Test func openEditorSaveAfterASyncedChangeIsRefused() async throws {
        try await withPair { pair in
            let target = pair.account("one")
            try await pair.save([target], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let opened = try await pair.managerA.snapshot()

            try await pair.edit(managerB, target.id) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.converge()
            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == "from B")

            var typed = opened.accounts
            typed[0].password = "typed on A"
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await pair.managerA.commit(typed, expectedRevision: opened.revision, authorizedEpoch: epoch, changing: [target.id])
            }
            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == "from B", "nothing was overwritten")
        }
    }

    @Test func inputHistoryAndFilesStayOnTheMac() async throws {
        try await withPair { pair in
            let source = FileManager.default.temporaryDirectory.appending(path: "scan-\(UUID().uuidString).txt")
            try Data("body-\(UUID().uuidString)".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            // Input History is a file beside the vault in the profile's folder: sync neither reads nor touches it.
            let history = pair.envA.directory.appending(path: "InputHistory/\(pair.vaultID.uuidString).wih")
            let historyMarker = Data("typed-\(UUID().uuidString)".utf8)
            try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
            try historyMarker.write(to: history)
            let file = try await pair.managerA.addAttachment(from: source)
            var entry = pair.account("one")
            entry.attachments = [file]
            try await pair.save([entry], in: pair.managerA)

            try await pair.enableA()

            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let record = try #require(pair.cloud.record(SyncRecordID(zone: zone, name: entry.id.uuidString)))
            let opened = try VaultSyncCodec.openItem(record.payload, accountID: entry.id, key: try await pair.managerA.syncKey())
            #expect(opened.account?.attachments == nil && opened.account?.username == entry.username)
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.pump()
            let managerB = try #require(pair.managerB)
            #expect(try await pair.accounts(managerB)[entry.id]?.attachments == nil, "the added vault has no files")
            #expect(try await pair.accounts(pair.managerA)[entry.id]?.attachments == [file], "this Mac keeps its own")
            #expect(pair.statusA == .synced && pair.statusB == .synced)
            for record in pair.cloud.records(in: zone) ?? [] {
                #expect(record.payload.range(of: historyMarker) == nil)
            }
            #expect(try Data(contentsOf: history) == historyMarker, "this Mac's Input History is untouched")
            let onB = VaultManagerFixture.image(of: pair.profile.supportDirectory)
            #expect(onB.keys.allSatisfy { !$0.hasPrefix("InputHistory") }, "and the other Mac got none")
        }
    }

    @Test(arguments: [true, false])
    func reviewChoicesKeepTheOtherVersionRecoverable(keepLocal: Bool) async throws {
        try await withPair { pair in
            let target = pair.account("one")
            try await pair.save([target], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            try await pair.edit(pair.managerA, target.id) { $0.password = "from A" }
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.pump()
            try await pair.edit(managerB, target.id) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.pump()
            #expect(pair.statusB == .needsReview(1))
            #expect(try await pair.accounts(managerB)[target.id]?.password == "from B", "nothing applied before the choice")

            try await pair.syncB.resolve(profileID: pair.profile.id, vaultID: pair.vaultID, accountIDs: [target.id], keepLocal: keepLocal)
            try await pair.converge()

            let winner = keepLocal ? "from B" : "from A"
            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == winner)
            #expect(try await pair.accounts(managerB)[target.id]?.password == winner)
            // The version not kept is in History on the Mac that had it, as a change from another device.
            let loser = keepLocal ? pair.managerA : managerB
            #expect(try await loser.revisionLog()[target.id]?.contains { $0.cause == CredentialChangeCause.sync } == true)
            #expect(pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    // MARK: The app's wiring

    private static func gate(tabs: Bool, vaults: Bool) -> CloudSyncGate.Inputs {
        let held = CloudTabsTests.Launch.entitlements
        return CloudSyncGate.Inputs(
            tabsFlag: tabs, vaultFlag: vaults, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { held[$0] }
        )
    }

    @Test func theVaultFlagAloneCreatesTheEngineAndTabsJoinItLater() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeSyncCloud()
        var engines: [FakeSyncEngine] = []
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite(UUID().uuidString))!
        let started = CloudSync.start(
            gate: Self.gate(tabs: true, vaults: true), installIDs: MemoryInstallIDStorage(), stateFile: directory.appending(path: "iCloudSync.json"),
            profiles: [.original()], host: { CredentialVaultSyncHost(profiles: { [] }) }, optInDefaults: { _ in defaults },
            windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, _ in
                let engine = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engines.append(engine)
                return engine
            }
        )
        let cloudSync = try #require(started)
        let tabs = try #require(cloudSync.tabs)
        #expect(engines.count == 1, "the vault flag is the consent to fetch")
        #expect(cloudSync.vaults != nil)

        tabs.setOptIn(true, for: .original())
        try await engines[0].sendNow()

        #expect(engines.count == 1, "one engine for both")
        #expect(cloud.record(SyncRecordID(zone: SyncZone.devices, name: tabs.sync.installID)) != nil, "tabs ride the same engine")
        cloudSync.prepareToTerminate()
    }

    @Test func onlyTheFlagsThatAreOnStartAFeature() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "iCloudSync.json")
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite(UUID().uuidString))!
        func start(tabs: Bool, vaults: Bool) -> CloudSync? {
            CloudSync.start(
                gate: Self.gate(tabs: tabs, vaults: vaults), installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [.original()],
                host: { CredentialVaultSyncHost(profiles: { [] }) }, optInDefaults: { _ in defaults }, windows: { [] }, clock: TestClock(),
                makeEngine: { delegate, _ in FakeSyncEngine(cloud: FakeSyncCloud(), delegate: delegate) }
            )
        }

        #expect(start(tabs: false, vaults: false) == nil)
        let tabsOnly = try #require(start(tabs: true, vaults: false))
        #expect(tabsOnly.tabs != nil && tabsOnly.vaults == nil)
        let vaultsOnly = try #require(start(tabs: false, vaults: true))
        #expect(vaultsOnly.tabs == nil && vaultsOnly.vaults != nil)
    }

    @Test func hooksReachTheSyncAndDeletionsDeleteTheirZones() async throws {
        let profile = try await VaultManagerFixture.newProfile("Hooks")
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let cloud = FakeSyncCloud()
        var engines: [FakeSyncEngine] = []
        let made: (profile: Profile, passkeys: VaultPasskeys, vaults: [FixtureVault])
        do {
            made = try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked, .unlocked])
        } catch {
            await VaultManagerFixture.cleanup(profile)
            throw error
        }
        let started = CloudSync.start(
            gate: Self.gate(tabs: false, vaults: true), installIDs: MemoryInstallIDStorage(), stateFile: directory.appending(path: "iCloudSync.json"),
            profiles: [profile], host: { CredentialVaultSyncHost(profiles: { [profile] }) }, clock: clock,
            makeEngine: { delegate, _ in
                let engine = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engines.append(engine)
                return engine
            }
        )
        let cloudSync = try #require(started)
        CloudSync.shared = cloudSync
        defer { CloudSync.shared = nil }
        let sync = try #require(cloudSync.vaults)
        let engine = try #require(engines.first)
        let (first, second) = (made.vaults[0], made.vaults[1])
        func zone(_ vault: FixtureVault) -> String {
            SyncZone.vault(profileID: profile.id, vaultID: vault.vaultID)
        }
        func send() async throws {
            for _ in 0..<4 {
                await sync.settle()
                try await engine.sendNow()
            }
        }

        try await sync.enable(profileID: profile.id, vaultID: first.vaultID)
        try await sync.enable(profileID: profile.id, vaultID: second.vaultID)
        try await send()
        #expect(cloud.zones[zone(first)] != nil && cloud.zones[zone(second)] != nil)

        // A write through the manager reaches the sync by itself (the hook in `writing`).
        let waiting = clock.pendingCount
        try await VaultManagerFixture.save([VaultFixtures.account(username: "hooked")], in: first)
        #expect(await waitUntil { clock.pendingCount > waiting }, "the write started the quiet moment")
        clock.advance(by: .seconds(2))
        for _ in 0..<20 {
            await Task.yield()
        }
        try await send()
        #expect(cloud.names(in: zone(first)).count == 2, "the vault record and the entry")

        // Deleting a vault deletes its zone, and only its zone (the hook after the store committed).
        let epoch = try #require(second.manager.authorizationEpoch)
        try await second.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())
        try await send()
        #expect(cloud.zones[zone(second)] == nil && cloud.zones[zone(first)] != nil)
        #expect(sync.status(profileID: profile.id, vaultID: second.vaultID) == .off)

        // Erasing the profile deletes the zones of the vaults it synced.
        await VaultManagerFixture.erase(profile)
        try await send()
        #expect(cloud.zones[zone(first)] == nil)
    }
}
