// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import Testing
import WebKit
import WSurfCore
import WSurfVault

@testable import WSurf

/// Spaces with their own sign-ins: a separate space is a new profile, and choosing a space of another profile is
/// the profile switch WSurf already does. Deleting a space never deletes a profile.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct SpaceProfileTests {
    @MainActor
    private final class Fixture {
        let app = BrowserApplication()
        let file = FileManager.default.temporaryDirectory.appending(path: "space-profiles-\(UUID())").appending(path: "profiles.json")
        let suite = AppDatabase.defaultsSuite("SpaceProfileTests-\(UUID().uuidString)")
        let catalog: ProfileStore
        let work: Profile
        let coordinator: AppCoordinator
        private let savedNotices: UserDefaults

        init() {
            savedNotices = SpaceSwitchNotice.defaults
            catalog = ProfileStore(file: file)
            work = catalog.add(name: "Work", symbol: "briefcase", color: .blue)
            let selection = ProfileStore.selection(profile: .original(), catalog: catalog)
            coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: .original()), windowID: UUID()), profiles: selection)
            app.register(coordinator)
            coordinator.prepareBrowser(restoring: false, show: false)
            // The explanation was seen, so choosing a space of another profile switches without a sheet.
            SpaceSwitchNotice.defaults = UserDefaults(suiteName: suite)!
            SpaceSwitchNotice.stopAsking()
        }

        func close(keeping otherOwners: Set<UUID> = []) {
            app.windows.forEach { $0.closeWindow() }
            SpaceSwitchNotice.defaults.removePersistentDomain(forName: suite)
            SpaceSwitchNotice.defaults = savedNotices
            for profile in catalog.profiles where !profile.isOriginal && !otherOwners.contains(profile.id) {
                BrowserProfileContext.forget(profile.id)
                SpaceStore.forget(profile.id)
                ProfileSettingsStore.forget(profile.id)
                try? FileManager.default.removeItem(at: profile.supportDirectory)
            }
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    // MARK: - Separate sign-ins

    @Test func openingVaultSettingsUsesTheCallingSpaceEvenWhenAnotherSpaceAlreadyHasSettings() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { owner, _, vaults in
            let fixture = Fixture()
            defer { fixture.close(keeping: [owner.id]) }
            let coordinator = fixture.coordinator, browser = coordinator.browser
            _ = try #require(fixture.catalog.adopt(id: owner.id, name: owner.name, symbol: owner.symbol, color: owner.color))
            let first = SpaceVaultReference(profileID: owner.id, vaultID: vaults[0].vaultID)
            let second = SpaceVaultReference(profileID: owner.id, vaultID: vaults[1].vaultID)
            let local = SpaceEditor.Choice(name: "Local Work", symbol: "briefcase", sharing: .separate, vault: first)
            let work = try await coordinator.saveSpace(local, editing: nil, openedIn: coordinator.context.profile.id)
            try #require(await waitUntil { coordinator.context.profile.id == work.profile.id })
            coordinator.openSettings(.sync)
            let previous = try #require(browser.activeTab)
            let choice = SpaceEditor.Choice(name: "Studio Work", symbol: "briefcase", sharing: .profile(work.profile.id), vault: second)
            let joined = try await coordinator.saveSpace(choice, editing: nil, openedIn: work.profile.id)
            browser.switchSpace(to: joined.id)
            coordinator.openSettings(.autofill)
            let settings = try #require(browser.activeTab)
            #expect(settings !== previous)
            #expect(browser.currentSpaceID == joined.id && settings.spaceID == joined.id)
            #expect(browser.vaultScope().contains(vaults[1].manager) && !browser.vaultScope().contains(vaults[0].manager))
            coordinator.routeSettings(to: .profiles)
            #expect(settings.urlString == SystemPages.settingsURL(.profiles).absoluteString)
            #expect(previous.urlString == SystemPages.settingsURL(.sync).absoluteString)
            browser.switchSpace(to: work.id)
            coordinator.openSettings(.sync)
            #expect(browser.activeTab === previous)
            #expect(browser.vaultScope().contains(vaults[0].manager) && !browser.vaultScope().contains(vaults[1].manager))
        }
    }

    @Test func aSeparateSpaceIsANewProfileWhoseFirstSpaceItIs() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator

        let space = try #require(coordinator.createSpace(name: "Side project", symbol: "hammer", sharing: .separate))

        let created = try #require(fixture.catalog.profiles.first { $0.name == "Side project" })
        #expect(created.symbol == "hammer")
        #expect(SpaceStore.shared(for: created)?.spaces == [space])
        #expect(created.supportDirectory != Profile.original().supportDirectory)
        #expect(created.databaseURL != Profile.original().databaseURL)
        #expect(await waitUntil { coordinator.profiles.current.id == created.id })
        #expect(coordinator.context.profile.id == created.id)
        #expect(coordinator.browser.currentSpaceID == space.id)
    }

    @Test func separateSignInsKeepTheChosenVaultAcrossReopeningAndForeignEdits() async throws {
        try await VaultManagerFixture.with(vaults: [.locked, .locked]) { owner, _, vaults in
            let fixture = Fixture()
            defer { fixture.close(keeping: [owner.id]) }
            let catalog = fixture.catalog, coordinator = fixture.coordinator
            _ = try #require(catalog.adopt(id: owner.id, name: owner.name, symbol: owner.symbol, color: owner.color,
                                          publicationSource: ProfilePublicationSource(macName: "Fixture Mac")))
            let ref = SpaceVaultReference(profileID: owner.id, vaultID: vaults[1].vaultID)
            let choice = SpaceEditor.Choice(name: "Side project", symbol: "hammer", sharing: .separate, vault: ref)
            let origin = coordinator.context.profile.id
            let created = try await coordinator.saveSpace(choice, editing: nil, openedIn: origin)
            #expect(created.profile.id != owner.id && created.profile.id != origin)
            #expect(created.space.vault == ref)
            #expect(ProfileStore(file: fixture.file).verifiedProfiles?.contains(created.profile) == true)
            #expect(SpaceStore(profile: created.profile, file: created.profile.spacesFile).spaces == [created.space])
            try #require(await waitUntil { coordinator.context.profile.id == created.profile.id })
            let websiteData = coordinator.context.dataStore
            #expect(websiteData.identifier == created.profile.id)
            try await checkIndependentCookies(websiteData, owner.makeDataStore())

            await coordinator.switchProfile(to: fixture.work)
            let clear = SpaceEditor.Choice(name: "Renamed", symbol: "star")
            let edited = try await coordinator.saveSpace(clear, editing: created, openedIn: fixture.work.id)
            #expect(edited.space.id == created.id && edited.space.vault == nil)
            #expect(SpaceStore(profile: created.profile, file: created.profile.spacesFile).spaces == [edited.space])
            #expect(coordinator.context.profile.id == fixture.work.id)
        }
    }

    private func checkIndependentCookies(_ space: WKWebsiteDataStore, _ owner: WKWebsiteDataStore) async throws {
        let domain = "\(UUID().uuidString.lowercased()).example.test"
        func cookie(_ value: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "session", .value: value]))
        }
        let spaceCookie = try cookie("space"), ownerCookie = try cookie("owner")
        await owner.httpCookieStore.setCookie(ownerCookie)
        await space.httpCookieStore.setCookie(spaceCookie)
        func matches(_ cookie: HTTPCookie) -> Bool {
            cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == domain && cookie.name == "session"
        }
        let inSpace = await space.httpCookieStore.allCookies().filter(matches)
        let inOwner = await owner.httpCookieStore.allCookies().filter(matches)
        #expect(inSpace.map(\.value) == ["space"])
        #expect(inOwner.map(\.value) == ["owner"])
        await space.httpCookieStore.deleteCookie(spaceCookie)
        await owner.httpCookieStore.deleteCookie(ownerCookie)
    }

    @Test func anUnavailableVaultCannotCreateAProfileOrReplaceAnExistingChoice() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let ref = SpaceVaultReference(profileID: fixture.work.id, vaultID: UUID())
        let choice = SpaceEditor.Choice(name: "Uncommitted", symbol: "book", sharing: .separate, vault: ref)
        let missing = SpaceVaultReference(profileID: UUID(), vaultID: UUID())
        let held = Space(id: UUID(), name: "Keep me", symbol: "key", color: .blue, vault: missing)
        let profile = try fixture.catalog.addProfile(forFirstSpace: held)
        let before = fixture.catalog.profiles
        await #expect(throws: SpaceEditorError.vaultUnavailable) {
            try await coordinator.saveSpace(choice, editing: nil, openedIn: coordinator.context.profile.id)
        }
        let picker = SpaceVaultPicker(.init(), selected: missing)
        #expect(picker.vault == missing)
        let edit = SpaceEditor.Choice(name: "Still unavailable", symbol: "book", vault: picker.vault)
        await #expect(throws: SpaceEditorError.vaultUnavailable) {
            try await coordinator.saveSpace(edit, editing: SpaceEntry(space: held, profile: profile), openedIn: coordinator.context.profile.id)
        }
        #expect(SpaceStore(profile: profile, file: profile.spacesFile).spaces == [held])
        picker.selectItem(at: 0)
        #expect(picker.vault == nil)
        #expect(fixture.catalog.profiles == before)
        #expect(ProfileStore(file: fixture.file).verifiedProfiles == before)
    }

    @Test func aFirstRunCanChooseTheProfileDefaultWithoutCreatingAVault() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "profiles.json")
        let catalog = ProfileStore(file: file)
        #expect(try catalog.profilesForSpaceEditor() == [.original()])
        #expect(ProfileStore(file: file).verifiedProfiles == [.original()])
        try await VaultManagerFixture.with(vaults: []) { empty, _, _ in
            let choices = await SpaceVaultPicker.Choices.load(from: [empty, .privateBrowsing()])
            #expect(choices.options.isEmpty && !choices.hasUnreadableProfile)
            let picker = SpaceVaultPicker(choices, selected: nil)
            #expect(picker.numberOfItems == 1)
            #expect(try picker.selectedReference() == nil)
            let store = try CredentialManager.store(for: empty)
            #expect(await store.openState() == .firstRun)
        }
    }

    @Test func aCatalogWriteFailureDoesNotExposeAnUnboundProfileOrDuplicateARetry() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let catalog = fixture.catalog
        let before = catalog.profiles
        let ref = SpaceVaultReference(profileID: fixture.work.id, vaultID: UUID())
        let space = Space(id: UUID(), name: "Retry", symbol: "book", color: .blue, vault: ref)
        let backup = fixture.file.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: fixture.file, to: backup)
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try catalog.addProfile(forFirstSpace: space) }
        #expect(catalog.profiles == before)
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.moveItem(at: backup, to: fixture.file)
        let profile = try catalog.addProfile(forFirstSpace: space)
        #expect(catalog.profiles == before + [profile])
        #expect(SpaceStore(profile: profile, file: profile.spacesFile).spaces == [space])
    }

    @Test func vaultPickerDistinguishesSameNamedProfilesAndMasksTheNameAfterLock() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { owner, _, vaults in
            let vault = try #require(vaults.first)
            let epoch = try #require(vault.manager.authorizationEpoch)
            _ = try await vault.manager.renameVault("Fixture Passwords", authorizedEpoch: epoch)
            var published = owner
            published.publicationOrigin = .published(ProfilePublicationSource(macName: "Fixture Mac"))
            let local = Profile(id: UUID(), name: owner.name, symbol: "key", color: .red)
            let duplicate = Profile(id: UUID(), name: owner.name, symbol: "key", color: .gray)
            let profiles = [local, duplicate, published, .privateBrowsing()]
            #expect(local.vaultPickerLabel(among: profiles) != duplicate.vaultPickerLabel(among: profiles))
            let choices = await SpaceVaultPicker.Choices.load(from: profiles)
            let selected = SpaceVaultReference(profileID: owner.id, vaultID: vault.vaultID)
            let picker = SpaceVaultPicker(choices, selected: selected)
            #expect(choices.options.map(\.id) == [selected])
            #expect(picker.titleOfSelectedItem?.contains("Fixture Mac") == true)
            #expect(picker.titleOfSelectedItem?.contains("Fixture Passwords") == true)
            vault.manager.lock(reason: .manual)
            #expect(await waitUntil { picker.titleOfSelectedItem?.contains("Fixture Passwords") == false })
            #expect(picker.titleOfSelectedItem?.contains(String(localized: "Vault \(1) (locked)")) == true)
            #expect(picker.vault == selected)
        }
    }

    @Test func theNativeNewAndEditSheetsSaveTheChosenVault() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { owner, _, vaults in
            let fixture = Fixture()
            defer { fixture.close(keeping: [owner.id]) }
            let coordinator = fixture.coordinator
            _ = try #require(fixture.catalog.adopt(id: owner.id, name: owner.name, symbol: owner.symbol, color: owner.color))
            let reference = SpaceVaultReference(profileID: owner.id, vaultID: try #require(vaults.first).vaultID)
            coordinator.showBrowser(activate: false)
            let window = try #require(coordinator.nativeWindow)

            @MainActor func controls(in view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { controls(in: $0) }
            }
            @MainActor func submit(_ title: String, answer: @MainActor ([NSView], SpaceVaultPicker) throws -> Void) async throws {
                try #require(await waitUntil { window.attachedSheet?.contentView != nil })
                let sheet = try #require(window.attachedSheet)
                do {
                    let views = controls(in: try #require(sheet.contentView))
                    let vault = try #require(views.compactMap { $0 as? SpaceVaultPicker }.first)
                    try answer(views, vault)
                    let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == title })
                    button.performClick(nil)
                } catch {
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                    throw error
                }
            }

            coordinator.showNewSpaceEditor()
            try await submit(String(localized: "Create Space")) { views, vault in
                let name = try #require(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == String(localized: "Space Name") })
                name.stringValue = "Sheet fixture"
                let signIns = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == String(localized: "Sign-ins and data") })
                signIns.selectItem(withTitle: String(localized: "Separate sign-ins and data"))
                vault.select(try #require(vault.itemArray.first { $0.representedObject as? SpaceVaultReference == reference }))
            }
            try #require(await waitUntil { coordinator.currentSpace?.name == "Sheet fixture" })
            let entry = SpaceEntry(space: try #require(coordinator.currentSpace), profile: coordinator.context.profile)
            #expect(entry.profile.id != owner.id && entry.space.vault == reference)
            await coordinator.switchProfile(to: fixture.work)
            coordinator.showSpaceEditor(for: entry)
            try await submit(String(localized: "Save")) { _, vault in
                #expect(vault.vault == reference)
                vault.selectItem(at: 0)
            }
            try #require(await waitUntil {
                guard let saved = SpaceStore.shared(for: entry.profile)?.space(id: entry.id) else { return false }
                return saved.vault == nil
            })
            let reopened = try #require(SpaceStore(profile: entry.profile, file: entry.profile.spacesFile).space(id: entry.id))
            #expect(reopened.vault == nil)
            #expect(coordinator.context.profile.id == fixture.work.id)
        }
    }

    @Test func aSpaceSharingAnotherProfilesSignInsJoinsThatProfile() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let profileCount = fixture.catalog.profiles.count

        let space = try #require(coordinator.createSpace(name: "Clients", symbol: "person.2", sharing: .profile(fixture.work.id)))

        #expect(fixture.catalog.profiles.count == profileCount)
        #expect(SpaceStore.shared(for: fixture.work)?.spaces.last == space)
        #expect(await waitUntil { coordinator.profiles.current.id == fixture.work.id })
        #expect(coordinator.browser.currentSpaceID == space.id)
    }

    @Test func theNewProfileIsNotTheDeveloperProfile() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        try trust.setDeveloperProfile(Profile.originalID)

        _ = fixture.coordinator.createSpace(name: "Side project", symbol: "hammer", sharing: .separate)

        let created = try #require(fixture.catalog.profiles.first { $0.name == "Side project" })
        #expect(!MCPDeveloperAccess.isDeveloperProfile(created, trust: trust))
        #expect(trust.developerProfileID == Profile.originalID)
    }

    // MARK: - Switching

    @Test func choosingASpaceOfAnotherProfileSwitchesAndLandsInIt() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let second = try #require(SpaceStore.shared(for: fixture.work)).add(name: "Work B")
        let left = coordinator.browser.newTab()

        await coordinator.switchProfile(to: fixture.work, landingIn: second.id)

        #expect(coordinator.profiles.current.id == fixture.work.id)
        #expect(coordinator.browser.currentSpaceID == second.id)
        #expect(coordinator.browser.activeTab?.spaceID == second.id)
        #expect(!coordinator.browser.tabs.contains { $0 === left })
        #expect(coordinator.notice == fixture.work.name)
        #expect(!coordinator.isSwitchingProfile)
    }

    @Test func theSwitcherListsEveryProfilesSpacesInProfileOrder() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        let entries = coordinator.spaceEntries
        let index = try #require(entries.firstIndex { $0.profile.id == fixture.work.id })

        #expect(entries.prefix(index).allSatisfy { $0.profile.isOriginal })
        #expect(entries.count == index + 1)
        #expect(coordinator.showsSpaceSwitcher)

        coordinator.switchToSpace(at: index)

        #expect(await waitUntil { coordinator.profiles.current.id == fixture.work.id })
        #expect(coordinator.browser.currentSpaceID == entries[index].id)
    }

    @Test func theSwitcherExplainsAProfileSwitchUntilToldNotTo() throws {
        let saved = SpaceSwitchNotice.defaults
        let suite = AppDatabase.defaultsSuite("SpaceSwitchNotice-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: suite))
        SpaceSwitchNotice.defaults = defaults
        defer {
            defaults.removePersistentDomain(forName: suite)
            SpaceSwitchNotice.defaults = saved
        }

        #expect(SpaceSwitchNotice.isNeeded)
        SpaceSwitchNotice.stopAsking()
        #expect(!SpaceSwitchNotice.isNeeded)
    }

    @Test func aPrivateWindowListsNoSpaces() {
        let coordinator = AppCoordinator(browser: BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID()))
        defer { coordinator.browser.closeAllTabs(saving: false) }

        #expect(coordinator.spaceEntries.isEmpty)
        #expect(!coordinator.showsSpaceSwitcher)
        #expect(coordinator.createSpace(name: "Nope", symbol: "star", sharing: .separate) == nil)
    }

    // MARK: - Deleting

    @Test func deletingASpaceNeverRemovesItsProfile() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        await coordinator.switchProfile(to: fixture.work)
        let store = try #require(SpaceStore.shared(for: fixture.work))
        let first = try #require(store.spaces.first)
        let extra = try #require(coordinator.createSpace(name: "Extra", symbol: "star"))

        coordinator.deleteSpace(extra)

        #expect(store.spaces == [first])
        #expect(fixture.catalog.profiles.contains { $0.id == fixture.work.id })
        #expect(!coordinator.canDeleteSpace(first))
        coordinator.deleteSpace(first)
        #expect(store.spaces == [first])
        #expect(fixture.catalog.profiles.contains { $0.id == fixture.work.id })
        let personal = try #require(coordinator.spaceEntries.first { $0.profile.isOriginal })
        #expect(!coordinator.canDeleteSpace(personal.space))
    }

    @Test func spacesNeverEraseAProfileOrChooseTheDeveloperProfile() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "WSurf/App/AppCoordinator+Spaces.swift",
            "WSurf/Profiles/Space.swift",
            "WSurf/Web/Model/BrowserModel+Spaces.swift",
            "WSurf/UI/Sidebar/Spaces/SpaceEditor.swift",
            "WSurf/UI/Sidebar/Spaces/SidebarSpaceSwitcher.swift",
        ]
        for file in files {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for name in ["Profile.erase", "profiles.remove", ".remove(profile", "prepareToRemove", "setDeveloperProfile", "MCPTrustStore"] {
                #expect(!source.contains(name), "\(file) names \(name)")
            }
        }
    }

    // MARK: - The editor

    @Test func theEditorOffersEachProfilesSignInsOrSeparateOnes() {
        let work = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)

        #expect(SpaceEditor.SharingOption(profile: work).title.contains("Work"))
        #expect(SpaceEditor.sharing(work.id) == .profile(work.id))
        #expect(SpaceEditor.sharing(nil) == .separate)
        #expect(SpaceEditor.choice(name: " Clients ", symbol: "person.2", sharing: .separate)?.sharing == .separate)
    }
}
