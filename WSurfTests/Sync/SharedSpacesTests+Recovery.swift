// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    /// A new model, Space store and SQLite connection for each launch. A simulated crash drops the debounce task.
    private final class RecoveryWindow {
        let profile = Profile.original()
        let browser: BrowserModel
        let store: SpaceStore
        let host: CloudSharedSpaces
        let router: SyncRouter
        let engine: FakeSyncEngine

        init(_ cloud: FakeSyncCloud, directory: URL, windowID: UUID, offline: Bool = false) {
            let spaces = SpaceStore(profile: profile, file: directory.appending(path: "Spaces.json"))
            store = spaces
            let model = BrowserModel(windowID: windowID, database: AppDatabase(at: directory.appending(path: "session.sqlite")))
            browser = model
            host = CloudSharedSpaces(
                stateFile: directory.appending(path: "catalog.json"), profiles: [profile],
                windows: { [weak model] in [model].compactMap { $0 } }, spaces: { _ in spaces }, pins: { _ in model.pinStore }
            )
            model.sharedSpacesHost = host
            spaces.sharedSpacesHost = host
            let checkpoint = directory.appending(path: "engine-state")
            let state = SyncRouterState(engineState: try? Data(contentsOf: checkpoint))
            router = SyncRouter(state: state, persist: { state in
                try? state.engineState?.write(to: checkpoint, options: .atomic)
            }, tabs: nil, vaults: nil, additional: [host.catalog])
            engine = FakeSyncEngine(cloud: cloud, delegate: router, state: state.engineState)
            engine.offline = offline
            host.attach(engine)
            model.saveDebounce = .seconds(120)
            model.saveDeadline = .seconds(120)
            model.adoptSpaces(spaces.spaces.map(\.id))
            model.restoreSession()
        }

        func close() {
            browser.closeAllTabs(saving: false)
            try? browser.database.writer.close()
        }
    }

    @Test(arguments: [false, true])
    func aLocalRenameSurvivesACrashBeforeTheSQLiteSessionWrite(acknowledged: Bool) async throws {
        try await checkRenameRecovery(acknowledged: acknowledged)
    }

    @Test func aQueuedRenameFromAnOlderCheckpointSurvivesRestart() async throws {
        try await checkRenameRecovery(acknowledged: false, legacyCheckpoint: true)
    }

    private func checkRenameRecovery(acknowledged: Bool, legacyCheckpoint: Bool = false) async throws {
        let cloud = FakeSyncCloud()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let old = RecoveryWindow(cloud, directory: directory, windowID: id)
        let space = try #require(old.store.spaces.first)
        let page = old.browser.addPage("https://cached.example.test/")
        let folder = old.browser.createFolder(named: "Earlier folder", containing: [page])
        let parent = old.browser.createFolder(named: "Parent")
        old.browser.move([.folder(folder.id)], into: parent)
        let local = old.browser.addPage("file:///local/stays-selected")
        old.browser.activeTabID = local.id
        try await old.host.share(space, in: old.profile)
        await old.host.refresh()
        old.browser.saveBlocking()
        old.engine.offline = true
        old.browser.renameFolder(folder, to: "Offline folder")
        old.browser.renameTab(page, to: "Offline tab")
        let change = try #require(old.host.catalog.state.pending.values.first { $0.item.customTitle == "Offline tab" })
        if legacyCheckpoint {
            for row in [page.id, folder.id] {
                old.host.links[old.profile.id]?.slots[row]?.editedAfterRevision = nil
            }
            old.host.persistLinks()
        }
        if acknowledged {
            old.engine.offline = false
            await old.host.refresh()
            #expect(old.host.catalog.state.pending[change.item.recordID] == nil)
        }
        old.close()

        let resumed = RecoveryWindow(cloud, directory: directory, windowID: id, offline: true)
        #expect(resumed.browser.tab(id: page.id)?.customTitle == "Offline tab")
        #expect(resumed.browser.folder(id: folder.id)?.name == "Offline folder")
        #expect(resumed.browser.folder(containing: try #require(resumed.browser.tab(id: page.id)))?.id == folder.id)
        #expect(resumed.browser.reconciledTree().parent(of: .folder(folder.id)) == parent.id)
        #expect(resumed.browser.activeTabID == local.id)
        resumed.browser.scheduleSave()
        #expect(resumed.host.catalog.state.pending[change.item.recordID] == (acknowledged ? nil : change))
        resumed.browser.saveBlocking()
        #expect(resumed.host.links[resumed.profile.id]?.slots[page.id]?.editedAfterRevision == nil)
        resumed.engine.offline = false
        await resumed.host.refresh()
        #expect(cloud.record(change.item.recordID).flatMap(SharedSpaceItem.init(record:))?.customTitle == "Offline tab")
        resumed.close()

        let saved = RecoveryWindow(cloud, directory: directory, windowID: id, offline: true)
        defer { saved.close() }
        #expect(saved.browser.tab(id: page.id)?.customTitle == "Offline tab")
        #expect(saved.browser.folder(id: folder.id)?.name == "Offline folder" && saved.browser.activeTabID == local.id)
    }

    @Test(arguments: [false, true], [false, true])
    func resolvingADeletedSpaceAfterRestartKeepsTheChosenCopy(keepingLocal: Bool, previouslyUnlinked: Bool) async throws {
        try await checkSpaceRecovery(keepingLocal: keepingLocal, previouslyUnlinked: previouslyUnlinked)
    }

    @Test func keepingAPreviouslyUnlinkedSpaceWorksBeforeTheFirstCloudRead() async throws {
        try await checkSpaceRecovery(keepingLocal: true, previouslyUnlinked: true, offlineChoice: true)
    }

    @Test(arguments: [false, true], [false, true])
    func keepingAnUnlinkedSpaceRetriesItsReservedID(localStoreCommitted: Bool, acknowledged: Bool) async throws {
        try await checkSpaceRecovery(keepingLocal: true, previouslyUnlinked: true, interruptedAfterLocalWrite: localStoreCommitted, acknowledged: acknowledged)
    }

    private func checkSpaceRecovery(
        keepingLocal: Bool, previouslyUnlinked: Bool, offlineChoice: Bool = false, interruptedAfterLocalWrite: Bool? = nil, acknowledged: Bool = false
    ) async throws {
        let cloud = FakeSyncCloud()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let old = RecoveryWindow(cloud, directory: directory, windowID: id)
        var space = old.store.add(name: "Reading")
        old.browser.adoptSpaces(old.store.spaces.map(\.id))
        old.browser.switchSpace(to: space.id)
        let page = old.browser.addPage("https://reading.example.test/")
        let deviceNote = old.browser.addPage("file:///reading/notes")
        try await old.host.share(space, in: old.profile)
        await old.host.refresh()
        old.browser.saveBlocking()
        let shared = try #require(old.host.links[old.profile.id]?.spaces[space.id])
        let key = SyncRecordID(zone: SharedCatalogCategory.spaces.zone, name: shared.uuidString)
        old.engine.offline = true
        space.name = "Air's reading list"
        old.store.update(space)
        cloud.deleteRecord(key)
        old.engine.offline = false
        try await old.engine.fetchNow()
        #expect(old.host.catalog.state.conflicts[key]?.item.title == space.name)
        if previouslyUnlinked {
            // A previous version had already dropped the Space while retaining the conflict in the checkpoint.
            old.host.links[old.profile.id]?.spaces[space.id] = nil
            old.host.persistLinks()
            old.store.remove(space)
        }
        old.close()

        let resumed = RecoveryWindow(cloud, directory: directory, windowID: id, offline: offlineChoice)
        await resumed.host.refresh()
        if let interruptedAfterLocalWrite {
            try await checkInterruptedKeep(resumed, directory: directory, cloud: cloud, space: space, shared: shared, localStoreCommitted: interruptedAfterLocalWrite, acknowledged: acknowledged)
            return
        }
        defer { resumed.close() }
        resumed.host.catalog.resolve(key, keepingLocal: keepingLocal)
        if keepingLocal {
            var kept = try #require(resumed.store.spaces.first { resumed.host.links[resumed.profile.id]?.spaces[$0.id] == shared })
            #expect(kept.name == space.name)
            if !previouslyUnlinked {
                #expect(kept.id == space.id && resumed.browser.tab(id: deviceNote.id)?.spaceID == kept.id)
            }
            resumed.engine.offline = false
            await resumed.host.refresh()
            #expect(resumed.browser.tab(id: page.id)?.spaceID == kept.id)
            kept.name = "The next edit"
            resumed.store.update(kept)
            await resumed.host.refresh()
            #expect(cloud.record(key).flatMap(SharedSpaceItem.init(record:))?.title == kept.name)
        } else {
            #expect(resumed.store.space(id: space.id) == nil && resumed.host.links[resumed.profile.id]?.spaces[space.id] == nil)
            #expect(cloud.record(key) == nil)
        }
    }

    private func checkInterruptedKeep(
        _ window: RecoveryWindow, directory: URL, cloud: FakeSyncCloud, space: Space, shared: UUID, localStoreCommitted: Bool, acknowledged: Bool
    ) async throws {
        let prior = window.store.spaces
        let file = directory.appending(path: "Spaces.json")
        let backup = directory.appending(path: "saved-spaces")
        let key = SyncRecordID(zone: SharedCatalogCategory.spaces.zone, name: shared.uuidString)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        window.host.catalog.resolve(key, keepingLocal: true)
        #expect(window.store.spaces == prior)
        let reserved = try #require(window.host.links[window.profile.id]?.joiningSpaces?[shared])
        if acknowledged {
            await window.host.refresh()
            #expect(window.host.catalog.state.pending[key] == nil)
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        // The process can stop after Spaces.json was written and before the catalog link was committed.
        if localStoreCommitted {
            try window.store.ensureJoinedSpace(id: reserved, name: space.name, symbol: space.symbol, color: space.color)
        }
        window.close()

        let next = RecoveryWindow(cloud, directory: directory, windowID: window.browser.windowID, offline: true)
        defer { next.close() }
        let wanted = prior + [Space(id: reserved, name: space.name, symbol: space.symbol, color: space.color)]
        #expect(next.store.spaces == wanted)
        #expect(next.host.links[next.profile.id]?.spaces[reserved] == shared)
        #expect(next.host.links[next.profile.id]?.joiningSpaces?[shared] == nil)
        next.engine.offline = false
        await next.host.refresh()
        #expect(next.store.spaces == wanted && cloud.record(key).flatMap(SharedSpaceItem.init(record:))?.title == space.name)
    }

    @Test(arguments: [false, true])
    func keepingATabClosedOnAnotherMacReusesItsRecordAfterRestart(committedClose: Bool) async throws {
        try await checkTabRecovery(committedClose: committedClose, ownerClosed: false)
    }

    @Test func aKeptTabWaitsForItsClosedWindowAfterUpload() async throws {
        try await checkTabRecovery(committedClose: true, ownerClosed: true)
    }

    @Test func keepingARemoteCloseTombstoneRestoresTheOriginalTab() async throws {
        try await checkTabRecovery(committedClose: true, ownerClosed: false, softClose: true)
    }

    @Test func keepingATabWorksBeforeTheFirstCloudRead() async throws {
        try await checkTabRecovery(committedClose: true, ownerClosed: false, offlineChoice: true)
    }

    private func checkTabRecovery(committedClose: Bool, ownerClosed: Bool, softClose: Bool = false, offlineChoice: Bool = false) async throws {
        let cloud = FakeSyncCloud()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let old = RecoveryWindow(cloud, directory: directory, windowID: id)
        let original = old.browser.addPage("https://retained.example.test/")
        let space = try #require(old.store.spaces.first)
        try await old.host.share(space, in: old.profile)
        await old.host.refresh()
        old.host.stopSharing(space, in: old.profile)
        try await old.host.join(try #require(old.host.availableSpaces(for: old.profile).first), in: old.profile)
        let page = try #require(old.browser.tabs.first { $0.urlString == original.urlString && $0.id != original.id })
        old.browser.saveBlocking()
        let shared = try #require(old.host.links[old.profile.id]?.slots[page.id]?.cloudID)
        #expect(shared == original.id && shared != page.id)
        let key = SyncRecordID(zone: SharedCatalogCategory.spaces.zone, name: shared.uuidString)
        old.engine.offline = true
        old.browser.renameTab(page, to: "Keep this change")
        if softClose {
            let stored = try #require(cloud.record(key))
            let tombstone = try #require(SharedSpaceItem(record: stored)?.tombstone.record(fields: stored.systemFields))
            _ = cloud.save(tombstone)
        } else {
            cloud.deleteRecord(key)
        }
        old.engine.offline = false
        try await old.engine.fetchNow()
        #expect(old.host.catalog.state.conflicts[key]?.item.customTitle == "Keep this change")
        #expect(old.browser.tab(id: page.id) == nil)
        if committedClose {
            old.browser.saveBlocking()
        }
        old.close()

        let resumed = RecoveryWindow(cloud, directory: directory, windowID: id, offline: offlineChoice)
        await resumed.host.refresh()
        if ownerClosed {
            resumed.browser.markSessionClosed()
            resumed.browser.closeAllTabs(saving: false)
        }
        resumed.host.catalog.resolve(key, keepingLocal: true)
        if ownerClosed {
            await resumed.host.refresh()
            #expect(resumed.host.catalog.state.pending[key] == nil)
        } else {
            #expect(resumed.browser.tab(id: page.id)?.customTitle == "Keep this change")
            #expect(resumed.host.links[resumed.profile.id]?.slots[page.id]?.closedAfterRevision == nil)
        }
        resumed.close()

        let reopened = RecoveryWindow(cloud, directory: directory, windowID: id, offline: true)
        defer { reopened.close() }
        let recovered = try #require(reopened.browser.tab(id: page.id))
        #expect(recovered.customTitle == "Keep this change")
        #expect(reopened.host.links[reopened.profile.id]?.slots[page.id]?.closedAfterRevision == nil)
        #expect(reopened.browser.tab(id: original.id)?.customTitle.isEmpty == true)
        reopened.browser.renameTab(recovered, to: "Still the same tab")
        reopened.browser.saveBlocking()
        reopened.engine.offline = false
        await reopened.host.refresh()
        let records = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone))
        #expect(records.compactMap(SharedSpaceItem.init(record:)).filter { !$0.removed && $0.url == page.urlString }.map(\.id) == [shared])
        #expect(cloud.record(key).flatMap(SharedSpaceItem.init(record:))?.customTitle == "Still the same tab")
        #expect(reopened.browser.tab(id: page.id)?.customTitle == "Still the same tab")
    }
}
