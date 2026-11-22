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

extension VaultAdoptionSettingsTests {
    private struct MergeFixture {
        let pair: DevicePair
        let source: FixtureVault
        let model: CredentialSettingsModel
        let local: VaultMergeSource
        let destination: CredentialManager
        let sync: VaultSync
        let engine: FakeSyncEngine
        let clock: TestClock

        func review() async throws -> VaultMergeReview {
            try await model.reviewVaultMerge(from: local, in: VaultManagerFixture.anchor())
        }
    }

    /// A holds the shared vault; B adopted it and also holds a separately created local profile.
    private func withMergeFixture(
        scopedInstance: Bool = false, spaceSelected: Bool = false,
        verify: @escaping @MainActor (String) async throws -> Void = { _ in },
        _ body: (MergeFixture) async throws -> Void
    ) async throws {
        try await withDevicePair { pair in
            try await VaultManagerFixture.with(vaults: [.unlocked]) { sourceProfile, _, local in
                let instance = scopedInstance ? UUID() : nil
                let owner = pair.cloud.user
                if let instance {
                    let profileID = pair.profile.id
                    pair.syncA.profileInstance = { profile, user in profile == profileID && user == owner ? instance : nil }
                    pair.syncB.profileInstance = pair.syncA.profileInstance
                }
                try await pair.save([pair.account("shared"), pair.account("same"), pair.account("work", password: "on-A")], in: pair.managerA)
                try await pair.enableA()
                try await pair.addToB()
                try await pair.unlockB()
                try await pair.converge()
                pair.syncB.pauseDiscovery()
                let target = try #require(pair.managerB)
                let root = pair.envA.directory
                let catalog = ProfileStore(file: root.appending(path: "merge-profiles.json"))
                for profile in [pair.profile, sourceProfile] {
                    _ = try #require(catalog.adopt(id: profile.id, name: "Work", symbol: "key", color: .blue))
                }
                if let instance {
                    try catalog.updateCloudLedger { $0.active[pair.profile.id, default: [:]][owner] = instance }
                }
                let clock = TestClock()
                let gate = CloudSyncGate.Inputs(
                    tabsFlag: false, vaultFlag: true, isRunningTests: false, isStaged: false, ownsSession: true,
                    entitlement: { CloudTabsTests.Launch.entitlements[$0] }, offersMacSync: true
                )
                let profiles = [pair.profile, sourceProfile]
                let started = CloudSync.start(
                    gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: root.appending(path: "merge-router.json"),
                    profiles: profiles, profileStore: catalog, host: { CredentialVaultSyncHost(profiles: { profiles }) },
                    windows: { [] }, clock: clock, makeEngine: { delegate, _ in FakeSyncEngine(cloud: pair.cloud, delegate: delegate) }
                )
                let app = try #require(started)
                let previous = CloudSync.shared
                CloudSync.shared = app
                defer {
                    app.prepareToTerminate()
                    CloudSync.shared = previous
                }
                let model = CredentialSettingsModel(profile: pair.profile, spaceVaultID: spaceSelected ? target.vaultID : nil, verifyUser: verify)
                await model.load()
                try #require(await waitUntil { model.canMergeIntoSharedVault })
                let sync = try #require(app.vaults)
                let engine = try #require(app.engine as? FakeSyncEngine)
                let sources = try await model.mergeSources()
                let chosen = try #require(sources.first { $0.id.profileID == sourceProfile.id && $0.id.vaultID == local[0].vaultID })
                #expect(!sources.contains { $0.id.profileID == pair.profile.id && $0.id.vaultID == target.vaultID })
                try await body(MergeFixture(pair: pair, source: local[0], model: model, local: chosen, destination: target, sync: sync, engine: engine, clock: clock))
            }
        }
    }

