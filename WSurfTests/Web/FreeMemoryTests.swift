// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Free Memory unloads every background tab now, in every window, in both engines. Whatever the person is using stays.
@MainActor
struct FreeMemoryTests {
    private func makePermissions() -> SitePermissions {
        SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("FreeMemoryPermissions-\(UUID().uuidString).json")
        )
    }

    private func makeModel(permissions: SitePermissions? = nil) -> BrowserModel {
        BrowserModel(database: .temporary(), sitePermissions: permissions ?? makePermissions())
    }

    private func url(_ name: String) -> URL? {
        URL(string: "https://example.com/\(name)")
    }

    // MARK: - Which tabs go

    @Test(.boundedWebViews)
    func unloadsEveryBackgroundTabEvenWhileSleepInactiveTabsIsOff() {
        let model = makeModel()
        let settings = model.context.settings
        let previous = settings.sleepsInactiveTabs
        settings.sleepsInactiveTabs = false
        defer { settings.sleepsInactiveTabs = previous }
        let first = model.newTab(url: url("1"))
        let second = model.newTab(url: url("2"))
        let current = model.newTab(url: url("3"))

        model.relieveMemoryPressure(.critical)
        #expect(!first.isDeferred && !second.isDeferred, "memory pressure honors the switch")

        #expect(model.freeMemory() == 2)

        #expect(first.isDeferred)
        #expect(second.isDeferred)
        #expect(!current.isDeferred)
        #expect(model.activeTab === current)
        #expect(first.urlString == "https://example.com/1")
        #expect(model.tabs.count == 3)
    }

    @Test(.boundedWebViews)
    func keepsTheCurrentTabAndEverythingTheUserIsUsing() {
        let permissions = makePermissions()
        let model = makeModel(permissions: permissions)
        let plain = model.newTab(url: url("plain"))
        let playing = model.newTab(url: url("playing"))
        playing.isPlayingAudio = true
        let docked = model.newTab(url: url("docked"))
        docked.isControlledByMediaDock = true
        let form = model.newTab(url: url("form"))
        form.notePageActivity(.init(kind: .editedForm, token: "main", isActive: true))
        let favorite = model.newTab(url: url("favorite"))
        favorite.isFavorite = true
        let recording = model.newTab(url: URL(string: "https://call.example/room"))
        recording.permissions.setLive(.microphone, true)
        let kept = model.newTab(url: URL(string: "https://kept.example/page"))
        model.setKeepsActive(true, for: kept)
        let downloading = model.newTab(url: url("download"))
        let downloadID = model.downloads.beginItem(
            source: URL(string: "https://example.com/file.zip"),
            sourceTabID: downloading.id
        )
        let current = model.newTab(url: url("current"))
        let beside = model.newTab(url: url("beside"))
        model.split(current, with: beside, axis: .sideBySide)
        model.activate(current)

        #expect(model.freeMemory() == 1)

        #expect(plain.isDeferred)
        for tab in [playing, docked, form, favorite, recording, kept, downloading, current, beside] {
            #expect(!tab.isDeferred, "\(tab.urlString) stays loaded")
        }
        #expect(model.protectionReason(for: beside) == .visibleInSplit)
        #expect(model.protectionReason(for: playing) == .mediaPlayback)
        #expect(model.protectionReason(for: form) == .editedForm)
        #expect(model.protectionReason(for: recording) == .deviceAccess)
        #expect(model.protectionReason(for: kept) == .alwaysKeepActive)
        #expect(model.protectionReason(for: downloading) == .activeDownload)

        model.downloads.noteFailure(downloadID, reason: "Stopped", resumeData: nil)
        form.notePageActivity(.init(kind: .editedForm, token: "main", isActive: false))
        playing.isPlayingAudio = false
        #expect(model.freeMemory() == 3, "the tabs that were busy go once they are not")
        #expect(form.isDeferred && playing.isDeferred && downloading.isDeferred)
    }

    @Test(.boundedWebViews)
    func aPrivateTabStaysLoaded() {
        let model = makeModel()
        model.adopt(database: .temporary(), sitePermissions: makePermissions(), privately: true)
        let hidden = model.newTab(url: url("private"))
        _ = model.newTab(url: url("current"))

        #expect(model.freeMemory() == 0)
        #expect(!hidden.isDeferred)
    }

    @Test(.boundedWebViews)
    func aSecondRunLeavesTheUnloadedTabsAlone() {
        let model = makeModel()
        let background = model.newTab(url: url("a"))
        _ = model.newTab(url: url("b"))

        #expect(model.freeMemory() == 1)
        let state = background.sessionState
        #expect(model.freeMemory() == 0)
        #expect(background.isDeferred)
        #expect(background.sessionState == state)
    }

    @Test(.boundedWebViews)
    func aPinnedLinkIsUnloadedButKeepsItsPinFolderAndAddress() {
        let model = makeModel()
        let pinned = model.newTab(url: url("pinned"))
        pinned.customTitle = "Saved page"
        let folder = model.createFolder(named: "Saved", containing: [pinned])
        model.setPinned(true, for: [.tab(pinned.id)])
        let current = model.newTab(url: url("current"))

        #expect(model.freeMemory() == 1)

        #expect(pinned.isDeferred)
        #expect(model.activeTab === current)
        #expect(model.folder(containing: pinned) === folder)
        #expect(model.rows(in: folder) == [.tab(pinned.id)])
        #expect(pinned.customTitle == "Saved page")
        #expect(pinned.pinnedURL?.absoluteString == "https://example.com/pinned")

        model.activate(pinned)
        #expect(!pinned.isDeferred)
    }

    // MARK: - Both engines

    @Test(.boundedWebViews, arguments: [BrowserEngine.webKit, .chromium])
    func releasesThePageOfEitherEngine(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Background page</title>")])
        defer { withExtendedLifetime(server) {} }
        let address = try server.url("/")
        let profile = Profile(id: UUID(), name: "Free memory fixture", symbol: "person", color: .gray)
        let context = BrowserProfileContext.shared(for: profile)
        context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: address))
        let model = BrowserModel(context: context, windowID: UUID(), database: .temporary())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        func cleanUp() async {
            let tabs = model.tabs
            model.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            await context.sitePermissions.waitForPendingSave()
            window.close()
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }
        do {
            let background = model.newTab(url: address)
            let page = background.page
            window.contentView = page
            window.orderFront(nil)
            try #require(await waitUntil { page.title == "Background page" && !page.isLoading })
            #expect(page.engine == engine)
            let current = model.newTab()

            #expect(model.freeMemory() == 1)
            await background.waitForRetirement()

            #expect(!background.isMaterialised)
            #expect(background.isDeferred)
            #expect(page.superview == nil)
            if engine == .chromium {
                #expect(page.chromium?.isClosed == true)
            }
            #expect(model.activeTab === current)
            #expect(!current.isDeferred)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    // MARK: - Every window and the notice

    @Test(.boundedWebViews)
    func everyWindowKeepsItsCurrentTabAndSaysHowManyWent() {
        let app = BrowserApplication()
        let context = BrowserProfileContext.shared(for: .original())
        func window() -> AppCoordinator {
            let coordinator = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID(), database: .temporary()))
            app.register(coordinator)
            return coordinator
        }
        let first = window()
        let second = window()
        let firstBackground = first.browser.newTab(url: url("first-background"))
        let firstCurrent = first.browser.newTab(url: url("first-current"))
        let secondBackground = second.browser.newTab(url: url("second-background"))
        let secondPlaying = second.browser.newTab(url: url("second-playing"))
        secondPlaying.isPlayingAudio = true
        let secondCurrent = second.browser.newTab(url: url("second-current"))

        first.freeMemory()

        #expect(firstBackground.isDeferred)
        #expect(secondBackground.isDeferred)
        #expect(!firstCurrent.isDeferred)
        #expect(!secondPlaying.isDeferred)
        #expect(!secondCurrent.isDeferred)
        #expect(first.notice == "Unloaded 2 tabs.")

        second.freeMemory()
        #expect(second.notice == "No background tabs to unload.")
        first.browser.closeAllTabs(saving: false)
        second.browser.closeAllTabs(saving: false)
    }

    @Test(.boundedWebViews)
    func theNoticeCountsTheTabsUnloaded() {
        let coordinator = AppCoordinator()
        let browser = coordinator.browser
        _ = browser.newTab(url: url("a"))
        _ = browser.newTab(url: url("b"))

        coordinator.freeMemory()
        #expect(coordinator.notice == "Unloaded 1 tab.")

        coordinator.freeMemory()
        #expect(coordinator.notice == "No background tabs to unload.")

        _ = browser.newTab(url: url("c"))
        _ = browser.newTab(url: url("d"))
        coordinator.freeMemory()
        #expect(coordinator.notice == "Unloaded 2 tabs.")
        browser.closeAllTabs(saving: false)
    }

    // MARK: - Menu and palette

    @Test(.boundedWebViews)
    func theFileMenuOffersFreeMemoryAfterUnloadTab() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let file = try #require(root.items.compactMap(\.submenu).first { $0.title == String(localized: "File") })
        let unload = try #require(file.items.firstIndex { $0.title == String(localized: "Unload Tab") })
        let item = file.items[unload + 1]

        #expect(item.title == String(localized: "Free Memory"))
        #expect(item.keyEquivalent.isEmpty)
        #expect(menu.validateMenuItem(item))

        let background = coordinator.browser.newTab(url: url("background"))
        let current = coordinator.browser.newTab(url: url("current"))
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))

        #expect(background.isDeferred)
        #expect(!current.isDeferred)
        #expect(coordinator.notice == "Unloaded 1 tab.")
        coordinator.browser.closeAllTabs(saving: false)
    }

    @Test func theCommandPaletteOffersFreeMemoryEvenWithoutATab() throws {
        var performed: [CommandPaletteAction] = []
        let commands = CommandPaletteCatalog.commands(context: CommandPaletteContext()) { performed.append($0) }
        let command = try #require(commands.first { $0.id == "action-freeMemory" })

        #expect(command.title == "Free Memory")
        #expect(command.isAvailable)
        #expect(command.shortcut.isEmpty)
        command.run()
        #expect(performed == [.freeMemory])
        for query in ["free memory", "release memory", "unload all tabs"] {
            #expect(CommandPaletteCatalog.matching(query, in: commands).first?.id == "action-freeMemory")
        }

        let withTab = CommandPaletteCatalog.commands(context: CommandPaletteContext(tabCount: 2, hasActiveTab: true)) { _ in }
        #expect(CommandPaletteCatalog.matching("unload tab", in: withTab).first?.id == "action-unloadTab")
    }

    @Test(.boundedWebViews)
    func runningFreeMemoryFromThePaletteUnloadsTheBackgroundTabs() throws {
        let coordinator = AppCoordinator()
        let browser = coordinator.browser
        let background = browser.newTab(url: url("background"))
        let current = browser.newTab(url: url("current"))
        let model = CommandPaletteModel(browser: browser, coordinator: coordinator) {}
        model.prepare()
        model.interaction.query = "> free memory"

        let command = try #require(model.sections.flattened.first { $0.id == "action-freeMemory" })
        command.run()

        #expect(background.isDeferred)
        #expect(!current.isDeferred)
        #expect(coordinator.notice == "Unloaded 1 tab.")
        browser.closeAllTabs(saving: false)
    }
}
