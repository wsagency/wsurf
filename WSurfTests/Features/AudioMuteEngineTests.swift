// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Mute WSurf against a real page on each engine: the mute reaches the page's players (and its frames) through the same script
/// the media panel uses, and a page that has nothing to play yet, or loads a new document, or opens a frame later, still starts
/// silent. No sound is played: the effect that silences either engine is the player's `muted` property, and a page that plays
/// for real in the test host leaves WebKit's GPU process unresponsive for the cases after it. What the page reports as playing
/// is `MediaScriptTests`'s, and which tab carries the muted mark is `AudioIndicatorTests`'s.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AudioMuteEngineTests {
    private static let player = """
        <!doctype html><title>Player</title>
        <audio id="song"></audio>
        <audio id="quiet" muted></audio>
        """

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/": .html(player),
        "/next": .html("<!doctype html><title>Next</title><audio id='song'></audio>"),
        "/empty": .html("<!doctype html><title>Empty</title><p>Nothing plays here.</p>"),
        "/frames": .html("<!doctype html><title>Frames</title><iframe id='frame' src='/child' width='300' height='100'></iframe>"),
        "/child": .html("<!doctype html><title>Child</title><audio id='song'></audio>"),
    ]

    private struct Rig {
        let app: BrowserApplication
        let main: AppCoordinator
        let tab: BrowserTab
        let page: BrowserPage
        let server: HTTPFixtureServer
        func url(_ path: String) throws -> URL {
            try server.url(path)
        }
    }

    /// A window of a profile of its own with `path` open on `engine`, and the same web view for the whole case.
    private func withPage(
        engine: BrowserEngine, path: String, title: String, _ body: @MainActor (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let url = try server.url(path)
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Audio engines")
        LiveWindowRig.useSharedDataStore(for: profile)
        let context = BrowserProfileContext.shared(for: profile)
        context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let main = app.newWindow(profile: profile, show: false)
        var failure: (any Error)?
        var opened: BrowserTab?
        do {
            let tab = main.browser.newTab(url: url)
            opened = tab
            let page = tab.page
            try #require(await waitUntil { page.title == title && !page.isLoading })
            #expect(page.engine == engine)
            try await body(Rig(app: app, main: main, tab: tab, page: page, server: server))
        } catch {
            failure = error
        }
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        await opened?.waitForRetirement()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        await catalog.remove(profile)
        await LiveWindowRig.releaseSharedDataStore(for: profile)
        catalog.markCurrent(previous)
        withExtendedLifetime(server) {}
        if let failure {
            throw failure
        }
    }

    private func read(_ page: BrowserPage, _ expression: String) async -> Any? {
        try? await page.evaluateJavaScript(expression)
    }

    private func load(_ path: String, title: String, in rig: Rig) async throws {
        rig.tab.load(try rig.url(path))
        try #require(await waitUntil { rig.tab.page.title == title && !rig.tab.page.isLoading })
    }

    private func run(_ page: BrowserPage, _ script: String) async throws {
        _ = try await page.evaluateJavaScript(script)
    }

    private static let states = "[document.getElementById('song').muted, document.getElementById('quiet')?.muted ?? 'none'].join()"

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func mutingWSurfSilencesThePageAndUnmutingGivesTheSoundBack(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, path: "/", title: "Player") { rig in
            #expect(await read(rig.page, Self.states) as? String == "false,true", "one player is the page's own quiet loop")

            rig.app.muteAll()

            #expect(await waitUntil { await read(rig.page, Self.states) as? String == "true,true" }, "the player is silenced in the page")

            // A player the page makes later is born muted.
            try await run(rig.page, "const late = new Audio(); late.id = 'late'; document.body.append(late); true")
            #expect(await waitUntil { await read(rig.page, "document.getElementById('late').muted") as? Bool == true })

            rig.app.unmuteAll()

            #expect(await waitUntil { await read(rig.page, Self.states) as? String == "false,true" }, "its own player is heard again")
            #expect(await waitUntil { await read(rig.page, "document.getElementById('late').muted") as? Bool == false })
            #expect(await read(rig.page, "document.getElementById('quiet').muted") as? Bool == true, "the page's own muted loop stays muted")
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aPageWithNothingToPlayYetStartsMutedWhenItHasSomething(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, path: "/empty", title: "Empty") { rig in
            rig.app.muteAll()
            #expect(!rig.tab.isMuted, "nothing plays, so the tab carries no mark")
            // The page learns of the mute before it has a player: the message is not dropped for want of one.
            // The mute message is posted from a task of its own: let it start, then the page's messages are all delivered.
            await Task.yield()
            try await rig.page.finishPendingPageMessages()
            try await run(rig.page, "const song = new Audio(); song.id = 'song'; document.body.append(song); true")
            #expect(await waitUntil { await read(rig.page, "document.getElementById('song').muted") as? Bool == true })

            rig.app.unmuteAll()
            #expect(await waitUntil { await read(rig.page, "document.getElementById('song').muted") as? Bool == false })
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aNewDocumentStartsMutedWhileWSurfIsMutedAndWhileItsTabIs(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, path: "/", title: "Player") { rig in
            let song = "document.getElementById('song').muted"
            rig.app.muteAll()
            try await load("/next", title: "Next", in: rig)
            #expect(await waitUntil { await read(rig.tab.page, song) as? Bool == true }, "WSurf is muted: the new document, which starts unmuted, is muted again")

            rig.app.unmuteAll()
            #expect(await waitUntil { await read(rig.tab.page, song) as? Bool == false })

            rig.main.toggleMute(tab: rig.tab)
            try await load("/", title: "Player", in: rig)
            #expect(rig.tab.isMuted, "the tab keeps its own mute across the navigation")
            #expect(await waitUntil { await read(rig.tab.page, song) as? Bool == true }, "and its next document is muted, as the tab says")

            rig.main.toggleMute(tab: rig.tab)
            #expect(await waitUntil { await read(rig.tab.page, song) as? Bool == false })
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theMuteReachesFramesThatAreThereAndFramesOpenedLater(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, path: "/frames", title: "Frames") { rig in
            let child = "document.getElementById('frame').contentDocument.getElementById('song')"
            try #require(await waitUntil { await read(rig.page, "!!\(child)") as? Bool == true }, "the frame loaded its player")

            rig.app.muteAll()
            #expect(await waitUntil { await read(rig.page, "\(child).muted") as? Bool == true }, "a frame that was there")

            try await run(rig.page, """
                const frame = document.createElement('iframe'); frame.id = 'later'; frame.src = '/child';
                document.body.append(frame); true
                """)
            let later = "document.getElementById('later').contentDocument?.getElementById('song')"
            #expect(await waitUntil { await read(rig.page, "\(later)?.muted ?? false") as? Bool == true }, "a frame opened while muted asks, and is told")

            rig.app.unmuteAll()
            #expect(await waitUntil { await read(rig.page, "\(child).muted") as? Bool == false })
            #expect(await waitUntil { await read(rig.page, "\(later)?.muted ?? true") as? Bool == false })
        }
    }
}
