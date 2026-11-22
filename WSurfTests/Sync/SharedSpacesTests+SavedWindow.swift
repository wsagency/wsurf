// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    enum OpenPath: String, Sendable {
        case closedWindow, switchedWindow, profileAfterRestart, spaceAfterRestart

        var restarts: Bool {
            self == .profileAfterRestart || self == .spaceAfterRestart
        }
    }

    @Test(arguments: [OpenPath.closedWindow, .switchedWindow, .profileAfterRestart, .spaceAfterRestart])
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

        var air = BrowserApplication()
        let gate = CloudSyncGate.Inputs(tabsFlag: false, vaultFlag: false, isRunningTests: false, isStaged: false, ownsSession: true,
                                        entitlement: { CloudTabsTests.Launch.entitlements[$0] }, offersMacSync: true)
        var engine: FakeSyncEngine?
        let started = CloudSync.start(
            gate: gate, installIDs: MemoryInstallIDStorage(), stateFile: studio.dir.appending(path: "air/router.json"), profiles: [adopted, local],
            windows: { air.windows.map(\.browser) }, makeEngine: { delegate, _ in
                let transport = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engine = transport
                return transport
            }
        )
        let service = try #require(started)
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
        if path == .switchedWindow {
            await first.switchProfile(to: local)
        } else {
            first.closeWindow()
        }
        let kept = initialCaller.browser.addPage("https://local.example.test/air")
        initialCaller.browser.activate(kept)
        let caller: AppCoordinator
        if path.restarts {
            // Another Work window got a new shared tab while the older window held the rest.
            let small = air.newWindow(profile: adopted, show: false)
            small.browser.switchSpace(to: joined.id)
            let recent = small.browser.addPage("https://work.example.test/recent")
            small.browser.activate(recent)
            small.browser.scheduleSave()
            await host.refresh()
            air.prepareToTerminate()
            await air.closeTabsForTermination()
            air.windows.forEach { $0.nativeWindow?.close() }
            air = BrowserApplication()
            service.cancelTermination()
            air.restoreWindows(of: [local, adopted], show: false)
            let shortSession = try #require(air.windows.first { $0.windowID == small.windowID })
            #expect(shortSession.browser.tab(id: recent.id) != nil && shortSession.browser.tab(id: received.id) == nil)
            caller = try #require(air.windows.first { $0.windowID == initialCaller.windowID })
        } else {
            caller = initialCaller
        }
        if path == .profileAfterRestart {
            await caller.switchProfile(to: adopted)
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
        if path != .switchedWindow {
            #expect(caller.context.profile.id == local.id && caller.browser.activeTabID == kept.id)
        }
        #expect(reopened.browser.tabs.contains { $0.urlString == second.urlString })
        reopened.browser.close(try #require(reopened.browser.tab(id: received.id)))
        try await engine?.sendNow()
        try await studio.sync()
        #expect(studio.browser.tab(id: source.id) == nil)
    }
}
