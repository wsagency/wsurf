// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    enum OpenPath: String, Sendable {
        case closedWindow, switchedWindow, profileAfterRestart, spaceAfterRestart, profileWhileOwnerHasAnotherProfile, profileBeforeAccountVerification
        case spaceWhileLaunching, gatherAfterRestart

        var restarts: Bool {
            self == .profileAfterRestart || self == .spaceAfterRestart || self == .profileBeforeAccountVerification || self == .gatherAfterRestart
        }
    }

    @Test(arguments: [
        OpenPath.closedWindow, .switchedWindow, .profileAfterRestart, .spaceAfterRestart,
        .profileWhileOwnerHasAnotherProfile, .profileBeforeAccountVerification, .spaceWhileLaunching, .gatherAfterRestart,
    ])
    func openSpaceRestoresTheSharedTabWhenItsWindowClosedOrChangedProfile(path: OpenPath) async throws {
        let catalog = ProfileStore.shared, previous = catalog.current
        let local = catalog.add(name: "Work")
        let home = Space(id: UUID(), name: "Studio home", symbol: "briefcase", color: .blue)
        let adopted = try catalog.addProfile(forFirstSpace: home)
        let result: Result<Void, Error>
        do {
            try await reopenStudioTab(on: local, in: adopted, path: path)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await catalog.remove(adopted)
        await catalog.remove(local)
        catalog.markCurrent(previous)
        try result.get()
    }

    private func reopenStudioTab(on local: Profile, in adopted: Profile, path: OpenPath) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio")
        defer { studio.finish() }
        let published = try #require(studio.store.spaces.first)
        let source = studio.browser.addPage("https://work.example.test/saved-window")
        let second = studio.browser.addPage("https://work.example.test/second")
        try await studio.host.share(published, in: studio.profile)
        try await studio.sync()

        var air = BrowserApplication(ownsSession: true)
        var engine: FakeSyncEngine?
        let installIDs = MemoryInstallIDStorage()
        func makeService() throws -> CloudSync {
            try makeSavedWindowService(cloud: cloud, dir: studio.dir, profiles: [adopted, local], installIDs: installIDs,
                                       windows: { air.windows.map(\.browser) }, didMakeEngine: { engine = $0 })
        }
        var service = try makeService()
        let previous = CloudSync.shared, notices = SpaceSwitchNotice.defaults
        CloudSync.shared = service
        SpaceSwitchNotice.defaults = InMemoryUserDefaults(inheriting: notices)
        SpaceSwitchNotice.stopAsking()
        defer {
            air.windows.forEach { $0.closeWindow() }
            SpaceSwitchNotice.defaults = notices
            service.prepareToTerminate()
            CloudSync.shared = previous
        }
        let host = try #require(service.sharedSpaces)
        let first = air.newWindow(profile: adopted, show: false)
        try await host.enable(.spaces, for: adopted)
        let remote = try #require(host.availableSpaces(for: adopted).first)
        let joined = try await host.join(remote, in: adopted)
        let received = try #require(first.browser.tabs.first { $0.urlString == source.urlString })
        first.browser.switchSpace(to: joined.id, showing: received)
        first.openSettings(.sync)
        let initialCaller = path == .switchedWindow ? first : air.newWindow(profile: local, show: false)
        if path == .spaceWhileLaunching {
            air = await restartWindows(air, with: service)
            let launch = air.beginLaunchRestore(of: [local, adopted], lastWindowID: initialCaller.windowID, launchProfileID: nil, show: false)
            let lead = try #require(launch.leadWindow)
            #expect(lead.windowID == initialCaller.windowID)
            lead.openSharedSpace(SpaceEntry(space: joined, profile: adopted))
            #expect(air.windows.count == 1)
            #expect(air.continueLaunchRestore(launch, show: false))
            let restored = try #require(air.windows.first { $0.windowID == first.windowID })
            #expect(air.windows.count == 2 && restored.browser.tab(id: received.id) != nil)
            return
        }
        if path == .profileWhileOwnerHasAnotherProfile {
            await first.switchProfile(to: local)
            let localPage = first.browser.addPage("https://local.example.test/where-i-was")
            first.browser.activate(localPage)
            await initialCaller.switchProfile(to: adopted)
            #expect(initialCaller.context.profile.id == adopted.id)
            #expect(first.context.profile.id == local.id && first.browser.activeTab === localPage)
            return
        }
        if path == .switchedWindow {
            await first.switchProfile(to: local)
        } else {
            first.closeWindow()
        }
        let kept = initialCaller.browser.addPage("https://local.example.test/air")
        initialCaller.browser.activate(kept)
        var splitTab: (window: UUID, tab: UUID)?
        let caller: AppCoordinator
        if path.restarts {
            // Another Work window got a new shared tab while the older window held the rest.
            let small = air.newWindow(profile: adopted, show: false)
            small.browser.switchSpace(to: joined.id)
            let recent = small.browser.addPage("https://work.example.test/recent")
            splitTab = (small.windowID, recent.id)
            small.browser.activate(recent)
            small.browser.scheduleSave()
            await host.refresh()
            air = await restartWindows(air, with: service)
            air.restoreWindows(of: [local, adopted], show: false)
            let shortSession = try #require(air.windows.first { $0.windowID == small.windowID })
            #expect(shortSession.browser.tab(id: recent.id) != nil && shortSession.browser.tab(id: received.id) == nil)
            caller = try #require(air.windows.first { $0.windowID == initialCaller.windowID })
        } else {
            caller = initialCaller
        }
        if path == .profileBeforeAccountVerification {
            let transport = try #require(engine)
            transport.available = false
            try #require(await !host.catalog.verifyAccount())
            #expect(host.isEnabled(.spaces, for: adopted) && host.cloudProfileID(for: adopted.id) == nil)
            await caller.switchProfile(to: adopted)
            #expect(caller.context.profile.id == adopted.id)
            #expect(!air.windows.contains { $0.windowID == first.windowID })
            return
        } else if path == .profileAfterRestart {
            await caller.switchProfile(to: adopted)
        } else if path == .gatherAfterRestart {
            try await gatherViaSettings(profile: adopted, host: host, caller: caller, split: try #require(splitTab), into: first.windowID)
        } else {
            caller.openSharedSpace(SpaceEntry(space: joined, profile: adopted))
        }
        try #require(await waitUntil {
            air.windows.contains { window in
                window.windowID == first.windowID && window.context.profile.id == adopted.id
                && (path.restarts ? window.browser.activeTab?.spaceID == joined.id : window.browser.activeTabID == received.id)
            }
        })
        let reopened = try #require(air.windows.first { $0.windowID == first.windowID })
        #expect(reopened.browser.currentSpaceID == joined.id)
        #expect(path == .switchedWindow || (caller.context.profile.id == local.id && caller.browser.activeTabID == kept.id))
        #expect(reopened.browser.tabs.contains { $0.urlString == second.urlString })
        if path == .gatherAfterRestart {
            air = await restartWindows(air, with: service, reconnecting: false)
            service = try makeService()
            CloudSync.shared = service
            let tab = try #require(splitTab?.tab)
            try await checkGatheredTab(tab, in: air, restoring: [local, adopted], destination: reopened.windowID,
                                       space: joined.id, studio: studio, engine: engine)
        }
        try await checkSharedClose(received.id, in: try #require(air.windows.first { $0.windowID == reopened.windowID }),
                                   peer: source.id, studio: studio, engine: engine)
    }

    private func makeSavedWindowService(cloud: FakeSyncCloud, dir: URL, profiles: [Profile], installIDs: MemoryInstallIDStorage,
                                        windows: @escaping @MainActor () -> [BrowserModel], didMakeEngine: @escaping (FakeSyncEngine) -> Void) throws -> CloudSync {
        let gate = CloudSyncGate.Inputs(tabsFlag: false, vaultFlag: false, isRunningTests: false, isStaged: false, ownsSession: true,
                                        entitlement: { CloudTabsTests.Launch.entitlements[$0] }, offersMacSync: true)
        let started = CloudSync.start(gate: gate, installIDs: installIDs, stateFile: dir.appending(path: "air/router.json"), profiles: profiles,
                                      windows: windows, makeEngine: { delegate, _ in
            let transport = FakeSyncEngine(cloud: cloud, delegate: delegate)
            didMakeEngine(transport)
            return transport
        })
        return try #require(started)
    }

    private func checkGatheredTab(_ recent: UUID, in application: BrowserApplication, restoring profiles: [Profile], destination: UUID,
                                  space: UUID, studio: Mac, engine: FakeSyncEngine?) async throws {
        application.restoreWindows(of: profiles, show: false)
        let destination = try #require(application.windows.first { $0.windowID == destination })
        #expect(application.windows.filter { $0.browser.tab(id: recent) != nil }.map(\.windowID) == [destination.windowID])
        #expect(destination.browser.tab(id: recent)?.spaceID == space)
        #expect(try destination.browser.savedSharedRowOwners(in: space)[recent] == destination.windowID)
        let host = try #require(destination.browser.sharedSpaceService)
        let slot = try #require(host.links[destination.context.profile.id]?.slots[recent])
        #expect(slot.movingFrom == nil && (slot.editedAfterRevision ?? .max) < destination.browser.sessionRevision)
        await host.refresh()
        let local = try #require(application.windows.first { $0.context.profile.id != destination.context.profile.id })
        let prior = local.context.profile.id
        await local.switchProfile(to: destination.context.profile)
        #expect(local.context.profile.id == prior)
        try await engine?.sendNow()
        try await studio.sync()
        let peer = try #require(studio.browser.tab(id: slot.cloudID))
        try await checkSharedClose(recent, in: destination, peer: peer.id, studio: studio, engine: engine)
    }

    private func gatherViaSettings(profile: Profile, host: CloudSharedSpaces, caller: AppCoordinator, split: (window: UUID, tab: UUID),
                                   into destination: UUID) async throws {
        let source = try #require(caller.application?.windows.first { $0.windowID == split.window })
        try checkGatherWriteFailure(source: source, caller: caller, profile: profile, tab: split.tab, destination: destination)
        host.links[profile.id]?.slots[split.tab]?.window = destination
        host.links[profile.id]?.slots[split.tab]?.movingFrom = split.window
        try #require(host.persistLinks())
        host.recoverGatheredWindows(in: source.browser)
        #expect(host.links[profile.id]?.slots[split.tab]?.window == split.window)
        #expect(host.links[profile.id]?.slots[split.tab]?.movingFrom == nil)
        source.closeWindow()
        try #require(source.isClosed)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: SharedSpacesSettingsView(profile: profile, host: host, coordinator: caller)
            .environment(\.accessibilityEnabled, true))
        window.contentView = view
        window.orderBack(nil)
        let title = String(localized: "Gather Tabs in One Window")
        try #require(await waitUntil { self.sharedSpaceButton(title, in: view)?.isAccessibilityEnabled?() == true })
        _ = sharedSpaceButton(title, in: view)?.accessibilityPerformPress?()
        try #require(await waitUntil { host.links[profile.id]?.slots[split.tab]?.window == destination })
        #expect(host.links[profile.id]?.slots[split.tab]?.movingFrom == nil)
        // The SQLite commit can finish before the checkpoint clears its transfer marker.
        host.links[profile.id]?.slots[split.tab]?.movingFrom = split.window
        host.links[profile.id]?.slots[split.tab]?.editedAfterRevision = .max
        try #require(host.persistLinks())
    }

    private func checkGatherWriteFailure(source: AppCoordinator, caller: AppCoordinator, profile: Profile, tab: UUID, destination: UUID) throws {
        let spaceID = try #require(source.browser.tab(id: tab)?.spaceID)
        let space = try #require(source.context.spaces?.space(id: spaceID))
        let entry = SpaceEntry(space: space, profile: profile)
        let database = source.context.database.writer
        let id = tab.uuidString.replacingOccurrences(of: "-", with: "")
        let windowID = destination.uuidString.replacingOccurrences(of: "-", with: "")
        try database.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER rejectGather BEFORE INSERT ON sessionTab
                WHEN upper(CASE typeof(NEW.id) WHEN 'blob' THEN hex(NEW.id) ELSE replace(NEW.id, '-', '') END) = '\(id)'
                 AND upper(CASE typeof(NEW.windowID) WHEN 'blob' THEN hex(NEW.windowID) ELSE replace(NEW.windowID, '-', '') END) = '\(windowID)'
                BEGIN SELECT RAISE(ABORT, 'test gather write failure'); END
                """)
        }
        defer { try? database.write { try $0.execute(sql: "DROP TRIGGER rejectGather") } }
        #expect(throws: SharedCatalogError.storage) { try caller.gatherSharedTabs(in: entry) }
        source.browser.saveBlocking()
        #expect(source.browser.tab(id: tab)?.spaceID == spaceID)
        #expect(try source.browser.savedSharedRowOwners(in: spaceID)[tab] == source.windowID)
    }

    private func checkSharedClose(_ id: UUID, in window: AppCoordinator, peer: UUID, studio: Mac, engine: FakeSyncEngine?) async throws {
        window.browser.close(try #require(window.browser.tab(id: id)))
        try await engine?.sendNow()
        try await studio.sync()
        #expect(studio.browser.tab(id: peer) == nil)
    }

    private func restartWindows(_ app: BrowserApplication, with service: CloudSync, reconnecting: Bool = true) async -> BrowserApplication {
        app.prepareToTerminate()
        await app.closeTabsForTermination()
        app.windows.forEach { $0.nativeWindow?.close() }
        let restarted = BrowserApplication(ownsSession: app.ownsSession)
        if reconnecting {
            service.cancelTermination()
        }
        return restarted
    }
}
