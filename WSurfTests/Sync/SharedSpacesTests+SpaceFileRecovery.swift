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
        private let windows = NSHashTable<BrowserModel>.weakObjects()

        init(_ root: URL, window: UUID, cloud: FakeSyncCloud, offline: Bool = false) {
            let database = AppDatabase(at: root.appending(path: "session.sqlite"))
            let store = SpaceStore(profile: profile, file: root.appending(path: "Spaces.json"), database: database)
            let model = BrowserModel(windowID: window, database: database)
            spaces = store
            browser = model
            let windows = self.windows
            windows.add(model)
            host = CloudSharedSpaces(
                stateFile: root.appending(path: "catalog.json"), profiles: [profile], windows: { windows.allObjects },
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

        func addWindow(_ id: UUID, in space: UUID) -> BrowserModel {
            let window = BrowserModel(context: browser.context, windowID: id, database: browser.database)
            windows.add(window)
            window.sharedSpacesHost = host
            window.adoptSpaces(from: spaces)
            window.restoreSession()
            window.switchSpace(to: space)
            return window
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
        let legacyURL = "https://older-unassigned.example.invalid/"
        let legacyID = first.browser.addPage(legacyURL).id
        first.browser.move([.tab(legacyID)], toSpace: local.id)
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
        #expect(reopened.browser.tab(id: legacyID)?.spaceID == nil)
        reopened.browser.saveBlocking()
        reopened.engine.offline = false
        await reopened.host.refresh()
        let slots = try #require(reopened.host.links[first.profile.id]?.slots)
        #expect(slots[localID] == nil && slots[folderID] == nil && slots[bookmark.id] == nil && slots[localContainer.id] == nil)
        let key = try #require(slots[second.id]?.last?.recordID)
        #expect(cloud.record(key).flatMap(SharedSpaceItem.init(record:))?.url == sharedURL.absoluteString)
        let published = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone)).compactMap(SharedSpaceItem.init(record:))
        #expect(!published.contains { $0.url == localURL.absoluteString || $0.url == legacyURL || $0.url == "https://private-bookmark.example.invalid/" })
        await server.stop()
    }

    @Test(arguments: [false, true])
    func aLegacyHTTPSRowWithoutProvenMembershipWaitsForAnExplicitMove(allSpacesShared: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID(), cloud = FakeSyncCloud()
        let first = StoredWindow(root, window: window, cloud: cloud), peer = Mac(cloud)
        defer { peer.finish() }
        let shared = try #require(first.spaces.spaces.first)
        let local = first.spaces.add(name: "Device only"), other = first.spaces.add(name: "Another shared Space")
        first.browser.adoptSpaces(from: first.spaces)
        let sharedTab = first.browser.addPage("https://anchor.example.test/")
        let known = first.browser.addPage("https://known-linked.example.test/")
        first.browser.move([.tab(known.id)], toSpace: other.id)
        let localTab = first.browser.addPage("file:///local-note")
        first.browser.move([.tab(localTab.id)], toSpace: local.id)
        let pin = first.browser.pinned("https://pin.example.test/")
        for space in allSpacesShared ? [shared, other, local] : [shared, other] {
            try await first.host.share(space, in: first.profile)
        }
        await first.host.refresh()
        try await peer.host.enable(.spaces, for: peer.profile)
        for value in peer.host.availableSpaces(for: peer.profile) {
            try await peer.host.join(value, in: peer.profile)
        }
        let knownSlot = try #require(first.host.links[first.profile.id]?.slots[known.id])
        let peerKnown = try #require(peer.browser.page(at: known.urlString))
        let peerSpace = try #require(peerKnown.spaceID)
        first.browser.activate(localTab)
        first.browser.activate(pin)
        first.browser.saveBlocking()
        first.close()

        let file = root.appending(path: "Spaces.json"), saved = root.appending(path: "Spaces.saved")
        try FileManager.default.moveItem(at: file, to: saved)
        let outage = StoredWindow(root, window: window, cloud: cloud, offline: true)
        let localURL = try #require(URL(string: "https://private-note.example.invalid/upgrade"))
        let opener = try #require(outage.browser.tab(id: pin.id))
        let unplaced = outage.browser.newTab(url: localURL, after: opener)
        outage.browser.activate(try #require(outage.browser.tab(id: sharedTab.id)))
        outage.browser.activate(opener)
        outage.browser.noteUse(of: [unplaced.id, localTab.id, known.id], at: Date(timeIntervalSinceNow: -30))
        outage.browser.saveBlocking()
        let localID = unplaced.id, knownID = known.id
        // Older builds saved NULL after this sequence. Also remove a linked row's SQLite membership
        // so the upgrade must recover it from its durable catalog record in the other shared Space.
        try await outage.browser.database.writer.write { db in
            try db.execute(sql: "UPDATE sessionTab SET spaceID = NULL WHERE id IN (?, ?)", arguments: [localID, knownID])
        }
        try #require(outage.host.links[first.profile.id]?.slots[localID] == nil)
        outage.close()
        try FileManager.default.moveItem(at: saved, to: file)

        var upgraded = StoredWindow(root, window: window, cloud: cloud, offline: true)
        defer { upgraded.close() }
        for launch in 0..<2 {
            let page = try #require(upgraded.browser.tab(id: localID))
            if let space = page.spaceID {
                try #require(upgraded.spaces.space(id: space) != nil)
                upgraded.browser.switchSpace(to: space, showing: page)
            }
            #expect(upgraded.browser.isShown(page))
            #expect(upgraded.browser.sidebarTree.walk().contains(.tab(localID)))
            #expect(page.spaceID.flatMap { upgraded.host.links[first.profile.id]?.spaces[$0] } == nil)
            #expect(upgraded.browser.tab(id: knownID)?.spaceID == other.id)
            #expect(upgraded.host.links[first.profile.id]?.slots[knownID]?.cloudID == knownSlot.cloudID)
            upgraded.browser.scheduleSave()
            upgraded.browser.saveBlocking()
            upgraded.engine.offline = false
            await upgraded.host.refresh()
            try await peer.sync()
            #expect(peer.browser.page(at: localURL.absoluteString) == nil)
            #expect(peer.browser.page(at: known.urlString)?.spaceID == peerSpace)
            let published = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone)).compactMap(SharedSpaceItem.init(record:))
            #expect(!published.contains { $0.url == localURL.absoluteString })
            if launch == 0 {
                upgraded.close()
                upgraded = StoredWindow(root, window: window, cloud: cloud, offline: true)
            }
        }
        upgraded.browser.switchSpace(to: shared.id)
        #expect(upgraded.browser.spaceMoveTargets(for: [.tab(localID)]).map(\.id).contains(shared.id))
        #expect(upgraded.browser.spaceMoveTargets(for: [.tab(pin.id)]).isEmpty)
        upgraded.browser.move([.tab(localID)], toSpace: shared.id)
        await upgraded.host.refresh()
        try await peer.sync()
        #expect(upgraded.browser.tab(id: localID)?.spaceID == shared.id)
        #expect(peer.browser.page(at: localURL.absoluteString) != nil)
        let chosen = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone)).compactMap(SharedSpaceItem.init(record:))
        #expect(chosen.contains { $0.url == localURL.absoluteString && !$0.removed })
    }

    @Test(arguments: [false, true], [false, true])
    func temporarilyPinningALegacyUnplacedPageKeepsItLocalAcrossWindows(restartWhilePinned: Bool, unpinAtSource: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud(), firstID = UUID(), secondID = UUID()
        let peer = Mac(cloud)
        defer { peer.finish() }
        let old = StoredWindow(root, window: firstID, cloud: cloud)
        let shared = try #require(old.spaces.spaces.first), local = old.spaces.add(name: "Device only")
        let other = old.spaces.add(name: "Second shared Space")
        old.browser.adoptSpaces(from: old.spaces)
        let anchor = old.browser.addPage("https://anchor.example.invalid/")
        let privateURL = "https://private-note.example.invalid/pin-cycle"
        let privateID = old.browser.addPage(privateURL).id
        old.browser.move([.tab(privateID)], toSpace: local.id)
        let knownURL = "https://proven.example.invalid/pin-cycle"
        let knownID = old.browser.addPage(knownURL).id
        old.browser.move([.tab(knownID)], toSpace: other.id)
        old.browser.activate(anchor)
        for space in [shared, other] {
            try await old.host.share(space, in: old.profile)
        }
        await old.host.refresh()
        try await peer.host.enable(.spaces, for: peer.profile)
        for space in peer.host.availableSpaces(for: peer.profile) {
            try await peer.host.join(space, in: peer.profile)
        }
        let oldCloudID = try #require(old.host.links[old.profile.id]?.slots[knownID]?.cloudID)
        let peerKnownSpace = try #require(peer.browser.page(at: knownURL)?.spaceID)
        old.browser.saveBlocking()
        // Reproduce the ordinary NULL row written by older releases, before pinning existed in this session.
        try await old.browser.database.writer.write { db in
            try db.execute(sql: "UPDATE sessionTab SET spaceID = NULL WHERE id = ?", arguments: [privateID])
        }
        old.close()

        var first = StoredWindow(root, window: firstID, cloud: cloud, offline: true)
        var second = first.addWindow(secondID, in: local.id)
        defer { second.closeAllTabs(saving: false); first.close() }
        let loose = try #require(first.browser.tab(id: privateID))
        try #require(loose.spaceID == nil && !first.host.isEnabled(.pins, for: first.profile))
        first.browser.pin(loose)
        first.browser.pin(try #require(first.browser.tab(id: knownID)))
        let privatePin = try #require(loose.pinID), sharedPin = try #require(first.browser.tab(id: knownID)?.pinID)
        first.browser.saveBlocking()
        second.saveBlocking()
        if restartWhilePinned {
            if !unpinAtSource {
                // A pin saved by v4 has no record of its pre-pin Space ownership.
                try await first.browser.database.writer.write { db in
                    if try db.columns(in: "profilePin").contains(where: { $0.name == "requiresSpacePlacement" }) {
                        try db.execute(sql: "ALTER TABLE profilePin DROP COLUMN requiresSpacePlacement")
                        try db.execute(sql: "ALTER TABLE sessionTab DROP COLUMN requiresSpacePlacement")
                        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5-pin-space-placement'")
                    }
                }
            }
            second.closeAllTabs(saving: false)
            first.close()
            first = StoredWindow(root, window: firstID, cloud: cloud, offline: true)
            second = first.addWindow(secondID, in: local.id)
        }
        first.browser.switchSpace(to: shared.id)
        let original = try #require(first.browser.tab(id: privateID))
        first.browser.activate(original)
        original.realizeDeferredSession(byPerson: true)
        try #require(original.pinID == privatePin && original.isMaterialised && !original.isDeferred)
        try #require(first.browser.currentSpaceID == shared.id && second.currentSpaceID == local.id)
        first.browser.saveBlocking()
        #expect(first.browser.spaceMoveTargets(for: [.tab(original.id)]).isEmpty)
        let freshURL = try #require(URL(string: "https://fresh-link.example.invalid/"))
        let fresh = first.browser.newTab(url: freshURL, activate: false, after: original)
        #expect(fresh.spaceID == shared.id)
        let unpinner = unpinAtSource ? first.browser : second
        unpinner.unpin(try #require(unpinner.tabs.first { $0.pinID == privatePin }))
        unpinner.unpin(try #require(unpinner.tabs.first { $0.pinID == sharedPin }))
        #expect(first.browser.tab(id: privateID) === original && original.pinID == nil)
        #expect(original.spaceID == nil && first.browser.isShown(original))
        first.browser.scheduleSave()
        if restartWhilePinned || unpinAtSource {
            first.browser.saveBlocking()
        }
        // The remaining case restarts after profilePin changed and before this window saved its demotion.
        second.saveBlocking()
        first.engine.offline = false
        await first.host.refresh()
        try await peer.sync()
        #expect(!peer.browser.tabs.contains { $0.urlString == privateURL })
        let before = try #require(cloud.records(in: SharedCatalogCategory.spaces.zone)).compactMap(SharedSpaceItem.init(record:))
        #expect(!before.contains { $0.url == privateURL })
        #expect(first.browser.tab(id: knownID)?.spaceID == other.id)
        #expect(first.host.links[first.profile.id]?.slots[knownID]?.cloudID == oldCloudID)
        #expect(peer.browser.page(at: knownURL)?.spaceID == peerKnownSpace)

        second.closeAllTabs(saving: false)
        first.close()
        first = StoredWindow(root, window: firstID, cloud: cloud)
        second = first.addWindow(secondID, in: local.id)
        let retained = try #require(first.browser.tab(id: privateID))
        #expect(first.browser.tab(id: knownID)?.spaceID == other.id)
        #expect(retained.pinID == nil && retained.spaceID == nil && first.browser.isShown(retained))
        first.browser.move([.tab(privateID)], toSpace: shared.id)
        await first.host.refresh()
        try await peer.sync()
        #expect(peer.browser.tabs.filter { $0.urlString == privateURL }.count == 1)
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
