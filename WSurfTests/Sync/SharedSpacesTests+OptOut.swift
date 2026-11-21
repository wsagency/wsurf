// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

@MainActor
private struct CatalogFiles {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let profile: Profile
    let spaces: SpaceStore
    let pins = ProfilePinStore.store(for: .temporary())

    init() {
        profile = Profile.original()
        spaces = SpaceStore(profile: profile, file: nil)
    }

    var file: URL {
        directory.appending(path: "iCloudSharedSpaces.json")
    }

    private var saved: URL {
        directory.appending(path: "saved.json")
    }

    func open() -> CloudSharedSpaces {
        CloudSharedSpaces(stateFile: file, profiles: [profile], windows: { [] }, spaces: { _ in spaces }, pins: { _ in pins })
    }

    func interruptWrites() throws {
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    }

    func restoreFile() throws {
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension SharedSpacesTests {
    @Test(arguments: SharedCatalogCategory.allCases, [false, true])
    func failedCatalogPauseStaysOffAcrossRestart(category: SharedCatalogCategory, restartBeforeRetry: Bool) async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let cloud = FakeSyncCloud()
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        try await host.enable(category, for: profile)

        try fixture.interruptWrites()
        host.pause(category, for: profile)
        #expect(!host.isEnabled(category, for: profile))
        #expect(!host.needsEngine)
        #expect(!host.catalog.storageAvailable)
        #expect(host.hasPendingOptOut(category, for: profile))
        #expect(!host.retryOptOuts())

        try fixture.restoreFile()
        engine.offline = true
        let retry = restartBeforeRetry ? fixture.open() : host
        #expect(!retry.isEnabled(category, for: profile))
        if restartBeforeRetry {
            retry.beat()
        } else {
            #expect(retry.retryOptOuts())
        }
        #expect(!retry.hasPendingOptOut(category, for: profile))
        #expect(retry.catalog.storageAvailable)
        #expect(!fixture.open().isEnabled(category, for: profile))
        #expect(cloud.recordCount == 0)
    }

    @Test func pausingProfileDiscoveryPreservesItsLinkAndOtherOptIns() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let store = fixture.spaces
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        let linked = try await host.publishProfile(profile)
        try await host.enable(.pins, for: profile)
        host.pause(.profiles, for: profile)
        #expect(!host.isEnabled(.profiles, for: profile))
        #expect(host.cloudProfileID(for: profile.id) == linked)
        #expect(host.isEnabled(.pins, for: profile))
        #expect(host.available(.profiles, for: profile).isEmpty)
        try await host.share(store.add(name: "Fixture"), in: profile)
        #expect(!host.isEnabled(.profiles, for: profile))
    }

