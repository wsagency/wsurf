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

        init(_ root: URL, window: UUID, cloud: FakeSyncCloud, offline: Bool = false) {
            let database = AppDatabase(at: root.appending(path: "session.sqlite"))
            let store = SpaceStore(profile: profile, file: root.appending(path: "Spaces.json"), database: database)
            let model = BrowserModel(windowID: window, database: database)
            spaces = store
            browser = model
            host = CloudSharedSpaces(
                stateFile: root.appending(path: "catalog.json"), profiles: [profile], windows: { [weak model] in [model].compactMap { $0 } },
                spaces: { _ in store }, pins: { _ in model.pinStore }
            )
            model.sharedSpacesHost = host
            engine = FakeSyncEngine(cloud: cloud, delegate: host.catalog)
            engine.offline = offline
            host.attach(engine)
            model.saveDebounce = .seconds(120)
            model.saveDeadline = .seconds(120)
            model.adoptSpaces(from: store)
            model.restoreSession()
        }

        func close() {
            browser.closeAllTabs(saving: false)
            try? browser.database.writer.close()
        }
    }

    @Test(arguments: [false, true])
    func unreadableSpacesPreservePopulatedWindowMembershipAndQueuedRows(fileMissing: Bool) async throws {
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
        if !fileMissing {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
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
        if fileMissing {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
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

        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
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

    @Test(arguments: [false, true])
    func restoringTheSpaceListKeepsTabsOpenedFromAPinInTheLastLocalSpace(restarting: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID(), cloud = FakeSyncCloud()
        let first = StoredWindow(root, window: window, cloud: cloud)
        let shared = try #require(first.spaces.spaces.first)
        let local = first.spaces.add(name: "Device only")
        first.browser.adoptSpaces(from: first.spaces)
        let sharedPage = first.browser.addPage("https://shared.example.test/")
        let privatePage = first.browser.addPage("https://device-only.example.test/")
        first.browser.move([.tab(privatePage.id)], toSpace: local.id)
        let pin = first.browser.pinned("https://pinned.example.test/")
        try await first.host.share(shared, in: first.profile)
        await first.host.refresh()
        first.browser.activate(privatePage)
        first.browser.activate(pin)
        try #require(first.browser.currentSpaceID == local.id && first.browser.activeTabID == pin.id)
        first.browser.saveBlocking()
        let writes = cloud.writeCount
        first.close()

        let file = root.appending(path: "Spaces.json"), saved = root.appending(path: "Spaces.saved")
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var offline = StoredWindow(root, window: window, cloud: cloud, offline: true)
        defer { offline.close() }
        try #require(offline.browser.activeTabID == pin.id)
        let existingShared = try #require(offline.browser.tab(id: sharedPage.id))
        #expect(offline.browser.isShown(existingShared))
        let existingLocal = try #require(offline.browser.tab(id: privatePage.id))
        #expect(offline.browser.isShown(existingLocal))
        offline.browser.renameTab(existingLocal, to: "Local rename during outage")
        let server = try await HTTPFixtureServer.start(routes: ["/local": .html("<title>Device only</title>")])
        let opener = try #require(offline.browser.tab(id: pin.id))
        let newPage = offline.browser.newTab(url: try server.url("/local"), after: opener)
        offline.browser.saveBlocking()
        if restarting {
            offline.close()
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
        if restarting {
            offline = StoredWindow(root, window: window, cloud: cloud, offline: true)
        }
        offline.browser.sidebarDidChange()
        offline.browser.scheduleSave()
        #expect(offline.browser.currentSpaceID == local.id)
        #expect(offline.browser.tab(id: newPage.id)?.spaceID == local.id)
        #expect(offline.browser.tab(id: privatePage.id)?.spaceID == local.id)
        #expect(offline.browser.tab(id: privatePage.id)?.customTitle == "Local rename during outage")
        #expect(offline.browser.tab(id: sharedPage.id)?.spaceID == shared.id)
        offline.browser.saveBlocking()
        let newID = newPage.id
        let stored = try await offline.browser.database.writer.read { db in
            try UUID.fetchOne(db, sql: "SELECT spaceID FROM sessionTab WHERE id = ?", arguments: [newID])
        }
        #expect(stored == local.id)
        offline.engine.offline = false
        await offline.host.refresh()
        #expect(cloud.writeCount == writes)
        #expect(offline.host.links[first.profile.id]?.slots[newPage.id] == nil)
        await server.stop()
    }

    @Test func aRenameSavedDuringASpaceFileOutageSupersedesTheOlderQueuedRename() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID(), cloud = FakeSyncCloud()
        let first = StoredWindow(root, window: window, cloud: cloud)
        let shared = try #require(first.spaces.spaces.first)
        let tab = first.browser.addPage("https://saved-edit.example.test/")
        let folder = first.browser.createFolder(named: "Original folder", containing: [tab])
        try await first.host.share(shared, in: first.profile)
        await first.host.refresh()
        first.browser.saveBlocking()
        first.engine.offline = true
        first.browser.renameTab(tab, to: "Queued tab")
        first.browser.renameFolder(folder, to: "Queued folder")
        let tabKey = try #require(first.host.links[first.profile.id]?.slots[tab.id]?.last?.recordID)
        let folderKey = try #require(first.host.links[first.profile.id]?.slots[folder.id]?.last?.recordID)
        first.browser.saveBlocking()
        first.close()

        let file = root.appending(path: "Spaces.json"), saved = root.appending(path: "Spaces.saved")
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let outage = StoredWindow(root, window: window, cloud: cloud, offline: true)
        let page = try #require(outage.browser.tab(id: tab.id))
        let parent = try #require(outage.browser.folder(id: folder.id))
        outage.browser.renameTab(page, to: "Newer tab")
        outage.browser.renameFolder(parent, to: "Newer folder")
        outage.browser.saveBlocking()
        let tabID = tab.id
        let savedTitle = try await outage.browser.database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT customTitle FROM sessionTab WHERE id = ?", arguments: [tabID])
        }
        try #require(savedTitle == "Newer tab")
        let writes = cloud.writeCount
        outage.engine.offline = false
        await outage.host.refresh()
        #expect(cloud.writeCount == writes)
        outage.close()

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
        let next = StoredWindow(root, window: window, cloud: cloud, offline: true)
        defer { next.close() }
        #expect(next.browser.tab(id: tab.id)?.customTitle == "Newer tab")
        #expect(next.browser.folder(id: folder.id)?.name == "Newer folder")
        #expect(next.browser.reconciledTree().parent(of: .tab(tab.id)) == folder.id)
        next.engine.offline = false
        await next.host.refresh()
        #expect(cloud.record(tabKey).flatMap(SharedSpaceItem.init(record:))?.customTitle == "Newer tab")
        #expect(cloud.record(folderKey).flatMap(SharedSpaceItem.init(record:))?.title == "Newer folder")
    }
}
