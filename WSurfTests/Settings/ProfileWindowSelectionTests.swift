// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct ProfileWindowSelectionTests {
    @Test func selectingAProfileAffectsOnlyThatWindow() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        let catalog = ProfileStore(file: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let work = catalog.add(name: "Work")
        let first = ProfileStore.selection(profile: .original(), catalog: catalog)
        let second = ProfileStore.selection(profile: .original(), catalog: catalog)

        first.markCurrent(work)

        #expect(first.current.id == work.id)
        #expect(second.current.isOriginal)
        #expect(catalog.current.id == work.id)
    }

    @Test func windowsShareCatalogEditsButKeepSelection() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        let catalog = ProfileStore(file: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let work = catalog.add(name: "Work")
        catalog.setLaunchProfile(work.id)
        let first = ProfileStore.selection(profile: work, catalog: catalog)
        let second = ProfileStore.selection(profile: .original(), catalog: catalog)

        first.rename(work, to: "Research")
        first.setLaunchProfile(nil)

        #expect(second.profiles.first(where: { $0.id == work.id })?.name == "Research")
        #expect(second.launchProfileID == nil)
        #expect(first.current.id == work.id)
        #expect(second.current.isOriginal)
    }

    @Test func privateSelectionDoesNotChangeRegularWindowOrCatalogSelection() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        let catalog = ProfileStore(file: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let work = catalog.add(name: "Work")
        let regular = ProfileStore.selection(profile: work, catalog: catalog)
        let privateWindow = ProfileStore.selection(profile: .privateBrowsing(), catalog: catalog)

        #expect(privateWindow.isPrivate)
        #expect(regular.current.id == work.id)
        #expect(ProfileStore(file: file).current.id == work.id)
    }
}
