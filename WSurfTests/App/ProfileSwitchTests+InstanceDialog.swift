// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing
import WSurfVault

@testable import WSurf
@testable import WSurfCore

extension ProfileSwitchTests {
    @MainActor
    func button(_ title: String, in view: NSView?) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        return view?.subviews.lazy.compactMap { self.button(title, in: $0) }.first
    }

    private func confirmSharedDeletion(_ profile: Profile, in catalog: ProfileStore) async throws {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()), profiles: .selection(profile: .original(), catalog: catalog))
        defer { coordinator.closeWindow() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ProfileSettings(coordinator: coordinator).environment(\.accessibilityEnabled, true))
        window.contentView = host
        window.orderBack(nil)
        func element(_ node: AnyObject, role: NSAccessibility.Role, text: String) -> AnyObject? {
            if node.accessibilityRole?() == role {
                let value: String? = role == .staticText ? node.accessibilityValue?() : nil
                if [node.accessibilityLabel?(), node.accessibilityTitle?(), value].contains(where: { $0?.contains(text) == true }) {
                    return node
                }
            }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = element(child as AnyObject, role: role, text: text) {
                    return found
                }
            }
            return nil
        }
        func press(_ title: String, in view: NSView) async throws {
            try #require(await waitUntil { element(view, role: .button, text: title) != nil })
            _ = element(view, role: .button, text: title)?.accessibilityPerformPress?()
        }
        try await press(profile.name, in: host)
        try await press(String(localized: "Delete profile…"), in: host)
        try #require(await waitUntil { window.attachedSheet?.contentView != nil })
        let sheet = try #require(window.attachedSheet?.contentView)
        let message = String(localized: "Macs sharing this profile will ask whether to create a new iCloud instance or delete their local copy.")
        #expect(element(sheet, role: .staticText, text: message) != nil)
        try await press(String(localized: "Delete profile"), in: sheet)
        try #require(await waitUntil { !catalog.profiles.contains(profile) })
    }

    private func containsText(_ text: String, in view: NSView?) -> Bool {
        if let label = view as? NSTextField, label.stringValue.contains(text) {
            return true
        }
        return view?.subviews.contains { containsText(text, in: $0) } == true
    }

    @Test(arguments: [false, true])
    func aLinkedMacKeepsItsWorkingCopyUntilTheDeletionDialogIsAnswered(create: Bool) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { copy, _, vaults in
            let vault = try #require(vaults.first)
            let item = syncAccounts(1)[0]
            try await VaultManagerFixture.save([item], in: vault)
            try await chooseInWindow(create: create, copy: copy, vault: vault, item: item)
        }
    }

    private func chooseInWindow(create: Bool, copy: Profile, vault: FixtureVault, item: CredentialAccount) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let senderFile = root.appending(path: "A/profiles.json"), receiverFile = root.appending(path: "B/profiles.json")
        let a = ProfileStore(file: senderFile), b = ProfileStore(file: receiverFile)
        let first = a.add(name: "Other name on A"), kept = b.add(name: "Unrelated")
        let work = try #require(b.adopt(id: copy.id, name: "Work on B", symbol: "key", color: .blue))
        let cloud = FakeSyncCloud(user: "synthetic-shared-owner")
        let previous = CloudSync.shared
        defer {
            CloudSync.shared = previous
            for folder in [root, first.supportDirectory, work.supportDirectory, kept.supportDirectory] {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        func start(_ store: ProfileStore, file: URL, using launch: VaultRemovalLaunch) throws -> CloudSync {
            try launch.start(store, file: file.deletingLastPathComponent().appending(path: "router.json"), cloud: cloud,
                             host: CredentialVaultSyncHost(profiles: { store.profiles }), discovery: false)
        }
        let sender = try start(a, file: senderFile, using: VaultRemovalLaunch())
        let firstB = try start(b, file: receiverFile, using: VaultRemovalLaunch())
        defer { sender.prepareToTerminate(); firstB.prepareToTerminate() }
        let sharing = try #require(sender.sharedSpaces), receiving = try #require(firstB.sharedSpaces)
        let sharedID = try await sharing.publishProfile(first)
        try await sharing.refresh()
        try await receiving.enable(.profiles, for: work)
        try #require(receiving.linkProfile(work.id, to: sharedID))
        try #require(sharedID != work.id && first.id != work.id)
        firstB.setVaultDiscovery(true)
        let syncing = try #require(firstB.vaults)
        try #require(await waitUntil { syncing.engine != nil })
        try await syncing.enable(profileID: work.id, vaultID: vault.vaultID)
        let vaultZone = SyncZone.vault(profileID: work.id, vaultID: vault.vaultID)
        try #require(try await waitUntil {
            await syncing.settle()
            try await syncing.engine?.sendNow()
            return cloud.names(in: vaultZone).contains(item.id.uuidString)
        })
        let originalVault = try #require(cloud.records(in: vaultZone))
        let visit = "https://example.invalid/profile-instance"
        func history() throws -> HistoryStore {
            HistoryStore(database: AppDatabase(at: try #require(work.databaseURL)))
        }
        try #require(try history().record(url: visit, title: "Synthetic visit") != nil)
        CloudSync.shared = sender
        try await confirmSharedDeletion(first, in: a)

        func open(_ store: ProfileStore) -> (BrowserApplication, AppCoordinator) {
            let app = BrowserApplication()
            let coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: work), windowID: UUID()), profiles: .selection(profile: work, catalog: store))
            app.register(coordinator)
            coordinator.prepareBrowser(restoring: false, show: false)
            coordinator.showBrowser(activate: false)
            return (app, coordinator)
        }
        let local = String(localized: "Delete from This Mac"), new = String(localized: "Create New Instance")
        CloudSync.shared = firstB
        let (before, window) = open(b)
        defer { before.windows.forEach { $0.closeWindow() } }
        let tab = window.browser.newTab(url: URL(string: "about:blank#synthetic"))
        try #require(await waitUntil(timeout: .seconds(6)) {
            sender.beat()
            firstB.beat()
            return button(new, in: window.nativeWindow?.attachedSheet?.contentView) != nil
        }, "The different local UUID must resolve through the confirmed iCloud profile link.")
        let sheet = window.nativeWindow?.attachedSheet?.contentView
        #expect(containsText(String(localized: "This profile was deleted from iCloud"), in: sheet))
        #expect(containsText(work.name, in: sheet))
        #expect(window.browser.tabs.contains { $0 === tab })
        #expect(try await vault.manager.snapshot().accounts == [item])
        #expect(try history().visits.contains { $0.url == visit })
        firstB.prepareToTerminate()
        window.closeWindow()
        let restored = ProfileStore(file: receiverFile), launch = VaultRemovalLaunch()
        let secondB = try start(restored, file: receiverFile, using: launch)
        CloudSync.shared = secondB
        defer { secondB.prepareToTerminate() }
        let (after, reopened) = open(restored)
        defer { after.windows.forEach { $0.closeWindow() } }
        func press(_ title: String) async throws {
            try #require(await waitUntil { button(title, in: reopened.nativeWindow?.attachedSheet?.contentView) != nil })
            let target = try #require(button(title, in: reopened.nativeWindow?.attachedSheet?.contentView))
            target.performClick(nil)
        }
        try await press(local)
        try await press(String(localized: "Cancel"))
        #expect(restored.profiles.contains(work))
        #expect(try history().visits.contains { $0.url == visit })
        if create {
            try await press(new)
            let catalog = try #require(secondB.sharedSpaces)
            try #require(await waitUntil {
                secondB.beat()
                guard let next = catalog.links[work.id]?.profile, next != sharedID else { return false }
                return cloud.names(in: SharedCatalogCategory.profiles.zone).contains(next.uuidString)
            })
            #expect(restored.profiles.filter { $0.id == work.id }.count == 1 && restored.profiles.count == 3)
            if !vault.manager.isUnlocked {
                try await VaultManagerFixture.unlock(vault)
            }
            #expect(try await vault.manager.snapshot().accounts == [item])
            #expect(try history().visits.contains { $0.url == visit })
            #expect(!catalog.available(.profiles, for: work).contains { $0.id == sharedID })
        } else {
            try await press(local)
            try await press(String(localized: "Delete profile"))
            try #require(await waitUntil { !restored.profiles.contains(work) && !FileManager.default.fileExists(atPath: work.supportDirectory.path) })
            #expect(reopened.context.profile.isOriginal)
            secondB.beat()
            try await launch.engine?.sendNow()
            #expect(cloud.records(in: vaultZone) == originalVault)
            let localVault = CloudProfileInstance.vault(profile: work.id, instance: nil, owner: cloud.user)
            #expect(cloud.record(localVault.recordID) == nil && restored.vaultRemovals.isEmpty)
        }
        #expect(restored.profiles.contains(kept))
    }

    @Test func onlyTheOwnersRetirementOfTheLinkedInstanceCanOfferTheDecision() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ProfileStore(file: root.appending(path: "profiles.json"))
        let work = store.add(name: "Bound Work")
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeSyncCloud(user: "synthetic-first")
        let launch = VaultRemovalLaunch(), host = FakeVaultHost(root: root.appending(path: "vaults"))
        let vault = try host.addVault(profile: work.id)
        let app = try launch.start(store, file: root.appending(path: "router.json"), cloud: cloud, host: host, discovery: true)
        defer { app.prepareToTerminate() }
        let sharing = try #require(app.sharedSpaces)
        let group = try await sharing.publishProfile(work)
        let sync = try #require(app.vaults)
        try #require(await waitUntil { sync.engine != nil })
        try await sync.enable(profileID: work.id, vaultID: vault.vaultID)
        let engine = try #require(launch.engine)
        await sync.settle()
        try await engine.sendNow()
        let zone = SyncZone.vault(profileID: work.id, vaultID: vault.vaultID)
        cloud.deleteZone(zone, reason: .deleted)
        try await engine.fetchNow()
        #expect(store.cloudLedger.pending.isEmpty && store.profiles.contains(work))
        let unrelated = CloudProfileInstance(.shared, id: work.id, owner: cloud.user)
        try await engine.publishRetirement(unrelated)
        await app.checkProfileInstances()
        #expect(store.cloudLedger.pending.isEmpty)
        let proof = CloudProfileInstance(.shared, id: group, owner: cloud.user)
        try await engine.publishRetirement(proof)
        engine.offline = true
        await app.checkProfileInstances()
        #expect(store.cloudLedger.pending.isEmpty)
        engine.offline = false
        let other = FakeSyncCloud(user: "synthetic-visitor")
        engine.cloud = other
        try await engine.publishRetirement(.init(.shared, id: group, owner: other.user))
        await app.checkProfileInstances()
        #expect(store.cloudLedger.pending.isEmpty && store.profiles.contains(work))
        engine.cloud = cloud
        await app.checkProfileInstances()
        try #require(store.cloudLedger.pending[work.id] == proof)
        engine.cloud = other
        await #expect(throws: VaultSyncFailure.self) { try await app.createNewInstance(of: work, retiring: proof) }
        #expect(store.cloudLedger.pending[work.id] == proof && store.cloudLedger.active[work.id] == nil)
    }

    @Test func retryAfterARejectedCatalogWriteRetiresOnlyTheWarnedLink() async throws {
        let files = FileManager.default, root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let catalogFile = root.appending(path: "iCloudSharedSpaces.json"), profiles = root.appending(path: "profiles.json")
        let store = ProfileStore(file: profiles), work = store.add(name: "Retry Work")
        let oldService = CloudSync.shared
        defer {
            CloudSync.shared = oldService
            try? files.setAttributes([.immutable: false], ofItemAtPath: catalogFile.path)
            try? files.removeItem(at: work.supportDirectory)
            try? files.removeItem(at: root)
        }
        let cloud = FakeSyncCloud(user: "synthetic-retry-owner"), host = FakeVaultHost(root: root)
        let first = VaultRemovalLaunch(), router = root.appending(path: "router.json")
        let app = try first.start(store, file: router, cloud: cloud, host: host, discovery: false)
        defer { app.prepareToTerminate() }
        CloudSync.shared = app
        let sharing = try #require(app.sharedSpaces)
        let group = try await sharing.publishProfile(work)
        await sharing.refresh()
        let proof = CloudProfileInstance(.shared, id: group, owner: cloud.user)
        let warning = try await CredentialErasureNote.warning(for: work)
        try #require(warning.sharedCopies == [proof])
        try files.setAttributes([.immutable: true], ofItemAtPath: catalogFile.path)
        let failed = await store.remove(work, confirmedVaults: [], scope: .confirmed(warning.sharedCopies))
        #expect(throws: (any Error).self) { try failed.get() }
        #expect(store.profiles.contains(work) && cloud.record(proof.recordID) == nil)
        app.prepareToTerminate()

        try files.setAttributes([.immutable: false], ofItemAtPath: catalogFile.path)
        let recovered = ProfileStore(file: profiles), relaunch = VaultRemovalLaunch()
        let service = try relaunch.start(recovered, file: router, cloud: cloud, host: host, discovery: false)
        defer { service.prepareToTerminate() }
        CloudSync.shared = service
        #expect(service.sharedSpaces?.links[work.id] == nil && cloud.record(proof.recordID) == nil)
        try await confirmSharedDeletion(work, in: recovered)
        try #require(await waitUntil { service.beat(); return cloud.record(proof.recordID) != nil })
        #expect(cloud.names(in: CloudProfileInstance.zone) == [proof.recordID.name])
    }
}
