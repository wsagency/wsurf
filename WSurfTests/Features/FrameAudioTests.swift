// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WebKit

@testable import WSurf

/// How a page that plays sound in a frame is told apart from one that does not: the reports a frame's script sends and what the
/// page, taken as a whole, makes of them. Real pages with real frames are `AudioFrameEngineTests`.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct FrameAudioTests {
    // MARK: - What a message says

    @Test func theMessagesAFrameAndTheDocumentSend() {
        #expect(FrameAudio.report(in: "audio:1", isMainFrame: true) == .document(playing: true))
        #expect(FrameAudio.report(in: "audio:0", isMainFrame: true) == .document(playing: false))
        #expect(FrameAudio.report(in: "frameaudio:k3x9:1", isMainFrame: false) == .frame(key: "k3x9", playing: true))
        #expect(FrameAudio.report(in: "frameaudio:k3x9:0", isMainFrame: false) == .frame(key: "k3x9", playing: false))
    }

    @Test func aReportFromTheWrongPlaceOrOfTheWrongShapeSaysNothing() {
        #expect(FrameAudio.report(in: "audio:1", isMainFrame: false) == nil, "a frame speaks for itself with its key")
        #expect(FrameAudio.report(in: "frameaudio:k:1", isMainFrame: true) == nil, "the page's own document has no key")
        for bad in [
            "frameaudio::1", "frameaudio:k:", "frameaudio:k:2", "frameaudio:k", "frameaudio:k:1:x", "frameaudio:k k:1",
            "frameaudio:ключ:1", "frameaudio:\(String(repeating: "a", count: 49)):1", "audio:", "audio:2", "audio:11", "state:{}",
        ] {
            #expect(FrameAudio.report(in: bad, isMainFrame: false) == nil, "\(bad)")
            #expect(FrameAudio.report(in: bad, isMainFrame: true) == nil, "\(bad)")
        }
    }

    // MARK: - What the page makes of them

    @Test func aPagePlaysWhileAnyOfItsPartsDoes() {
        var audio = FrameAudio()
        #expect(!audio.isPlaying)

        audio.apply(.frame(key: "a", playing: true))
        #expect(audio.isPlaying, "a player in one frame")
        audio.apply(.frame(key: "b", playing: true))
        audio.apply(.frame(key: "a", playing: false))
        #expect(audio.isPlaying, "the other frame still plays")
        audio.apply(.document(playing: true))
        audio.apply(.frame(key: "b", playing: false))
        #expect(audio.isPlaying, "the page's own document plays")
        audio.apply(.document(playing: false))
        #expect(!audio.isPlaying)

    }

    @Test func aFrameThatNeverPlayedStoppingChangesNothing() {
        var audio = FrameAudio()
        audio.apply(.frame(key: "never", playing: false))
        #expect(audio == FrameAudio())
    }

    @Test func aNewDocumentEndsWhatTheOldOneAndItsFramesSaid() {
        var audio = FrameAudio()
        audio.apply(.document(playing: true))
        audio.apply(.frame(key: "a", playing: true))

        audio.startDocument()
        #expect(!audio.isPlaying)
        #expect(!audio.isDocumentPlaying && audio.frames.isEmpty)
    }

    @Test func aRefreshKeepsTheFramesThatAnswerAndDropsTheOthers() {
        var audio = FrameAudio()
        audio.apply(.frame(key: "stays", playing: true), engineFrame: "1")
        audio.apply(.frame(key: "goes", playing: true))
        audio.apply(.frame(key: "stops", playing: true))
        audio.beginRefresh()
        #expect(audio.frames.count == 3, "asking again drops nothing by itself: the tab does not stop for the moment it takes")

        audio.apply(.frame(key: "stays", playing: true), engineFrame: "1")
        audio.apply(.frame(key: "stops", playing: false))
        audio.endRefresh()
        #expect(Set(audio.frames.keys) == ["stays"], "the frame that said nothing is gone with the one that said it stopped")
        #expect(audio.unconfirmed.isEmpty)

        audio.endRefresh()
        #expect(Set(audio.frames.keys) == ["stays"], "and a refresh that was not begun drops nothing")
    }

    @Test func aNewDocumentEndsARefreshInProgress() {
        var audio = FrameAudio()
        audio.apply(.frame(key: "a", playing: true))
        audio.beginRefresh()
        audio.startDocument()
        audio.apply(.frame(key: "b", playing: true))
        audio.endRefresh()
        #expect(Set(audio.frames.keys) == ["b"], "a frame of the new document is not dropped for the old one's refresh")
    }

    @Test func aLostRendererEndsEverything() {
        var audio = FrameAudio()
        audio.apply(.document(playing: true))
        audio.apply(.frame(key: "a", playing: true))
        audio.reset()
        #expect(audio == FrameAudio())
    }

    @Test func theEnginesWordThatAFrameIsGoneEndsWhatItSaid() {
        var audio = FrameAudio()
        audio.apply(.frame(key: "a", playing: true), engineFrame: "7")
        audio.apply(.frame(key: "b", playing: true), engineFrame: "8")
        audio.apply(.frame(key: "c", playing: true))

        audio.forget(engineFrames: ["9"])
        #expect(audio.frames.count == 3, "a frame it does not know is not one of these")
        audio.forget(engineFrames: ["7"])
        #expect(Set(audio.frames.keys) == ["b", "c"])
        audio.forget(engineFrames: ["8", ""])
        #expect(Set(audio.frames.keys) == ["c"], "a frame the engine gave no id keeps what it said: only its own word ends it")
    }

    @Test func aPageThatOpensAGreatManyPlayersIsNotMadeToCostMore() {
        var audio = FrameAudio()
        for number in 0..<(FrameAudio.maximumFrames + 10) {
            audio.apply(.frame(key: "f\(number)", playing: true))
        }
        #expect(audio.frames.count == FrameAudio.maximumFrames)

        audio.apply(.frame(key: "f0", playing: false))
        #expect(audio.frames.count == FrameAudio.maximumFrames - 1, "one that is kept can still stop")
        audio.apply(.frame(key: "late", playing: true))
        #expect(audio.frames["late"] != nil, "and the room it left is used")
    }

    // MARK: - What the window makes of a page's reports

    private func withWindow(_ body: @MainActor (BrowserApplication, AppCoordinator, BrowserTab) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Audio frames")
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let main = app.newWindow(profile: profile, show: false)
        let tab = main.browser.newTab(adopting: WKWebView())
        var failure: (any Error)?
        do {
            try await body(app, main, tab)
        } catch {
            failure = error
        }
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    @Test func aPlayerInAFrameMakesTheTabPlayAndListedAndItsEndTakesItOut() async throws {
        try await withWindow { app, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("audio:0", from: page, isMainFrame: true)
            #expect(!tab.isPlayingAudio)
            #expect(app.audibleTabs(for: main).isEmpty)

            main.media.receiveScriptMessage("frameaudio:abc:1", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio, "the page's own document plays nothing; a frame does")
            #expect(app.audibleTabs(for: main).map(\.id) == [tab.id], "so the tab is listed")
            #expect(AudioIndicator.isVisible(audibleCount: app.audibleTabs(for: main).count, isMuted: app.isMuted), "and the speaker shows")

            main.media.receiveScriptMessage("frameaudio:abc:0", from: page, isMainFrame: false)
            #expect(!tab.isPlayingAudio)
            #expect(app.audibleTabs(for: main).isEmpty)
        }
    }

    @Test func theTabPlaysUntilTheLastPartStops() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("audio:1", from: page, isMainFrame: true)
            main.media.receiveScriptMessage("frameaudio:one:1", from: page, isMainFrame: false)
            main.media.receiveScriptMessage("frameaudio:two:1", from: page, isMainFrame: false)

            main.media.receiveScriptMessage("audio:0", from: page, isMainFrame: true)
            #expect(tab.isPlayingAudio, "two frames still play")
            main.media.receiveScriptMessage("frameaudio:one:0", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio)
            main.media.receiveScriptMessage("frameaudio:two:0", from: page, isMainFrame: false)
            #expect(!tab.isPlayingAudio)
        }
    }

    @Test func aNewDocumentOfThePageEndsWhatItsFramesSaid() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("frameaudio:old:1", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio)

            main.media.receiveScriptMessage("hello", from: page, isMainFrame: true)
            #expect(!tab.isPlayingAudio, "the frame went with its document, and said nothing as it went")

            main.media.receiveScriptMessage("frameaudio:old:0", from: page, isMainFrame: false)
            #expect(!tab.isPlayingAudio, "a late word from it changes nothing")
            main.media.receiveScriptMessage("frameaudio:new:1", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio, "a frame of the new document is heard")
        }
    }

    @Test func aFrameDoesNotStartADocumentAndASoundFromAFrameIsNotTheDocuments() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("audio:1", from: page, isMainFrame: true)
            main.media.receiveScriptMessage("hello", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio, "a frame's hello is not the page's new document")

            main.media.receiveScriptMessage("audio:0", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio, "and a frame cannot speak for the document")
            main.media.receiveScriptMessage("frameaudio:k:0", from: page, isMainFrame: true)
            #expect(tab.isPlayingAudio, "nor the document for a frame")
        }
    }

    @Test func aFrameTheEngineSaysIsGoneStopsPlayingWithoutSayingSo() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("frameaudio:a:1", from: page, isMainFrame: false, frameID: "frame-1")
            main.media.receiveScriptMessage("frameaudio:b:1", from: page, isMainFrame: false, frameID: "frame-2")

            main.media.forgetFrames(["frame-1"], of: page)
            #expect(tab.isPlayingAudio, "the other one plays on")
            main.media.forgetFrames(["frame-2"], of: page)
            #expect(!tab.isPlayingAudio)
            main.media.forgetFrames(["frame-3"], of: page)
            #expect(!tab.isPlayingAudio, "a frame it never heard of is nothing")
        }
    }

    @Test func aFrameThatGoesWithoutAWordIsFoundOutWhenTheDocumentSaysAFrameMoved() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("frameaudio:gone:1", from: page, isMainFrame: false)
            main.media.receiveScriptMessage("frameaudio:stays:1", from: page, isMainFrame: false)

            main.media.receiveScriptMessage("frames:moved", from: page, isMainFrame: true)
            #expect(tab.isPlayingAudio, "nothing is dropped while the frames are being asked")
            main.media.receiveScriptMessage("frameaudio:stays:1", from: page, isMainFrame: false)
            #expect(await waitUntil { main.media.audio(of: page).frames.count == 1 }, "the frame that did not answer is dropped")
            #expect(Set(main.media.audio(of: page).frames.keys) == ["stays"])
            #expect(tab.isPlayingAudio, "the one that did still plays")

            main.media.receiveScriptMessage("frames:moved", from: page, isMainFrame: true)
            #expect(await waitUntil { !tab.isPlayingAudio }, "when none answers, the tab stops playing")
        }
    }

    @Test func aFrameMovingOnAPageThatPlaysNothingInAFrameDoesNothing() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("audio:1", from: page, isMainFrame: true)
            main.media.receiveScriptMessage("frames:moved", from: page, isMainFrame: false)
            try await Task.sleep(for: MediaCenter.refreshWindow + .milliseconds(200))
            #expect(tab.isPlayingAudio, "the page's own document plays on")
            #expect(main.media.audio(of: page).unconfirmed.isEmpty)
        }
    }

    @Test func aLostRendererTakesWhatItsFramesSaidWithIt() async throws {
        try await withWindow { _, main, tab in
            let page = tab.page
            main.media.receiveScriptMessage("frameaudio:a:1", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio)

            tab.isPlayingAudio = false
            main.media.pageDidReset(page)
            #expect(!main.media.audio(of: page).isPlaying)

            main.media.receiveScriptMessage("frameaudio:b:1", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio, "what plays in the new renderer is heard")
            main.media.receiveScriptMessage("frameaudio:a:0", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio, "and a word from the old one's frame changes nothing")
        }
    }

    @Test func aTabThatBeginsToPlayInAFrameWhileWSurfIsMutedIsSilencedLikeAnyOther() async throws {
        try await withWindow { app, main, tab in
            let page = tab.page
            app.muteAll()
            #expect(!tab.isMuted, "nothing plays, so no mark")

            main.media.receiveScriptMessage("frameaudio:a:1", from: page, isMainFrame: false)
            #expect(tab.isPlayingAudio && tab.isMuted, "it plays, and is silenced and marked at once")

            app.unmuteAll()
            #expect(!tab.isMuted)
        }
    }
}