    @Test func retryAfterRestartWhileCatalogIsUnreadableRecoversOtherConsent() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        let linked = try await host.publishProfile(profile)
        try await host.enable(.pins, for: profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: profile)
        let reopened = fixture.open()
        #expect(!reopened.isEnabled(.profiles, for: profile))
        #expect(reopened.hasPendingOptOut(.profiles, for: profile))
        try fixture.restoreFile()
        reopened.beat()
        #expect(!reopened.hasPendingOptOut(.profiles, for: profile))
        #expect(reopened.isEnabled(.pins, for: profile))
        #expect(reopened.links[profile.id]?.profile == linked)
        let saved = fixture.open()
        #expect(!saved.isEnabled(.profiles, for: profile))
        #expect(saved.isEnabled(.pins, for: profile))
    }

    @Test(arguments: [true, false])
    func sharingFromAnUnlinkedProfileKeepsDiscoveryOff(sharesSpace: Bool) async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let spaces = fixture.spaces
        let pins = fixture.pins
        let host = fixture.open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.profiles, for: profile)
        host.pause(.profiles, for: profile)
        if sharesSpace {
            try await host.share(spaces.add(name: "Fixture"), in: profile)
        } else {
            let pin = ProfilePin(id: UUID(), orderKey: "V", kind: .tab, url: "https://example.test/pin")
            pins.publish([pin])
            try await host.selectPin(pin.id, in: profile)
        }
        try await engine.sendNow()
        let id = try #require(host.cloudProfileID(for: profile.id))
        #expect(!host.isEnabled(.profiles, for: profile))
        #expect(cloud.names(in: SharedCatalogCategory.profiles.zone).isEmpty)
        let published = try await host.publishProfile(profile)
        try await engine.sendNow()
        #expect(published == id)
        #expect(cloud.names(in: SharedCatalogCategory.profiles.zone).contains(id.uuidString))
    }

    @Test func retryFinishesIfThePrimaryFileIsMissingAfterRestart() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.profiles, for: profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: profile)
        let reopened = fixture.open()
        try FileManager.default.removeItem(at: fixture.file)
        #expect(reopened.retryOptOuts())
        #expect(!reopened.hasPendingOptOut(.profiles, for: profile))
        #expect(!fixture.open().needsEngine)
    }

    @Test func aRepairedCheckpointCanBeRetriedWithoutAJournal() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.pins, for: fixture.profile)
        try fixture.interruptWrites()
        let reopened = fixture.open()
        #expect(!reopened.catalog.storageAvailable)
        try fixture.restoreFile()
        #expect(reopened.retryOptOuts())
        #expect(reopened.isEnabled(.pins, for: fixture.profile))
    }

    @Test(arguments: [false, true])
    func signOutDuringRecoveryRequiresNewConsent(restartAgain: Bool) async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let host = fixture.open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.pins, for: fixture.profile)
        try await host.enable(.profiles, for: fixture.profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: fixture.profile)
        let interrupted = fixture.open()
        await interrupted.catalog.handle(.account(.signOut))
        try fixture.restoreFile()
        let reopened = restartAgain ? fixture.open() : interrupted
        #expect(reopened.retryOptOuts())
        let sameAccount = FakeSyncEngine(cloud: cloud, delegate: reopened.catalog)
        reopened.attach(sameAccount)
        await reopened.refresh()
        #expect(!reopened.needsEngine)
        #expect(!fixture.open().needsEngine)
    }

    @Test func anUnreadableJournalWaitsForRecoveryBeforeChangingOtherSelections() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        let kept = fixture.spaces.add(name: "Kept")
        try await host.share(kept, in: fixture.profile)
        try await host.enable(.profiles, for: fixture.profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: fixture.profile)
        try fixture.restoreFile()
        let journal = fixture.file.appendingPathExtension("opt-outs")
        let saved = fixture.directory.appending(path: "saved-journal")
        let files = FileManager.default
        try files.moveItem(at: journal, to: saved)
        try files.createDirectory(at: journal, withIntermediateDirectories: false)
        let reopened = fixture.open()
        #expect(!reopened.needsEngine)
        #expect(!reopened.retryOptOuts())
        try files.removeItem(at: journal)
        try files.moveItem(at: saved, to: journal)
        #expect(reopened.retryOptOuts())
        #expect(!reopened.isEnabled(.profiles, for: fixture.profile))
        #expect(reopened.isEnabled(.spaces, for: fixture.profile))
        #expect(reopened.links[fixture.profile.id]?.spaces[kept.id] != nil)
    }

    @Test func anAccountResetSurvivesAnInaccessibleJournalAndAnotherRestart() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.pins, for: fixture.profile)
        try await host.enable(.profiles, for: fixture.profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: fixture.profile)
        let journal = fixture.file.appendingPathExtension("opt-outs")
        let saved = fixture.directory.appending(path: "saved-journal")
        let files = FileManager.default
        try files.moveItem(at: journal, to: saved)
        try files.createDirectory(at: journal, withIntermediateDirectories: false)
        let blocked = fixture.open()
        await blocked.catalog.handle(.account(.signOut))
        try files.removeItem(at: journal)
        try files.moveItem(at: saved, to: journal)
        try fixture.restoreFile()
        #expect(!fixture.open().needsEngine)
    }

    @Test func aDamagedRevocationListRequiresFreshItemSelection() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let host = fixture.open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        let space = fixture.spaces.add(name: "Fixture")
        try await host.share(space, in: fixture.profile)
        try fixture.interruptWrites()
        host.stopSharing(space, in: fixture.profile)
        try Data([0xFF]).write(to: fixture.file.appendingPathExtension("opt-outs"))
        try fixture.restoreFile()
        let reopened = fixture.open()
        let resumed = FakeSyncEngine(cloud: cloud, delegate: reopened.catalog)
        reopened.attach(resumed)
        try await reopened.enable(.spaces, for: fixture.profile)
        try await resumed.sendNow()
        #expect(reopened.links[fixture.profile.id]?.spaces[space.id] == nil)
        #expect(cloud.names(in: SharedCatalogCategory.spaces.zone).isEmpty)
    }

    @Test func anOldOptOutJournalCannotUndoExplicitReenrollment() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: FakeSyncCloud(), delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.profiles, for: profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: profile)
        let journal = fixture.file.appendingPathExtension("opt-outs")
        let stale = try Data(contentsOf: journal)
        try fixture.restoreFile()
        #expect(host.retryOptOuts())
        try await host.enable(.profiles, for: profile)
        try stale.write(to: journal, options: .atomic)
        let reopened = fixture.open()
        #expect(reopened.isEnabled(.profiles, for: profile))
        #expect(!reopened.hasPendingOptOut(.profiles, for: profile))
    }

    @Test func stoppedPinsDoNotUploadUnusedAncestorFolders() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let host = fixture.open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        let root = UUID(), branch = UUID(), kept = UUID(), stopped = UUID()
        try await host.enable(.pins, for: profile)
        let group = UUID()
        #expect(host.linkProfile(profile.id, to: group))
        // Persist a nested pin selection and a sibling which still needs the root folder.
        host.links[profile.id]?.pins = [kept: kept, stopped: stopped]
        host.links[profile.id]?.pinFolders = [root: root, branch: branch]
        host.catalog.stage([
            .init(id: root, kind: .pinFolder, profileID: group, title: "Root"),
            .init(id: branch, kind: .pinFolder, profileID: group, parentID: root, title: "Branch"),
            .init(id: kept, kind: .pin, profileID: group, parentID: root, url: "https://example.test/kept"),
            .init(id: stopped, kind: .pin, profileID: group, parentID: branch, url: "https://example.test/stopped"),
        ], for: profile.id)
        try fixture.interruptWrites()
        host.stopSharingPin(stopped, in: profile)
        try fixture.restoreFile()
        let reopened = fixture.open()
        let resumed = FakeSyncEngine(cloud: cloud, delegate: reopened.catalog)
        reopened.attach(resumed)
        try await reopened.catalog.prepare(.pins)
        try await resumed.sendNow()
        #expect(Set(cloud.names(in: SharedCatalogCategory.pins.zone)) == [root.uuidString, kept.uuidString])
    }

    @Test func interruptedStopSharingKeepsOnlyTheDeselectedSpaceAndPinLocal() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let profile = fixture.profile
        let spaces = fixture.spaces
        let stopped = spaces.add(name: "Stopped")
        let kept = spaces.add(name: "Kept")
        let pins = fixture.pins
        let pin = ProfilePin(id: UUID(), orderKey: "V", kind: .tab, url: "https://example.test/pin")
        pins.publish([pin])
        let host = fixture.open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        try await host.share(stopped, in: profile)
        try await host.share(kept, in: profile)
        try await host.selectPin(pin.id, in: profile)
        try await engine.sendNow()
        let pinID = try #require(host.links[profile.id]?.pins[pin.id])
        let count = cloud.recordCount
        try fixture.interruptWrites()
        host.stopSharing(stopped, in: profile)
        host.stopSharingPin(pin.id, in: profile)
        try fixture.restoreFile()
        let reopened = fixture.open()
        let link = try #require(reopened.links[profile.id])
        #expect(link.spaces[stopped.id] == nil && link.spaces[kept.id] != nil)
        #expect(link.pins[pin.id] == nil && link.skippedPins?.contains(pinID) == true)
        #expect(spaces.space(id: stopped.id) != nil && pins.pins.contains { $0.id == pin.id })
        #expect(cloud.recordCount == count)
    }

    @Test func aVerifiedProfileLinkIsAvailableAfterRestartWithDiscoveryOff() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let host = fixture.open()
        let cloud = FakeSyncCloud()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        let linked = try await host.publishProfile(fixture.profile)
        host.pause(.profiles, for: fixture.profile)
        var engineStarts = 0
        let app = try fixture.startSettings(cloud: cloud) { engineStarts += 1 }
        defer { app.prepareToTerminate() }
        let settings = try #require(app.settingsSync)
        let spaces = try #require(app.sharedSpaces)
        #expect(spaces.cloudProfileID(for: fixture.profile.id) == nil)
        try settings.accountDidResolve(cloud.user)
        #expect(spaces.cloudProfileID(for: fixture.profile.id) == linked)
        settings.suspendAccount()
        #expect(spaces.cloudProfileID(for: fixture.profile.id) == nil)
        try settings.accountDidResolve("different-fixture-account")
        #expect(spaces.cloudProfileID(for: fixture.profile.id) == nil)
        #expect(!spaces.isEnabled(.profiles, for: fixture.profile))
        #expect(engineStarts == 0)
    }

    @Test func monitoredSignOutDuringCheckpointRecoveryRequiresFreshConsent() async throws {
        let fixture = CatalogFiles()
        defer { fixture.cleanUp() }
        let cloud = FakeSyncCloud()
        let host = fixture.open()
        let engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
        host.attach(engine)
        try await host.enable(.pins, for: fixture.profile)
        try await host.enable(.profiles, for: fixture.profile)
        try fixture.interruptWrites()
        host.pause(.profiles, for: fixture.profile)
        var engineStarts = 0
        let app = try fixture.startSettings(cloud: cloud) { engineStarts += 1 }
        defer { app.prepareToTerminate() }
        let settings = try #require(app.settingsSync)
        try settings.accountDidResolve(nil)
        try settings.accountDidResolve(cloud.user)
        try fixture.restoreFile()
        #expect(!fixture.open().needsEngine)
        #expect(engineStarts == 0)
    }
}

private extension CatalogFiles {
    func startSettings(cloud: FakeSyncCloud, onEngine: @escaping @MainActor () -> Void) throws -> CloudSync {
        let entitlements = CloudTabsTests.Launch.entitlements
        let gate = CloudSyncGate.Inputs(
            tabsFlag: false, vaultFlag: false, isRunningTests: false, isStaged: false, ownsSession: true,
            entitlement: { entitlements[$0] }, offersMacSync: true
        )
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: directory.appending(path: "router.json"),
            profiles: [profile], host: { FakeVaultHost(root: directory.appending(path: "vaults")) },
            windows: { [] }, makeEngine: { delegate, _ in
                onEngine()
                return FakeSyncEngine(cloud: cloud, delegate: delegate)
            }
        )
        return try #require(started)
    }
}
