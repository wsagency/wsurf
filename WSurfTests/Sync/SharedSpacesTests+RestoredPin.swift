// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf

extension SharedSpacesTests {
    @Test(arguments: [false, true])
    func restoringAnOlderWindowSnapshotKeepsTheOriginalSharedFavorite(windowWasClosed: Bool) async throws {
        let cloud = FakeSyncCloud()
        let studio = Mac(cloud), air = Mac(cloud)
        defer { studio.finish(); air.finish() }
        let address = "https://restored-favorite.example.test/"
        let page = studio.browser.addPage(address)
        let local = air.browser.addPage(address)
        try await studio.host.share(try #require(studio.store.spaces.first), in: studio.profile)
        try await studio.sync()
        try await air.host.enable(.spaces, for: air.profile)
        try await air.host.join(try #require(air.host.availableSpaces(for: air.profile).first), in: air.profile)
        let original = try #require(air.browser.tab(id: page.id))
        local.spaceID = nil
        air.browser.unplacedSpaceRows.insert(.tab(local.id))
        air.browser.saveDebounce = .seconds(120)
        air.browser.saveDeadline = .seconds(120)
        air.browser.saveBlocking()
        if windowWasClosed {
            air.browser.markSessionClosed()
            air.browser.closeAllTabs(saving: false)
        }

        studio.browser.addFavorite(page)
        try await studio.sync()
        try await air.sync()
        let pin = try #require(page.pinID)
        try #require(air.browser.pinStore.pins.contains { $0.id == pin && $0.isFavorite })
        air.browser.closeAllTabs(saving: false)

        let restored = BrowserModel(context: air.browser.context, windowID: air.browser.windowID, database: air.browser.database)
        defer { restored.closeAllTabs(saving: false) }
        let host = CloudSharedSpaces(
            stateFile: air.dir.appending(path: "shared.json"), profiles: [air.profile], windows: { [weak restored] in [restored].compactMap { $0 } },
            spaces: { _ in air.store }, pins: { _ in restored.pinStore }
        )
        restored.sharedSpacesHost = host
        restored.adoptSpaces(air.store.spaces.map(\.id))
        restored.restoreSession()

        #expect(restored.tabs.filter { $0.urlString == address && $0.isFavorite }.map(\.id) == [original.id])
        #expect(restored.tab(id: original.id)?.pinID == pin)
        let localCopy = try #require(restored.tab(id: local.id))
        #expect(localCopy.pinID == nil && !localCopy.isFavorite && restored.unplacedSpaceRows.contains(.tab(localCopy.id)))
        #expect(restored.tabs.filter { $0.urlString == address }.count == 2)
    }
}
