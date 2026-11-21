// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

extension ProfileSwitchTests {
    enum DeletionFault: CaseIterable {
        case none, profileList, database
    }

    @Test(arguments: DeletionFault.allCases)
    func deletingWorkFromPersonalSettingsShowsWhatWasRemoved(fault: DeletionFault) async throws {
        let files = FileManager.default
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json")
        let catalog = ProfileStore(file: file), work = catalog.add(name: "Work")
        let database = try #require(work.databaseURL)
        defer {
            try? files.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? files.setAttributes([.immutable: false], ofItemAtPath: database.path)
            try? files.removeItem(at: work.supportDirectory)
            try? files.removeItem(at: root)
        }
        try #require(!AppDatabase(at: database).isEphemeral)
        let personal = ProfileStore.selection(profile: .original(), catalog: catalog)
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()), profiles: personal)
        defer { coordinator.closeWindow() }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: VStack(alignment: .leading) {
            ProfileSettings(coordinator: coordinator)
        }.environment(\.accessibilityEnabled, true))
        window.contentView = host
        window.orderBack(nil)
        func shows(_ role: NSAccessibility.Role, _ name: String) -> Bool {
            host.layoutSubtreeIfNeeded()
            return profilePageElement(in: host, role: role, containing: name) != nil
        }
        func press(_ name: String, in view: NSView) async throws {
            try #require(await waitUntil { profilePageElement(in: view, role: .button, containing: name) != nil })
            let button = try #require(profilePageElement(in: view, role: .button, containing: name))
            _ = button.accessibilityPerformPress?()
        }
        func confirmDeletion() async throws {
            try await press(String(localized: "Delete profile…"), in: host)
            try #require(await waitUntil { window.attachedSheet != nil })
            let sheet = try #require(window.attachedSheet?.contentView)
            try await press(String(localized: "Delete profile"), in: sheet)
        }

        try await press(work.name, in: host)
        if fault != .none {
            let locked = fault == .profileList ? file : database
            try files.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        }
        try await confirmDeletion()
        let retryNotice = String(localized: "The profile was removed from the list. Reopen WSurf to retry deleting its local data.")
        switch fault {
        case .profileList:
            try #require(await waitUntil { shows(.staticText, file.lastPathComponent) })
            #expect(catalog.profiles.contains(work) && files.fileExists(atPath: database.path))
            #expect(!shows(.staticText, retryNotice))
            try files.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try await confirmDeletion()
        case .database:
            try #require(await waitUntil { !catalog.profiles.contains(work) })
            #expect(files.fileExists(atPath: database.path))
            try #require(await waitUntil { shows(.staticText, retryNotice) }, "A removed profile still explains its pending local erasure")
            try await press(String(localized: "Profiles"), in: host)
            try #require(await waitUntil { shows(.button, String(localized: "Add profile…")) })
            try files.setAttributes([.immutable: false], ofItemAtPath: database.path)
            let reopened = ProfileStore(file: file)
            #expect(reopened.profiles == [.original()])
        case .none:
            break
        }
        try #require(await waitUntil { shows(.button, String(localized: "Add profile…")) })
        #expect(personal.current.isOriginal && catalog.profiles == [.original()])
        #expect(!shows(.staticText, retryNotice))
        #expect(await waitUntil {
            guard let saved = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return !files.fileExists(atPath: work.supportDirectory.path) && !saved.contains(work.id.uuidString)
        })
    }

    // SwiftUI's nodes implement the AppKit accessibility methods without conforming to NSAccessibilityProtocol.
    private func profilePageElement(in root: AnyObject, role: NSAccessibility.Role, containing name: String) -> AnyObject? {
        if root.accessibilityRole?() == role {
            let value: String? = role == .staticText ? root.accessibilityValue?() : nil
            if [root.accessibilityLabel?(), root.accessibilityTitle?(), value].contains(where: { $0?.contains(name) == true }) {
                return root
            }
        }
        for child in root.accessibilityChildren?() ?? [] {
            if let found = profilePageElement(in: child as AnyObject, role: role, containing: name) {
                return found
            }
        }
        return nil
    }
}
