// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
/// What the injected script decides on its own, against the real player it
/// reads. The Swift side is fed `state:` lines by `MediaCenterTests`; nothing
/// there says which numbers the page puts in them.
@Suite(.serialized, .boundedWebViews)
struct MediaScriptTests {
    private final class Collector: NSObject, WKScriptMessageHandler {
        var messages: [String] = []

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            messages.append(message.body as? String ?? "")
        }
    }

    /// A `<video>` with no source answers every read with a browser default and
    /// refuses most writes, so the fields the script reads are replaced with
    /// plain storage the test can set.
    private static let stand = """
    (() => {
      const video = document.querySelector('video');
      const box = {
        duration: NaN,
        currentTime: 0,
        paused: true,
        ended: false,
        muted: false,
        volume: 1,
        readyState: 0,
        audioTracks: null,
        videoWidth: 0
      };
      window.__box = box;
      for (const key of Object.keys(box)) {
        Object.defineProperty(video, key, {
          configurable: true,
          get() { return box[key]; },
          set(value) { box[key] = value; }
        });
      }
      Object.defineProperty(navigator, 'userActivation', {
        configurable: true,
        get() { return { hasBeenActive: false, isActive: false }; }
      });
      return true;
    })()
    """

    private func player(hasVideo: Bool = true) async -> (WKWebView, Collector) {
        let collector = Collector()
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserPage.installBridge(in: configuration.userContentController, world: .page)
        configuration.userContentController.add(
            collector,
            name: MediaCenter.frameScriptHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: MediaCenter.frameScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.loadHTMLString(
            """
            <!doctype html><html><body style="margin:0">
            \(hasVideo ? "<video style=\"width:640px;height:360px\"></video>" : "<p>Idle page</p>")
            </body></html>
            """,
            baseURL: nil
        )
        #expect(await PageSettle.untilIdle(BrowserPage(webKit: webView, context: BrowserProfileContext(profile: .privateBrowsing())), timeout: .seconds(30)))
        #expect(await waitUntil { collector.messages.contains("hello") })
        if hasVideo {
            _ = try? await webView.evaluateJavaScript(Self.stand)
            #expect(await waitUntil {
                (try? await webView.evaluateJavaScript("document.querySelector('video').__wsurfBound === true")) as? Bool == true
            })
        }
        return (webView, collector)
    }

    private func countDOMReads(in webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("""
        window.__mediaDOMReads = 0;
        for (const name of ['querySelector', 'querySelectorAll']) {
          const original = document[name].bind(document);
          document[name] = function (...args) {
            window.__mediaDOMReads++;
            return original(...args);
          };
        }
        true
        """)
    }

    @Test func aPageWithoutMediaDoesNoRepeatedDOMWork() async {
        let (webView, _) = await player(hasVideo: false)
        await countDOMReads(in: webView)
        _ = try? await webView.evaluateJavaScript("""
        document.body.className = 'changed';
        document.body.firstElementChild.textContent = 'Updated page';
        document.body.append(document.createElement('p'));
        true
        """)
        try? await Task.sleep(for: .milliseconds(700))
        let reads = try? await webView.evaluateJavaScript("window.__mediaDOMReads") as? Int
        #expect(reads == 0)
    }

    @Test func aPausedPlayerDoesNoRepeatedDOMWork() async {
        let (webView, _) = await player()
        await countDOMReads(in: webView)
        try? await Task.sleep(for: .milliseconds(700))
        let reads = try? await webView.evaluateJavaScript("window.__mediaDOMReads") as? Int
        #expect(reads == 0)
    }

    @Test func pollingStopsOnPauseAndWhileHiddenThenResumesWhenVisible() async {
        let (webView, collector) = await player()
        await countDOMReads(in: webView)
        _ = try? await webView.evaluateJavaScript("""
        window.__pageHidden = false;
        Object.defineProperty(document, 'hidden', { get() { return window.__pageHidden; } });
        window.__box.paused = false;
        document.querySelector('video').dispatchEvent(new Event('play'));
        window.__mediaDOMReads = 0;
        true
        """)
        #expect(await waitUntil(timeout: .seconds(3)) {
            (try? await webView.evaluateJavaScript("window.__mediaDOMReads") as? Int) ?? 0 > 0
        })

        _ = try? await webView.evaluateJavaScript("""
        window.__box.paused = true;
        document.querySelector('video').dispatchEvent(new Event('pause'));
        window.__mediaDOMReads = 0;
        true
        """)
        try? await Task.sleep(for: .milliseconds(700))
        let pausedReads = try? await webView.evaluateJavaScript("window.__mediaDOMReads") as? Int
        #expect(pausedReads == 0)

        _ = try? await webView.evaluateJavaScript("""
        window.__box.paused = false;
        document.querySelector('video').dispatchEvent(new Event('play'));
        window.__pageHidden = true;
        document.dispatchEvent(new Event('visibilitychange'));
        window.__mediaDOMReads = 0;
        true
        """)
        try? await Task.sleep(for: .milliseconds(700))
        let hiddenReads = try? await webView.evaluateJavaScript("window.__mediaDOMReads") as? Int
        #expect(hiddenReads == 0)
        let hiddenState = await state(webView, collector, after: """
        window.__box.currentTime = 17;
        document.querySelector('video').dispatchEvent(new Event('timeupdate'))
        """, resending: false)
        #expect(hiddenState["t"] == 17)

        _ = try? await webView.evaluateJavaScript("""
        window.__pageHidden = false;
        document.dispatchEvent(new Event('visibilitychange'));
        true
        """)
        #expect(await waitUntil(timeout: .seconds(3)) {
            (try? await webView.evaluateJavaScript("window.__mediaDOMReads") as? Int) ?? 0 > 0
        })
    }

    @Test(arguments: [false, true])
    func mediaAddedAfterLoadIsDiscoveredAndRemovalClearsItsAudio(hidden: Bool) async throws {
        let (webView, collector) = await player(hasVideo: false)
        _ = try await webView.evaluateJavaScript("""
        Object.defineProperty(document, 'hidden', { configurable: true, get() { return \(hidden); } });
        document.dispatchEvent(new Event('visibilitychange'));
        true
        """)
        collector.messages.removeAll()
        _ = try await webView.evaluateJavaScript("""
        const audio = document.createElement('audio');
        Object.defineProperty(audio, 'paused', { get() { return false; } });
        Object.defineProperty(audio, 'currentTime', { configurable: true, writable: true, value: 0 });
        document.body.append(audio);
        true
        """)
        try #require(await waitUntil { collector.messages.contains("audio:1") })
        let playing = await state(webView, collector, after: """
        document.querySelector('audio').currentTime = 17;
        document.querySelector('audio').dispatchEvent(new Event('timeupdate'))
        """, resending: false)
        #expect(playing["p"] == 1)
        #expect(playing["t"] == 17)

        collector.messages.removeAll()
        _ = try await webView.evaluateJavaScript("document.querySelector('audio').remove(); true")
        #expect(await waitUntil { collector.messages.contains("audio:0") })
    }

    @Test func hiddenDiscoverySelectsThePlayingVideoAndCommandsIt() async throws {
        let (webView, collector) = await player()
        _ = try await webView.evaluateJavaScript("""
        Object.defineProperty(document, 'hidden', { configurable: true, get() { return true; } });
        window.__box.currentTime = 5;
        const video = document.createElement('video');
        for (const [key, value] of Object.entries({
          paused: false, ended: false, currentTime: 21, duration: 100,
          muted: false, volume: 1, videoWidth: 640, readyState: 0
        })) {
          Object.defineProperty(video, key, { configurable: true, writable: true, value });
        }
        video.style.cssText = 'width:640px;height:360px';
        document.body.append(video);
        true
        """)
        #expect(await waitUntil { (try? await webView.evaluateJavaScript("document.querySelectorAll('video')[1].__wsurfBound === true")) as? Bool == true })

        let selected = await state(webView, collector, resending: true)
        #expect(selected["p"] == 1)
        #expect(selected["t"] == 21)

        // `postMessage` delivers the seek as a task of its own, so the new time is read once the page has handled it.
        _ = try await webView.evaluateJavaScript("window.postMessage('wsurf-seek:1', '*'); true")
        #expect(await waitUntil {
            (try? await webView.evaluateJavaScript("document.querySelectorAll('video')[1].currentTime")) as? Int == 22
        }, "the seek never reached the playing video")
        #expect((try? await webView.evaluateJavaScript("document.querySelectorAll('video')[0].currentTime")) as? Int == 5)
    }

    @Test func aVisiblePausedPlayerReportsItsNewRectAfterLayoutInsertion() async throws {
        let (webView, collector) = await player()
        _ = try await webView.evaluateJavaScript("""
        Object.defineProperty(document, 'hidden', { configurable: true, get() { return false; } });
        document.dispatchEvent(new Event('visibilitychange'));
        true
        """)
        let original = await waitUntil { collector.messages.contains { $0.hasPrefix("rect:") } }
        #expect(original)
        let initialLine = collector.messages.last { $0.hasPrefix("rect:") }
        let initialData = Data((initialLine ?? "rect:{}").dropFirst("rect:".count).utf8)
        let initial = (try? JSONSerialization.jsonObject(with: initialData)) as? [String: Int]
        #expect(initial?["y"] == 0)

        collector.messages.removeAll { $0.hasPrefix("rect:") }
        _ = try await webView.evaluateJavaScript("""
        const block = document.createElement('div');
        block.style.height = '200px';
        document.body.insertBefore(block, document.querySelector('video'));
        true
        """)
        #expect(await waitUntil(timeout: .seconds(3)) {
            collector.messages.contains { message in
                guard message.hasPrefix("rect:"),
                      let data = String(message.dropFirst("rect:".count)).data(using: .utf8),
                      let rect = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int]
                else { return false }
                return rect["y"] == 200
            }
        })
    }

    /// Runs `script`, asks the page to report, and reads the line it sends.
    @discardableResult
    private func state(
        _ webView: WKWebView,
        _ collector: Collector,
        after script: String = "",
        resending: Bool = true
    ) async -> [String: Double] {
        collector.messages.removeAll { $0.hasPrefix("state:") }
        if !script.isEmpty {
            _ = try? await webView.evaluateJavaScript("\(script); true")
        }
        if resending {
            _ = try? await webView.evaluateJavaScript("window.postMessage('wsurf-resend', '*'); true")
        }
        var line: String?
        let arrived = await waitUntil {
            line = collector.messages.last { $0.hasPrefix("state:") }
            return line != nil
        }
        #expect(arrived, "the page never reported its state")
        let payload = Data((line ?? "state:{}").dropFirst("state:".count).utf8)
        let fields = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        return fields.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    private func audio(_ collector: Collector) async -> String? {
        var line: String?
        _ = await waitUntil {
            line = collector.messages.last { $0.hasPrefix("audio:") }
            return line != nil
        }
        return line
    }

    private func post(_ command: String) -> String {
        "window.postMessage('\(command)', '*')"
    }

    // MARK: - What counts as a length

    /// The live-stream sentinel: WebKit reports `INT64_MAX` microseconds for a
    /// stream, which is finite and passes every ordinary check.
    @Test func aStreamsSentinelLengthIsNotALength() async {
        let (webView, collector) = await player()

        let real = await state(webView, collector, after: "window.__box.duration = 331")
        #expect(real["d"] == 331)
        #expect(real["l"] == 0)

        let sentinel = await state(webView, collector, after: "window.__box.duration = 9223372036854.775")
        #expect(sentinel["d"] == 0, "a sentinel must never be offered as a length")
        #expect(sentinel["l"] == 1, "and the player it came from is live")
    }

    @Test func anEndlessStreamHasNoLengthEither() async {
        let (webView, collector) = await player()

        let endless = await state(webView, collector, after: "window.__box.duration = Infinity")
        #expect(endless["d"] == 0)
        #expect(endless["l"] == 1)
    }

    @Test func aPlayerThatHasNotLoadedIsNotCalledLive() async {
        let (webView, collector) = await player()

        let unknown = await state(webView, collector, after: "window.__box.duration = NaN")
        #expect(unknown["d"] == 0)
        #expect(unknown["l"] == 0)

        let empty = await state(webView, collector, after: "window.__box.duration = 0")
        #expect(empty["d"] == 0)
        #expect(empty["l"] == 0)
    }

    @Test func aNegativeLengthIsNoLength() async {
        let (webView, collector) = await player()

        let backwards = await state(webView, collector, after: "window.__box.duration = -5")
        #expect(backwards["d"] == 0)
    }

    // MARK: - A length that keeps growing

    /// A DVR window reports a real length that rises as the stream runs. One
    /// rise is a seek or a load; it takes a run of them to call the player live.
    @Test func aLengthThatKeepsGrowingIsAStream() async {
        let (webView, collector) = await player()

        let first = await state(webView, collector, after: "window.__box.duration = 100")
        #expect(first["l"] == 0)

        let second = await state(webView, collector, after: "window.__box.duration = 200")
        #expect(second["l"] == 0, "one rise is not a stream")

        let third = await state(webView, collector, after: "window.__box.duration = 300")
        #expect(third["l"] == 1, "a second rise is")
        #expect(third["d"] == 300, "and the length is still reported")
    }

    @Test func aLengthThatSettlesStopsBeingAStream() async {
        let (webView, collector) = await player()

        for length in [100, 200, 300] {
            await state(webView, collector, after: "window.__box.duration = \(length)")
        }
        let held = await state(webView, collector, after: "window.__box.duration = 300")
        #expect(held["l"] == 0)
    }

    @Test func aLengthThatBarelyMovesIsTheSameLength() async {
        let (webView, collector) = await player()

        for length in ["100", "100.1", "100.2"] {
            let step = await state(webView, collector, after: "window.__box.duration = \(length)")
            #expect(step["l"] == 0, "\(length)")
        }
    }

    @Test func aLengthThatFallsStartsTheCountOver() async {
        let (webView, collector) = await player()

        for length in [100, 200] {
            await state(webView, collector, after: "window.__box.duration = \(length)")
        }
        await state(webView, collector, after: "window.__box.duration = 50")
        let after = await state(webView, collector, after: "window.__box.duration = 150")
        #expect(after["l"] == 0, "a fall means a new track, not a longer stream")
    }

    // MARK: - What counts as a sound

    @Test func aPlayingPlayerIsHeard() async {
        let (webView, collector) = await player()

        collector.messages.removeAll()
        await state(webView, collector, after: "window.__box.paused = false")
        #expect(await audio(collector) == "audio:1")
    }

    @Test func aMutedOrSilentPlayerIsNotHeard() async {
        let (webView, collector) = await player()

        collector.messages.removeAll()
        await state(webView, collector, after: "window.__box.paused = false; window.__box.muted = true")
        #expect(await audio(collector) == "audio:0")

        collector.messages.removeAll()
        await state(webView, collector, after: "window.__box.muted = false; window.__box.volume = 0")
        #expect(await audio(collector) == "audio:0")
    }

    @Test func aLoadedPlayerWithNoTrackIsNotHeard() async {
        let (webView, collector) = await player()

        collector.messages.removeAll()
        await state(
            webView,
            collector,
            after: """
                window.__box.paused = false;
                window.__box.readyState = 2;
                window.__box.audioTracks = { length: 0 };
                """
        )
        #expect(await audio(collector) == "audio:0")

        collector.messages.removeAll()
        await state(webView, collector, after: "window.__box.audioTracks = { length: 1 }")
        #expect(await audio(collector) == "audio:1")
    }

    @Test func aPlayerStillLoadingIsTakenAtItsWord() async {
        let (webView, collector) = await player()

        collector.messages.removeAll()
        await state(
            webView,
            collector,
            after: """
                window.__box.paused = false;
                window.__box.readyState = 1;
                window.__box.audioTracks = { length: 0 };
                """
        )
        #expect(await audio(collector) == "audio:1")
    }

    @Test func aTabMutedByTheAppIsStillPlaying() async {
        let (webView, collector) = await player()
        await state(webView, collector, after: "window.__box.paused = false")

        await state(webView, collector, after: post("wsurf-mute:1"), resending: false)
        collector.messages.removeAll()
        await state(webView, collector)
        #expect(await audio(collector) == "audio:1")
    }

    // MARK: - Driving the player

    @Test func aRelativeSeekStaysInsideTheTrack() async {
        let (webView, collector) = await player()
        await state(webView, collector, after: "window.__box.duration = 100; window.__box.currentTime = 10")

        let back = await state(webView, collector, after: post("wsurf-seek:-30"), resending: false)
        #expect(back["t"] == 0, "a seek before the start lands on the start")

        let forward = await state(webView, collector, after: post("wsurf-seek:500"), resending: false)
        #expect(forward["t"] == 100, "and one past the end lands on the end")
    }

    @Test func aProportionalSeekIsReadAgainstTheLength() async {
        let (webView, collector) = await player()
        await state(webView, collector, after: "window.__box.duration = 100")

        let middle = await state(webView, collector, after: post("wsurf-seekto:0.5"), resending: false)
        #expect(middle["t"] == 50)

        let past = await state(webView, collector, after: post("wsurf-seekto:2"), resending: false)
        #expect(past["t"] == 100)
    }

    @Test func anAbsoluteSeekIsClampedToo() async {
        let (webView, collector) = await player()
        await state(webView, collector, after: "window.__box.duration = 100")

        let before = await state(webView, collector, after: post("wsurf-seekabs:-5"), resending: false)
        #expect(before["t"] == 0)

        let after = await state(webView, collector, after: post("wsurf-seekabs:250"), resending: false)
        #expect(after["t"] == 100)
    }

    @Test func seekingALiveStreamIsNotClampedToNothing() async {
        let (webView, collector) = await player()
        await state(
            webView,
            collector,
            after: "window.__box.duration = Infinity; window.__box.currentTime = 10"
        )

        let moved = await state(webView, collector, after: post("wsurf-seek:30"), resending: false)
        #expect(moved["t"] == 40)

        let unmoved = await state(webView, collector, after: post("wsurf-seekto:0.5"), resending: false)
        #expect(unmoved["t"] == 40, "a proportion of no length means nothing")
    }

    @Test func theVolumeCarriesTheMute() async {
        let (webView, collector) = await player()

        let silent = await state(webView, collector, after: post("wsurf-volume:0"), resending: false)
        #expect(silent["v"] == 0)
        #expect(silent["m"] == 1, "turning it all the way down mutes the player")

        let heard = await state(webView, collector, after: post("wsurf-volume:0.5"), resending: false)
        #expect(heard["v"] == 0.5)
        #expect(heard["m"] == 0)

        let loud = await state(webView, collector, after: post("wsurf-volume:4"), resending: false)
        #expect(loud["v"] == 1, "and the volume never goes above one")
    }

    @Test func mutingTheTabMutesThePlayer() async {
        let (webView, collector) = await player()

        let muted = await state(webView, collector, after: post("wsurf-mute:1"), resending: false)
        #expect(muted["m"] == 1)

        let unmuted = await state(webView, collector, after: post("wsurf-mute:0"), resending: false)
        #expect(unmuted["m"] == 0)
    }

    // MARK: - Muting the page as a whole

    private func muted(_ webView: WKWebView, _ selector: String) async -> Bool? {
        (try? await webView.evaluateJavaScript("document.querySelector('\(selector)').muted")) as? Bool
    }

    private func bound(_ webView: WKWebView, _ selector: String) async -> Bool {
        await waitUntil {
            (try? await webView.evaluateJavaScript("document.querySelector('\(selector)').__wsurfBound === true")) as? Bool == true
        }
    }

    /// The app mutes a page before the page has a player: the message is kept, and the player it makes later is born muted.
    @Test func aPageWithNothingToPlayYetStillTakesTheMute() async throws {
        let (webView, _) = await player(hasVideo: false)
        _ = try await webView.evaluateJavaScript("\(post("wsurf-mute:1")); true")
        try await webView.finishPendingPageMessages()

        _ = try await webView.evaluateJavaScript("document.body.append(document.createElement('audio')); true")

        #expect(await bound(webView, "audio"))
        #expect(await muted(webView, "audio") == true)

        _ = try await webView.evaluateJavaScript("\(post("wsurf-mute:0")); true")
        #expect(await waitUntil { await muted(webView, "audio") == false })
    }

    /// Unmuting gives back what the app muted and nothing else: a loop the page muted itself stays muted.
    @Test func unmutingGivesBackOnlyWhatTheAppMuted() async throws {
        let (webView, _) = await player(hasVideo: false)
        _ = try await webView.evaluateJavaScript("""
        const own = document.createElement('audio'); own.id = 'own';
        const quiet = document.createElement('audio'); quiet.id = 'quiet'; quiet.muted = true;
        document.body.append(own, quiet); true
        """)
        #expect(await bound(webView, "#own"))
        #expect(await bound(webView, "#quiet"))

        _ = try await webView.evaluateJavaScript("\(post("wsurf-mute:1")); true")
        #expect(await waitUntil { await muted(webView, "#own") == true })
        #expect(await muted(webView, "#quiet") == true)

        _ = try await webView.evaluateJavaScript("\(post("wsurf-mute:0")); true")
        #expect(await waitUntil { await muted(webView, "#own") == false }, "what the app muted is heard again")
        #expect(await muted(webView, "#quiet") == true, "what the page muted is not the app's to unmute")
    }

    /// A player the page starts while muted is silenced by its own play event, not at the next scan, so no first sound gets out.
    @Test func aPlayerStartedWhileMutedIsSilencedByItsPlayEvent() async throws {
        let (webView, _) = await player(hasVideo: false)
        _ = try await webView.evaluateJavaScript("\(post("wsurf-mute:1")); true")
        try await webView.finishPendingPageMessages()

        let silenced = try await webView.evaluateJavaScript("""
        const song = document.createElement('audio'); document.body.append(song);
        song.dispatchEvent(new Event('play'));
        song.muted
        """)

        #expect(silenced as? Bool == true)
    }

    /// Muted by the app still counts as playing (the tab stays in the list to be unmuted); a player the page muted does not,
    /// whatever the app has done.
    @Test func aPlayerThePageMutedIsNotCountedWhileTheAppHasTheTabMuted() async {
        let (webView, collector) = await player()

        collector.messages.removeAll()
        await state(webView, collector, after: "window.__box.paused = false; window.__box.muted = true")
        #expect(await audio(collector) == "audio:0")

        collector.messages.removeAll()
        await state(webView, collector, after: post("wsurf-mute:1"))
        #expect(await audio(collector) == "audio:0", "the page's own muted loop is no sound for the list")
    }
    // MARK: - Frames

    /// A frame made of its own document, with an `audio` element whose `paused` the page controls, as the player of an embed is.
    private static let framePlayer = """
    <!doctype html><audio id="song"></audio><script>
    let playing = true;
    const song = document.getElementById('song');
    Object.defineProperty(song, 'paused', { get() { return !playing; } });
    addEventListener('message', (event) => {
      if (event.data !== 'play' && event.data !== 'stop') { return; }
      playing = event.data === 'play';
      song.dispatchEvent(new Event(playing ? 'play' : 'pause'));
    });
    </script>
    """

    private func addFrame(_ id: String, source: String = MediaScriptTests.framePlayer, to webView: WKWebView) async throws {
        let literal = String(data: try JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed]), encoding: .utf8) ?? "\"\""
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const frame = document.createElement('iframe'); frame.id = '\(id)'; frame.srcdoc = \(literal);
          document.body.append(frame);
        })(); true
        """)
    }

    private func frameReports(_ collector: Collector) -> [(key: String, playing: Bool)] {
        collector.messages.compactMap { message in
            guard message.hasPrefix("frameaudio:") else { return nil }
            let fields = message.dropFirst("frameaudio:".count).split(separator: ":")
            guard fields.count == 2 else { return nil }
            return (String(fields[0]), fields[1] == "1")
        }
    }

    /// A frame says what plays in it under a key of its own, and the page's own document keeps saying `audio:`.
    @Test func aFrameReportsItsOwnSoundUnderItsOwnKey() async throws {
        let (webView, collector) = await player(hasVideo: false)
        collector.messages.removeAll()

        try await addFrame("a", to: webView)
        #expect(await waitUntil { frameReports(collector).contains { $0.playing } }, "a player in a frame is reported")
        let key = try #require(frameReports(collector).first?.key)
        #expect(!collector.messages.contains("audio:1"), "the page's own document plays nothing")

        _ = try await webView.evaluateJavaScript("document.getElementById('a').contentWindow.postMessage('stop', '*'); true")
        #expect(await waitUntil { frameReports(collector).last.map { $0.key == key && !$0.playing } == true }, "and when it stops")

        try await addFrame("b", to: webView)
        #expect(await waitUntil { frameReports(collector).contains { $0.playing && $0.key != key } }, "another frame, another key")
    }

    @Test func aFrameThatGoesSaysItsSoundIsOver() async throws {
        let (webView, collector) = await player(hasVideo: false)
        try await addFrame("a", to: webView)
        try #require(await waitUntil { frameReports(collector).contains { $0.playing } })
        let key = try #require(frameReports(collector).first?.key)

        _ = try await webView.evaluateJavaScript("document.getElementById('a').remove(); true")
        #expect(
            await waitUntil { frameReports(collector).last.map { $0.key == key && !$0.playing } == true },
            "a frame removed while it plays says so as it goes"
        )
    }

    @Test func aFrameWithNothingToPlayStaysQuiet() async throws {
        let (webView, collector) = await player(hasVideo: false)
        collector.messages.removeAll()
        try await addFrame("quiet", source: "<!doctype html><p>No player here.</p>", to: webView)
        try await Task.sleep(for: .milliseconds(600))
        #expect(frameReports(collector).isEmpty, "no word, rather than a word of silence from every frame of the page")
    }

    /// The mute still reaches a player that lives in a frame, and the frame still counts as playing under it.
    @Test func aFramePlayerMutedByTheAppStillCountsAsPlaying() async throws {
        let (webView, collector) = await player(hasVideo: false)
        try await addFrame("a", to: webView)
        try #require(await waitUntil { frameReports(collector).contains { $0.playing } })

        _ = try await webView.evaluateJavaScript("\(post("wsurf-mute:1")); true")
        try await Task.sleep(for: .milliseconds(400))
        #expect(frameReports(collector).last?.playing == true, "muted by the app, it is still playing, for the list")
    }
    /// A document that sees one of its frames go, or load another page, says so: the frame itself may not get to.
    @Test func aDocumentSaysWhenItsFramesMove() async throws {
        let (webView, collector) = await player(hasVideo: false)
        collector.messages.removeAll()

        try await addFrame("a", source: "<!doctype html><p>Quiet.</p>", to: webView)
        #expect(await waitUntil { collector.messages.contains("frames:moved") }, "a frame loaded")

        try await Task.sleep(for: .milliseconds(400))
        collector.messages.removeAll { $0 == "frames:moved" }
        _ = try await webView.evaluateJavaScript("document.getElementById('a').remove(); true")
        #expect(await waitUntil { collector.messages.contains("frames:moved") }, "a frame was removed")
    }

    /// Asking again reaches a frame inside a frame, which the app has no way to address itself.
    @Test func aResendReachesTheFramesInsideFrames() async throws {
        let (webView, collector) = await player(hasVideo: false)
        let inner = String(
            data: try JSONSerialization.data(withJSONObject: Self.framePlayer, options: [.fragmentsAllowed]), encoding: .utf8
        )?.replacingOccurrences(of: "</", with: "<\\/") ?? "\"\""
        try await addFrame(
            "outer",
            source: "<!doctype html><script>const f = document.createElement('iframe'); f.srcdoc = \(inner); document.documentElement.append(f);</script>",
            to: webView
        )
        try #require(await waitUntil { frameReports(collector).contains { $0.playing } }, "the inner frame plays")
        let key = try #require(frameReports(collector).first { $0.playing }?.key)

        collector.messages.removeAll()
        _ = try await webView.evaluateJavaScript("\(post("wsurf-resend")); true")
        #expect(await waitUntil { frameReports(collector).contains { $0.playing && $0.key == key } }, "it says so again")
    }
    // MARK: - Who lifts a mute

    /// The page's `muted` read without a user gesture: the public script call grants one, which is user activation, and a test of
    /// what happens without it must not give it.
    private func quietMuted(_ webView: WKWebView, _ selector: String) async -> Bool? {
        (try? await webView.evaluate(
            "document.querySelector('\(selector)').muted", asFunction: false, in: nil, in: .page
        )) as? Bool
    }

    private func quietRun(_ webView: WKWebView, _ script: String) async throws {
        _ = try await webView.evaluate("\(script); true", asFunction: false, in: nil, in: .page)
    }

    private func mutedPage() async throws -> (WKWebView, Collector) {
        let (webView, collector) = await player(hasVideo: false)
        try await quietRun(webView, "const song = document.createElement('audio'); song.id = 'song'; document.body.append(song)")
        try #require(await waitUntil {
            (try? await webView.evaluate("document.querySelector('#song').__wsurfBound === true", asFunction: false, in: nil, in: .page)) as? Bool == true
        })
        try await quietRun(webView, post("wsurf-mute:1"))
        try #require(await waitUntil { await quietMuted(webView, "#song") == true })
        collector.messages.removeAll()
        return (webView, collector)
    }

    /// Waits until the page has no user activation: the public script calls the test's own setup made grant it for a few seconds.
    private func quietPage(_ webView: WKWebView) async throws {
        try #require(await waitUntil(timeout: .seconds(30)) {
            (try? await webView.evaluate("navigator.userActivation.isActive", asFunction: false, in: nil, in: .page)) as? Bool == false
        }, "the page still has user activation")
    }

    /// An advertisement does this: its own script lifts the mute, with no one having pressed anything.
    @Test func aScriptThatUnmutesAPlayerOnItsOwnIsSilencedAgainAndTheMuteStays() async throws {
        let (webView, collector) = try await mutedPage()
        try await quietPage(webView)

        try await quietRun(webView, "document.getElementById('song').muted = false")
        #expect(await waitUntil { await quietMuted(webView, "#song") == true }, "the player is silenced again at once")
        try await Task.sleep(for: .milliseconds(250))
        #expect(!collector.messages.contains { $0.hasPrefix("tabunmuted") }, "and the app is not told the person unmuted it")

        try await quietRun(webView, "const late = document.createElement('audio'); late.id = 'late'; document.body.append(late)")
        #expect(await waitUntil { await quietMuted(webView, "#late") == true }, "the page is still muted: a player made later is born so")
    }

    /// The person pressed the player's own control: the frame has user activation, and the page's script lifts the mute. A real
    /// press cannot be made here without a system event, and WebKit's script gesture is not user activation, so the activation is
    /// stood in for, as `stand` does for the rest of what a player answers.
    @Test func anUnmuteWithUserActivationIsReportedAsTheUsers() async throws {
        let (webView, collector) = try await mutedPage()
        try await quietRun(webView, """
        Object.defineProperty(navigator, 'userActivation', { configurable: true, get() { return { hasBeenActive: true, isActive: true }; } })
        """)

        try await quietRun(webView, "document.getElementById('song').muted = false")
        #expect(await waitUntil { collector.messages.contains("tabunmuted") }, "the person unmuted it")
        #expect(await quietMuted(webView, "#song") == false, "and it stays unmuted until the app answers")
    }

    /// A frame has the person's own input or it has not: a script cannot make one, so a frame that unmutes its player on its own is
    /// silenced again even while its page has user activation.
    @Test func aFrameThatUnmutesItsPlayerWithoutTheInputItselfIsSilencedAgain() async throws {
        let (webView, collector) = await player(hasVideo: false)
        try await addFrame("a", to: webView)
        try #require(await waitUntil { frameReports(collector).contains { $0.playing } })
        try await quietRun(webView, post("wsurf-mute:1"))
        let song = "document.getElementById('a').contentDocument.getElementById('song')"
        try #require(await waitUntil { (try? await webView.evaluate("\(song).muted", asFunction: false, in: nil, in: .page)) as? Bool == true })
        collector.messages.removeAll()

        // With user activation in the page (the public call grants it, and a same-origin frame shares it): still no input in the frame.
        _ = try await webView.evaluateJavaScript("\(song).muted = false; true")
        #expect(await waitUntil { (try? await webView.evaluate("\(song).muted", asFunction: false, in: nil, in: .page)) as? Bool == true }, "silenced again")
        try await Task.sleep(for: .milliseconds(250))
        #expect(!collector.messages.contains { $0.hasPrefix("tabunmuted") }, "no report from a frame the person did not touch")
    }
}
