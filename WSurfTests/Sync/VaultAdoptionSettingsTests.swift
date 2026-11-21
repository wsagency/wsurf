// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import WSurf
@testable import WSurfCore
@testable import WSurfVault

@MainActor
@Suite(.serialized)
struct VaultAdoptionSettingsTests {
    @Test func losingVaultDiscoveryAfterConfirmationShowsAnErrorForEitherChoice() async throws {
        try await withDevicePair { pair in
            let setup = try await VaultManagerFixture.make(profile: pair.profile, passkeys: pair.passkeysB, vaults: [.unlocked])
            let vault = try #require(setup.vaults.first)
            let model = CredentialSettingsModel(profile: pair.profile, manager: vault.manager)
            await model.load()
            try #require(model.selectedVaultID == vault.vaultID)
            let unavailable = try #require(CredentialSettingsModel.message(for: VaultSyncFailure.unavailable))
            let previous = CloudSync.shared
            defer { CloudSync.shared = previous }
            CloudSync.shared = nil
            await model.removeVaultFromICloud(vaultID: vault.vaultID, confirmingAccount: pair.cloud.user)
            #expect(model.error == unavailable)
            model.error = nil
            await model.enableSync(vaultID: vault.vaultID, confirmingAccount: pair.cloud.user)
            #expect(model.error == unavailable)
        }
    }

    @Test(arguments: [false, true])
    func aPasskeyCreatedVaultOffersExplicitRetryAfterRelaunch(enrollmentWriteFails: Bool) async throws {
        try await withDevicePair { pair in
            let made = try await VaultManagerFixture.make(profile: pair.profile, passkeys: pair.passkeysB, vaults: [.unlocked])
            let independent = try #require(made.vaults.first)
            let local = pair.account("only-on-this-mac")
            _ = try await VaultManagerFixture.save([local], in: independent)
            let incoming = pair.account("from-another-mac")
            try await pair.save([incoming], in: pair.managerA)
            try await pair.enableA()

            let file = pair.envA.directory.appending(path: "settings-router.json")
            @MainActor func launch() throws -> CloudSync {
                let gate = CloudSyncGate.Inputs(
                    tabsFlag: false, vaultFlag: false, isRunningTests: false, isStaged: false, ownsSession: true,
                    entitlement: { CloudTabsTests.Launch.entitlements[$0] }, offersMacSync: true
                )
                let started = CloudSync.start(
                    gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [], host: { CredentialVaultSyncHost(profiles: { [pair.profile] }) },
                    windows: { [] }, clock: TestClock(), makeEngine: { delegate, _ in FakeSyncEngine(cloud: pair.cloud, delegate: delegate) }
                )
                let app = try #require(started)
                CloudSync.shared = app
                return app
            }
            defer {
                CloudSync.shared?.prepareToTerminate()
                CloudSync.shared = nil
            }
            let first = try launch()
            first.setVaultDiscovery(true)
            let model = CredentialSettingsModel(profile: pair.profile, native: pair.passkeysB.native)
            await model.load()
            try #require(await waitUntil { model.addableSyncedVaults.count == 1 })
            let remote = try #require(model.addableSyncedVaults.first)
            pair.passkeysB.beforeAssert = {
                if enrollmentWriteFails {
                    let db = try #require(try VaultSyncDatabase.open(directory: pair.profile.supportDirectory, create: false))
                    try db.write { tx in
                        try tx.db.execute(sql: """
                            CREATE TRIGGER refuse_enrollment BEFORE INSERT ON vault WHEN NEW.enabled = 1
                            BEGIN SELECT RAISE(ABORT, 'fixture enrollment failure'); END
                            """)
                    }
                } else {
                    first.setVaultDiscovery(false)
                }
            }
            await model.addSyncedVault(remote, in: VaultManagerFixture.anchor())
            pair.passkeysB.beforeAssert = nil
            #expect(model.vaults.contains { $0.vaultID == remote.vaultID })
            #expect(!model.vaultIsSyncedHere(remote.vaultID))
            if enrollmentWriteFails {
                #expect(model.retryableSyncedVaults.map(\.id) == [remote.vaultID])
                let db = try #require(try VaultSyncDatabase.open(directory: pair.profile.supportDirectory, create: false))
                try db.write { try $0.db.execute(sql: "DROP TRIGGER refuse_enrollment") }
                first.setVaultDiscovery(false)
            }
            first.prepareToTerminate()

            let restarted = try launch()
            let page = CredentialSettingsModel(profile: pair.profile, native: pair.passkeysB.native)
            await page.load()
            #expect(restarted.vaults == nil && page.retryableSyncedVaults.isEmpty)
            restarted.setVaultDiscovery(true)
            try #require(await waitUntil { page.retryableSyncedVaults.map(\.id) == [remote.vaultID] })
            let sync = try #require(restarted.vaults)
            #expect(sync.status(profileID: pair.profile.id, vaultID: remote.vaultID) == .off)
            #expect(page.addableSyncedVaults.isEmpty && !sync.hasSyncedVaults(profileID: pair.profile.id))
            @MainActor func cardHeight() -> CGFloat {
                let card = VaultSyncCard(model: page, withWindow: { _ in }, showSettings: {})
                let view = NSHostingView(rootView: card.frame(width: 600))
                view.layoutSubtreeIfNeeded()
                return view.fittingSize.height
            }
            #expect(cardHeight() > 20)
            let retry = try #require(page.retryableSyncedVaults.first)
            await page.retrySyncedVault(retry, in: VaultManagerFixture.anchor())
            await sync.settle()

            #expect(sync.isSyncing(profileID: pair.profile.id, vaultID: remote.vaultID))
            #expect(page.retryableSyncedVaults.isEmpty && cardHeight() < 1)
            let joined = try CredentialManager.forVault(pair.profile, vaultID: remote.vaultID, native: pair.passkeysB.native)
            #expect(try await pair.accounts(joined)[incoming.id]?.password == incoming.password)
            #expect(!sync.isSyncing(profileID: pair.profile.id, vaultID: independent.vaultID))
            #expect(try await pair.accounts(independent.manager)[local.id]?.password == local.password)
            #expect(pair.cloud.records(in: SyncZone.vault(profileID: pair.profile.id, vaultID: independent.vaultID)) == nil)
        }
    }
}
