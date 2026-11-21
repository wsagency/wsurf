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

    @Test(arguments: [false, true])
    func eachNewRowKeepsItsSpaceWhenTheSelectionChangesDuringAnOutage(restarting: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID(), cloud = FakeSyncCloud()
        let first = StoredWindow(root, window: window, cloud: cloud)
        let shared = try #require(first.spaces.spaces.first)
        let local = first.spaces.add(name: "Device only")
        first.browser.adoptSpaces(from: first.spaces)
        let sharedTab = first.browser.addPage("https://shared.example.test/")
        let sharedFolder = first.browser.createFolder(named: "Shared folder", containing: [sharedTab])
        let legacyID = first.browser.addPage("file:///older-unassigned-row").id
        let localTab = first.browser.addPage("https://device-only.example.test/")
        first.browser.move([.tab(localTab.id)], toSpace: local.id)
        let pin = first.browser.pinned("https://pinned.example.test/")
        try await first.host.share(shared, in: first.profile)
        await first.host.refresh()
        first.browser.activate(localTab)
        first.browser.activate(pin)
        first.browser.saveBlocking()
        try await first.browser.database.writer.write { db in
            try db.execute(sql: "UPDATE sessionTab SET spaceID = NULL WHERE id = ?", arguments: [legacyID])
        }
        first.close()

        let file = root.appending(path: "Spaces.json"), saved = root.appending(path: "Spaces.saved")
        try FileManager.default.moveItem(at: file, to: saved)
        if !restarting {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        var reopened = StoredWindow(root, window: window, cloud: cloud, offline: true)
        defer { reopened.close() }
        let opener = try #require(reopened.browser.tab(id: pin.id))
        try #require(reopened.browser.activeTabID == opener.id)
        let server = try await HTTPFixtureServer.start(routes: ["/shared": .html("Shared tab")])
        let localURL = try #require(URL(string: "https://private-note.example.invalid/first")), sharedURL = try server.url("/shared")
        let privateTab = reopened.browser.newTab(url: localURL, after: opener)
        let privateFolder = try #require(reopened.browser.importBookmarksFolder(named: "New device-only folder", entries: [
            .init(url: "https://private-bookmark.example.invalid/", title: "Local bookmark", date: .distantPast),
        ]))
        let bookmark = try #require(reopened.browser.tabs(in: privateFolder).first)
        let sharedRow = try #require(reopened.browser.tab(id: sharedTab.id))
        // Even in a background Space, a page opened inside a folder still belongs to its opener's folder.
        let nested = reopened.browser.newTab(url: sharedURL, activate: false, after: sharedRow)
        #expect(reopened.browser.reconciledTree().parent(of: .tab(nested.id)) == sharedFolder.id)
        let subfolder = reopened.browser.createFolder(named: "Nested", containing: [nested])
        #expect(subfolder.spaceID == shared.id)
        #expect(nested.spaceID == shared.id)
        #expect(bookmark.spaceID == local.id)
        #expect(privateTab.spaceID == local.id)
        #expect(privateFolder.spaceID == local.id)
        reopened.browser.activate(sharedRow)
        reopened.browser.activate(opener)
        let existingLocal = try #require(reopened.browser.tab(id: localTab.id))
        let localContainer = reopened.browser.createFolder(named: "Wrap a local row", containing: [existingLocal])
        #expect(localContainer.spaceID == local.id && existingLocal.spaceID == local.id)
        #expect(reopened.browser.tab(id: legacyID)?.spaceID == nil)
        // SQLite records millisecond timestamps; make the two distinct user selections deterministic.
        reopened.browser.noteUse(of: [privateTab.id, localTab.id], at: Date(timeIntervalSinceNow: -30))
        reopened.browser.saveBlocking()
        let localID = privateTab.id, folderID = privateFolder.id
        let stored = try await reopened.browser.database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM sessionTab WHERE id = ? AND spaceID = ?)
                     + (SELECT COUNT(*) FROM sessionFolder WHERE id = ? AND spaceID = ?)
                """, arguments: [localID, local.id, folderID, local.id])
        }
        #expect(stored == 2)

        if restarting {
            reopened.close()
        } else {
            try FileManager.default.removeItem(at: file)
        }
        try FileManager.default.moveItem(at: saved, to: file)
        if restarting {
            reopened = StoredWindow(root, window: window, cloud: cloud, offline: true)
        }
        reopened.browser.sidebarDidChange()
        let second = reopened.browser.newTab(url: sharedURL, after: try #require(reopened.browser.tab(id: pin.id)))
        #expect(reopened.browser.tab(id: localID)?.spaceID == local.id)
        #expect(reopened.browser.folder(id: folderID)?.spaceID == local.id)
        #expect(reopened.browser.tab(id: pin.id)?.spaceID == nil)
        #expect(second.spaceID == shared.id)
        reopened.browser.saveBlocking()
        reopened.engine.offline = false
        await reopened.host.refresh()
        let slots = try #require(reopened.host.links[first.profile.id]?.slots)
        #expect(slots[localID] == nil && slots[folderID] == nil && slots[bookmark.id] == nil && slots[localContainer.id] == nil)
        let key = try #require(slots[second.id]?.last?.recordID)
        #expect(cloud.record(key).flatMap(SharedSpaceItem.init(record:))?.url == sharedURL.absoluteString)
        let published = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone)).compactMap(SharedSpaceItem.init(record:))
        #expect(!published.contains { $0.url == localURL.absoluteString || $0.url == "https://private-bookmark.example.invalid/" })
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
