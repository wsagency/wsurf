// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    private final class StoredWindow {
        let profile = Profile.original()
        let spaces: SpaceStore
        let browser: BrowserModel
        let host: CloudSharedSpaces
        let engine: FakeSyncEngine

        init(_ root: URL, window: UUID, cloud: FakeSyncCloud) {
            let store = SpaceStore(profile: profile, file: root.appending(path: "Spaces.json"))
            let model = BrowserModel(windowID: window, database: AppDatabase(at: root.appending(path: "session.sqlite")))
            spaces = store
            browser = model
            host = CloudSharedSpaces(
                stateFile: root.appending(path: "catalog.json"), profiles: [profile], windows: { [weak model] in [model].compactMap { $0 } },
                spaces: { _ in store }, pins: { _ in model.pinStore }
            )
            model.sharedSpacesHost = host
            engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
            host.attach(engine)
            model.adoptSpaces(from: store)
            model.restoreSession()
        }

        func close() {
            browser.closeAllTabs(saving: false)
            try? browser.database.writer.close()
        }
    }

    @Test func unreadableSpacesPreservePopulatedWindowMembershipAndQueuedRows() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID(), cloud = FakeSyncCloud()
        let old = StoredWindow(root, window: window, cloud: cloud)
        let shared = try #require(old.spaces.spaces.first)
        let local = old.spaces.add(name: "Device only")
        old.browser.adoptSpaces([shared.id, local.id])
        let page = old.browser.addPage("https://shared.example.test/")
        let folder = old.browser.createFolder(named: "Shared folder", containing: [page])
        let note = old.browser.addPage("file:///local-note")
        let localFolder = old.browser.createFolder(named: "Local folder", containing: [note])
        old.browser.move([.folder(localFolder.id)], toSpace: local.id)
        try await old.host.share(shared, in: old.profile)
        await old.host.refresh()
        let links = try #require(old.host.links[old.profile.id])
        let pageID = try #require(links.slots[page.id]?.cloudID)
        let folderID = try #require(links.slots[folder.id]?.cloudID)
        old.engine.offline = true
        old.browser.renameTab(page, to: "Offline edit")
        old.browser.renameFolder(folder, to: "Offline folder")
        old.browser.saveBlocking()
        let queued = old.host.catalog.state.pending
        let rowIDs = Set([pageID, folderID])
        try #require(Set(queued.values.map(\.item.id)) == rowIDs)
        let writes = cloud.writeCount
        old.close()

        let file = root.appending(path: "Spaces.json"), saved = root.appending(path: "Spaces.saved")
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let reopened = StoredWindow(root, window: window, cloud: cloud)
        defer { reopened.close() }
        reopened.engine.offline = true
        func checkRows(_ model: BrowserModel) {
            #expect(model.tab(id: page.id)?.spaceID == shared.id && model.folder(id: folder.id)?.spaceID == shared.id)
            #expect(model.tab(id: note.id)?.spaceID == local.id && model.folder(id: localFolder.id)?.spaceID == local.id)
            #expect(model.reconciledTree().parent(of: .tab(page.id)) == folder.id)
            #expect(model.reconciledTree().parent(of: .tab(note.id)) == localFolder.id)
        }
        checkRows(reopened.browser)
        reopened.browser.scheduleSave()
        reopened.browser.saveBlocking()
        #expect(reopened.host.catalog.state.pending == queued)
        #expect(reopened.host.links[old.profile.id]?.slots[page.id]?.cloudID == pageID)
        #expect(reopened.host.links[old.profile.id]?.slots[folder.id]?.cloudID == folderID)
        let savedMembership = try await reopened.browser.database.writer.read { db in
            try UUID.fetchSet(db, sql: "SELECT spaceID FROM sessionTab WHERE windowID = ? UNION SELECT spaceID FROM sessionFolder WHERE windowID = ?", arguments: [window, window])
        }
        #expect(savedMembership == [shared.id, local.id])
        reopened.engine.offline = false
        try await reopened.host.catalog.prepare(.spaces)
        reopened.engine.add(queued.keys.map(SyncChange.saveRecord))
        try await reopened.engine.sendNow()
        checkRows(reopened.browser)
        #expect(cloud.writeCount == writes)
        #expect(reopened.host.catalog.state.pending == queued)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
        reopened.browser.sidebarDidChange()
        await reopened.host.refresh()
        checkRows(reopened.browser)
        #expect(reopened.browser.knownSpaceIDs == [shared.id, local.id])
        #expect(Set(reopened.spaces.spaces.map(\.id)) == [shared.id, local.id])
        for edit in queued.values {
            #expect(cloud.record(edit.item.recordID).flatMap(SharedSpaceItem.init(record:)) == edit.item)
        }
        reopened.browser.saveBlocking()
        let restored = StoredWindow(root, window: window, cloud: cloud)
        defer { restored.close() }
        checkRows(restored.browser)
    }
}