    @Test func reviewedCopyPreservesTheSourceAndConvergesWithThePublishingMac() async throws {
        var confirmations = 0
        try await withMergeFixture(spaceSelected: true, verify: { _ in confirmations += 1 }) { f in
            var fresh = f.pair.account("new")
            let same = f.pair.account("same"), conflict = f.pair.account("work", password: "on-B")
            let input = f.pair.envA.directory.appending(path: "example.txt")
            let fileBytes = Data("synthetic attachment".utf8)
            try fileBytes.write(to: input)
            fresh.attachments = [try await f.source.manager.addAttachment(from: input)]
            fresh.passkeys = [try VaultFixtures.passkey(rpID: "new.test")]
            fresh.notes = [.init(text: "synthetic note")]
            try await VaultManagerFixture.save([fresh, same, conflict], in: f.source)
            let sourceDirectory = await f.source.manager.store.directory
            let bytes = try VaultManagerFixture.rows(of: f.source.vaultID, inDirectory: sourceDirectory)
            let before = try await f.destination.snapshot()
            let cancelled = try await f.review()
            #expect(cancelled.rows.count == 3)
            #expect(try await f.destination.snapshot().stamps == before.stamps && confirmations == 0)
            let review = try await f.review()
            #expect(review.rows.first { $0.id == same.id }?.kind == .duplicate)
            #expect(review.rows.first { $0.id == conflict.id }?.kind == .conflict)
            let choices: [UUID: CredentialVaultMergePlan.Choice] = [fresh.id: .copy, same.id: .skip, conflict.id: .replace]
            #expect(try await f.model.confirmVaultMerge(review, choices: choices) == 2)
            #expect(confirmations == 1)
            #expect(try VaultManagerFixture.rows(of: f.source.vaultID, inDirectory: sourceDirectory) == bytes)
            let repeated = try await f.review()
            #expect(repeated.rows.allSatisfy { $0.kind == .duplicate })
            // The real Settings commit already scheduled a write. The router's heartbeat shares this clock.
            await f.clock.run(for: .seconds(2), step: .milliseconds(100))
            await f.sync.settle()
            for _ in 0..<4 {
                try await f.engine.sendNow()
                await f.sync.settle()
                try await f.engine.fetchNow()
                await f.sync.settle()
                try await f.pair.engineA.fetchNow()
                await f.pair.syncA.settle()
            }
            let uploaded = f.sync.localKey(profileID: f.pair.profile.id, vaultID: f.destination.vaultID).itemRecord(fresh.id)
            try #require(f.pair.cloud.record(uploaded) != nil, "The receiving Mac uploaded the copied entry and its encrypted file.")
            let accounts = try await f.pair.managerA.snapshot().accounts
            #expect(accounts.count == 4 && accounts.contains { $0.username == "work" && $0.password == "on-B" })
            let received = try #require(accounts.first { $0.id == fresh.id })
            #expect(received.passkeys.first?.privateKeyPKCS8 == fresh.passkeys.first?.privateKeyPKCS8 && received.notes == fresh.notes)
            #expect(accounts.contains { $0.username == "shared" })
            let file = try #require(received.attachments?.first)
            let output = f.pair.envA.directory.appending(path: "received.txt")
            try await f.pair.managerA.readAttachment(file, to: output)
            #expect(try Data(contentsOf: output) == fileBytes)
        }
    }

    private func addDuplicateFile(to f: MergeFixture) async throws -> (sourceID: UUID, destinationBlob: URL) {
        let input = f.pair.envA.directory.appending(path: "matching-file.txt")
        try Data("synthetic independent copy".utf8).write(to: input)
        var local = f.pair.account("same-file"), shared = f.pair.account("same-file")
        local.attachments = [try await f.source.manager.addAttachment(from: input)]
        let sharedFile = try await f.destination.addAttachment(from: input)
        shared.attachments = [sharedFile]
        try await VaultManagerFixture.save([local], in: f.source)
        try await f.pair.save([shared], in: f.destination)
        return (local.id, VaultBlob.file(sharedFile.id, in: f.destination.store.blobFolder(f.destination.vaultID)))
    }

    @Test(arguments: [VaultFileError.missing, .damaged])
    func duplicateFilesMustAuthenticateAtPreviewAndWhenAllEntriesAreSkipped(_ expected: VaultFileError) async throws {
        var confirmations = 0
        try await withMergeFixture(verify: { _ in confirmations += 1 }) { f in
            let duplicate = try await addDuplicateFile(to: f)
            let accepted = try await f.review()
            #expect(accepted.rows.map(\.kind) == [.duplicate])
            let choices: [UUID: CredentialVaultMergePlan.Choice] = [duplicate.sourceID: .skip]
            #expect(try await f.model.confirmVaultMerge(accepted, choices: choices) == 0)
            let source = try await f.source.manager.snapshot(), destination = try await f.destination.snapshot()
            let sealed = try Data(contentsOf: duplicate.destinationBlob)
            if expected == .missing {
                try FileManager.default.removeItem(at: duplicate.destinationBlob)
            } else {
                try VaultStoreFixture.flipped(sealed).write(to: duplicate.destinationBlob)
            }
            await #expect(throws: expected) { _ = try await f.review() }
            await #expect(throws: expected) { _ = try await f.model.confirmVaultMerge(accepted, choices: choices) }
            #expect(try await f.source.manager.snapshot().stamps == source.stamps)
            #expect(try await f.destination.snapshot().stamps == destination.stamps)
            #expect(confirmations == 0)
        }
    }

