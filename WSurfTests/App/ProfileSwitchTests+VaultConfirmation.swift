// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import WSurf
@testable import WSurfCore

extension ProfileSwitchTests {
    @MainActor
    private struct VaultConfirmationFixture {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let work: Profile
        let vaults: [FixtureVault]
        let catalog: ProfileStore
        let cloud = FakeSyncCloud(user: "synthetic-owner")
        let launch = VaultRemovalLaunch()
        let app: CloudSync

        var file: URL {
            root.appending(path: "profiles.json")
        }
        var router: URL {
            root.appending(path: "iCloudSync.json")
        }

        init(_ profile: Profile, _ vaults: [FixtureVault]) throws {
            self.vaults = vaults
            let store = ProfileStore(file: root.appending(path: "profiles.json"))
            catalog = store
            work = try #require(store.adopt(id: profile.id, name: "Work", symbol: "key", color: .blue))
            app = try launch.start(store, file: root.appending(path: "iCloudSync.json"), cloud: cloud, host: CredentialVaultSyncHost(profiles: { store.profiles }), discovery: true)
        }

        func publish() async throws {
            let sync = try #require(app.vaults)
            try #require(await waitUntil { sync.engine != nil })
            let engine = try #require(launch.engine)
            for vault in vaults {
                try await sync.enable(profileID: work.id, vaultID: vault.vaultID)
            }
            for _ in 0..<4 {
                await sync.settle()
                try await engine.sendNow()
            }
        }

        func zone(_ vault: FixtureVault) -> String {
            SyncZone.vault(profileID: work.id, vaultID: vault.vaultID)
        }

        func confirmInSettings(
            names: [String], retryNames: [String]? = nil, recoverAfterError: (() async throws -> Void)? = nil,
            beforePress: () async throws -> Void
        ) async throws {
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()), profiles: .selection(profile: .original(), catalog: catalog))
            defer { coordinator.closeWindow() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: VStack {
                ProfileSettings(coordinator: coordinator)
            }.environment(\.accessibilityEnabled, true))
            window.contentView = host
            window.orderBack(nil)

