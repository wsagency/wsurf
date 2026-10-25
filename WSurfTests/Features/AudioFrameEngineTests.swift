// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A player inside a frame, on a real page on each engine: the tab counts as playing while it does, so the speaker shows and the
/// tab is listed. The player plays no sound: its element is told to play a file the server never sends, so `paused` is false (the
/// one thing the page's script reads, in its own world, where a page's overrides are not seen) and nothing is decoded or heard.
/// A page that plays for real in the test host leaves WebKit's GPU process unresponsive for the cases after it.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AudioFrameEngineTests {
    /// Where the frame comes from, in relation to the page that holds it.
    enum Origin: Sendable, CustomTestStringConvertible {
        /// The same origin: the frame's document is the page's neighbour.
        case same
        /// Another origin of the same site (another port): another document world, the same process on Chromium.
        case otherOrigin
        /// Another site (`localhost` against `127.0.0.1`).
        case otherSite

        var testDescription: String {
            switch self {
            case .same:
                "same origin"
            case .otherOrigin:
                "another origin"
            case .otherSite:
                "another site"
            }
        }
    }

    /// What every case runs: WebKit with all three. Chromium runs a frame of another site in a process of its own, where no script
    /// reaches it until the cross-site frame sessions run one (`ChromiumDevTools.crossSiteFrameScripts`), so it has the two origins
    /// of its own process.
    nonisolated static let scriptable: [(BrowserEngine, Origin)] = [
        (.webKit, .same), (.webKit, .otherOrigin), (.webKit, .otherSite),
        (.chromium, .same), (.chromium, .otherOrigin),
    ]

    private static let player = """
        <!doctype html><title>Player</title><audio id="song" src="/never"></audio>
        <script>
        // Plays until told to stop, trying again as long as the browser refuses (Chromium wants the page to have been used).
        const song = document.getElementById('song');
        let wanted = true;
        setInterval(() => {
          if (wanted && song.paused) {
            const attempt = song.play();
            if (attempt) { attempt.catch(() => {}); }
          }
        }, 100);
        addEventListener('message', (event) => {
          if (event.data === 'stop') { wanted = false; song.pause(); }
          if (event.data === 'play') { wanted = true; }
        });
        </script>
        """

    private static let host = "<!doctype html><title>Host</title><p>The page.</p>"

    /// The file the player is told to play, which the server never sends.
    private static let never = ResponseGate()

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/host": .html(host),
        "/player": .html(player),
        "/never": .html("", gate: never),
        "/empty": .html("<!doctype html><title>Empty</title><p>Nothing plays here.</p>"),
    ]

    private struct Rig {
        let app: BrowserApplication
        let main: AppCoordinator
        let tab: BrowserTab
        let page: BrowserPage
        let server: HTTPFixtureServer
        let neighbour: HTTPFixtureServer

        func url(_ path: String, from origin: Origin) throws -> String {
            switch origin {
            case .same:
                return try server.url(path).absoluteString
            case .otherOrigin:
                return try neighbour.url(path).absoluteString
            case .otherSite:
                var parts = try #require(URLComponents(url: try neighbour.url(path), resolvingAgainstBaseURL: false))
                parts.host = "localhost"
                return try #require(parts.url).absoluteString
            }
        }
    }

    /// A window of a profile of its own with the host page open on `engine`, and a second server beside the first.
    private func withPage(engine: BrowserEngine, _ body: @MainActor (Rig) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let neighbour = try await HTTPFixtureServer.start(routes: Self.routes)
        let url = try server.url("/host")
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Audio frames")
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
            try #require(await waitUntil { page.title == "Host" && !page.isLoading })
            #expect(page.engine == engine)
            try await body(Rig(app: app, main: main, tab: tab, page: page, server: server, neighbour: neighbour))
        } catch {
            failure = error
        }
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        await opened?.waitForRetirement()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        withExtendedLifetime((server, neighbour)) {}
        if let failure {
            throw failure
        }
    }

    private func run(_ page: BrowserPage, _ script: String) async throws {
        _ = try await page.evaluateJavaScript(script)
    }

    private func read(_ page: BrowserPage, _ expression: String) async -> Any? {
        try? await page.evaluateJavaScript(expression)
    }

    private func addFrame(_ id: String, _ address: String, to rig: Rig) async throws {
        try await run(rig.page, """
            (() => {
              const frame = document.createElement('iframe'); frame.id = '\(id)'; frame.src = '\(address)'; frame.allow = 'autoplay';
              document.body.append(frame);
            })(); true
            """)
    }

    /// The page has been used, as a person using it would have: Chromium lets sound start in it and in the frames it allows.
    private func use(_ rig: Rig) async throws {
        _ = try await rig.page.evaluateJavaScript("true", in: nil, contentWorld: .page, userGesture: true)
    }

    private func tell(_ id: String, _ message: String, in rig: Rig) async throws {
        try await run(rig.page, "document.getElementById('\(id)').contentWindow.postMessage('\(message)', '*'); true")
    }

    private func isListed(_ rig: Rig) -> Bool {
        rig.app.audibleTabs(for: rig.main).contains { $0.tab === rig.tab }
    }

    // MARK: - A player in a frame

    @Test(arguments: AudioFrameEngineTests.scriptable)
    func aPlayerInAFrameMakesTheTabPlayAndListedAndItsEndTakesItOut(engine: BrowserEngine, origin: Origin) async throws {
        try await withPage(engine: engine) { rig in
            #expect(!rig.tab.isPlayingAudio)
            try await use(rig)

            try await addFrame("a", try rig.url("/player", from: origin), to: rig)
            #expect(await waitUntil { rig.tab.isPlayingAudio }, "a player in a frame is heard")
            #expect(isListed(rig), "so the tab is in the list")
            #expect(AudioIndicator.isVisible(audibleCount: rig.app.audibleTabs(for: rig.main).count, isMuted: rig.app.isMuted))

            try await tell("a", "stop", in: rig)
            #expect(await waitUntil { !rig.tab.isPlayingAudio }, "and when it stops, the tab does")
            #expect(!isListed(rig))

            try await tell("a", "play", in: rig)
            #expect(await waitUntil { rig.tab.isPlayingAudio }, "it can start again")
        }
    }

    @Test(arguments: AudioFrameEngineTests.scriptable)
    func theTabPlaysUntilTheLastFrameStops(engine: BrowserEngine, origin: Origin) async throws {
        try await withPage(engine: engine) { rig in
            try await use(rig)
            try await addFrame("a", try rig.url("/player", from: origin), to: rig)
            try await addFrame("b", try rig.url("/player", from: origin), to: rig)
            try #require(await waitUntil { rig.main.media.audio(of: rig.page).frames.count == 2 }, "both frames reported for themselves")

            try await tell("a", "stop", in: rig)
            try await Task.sleep(for: .milliseconds(400))
            #expect(rig.tab.isPlayingAudio, "the other frame still plays")

            try await tell("b", "stop", in: rig)
            #expect(await waitUntil { !rig.tab.isPlayingAudio })
        }
    }

    @Test(arguments: AudioFrameEngineTests.scriptable)
    func aFrameThatIsRemovedOrShowsAnotherPageStopsPlayingWithoutBeingAskedTo(engine: BrowserEngine, origin: Origin) async throws {
        try await withPage(engine: engine) { rig in
            try await use(rig)
            try await addFrame("a", try rig.url("/player", from: origin), to: rig)
            try #require(await waitUntil { rig.tab.isPlayingAudio })

            try await run(rig.page, "document.getElementById('a').remove(); true")
            #expect(await waitUntil { !rig.tab.isPlayingAudio }, "a frame that is gone plays nothing")

            try await addFrame("b", try rig.url("/player", from: origin), to: rig)
            try #require(await waitUntil { rig.tab.isPlayingAudio })
            try await run(rig.page, "document.getElementById('b').src = '\(try rig.url("/empty", from: origin))'; true")
            #expect(await waitUntil { !rig.tab.isPlayingAudio }, "and so does one that shows another page")
        }
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aNewPageInTheTabEndsWhatItsFramesPlayed(engine: BrowserEngine) async throws {
        try await withPage(engine: engine) { rig in
            try await use(rig)
            try await addFrame("a", try rig.url("/player", from: .same), to: rig)
            try #require(await waitUntil { rig.tab.isPlayingAudio })

            rig.tab.load(try #require(URL(string: try rig.url("/empty", from: .same))))
            try #require(await waitUntil { rig.tab.page.title == "Empty" && !rig.tab.page.isLoading })
            #expect(await waitUntil { !rig.tab.isPlayingAudio }, "the frame went with its page")
            #expect(rig.main.media.audio(of: rig.tab.page).frames.isEmpty)
        }
    }

    @Test(arguments: AudioFrameEngineTests.scriptable)
    func aTabThatPlaysInAFrameTakesTheMuteOfWSurfAndGivesItBack(engine: BrowserEngine, origin: Origin) async throws {
        try await withPage(engine: engine) { rig in
            try await use(rig)
            try await addFrame("a", try rig.url("/player", from: origin), to: rig)
            try #require(await waitUntil { rig.tab.isPlayingAudio })

            rig.app.muteAll()
            #expect(rig.tab.isMuted, "it plays, so it is silenced and marked")
            #expect(rig.tab.isPlayingAudio && isListed(rig), "and stays listed, to be unmuted")

            rig.app.unmuteAll()
            #expect(!rig.tab.isMuted)
        }
    }

    // MARK: - Chromium's own ear and mute

    @Test func chromiumsOwnMuteFollowsWSurfsAndTheTabs() async throws {
        try await withPage(engine: .chromium) { rig in
            let chromium = try #require(rig.page.chromium)
            #expect(!chromium.isAudioMuted)

            rig.app.muteAll()
            #expect(chromium.isAudioMuted, "WSurf is muted: every frame of the page, the ones no script reaches too")
            rig.app.unmuteAll()
            #expect(!chromium.isAudioMuted)

            rig.main.toggleMute(tab: rig.tab)
            #expect(chromium.isAudioMuted, "a tab's own mute is the engine's too")
            rig.main.toggleMute(tab: rig.tab)
            #expect(!chromium.isAudioMuted)
        }
    }
}