    enum SheetFinish: CaseIterable { case confirm, cancel, skipMissingDuplicate }

    @Test(arguments: SheetFinish.allCases) func theAutofillSettingsReviewWritesOnlyAfterConfirmation(_ finish: SheetFinish) async throws {
        try await withMergeFixture { f in
            let duplicate: URL?
            if finish == .skipMissingDuplicate {
                duplicate = try await addDuplicateFile(to: f).destinationBlob
            } else {
                try await VaultManagerFixture.save([f.pair.account("only-local")], in: f.source)
                duplicate = nil
            }
            let before = try await f.destination.snapshot()
            let local = try await f.source.manager.snapshot()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: VStack {
                CredentialSettings(model: f.model, highlight: "autofill.passwords")
            }.environment(\.accessibilityEnabled, true))
            window.contentView = host
            window.orderBack(nil)
            func button(_ title: String, in node: AnyObject) -> AnyObject? {
                if node.accessibilityRole?() == .button, [node.accessibilityTitle?(), node.accessibilityLabel?()].contains(title) {
                    return node
                }
                return (node.accessibilityChildren?() ?? []).lazy.compactMap { button(title, in: $0 as AnyObject) }.first
            }
            func press(_ title: String, in view: NSView) async throws {
                try #require(await waitUntil { button(title, in: view)?.isAccessibilityEnabled?() == true })
                _ = button(title, in: view)?.accessibilityPerformPress?()
            }
            try await press(String(localized: "Merge Vaults…"), in: host)
            try #require(await waitUntil { window.attachedSheet?.contentView != nil })
            let sheet = try #require(window.attachedSheet?.contentView)
            try await press(String(localized: "Review Entries"), in: sheet)
            try await press(String(localized: "Continue"), in: sheet)
            #expect(try await f.destination.snapshot().stamps == before.stamps)
            switch finish {
            case .confirm:
                try await press(String(localized: "Confirm Merge"), in: sheet)
                try await press(String(localized: "Done"), in: sheet)
                #expect(try await f.destination.snapshot().accounts.contains { $0.username == "only-local" })
            case .cancel:
                try await press(String(localized: "Cancel"), in: sheet)
                #expect(try await f.destination.snapshot().stamps == before.stamps)
            case .skipMissingDuplicate:
                try FileManager.default.removeItem(at: #require(duplicate))
                try await press(String(localized: "Finish Without Changes"), in: sheet)
                let retry = String(localized: "Review Entries"), done = String(localized: "Done")
                try #require(await waitUntil { button(retry, in: sheet) != nil || button(done, in: sheet) != nil })
                try #require(button(done, in: sheet) == nil, "The missing file must return the sheet to review.")
                try await press(String(localized: "Cancel"), in: sheet)
                #expect(try await f.destination.snapshot().stamps == before.stamps)
            }
            try #require(await waitUntil { window.attachedSheet == nil })
            #expect(try await f.source.manager.snapshot().stamps == local.stamps)
        }
    }