            func element(_ node: AnyObject, role: NSAccessibility.Role, containing name: String) -> AnyObject? {
                if node.accessibilityRole?() == role {
                    let value: String? = role == .staticText ? node.accessibilityValue?() : nil
                    if [node.accessibilityLabel?(), node.accessibilityTitle?(), value].contains(where: { $0?.contains(name) == true }) {
                        return node
                    }
                }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = element(child as AnyObject, role: role, containing: name) {
                        return match
                    }
                }
                return nil
            }

            func press(_ name: String, in view: NSView) async throws {
                try #require(await waitUntil { element(view, role: .button, containing: name) != nil })
                let button = try #require(element(view, role: .button, containing: name))
                _ = button.accessibilityPerformPress?()
            }

            func confirm(names: [String], beforePress: () async throws -> Void) async throws {
                try await press(String(localized: "Delete profile…"), in: host)
                try #require(await waitUntil { window.attachedSheet?.contentView != nil })
                let sheet = try #require(window.attachedSheet?.contentView)
                if names.isEmpty {
                    let unreadable = String(localized: "Its credential files can’t be read right now, so they may contain recoverable items. They are erased with it and WSurf can’t undo this.")
                    #expect(element(sheet, role: .staticText, containing: unreadable) != nil)
                } else {
                    let expected = names.formatted(.list(type: .and))
                    let message = String(
                        localized: "WSurf will also remove \(expected) from iCloud. Your other devices keep their copies. To keep a vault in iCloud, turn off Sync with iCloud for it first."
                    )
                    #expect(element(sheet, role: .staticText, containing: message) != nil)
                }
                try await beforePress()
                try await press(String(localized: "Delete profile"), in: sheet)
            }

            try await press(work.name, in: host)
            try await confirm(names: names, beforePress: beforePress)
            if let recoverAfterError {
                let error = String(localized: "WSurf couldn’t read this profile’s vault list. Try deleting the profile again.")
                try #require(await waitUntil {
                    host.layoutSubtreeIfNeeded()
                    return !catalog.profiles.contains(work) || element(host, role: .staticText, containing: error) != nil
                })
                try #require(catalog.profiles.contains(work), "A failed read must keep the profile named in the confirmation.")
                #expect(element(host, role: .staticText, containing: error) != nil)
                try await recoverAfterError()
                try await confirm(names: retryNames ?? names) {}
            }
            try #require(await waitUntil { !catalog.profiles.contains(work) && !FileManager.default.fileExists(atPath: work.supportDirectory.path) })
        }

        func confirm(_ warned: Set<VaultProfileRemoval>) async throws {
            let window = AppCoordinator(browser: BrowserModel(context: .shared(for: .original()), windowID: UUID()),
                                        profiles: .selection(profile: .original(), catalog: catalog))
            try await window.deleteProfile(work, confirmedVaults: warned).get()
        }
    }

    private func withVaultConfirmation(_ body: (VaultConfirmationFixture) async throws -> Void) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let fixture = try VaultConfirmationFixture(profile, vaults)
            let previous = CloudSync.shared
            CloudSync.shared = fixture.app
            defer {
                fixture.app.prepareToTerminate()
                CloudSync.shared = previous
                try? FileManager.default.removeItem(at: fixture.root)
            }
            try await fixture.publish()
            try await body(fixture)
        }
    }

    @Test(arguments: [false, true])
    func theProfileDeletionWarningAndConfirmationRequireALiveLocalVault(removedAfterWarning: Bool) async throws {
        try await withVaultConfirmation { f in
            let removed = f.vaults[0], live = f.vaults[1]
            let zone = f.zone(removed), contents = try #require(f.cloud.records(in: zone))
            f.app.setVaultDiscovery(false)
            let epoch = try #require(removed.manager.authorizationEpoch)
            if !removedAfterWarning {
                try await removed.manager.deleteEmptyVault(authorizedEpoch: epoch)
            }
            try await f.confirmInSettings(names: removedAfterWarning ? ["Vault 1", "Vault 2"] : ["Vault 2"]) {
                if removedAfterWarning {
                    try await removed.manager.deleteEmptyVault(authorizedEpoch: epoch)
                }
            }
            try #require(await waitUntil { f.cloud.zones[f.zone(live)] == nil })
            #expect(f.cloud.records(in: zone) == contents)
        }
    }

    @Test func initiallyUnreadableLocalVaultsKeepTheirCloudCopiesAfterConfirmation() async throws {
        try await withVaultConfirmation { f in
            f.app.setVaultDiscovery(false)
            let store = f.work.supportDirectory.appending(path: "Credentials.store")
            try FileManager.default.moveItem(at: store, to: f.root.appending(path: "saved-store"))
            try Data("unreadable synthetic store".utf8).write(to: store)
            try await f.confirmInSettings(names: []) {}
            #expect(f.catalog.vaultRemovals.isEmpty)
            #expect(f.vaults.allSatisfy { f.cloud.records(in: f.zone($0))?.isEmpty == false })
        }
    }

    enum UnavailableVaultList: CaseIterable { case unreadableStore, missingEnrollment, emptyEnrollment }

    @Test(arguments: UnavailableVaultList.allCases)
    func anUnreadableVaultListAtConfirmationKeepsWorkUntilSettingsRetries(fault: UnavailableVaultList) async throws {
        try await withVaultConfirmation { f in
            let sharing = try #require(f.app.sharedSpaces), settings = try #require(f.app.settingsSync)
            let linked = try await sharing.publishProfile(f.work)
            try await settings.enable(.providers, localProfileID: f.work.id, cloudProfileID: linked)
            let engine = try #require(f.launch.engine)
            engine.offline = true
            let edit = SharedSpaceItem(id: linked, kind: .profile, profileID: linked, title: "Unsent Work rename")
            sharing.catalog.stage(edit, for: f.work.id)
            try #require(sharing.catalog.state.pending[edit.recordID]?.item == edit)
            let copies = try f.vaults.map { try #require(f.cloud.records(in: f.zone($0))) }
            let files = FileManager.default
            let store = f.work.supportDirectory.appending(path: fault == .unreadableStore ? "Credentials.store" : VaultSyncDatabase.fileName)
            let saved = f.root.appending(path: "saved-store")
            let optOut = fault == .unreadableStore
            try await f.confirmInSettings(names: ["Vault 1", "Vault 2"], retryNames: optOut ? ["Vault 2"] : nil, recoverAfterError: {
                #expect(ProfileStore(file: f.file).profiles.contains(f.work) && f.catalog.vaultRemovals.isEmpty)
                #expect(settings.isEnabled(.providers, localProfileID: f.work.id))
                #expect(sharing.links[f.work.id]?.profile == linked && sharing.catalog.state.pending[edit.recordID]?.item == edit)
                #expect(f.vaults.map { f.cloud.records(in: f.zone($0)) } == copies)
                if fault == .emptyEnrollment {
                    #expect(try Data(contentsOf: store).isEmpty, "Reading approvals must not initialize an empty database.")
                }
                if fault != .missingEnrollment {
                    try files.removeItem(at: store)
                }
                try files.moveItem(at: saved, to: store)
                if optOut {
                    let sync = try #require(f.app.vaults)
                    try sync.disable(profileID: f.work.id, vaultID: f.vaults[0].vaultID)
                }
            }) {
                try files.moveItem(at: store, to: saved)
                switch fault {
                case .unreadableStore:
                    try Data("unreadable synthetic store".utf8).write(to: store)
                case .emptyEnrollment:
                    try Data().write(to: store)
                case .missingEnrollment:
                    break
                }
            }
            try #require(f.catalog.vaultRemovals.count == (optOut ? 1 : 2))
            #expect(!settings.isEnabled(.providers, localProfileID: f.work.id))
            engine.offline = false
            try #require(await waitUntil { f.app.beat(); return f.catalog.vaultRemovals.isEmpty })
            #expect(f.cloud.zones[f.zone(f.vaults[1])] == nil)
            #expect(f.cloud.records(in: f.zone(f.vaults[0])) == (optOut ? copies[0] : nil))
        }
    }

    @Test func aReadWithNoRemainingApprovalsAllowsTheConfirmedDeletion() async throws {
        try await withVaultConfirmation { f in
            let sync = try #require(f.app.vaults)
            let copies = try f.vaults.map { try #require(f.cloud.records(in: f.zone($0))) }
            try await f.confirmInSettings(names: ["Vault 1", "Vault 2"]) {
                for vault in f.vaults {
                    try sync.disable(profileID: f.work.id, vaultID: vault.vaultID)
                }
            }
            #expect(f.catalog.vaultRemovals.isEmpty)
            #expect(f.vaults.map { f.cloud.records(in: f.zone($0)) } == copies)
        }
    }

    @Test(arguments: [false, true])
    func readingAnOlderVaultCheckpointPreservesItsSchemaAndExplicitConsent(hasExplicitConsent: Bool) throws {
        let files = FileManager.default, root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let profile = UUID(), vault = UUID(), owner = "synthetic-owner"
        do {
            let store = try #require(try VaultSyncDatabase.open(directory: root, create: true))
            try store.write { tx in
                try tx.save(VaultRow(vaultID: vault, approvedUser: owner))
                // Restore the released v5 schema with or without the subsequent explicit-consent migration.
                try tx.db.execute(sql: """
                    DROP INDEX pendingItemAssets;
                    ALTER TABLE base DROP COLUMN pendingAssetCheck;
                    ALTER TABLE base DROP COLUMN assetCheckEnvelope;
                    ALTER TABLE inbox DROP COLUMN serverTime;
                    ALTER TABLE inbox DROP COLUMN serverCheck;
                    ALTER TABLE outbox DROP COLUMN assetPublication;
                    DELETE FROM grdb_migrations WHERE identifier NOT IN ('v1', 'v2', 'v3', 'v4', 'v5', 'vaultExplicitConsent');
                    """)
                if !hasExplicitConsent {
                    try tx.db.execute(sql: """
                        UPDATE vault SET approvedUser = consentUser;
                        ALTER TABLE vault DROP COLUMN consentUser;
                        DELETE FROM grdb_migrations WHERE identifier = 'vaultExplicitConsent';
                        """)
                }
            }
        }
        let file = root.appending(path: VaultSyncDatabase.fileName), before = try Data(contentsOf: file)
        let approvals = try VaultProfileRemoval.approved(in: root, profileID: profile, localVaults: [vault])
        let expected = VaultProfileRemoval(profileID: profile, vaultID: vault, owner: owner)
        #expect(approvals == (hasExplicitConsent ? [expected] : []))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func aFailedVaultOptOutShowsTheErrorAndTheCommittedToggle() async throws {
        try await withVaultConfirmation { f in
            let vault = f.vaults[0], sync = try #require(f.app.vaults)
            let model = CredentialSettingsModel(profile: f.work, manager: vault.manager)
            await model.load()
            try #require(model.selectedVaultID == vault.vaultID)
            let db = try #require(try VaultSyncDatabase.open(directory: f.work.supportDirectory, create: false))
            try db.write { tx in
                try tx.db.execute(sql: """
                    CREATE TRIGGER refuse_opt_out BEFORE DELETE ON vault
                    BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END
                    """)
            }
            #expect(throws: DatabaseError.self) { try model.disableSync(vaultID: vault.vaultID).get() }
            #expect(model.error == String(localized: "WSurf couldn’t save this change. Try again."))
            #expect(CloudVaultRow.isOn(sync.status(profileID: f.work.id, vaultID: vault.vaultID)))
            #expect(try db.read { try $0.vault(vault.vaultID)?.enabled } == true)
            try db.write { try $0.db.execute(sql: "DROP TRIGGER refuse_opt_out") }
            try model.disableSync(vaultID: vault.vaultID).get()
            #expect(model.error == nil && !CloudVaultRow.isOn(sync.status(profileID: f.work.id, vaultID: vault.vaultID)))
            let warning = try await CredentialErasureNote.warning(for: f.work).vaultRemovals
            #expect(!warning.contains { $0.vaultID == vault.vaultID })
            try await f.confirm(warning)
            try #require(await waitUntil { f.cloud.zones[f.zone(f.vaults[1])] == nil })
            #expect(f.cloud.zones[f.zone(vault)] != nil)
        }
    }

    @Test func relaunchAfterCloudDeletionKeepsAFreshlyPublishedCopyOfTheVault() async throws {
        try await withVaultConfirmation { f in
            let vault = f.vaults[0], zone = f.zone(vault), files = FileManager.default
            let engine = try #require(f.launch.engine)
            engine.offline = true
            let warning = try await CredentialErasureNote.warning(for: f.work).vaultRemovals
            try await f.confirm(warning)
            let saved = f.root.appending(path: "before-receipt")
            var deletes = 0
            f.cloud.afterZoneDeletion = { name in
                guard name == zone else { return }
                deletes += 1
                do {
                    try files.moveItem(at: f.file, to: saved)
                    try files.createDirectory(at: f.file, withIntermediateDirectories: false)
                } catch {
                    Issue.record(error)
                }
            }
            engine.offline = false
            try #require(await waitUntil { f.app.beat(); return deletes == 1 })
            try #require(f.cloud.zones[zone] == nil && files.fileExists(atPath: saved.path))
            f.app.prepareToTerminate()
            f.cloud.afterZoneDeletion = nil

            let other = SimulatedMac(cloud: f.cloud, root: f.root.appending(path: "other-mac"))
            let fresh = try other.host.addVault(profile: f.work.id, vault: vault.vaultID, name: "Recreated on another Mac")
            fresh.add(syncAccounts(1)[0])
            other.start()
            try await other.sync.enable(profileID: f.work.id, vaultID: vault.vaultID)
            try await other.pump()
            let contents = try #require(f.cloud.records(in: zone))
            try #require(contents.count == 2)
            try files.removeItem(at: f.file)
            try files.moveItem(at: saved, to: f.file)
            let reopened = ProfileStore(file: f.file)
            let launch = VaultRemovalLaunch()
            let next = try launch.start(reopened, file: f.router, cloud: f.cloud, host: CredentialVaultSyncHost(profiles: { reopened.profiles }), discovery: false)
            defer { next.prepareToTerminate() }
            #expect(await waitUntil { next.beat(); return reopened.vaultRemovals.isEmpty })
            #expect(f.cloud.records(in: zone) == contents)
        }
    }
}
