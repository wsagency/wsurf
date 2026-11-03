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

    /// What every case runs: both engines with all three. Chromium runs a frame of another site in a process of its own, where
    /// the media script reaches it through the cross-site frame sessions (`ChromiumDevTools.crossSiteFrameScripts`).
    nonisolated static let scriptable: [(BrowserEngine, Origin)] = [
        (.webKit, .same), (.webKit, .otherOrigin), (.webKit, .otherSite),
        (.chromium, .same), (.chromium, .otherOrigin), (.chromium, .otherSite),
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
        // What a page script does of its own accord, and what the player's `muted` has been, told to the page that holds it.
        song.addEventListener('volumechange', () => { parent.postMessage('song:' + song.muted, '*'); });
        addEventListener('message', (event) => {
          if (event.data === 'stop') { wanted = false; song.pause(); }
          if (event.data === 'play') { wanted = true; }
          if (event.data === 'unmute') { song.muted = false; }
        });
        </script>
        """

    private static let host = """
        <!doctype html><title>Host</title><p>The page.</p>
        <script>
        window.__songs = [];
        addEventListener('message', (event) => {
          if (typeof event.data === 'string' && event.data.indexOf('song:') === 0) { window.__songs.push(event.data); }
        });
        </script>
        """

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
        await LiveWindowRig.releaseSharedDataStore(for: profile)
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
    // MARK: - Who lifts a mute

    /// A player of the page's own, which the page's script and WSurf's both see (`muted` is the page's own property, in every world).
    private func addSong(to rig: Rig) async throws {
        try await run(rig.page, "const song = new Audio(); song.id = 'main'; document.body.append(song); true")
        // The script binds it a moment after it is made.
        try await Task.sleep(for: .milliseconds(500))
    }

    private func isMuted(_ rig: Rig) async -> Bool? {
        await read(rig.page, "document.getElementById('main').muted") as? Bool
    }

    private func hasActivation(_ rig: Rig) async -> Bool? {
        await read(rig.page, "navigator.userActivation.isActive") as? Bool
    }

    /// Waits until the page has no user activation: Chromium gives a page that has just loaded a few seconds of it.
    private func waitForNoActivation(_ rig: Rig) async throws {
        try #require(await waitUntil(timeout: .seconds(30)) { await hasActivation(rig) == false }, "the page still has user activation")
    }

    private func songs(_ rig: Rig) async -> [String] {
        await read(rig.page, "window.__songs") as? [String] ?? []
    }

    /// An advertisement does this: its own script lifts the mute, with no one having pressed anything.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aScriptThatUnmutesAPlayerOnItsOwnDoesNotLiftTheTabsMute(engine: BrowserEngine) async throws {
        try await withPage(engine: engine) { rig in
            try await addSong(to: rig)
            try await waitForNoActivation(rig)
            rig.main.toggleMute(tab: rig.tab)
            try #require(await waitUntil { await isMuted(rig) == true }, "the tab's mute reaches the player")
            #expect(await hasActivation(rig) == false, "and muting does not give the page user activation for its script to take")

            _ = try await rig.page.evaluateJavaScript("document.getElementById('main').muted = false; true")
            #expect(await waitUntil { await isMuted(rig) == true }, "the player is silenced again")
            try await Task.sleep(for: .milliseconds(600))
            #expect(rig.tab.isMuted, "the tab is still muted")
            #expect(await isMuted(rig) == true)
        }
    }

    /// The person pressed the player's own control: the page has user activation, and the tab's mute is lifted. Only Chromium can be
    /// given the activation without a system event (its DevTools `userGesture`); WebKit's script gesture lasts while the script runs,
    /// not the moment later the player's event arrives, so there the same path is `MediaScriptTests`'s (with the activation stood in
    /// for) and `TabUnmuteTests`'s.
    @Test func aChromiumUnmuteWithUserActivationLiftsTheTabsMute() async throws {
        try await withPage(engine: .chromium) { rig in
            try await addSong(to: rig)
            try await waitForNoActivation(rig)
            rig.main.toggleMute(tab: rig.tab)
            try #require(await waitUntil { await isMuted(rig) == true })

            _ = try await rig.page.evaluateJavaScript("document.getElementById('main').muted = false; true", in: nil, contentWorld: .page, userGesture: true)
            #expect(await waitUntil { !rig.tab.isMuted }, "the person unmuted it: the tab is no longer muted")
            try await Task.sleep(for: .milliseconds(400))
            #expect(await isMuted(rig) == false, "and the player stays unmuted")
        }
    }

    /// Under Mute WSurf not even the person's press on a player lifts it: the speaker and ⌃⌘M do.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func anUnmuteWithUserActivationDuringMuteWSurfDoesNotLiftIt(engine: BrowserEngine) async throws {
        try await withPage(engine: engine) { rig in
            try await addSong(to: rig)
            rig.app.muteAll()
            try #require(await waitUntil { await isMuted(rig) == true })

            _ = try await rig.page.evaluateJavaScript("document.getElementById('main').muted = false; true", in: nil, contentWorld: .page, userGesture: true)
            #expect(await waitUntil { await isMuted(rig) == true }, "the player is silenced again")
            try await Task.sleep(for: .milliseconds(600))
            #expect(rig.app.isMuted, "WSurf is still muted")
            #expect(await isMuted(rig) == true)

            rig.app.unmuteAll()
            #expect(await waitUntil { await isMuted(rig) == false }, "the speaker lifts it, and the player is heard again")
        }
    }

    /// A frame, of another site too, that unmutes its player on its own cannot lift the mute: it has no input of the person's,
    /// whatever user activation its page has (the page has some here, and a frame of the same origin shares it).
    @Test(arguments: AudioFrameEngineTests.scriptable)
    func aFrameThatUnmutesItsPlayerOnItsOwnCannotLiftTheTabsMute(engine: BrowserEngine, origin: Origin) async throws {
        try await withPage(engine: engine) { rig in
            try await use(rig)
            try await addFrame("a", try rig.url("/player", from: origin), to: rig)
            try #require(await waitUntil { rig.tab.isPlayingAudio })
            rig.main.toggleMute(tab: rig.tab)
            try #require(await waitUntil { await songs(rig).last == "song:true" }, "the tab's mute reaches the frame's player")

            try await tell("a", "unmute", in: rig)
            #expect(await waitUntil { await songs(rig).suffix(2) == ["song:false", "song:true"] }, "the frame unmuted it, and it was silenced again")
            try await Task.sleep(for: .milliseconds(600))
            #expect(rig.tab.isMuted, "the tab is still muted")
        }
    }
}