    @Test func cancellingDeviceVerificationAfterUnlockingBothVaultsLeavesTheTargetIntact() async throws {
        var prompts = 0
        try await withMergeFixture(verify: { _ in
            prompts += 1
            throw CancellationError()
        }) { f in
            let entry = f.pair.account("declined")
            try await VaultManagerFixture.save([entry], in: f.source)
            let before = try await f.destination.snapshot().stamps
            f.source.manager.lock(reason: .manual)
            f.destination.lock(reason: .manual)
            let review = try await f.review()
            #expect(f.source.manager.isUnlocked && f.destination.isUnlocked && !review.sourceLabel.contains("locked"))
            await #expect(throws: CancellationError.self) {
                try await f.model.confirmVaultMerge(review, choices: [entry.id: .copy])
            }
            #expect(prompts == 1)
            #expect(try await f.destination.snapshot().stamps == before)
            #expect(try await f.source.manager.snapshot().accounts.first?.id == entry.id)
        }
    }

    enum WaitingChange: CaseIterable { case sourceEdit, disableSharing, accountSwitch, unavailableAccount, newerHeader, newerEntry, incompleteFetch }

    @Test(arguments: WaitingChange.allCases)
    func aWaitingMergeRechecksTheSourceAndEnrollmentBeforeCommitting(_ change: WaitingChange) async throws {
        var destinationDirectory: URL?
        var held: OperationLockHold?
        try await withMergeFixture(scopedInstance: change == .accountSwitch, verify: { _ in
            held = try await OperationLock.acquire(in: #require(destinationDirectory), mode: .exclusive)
        }) { f in
            let item = f.pair.account("late-change")
            try await VaultManagerFixture.save([item], in: f.source)
            let review = try await f.review()
            let before = try await f.destination.snapshot().stamps
            destinationDirectory = await f.destination.store.directory
            let commit = Task { try await f.model.confirmVaultMerge(review, choices: [item.id: .copy]) }
            defer { held?.release(); commit.cancel() }
            try #require(await waitUntil { held != nil && f.destination.stableGeneration == nil })
            let key = f.sync.localKey(profileID: f.pair.profile.id, vaultID: f.destination.vaultID)
            switch change {
            case .sourceEdit:
                try await f.pair.edit(f.source.manager, item.id) { $0.password = "changed during commit" }
            case .disableSharing:
                try f.sync.disable(profileID: key.profileID, vaultID: key.vaultID)
            case .accountSwitch:
                try #require(key.instanceID != nil)
                f.pair.cloud.switchUser("other-owner")
                await f.sync.handle(.account(.switchAccounts(user: "other-owner")))
                #expect(f.sync.localKey(profileID: key.profileID, vaultID: key.vaultID).instanceID == nil)
            case .unavailableAccount:
                f.engine.available = false
                f.sync.attach(f.engine)
                try #require(await waitUntil { f.sync.accountAvailable == false })
            case .newerHeader:
                let header = try #require(f.pair.cloud.record(key.vaultRecord))
                var payload = try JSONDecoder().decode(VaultRecordPayload.self, from: header.payload)
                payload.keyGeneration += 1
                f.pair.cloud.overwrite(key.vaultRecord, payload: try JSONEncoder().encode(payload))
                try await f.engine.fetchNow()
                #expect(f.sync.status(profileID: key.profileID, vaultID: key.vaultID) == .needsUpdate)
            case .newerEntry, .incompleteFetch:
                if change == .incompleteFetch {
                    let database = try #require(f.sync.database(key.profileID))
                    try database.write { try $0.db.execute(sql: "CREATE TRIGGER refuseInbox BEFORE INSERT ON inbox BEGIN SELECT RAISE(ABORT, 'fixture'); END") }
                }
                let id = key.itemRecord(try #require(before.keys.first))
                var bytes = try #require(f.pair.cloud.record(id)).payload
                bytes[bytes.startIndex] = VaultSyncCodec.assetFormat + 1
                f.pair.cloud.overwrite(id, payload: bytes)
                try await f.engine.fetchNow()
                if change == .incompleteFetch {
                    #expect(f.sync.needsFetch(key))
                } else {
                    #expect(f.sync.tally(profileID: key.profileID, vaultID: key.vaultID).newer == 1)
                }
            }
            held?.release()
            await #expect(throws: (any Error).self) { try await commit.value }
            #expect(try await f.destination.snapshot().stamps == before)
            let retained = try #require(try await f.source.manager.snapshot().accounts.first { $0.id == item.id })
            #expect(retained.password == (change == .sourceEdit ? "changed during commit" : item.password))
        }
    }

    enum ChangeDuringReview: CaseIterable {
        case sourceLocked, destinationLocked, sourceEdited, destinationEdited, disabled, anotherAccount
    }

    @Test(arguments: ChangeDuringReview.allCases)
    func aChangedReviewCannotCopyIntoTheSharedVault(_ change: ChangeDuringReview) async throws {
        try await withMergeFixture { f in
            let item = f.pair.account("new")
            try await VaultManagerFixture.save([item], in: f.source)
            let review = try await f.review()
            switch change {
            case .sourceLocked:
                f.source.manager.lock(reason: .manual)
                try await VaultManagerFixture.unlock(f.source)
            case .destinationLocked:
                f.destination.lock(reason: .manual)
                try await f.pair.unlockBWithoutSync()
            case .sourceEdited:
                try await f.pair.edit(f.source.manager, item.id) { $0.password = "changed" }
            case .destinationEdited:
                try await f.pair.save([f.pair.account("elsewhere")], in: f.destination)
            case .disabled:
                try f.sync.disable(profileID: f.pair.profile.id, vaultID: f.destination.vaultID)
            case .anotherAccount:
                f.pair.cloud.switchUser("other-owner")
                await #expect(throws: (any Error).self) { try await f.model.confirmVaultMerge(review, choices: [item.id: .skip]) }
            }
            await #expect(throws: (any Error).self) { try await f.model.confirmVaultMerge(review, choices: [item.id: .copy]) }
            #expect(try await !f.destination.snapshot().accounts.contains { $0.id == item.id })
            #expect(try await f.source.manager.snapshot().accounts.contains { $0.id == item.id })
        }
    }
}
