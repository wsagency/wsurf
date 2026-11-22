// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    @Test(arguments: [false, true])
    func openSpaceRestoresTheSharedTabWhenItsWindowClosedOrChangedProfile(sameWindow: Bool) async throws {
        let catalog = ProfileStore.shared, previous = catalog.current
        let local = catalog.add(name: "Work")
        let home = Space(id: UUID(), name: "Studio home", symbol: "briefcase", color: .blue)
        let adopted = try catalog.addProfile(forFirstSpace: home)
        let result: Result<Void, Error>
        do {
            try await reopenStudioTab(on: local, in: adopted, sameWindow: sameWindow)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await catalog.remove(adopted)
        await catalog.remove(local)
        catalog.markCurrent(previous)
        try result.get()
    }

    private func reopenStudioTab(on local: Profile, in adopted: Profile, sameWindow: Bool) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud, name: "Studio")
        defer { studio.finish() }
        let published = try #require(studio.store.spaces.first)
        let source = studio.browser.addPage("https://work.example.test/saved-window")
        try await studio.host.share(published, in: studio.profile)
        try await studio.sync()

        let air = BrowserApplication()
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
        let caller = sameWindow ? first : air.newWindow(profile: local, show: false)
        if sameWindow {
            await first.switchProfile(to: local)
        } else {
            first.closeWindow()
        }
        let kept = caller.browser.addPage("https://local.example.test/air")
        caller.browser.activate(kept)
        caller.openSharedSpace(SpaceEntry(space: joined, profile: adopted))
        try #require(await waitUntil {
            air.windows.contains { $0.windowID == first.windowID && $0.context.profile.id == adopted.id && $0.browser.activeTabID == received.id }
        })
        let reopened = try #require(air.windows.first { $0.windowID == first.windowID })
        #expect(reopened.browser.currentSpaceID == joined.id)
        if !sameWindow {
            #expect(caller.context.profile.id == local.id && caller.browser.activeTab === kept)
        }
        reopened.browser.close(try #require(reopened.browser.activeTab))
        try await engine?.sendNow()
        try await studio.sync()
        #expect(studio.browser.tab(id: source.id) == nil)
    }
}
