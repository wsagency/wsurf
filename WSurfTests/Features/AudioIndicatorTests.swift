// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import WSurf

/// What the speaker is built on: which tabs play, when it shows, the mute of all of WSurf and the way back to each tab's own,
/// and the jump to a playing tab. Every list is read from the audio state the tabs already keep (`isPlayingAudio`, `isMuted`);
/// what needs sound runs a real page on each engine in `AudioMuteEngineTests`, and the views and the menu are in
/// `AudioIndicatorViewTests`.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AudioIndicatorTests {
    /// Runs `body` with a profile of its own, so the saved windows of other suites cannot be restored with it.
    private func withProfile(_ name: String = "Audio", _ body: @MainActor (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: name)
        var failure: (any Error)?
        do {
            try await body(profile)
        } catch {
            failure = error
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    private func run() -> BrowserApplication {
        BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
    }

    private func finish(_ app: BrowserApplication) {
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
    }

    /// A page of `window` that plays: the flag the page's own report sets. Nothing loads.
    private func playing(_ address: String, in window: AppCoordinator, muted: Bool = false) -> BrowserTab {
        let tab = window.browser.addPage(address)
        tab.isPlayingAudio = true
        tab.isMuted = muted
        return tab
    }

    // MARK: - What plays

    @Test func theListHoldsWhatPlaysInEveryWindowOfTheProfileAndNothingFromAnotherSession() async throws {
        try await withProfile("Audio list") { profile in
            try await withProfile("Audio elsewhere") { other in
                let app = run()
                let first = app.newWindow(profile: profile, show: false)
                let second = app.newWindow(profile: profile, show: false)
                let elsewhere = app.newWindow(profile: other, show: false)
                let secret = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
                let secretToo = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
                let heard = playing("https://a.example/", in: first)
                _ = first.browser.addPage("https://quiet.example/")
                let alsoHeard = playing("https://b.example/", in: second)
                let otherProfile = playing("https://c.example/", in: elsewhere)
                let hidden = playing("https://p.example/", in: secret)
                let hiddenToo = playing("https://q.example/", in: secretToo)

                let list = app.audibleTabs(for: first)
                #expect(list.map(\.id) == [heard.id, alsoHeard.id], "this window's own first, then the profile's other windows")
                #expect(list.map(\.isHere) == [true, false])
                #expect(list.last?.window === second)
                #expect(app.audibleTabs(for: second).map(\.id) == [alsoHeard.id, heard.id])
                #expect(app.audibleTabs(for: elsewhere).map(\.id) == [otherProfile.id], "another profile has a list of its own")
                #expect(app.audibleTabs(for: secret).map(\.id) == [hidden.id], "a private window lists its own session only")
                #expect(app.audibleTabs(for: secretToo).map(\.id) == [hiddenToo.id])
                #expect(!list.contains { $0.id == hidden.id || $0.id == hiddenToo.id }, "no list names a private tab")

                alsoHeard.isPlayingAudio = false
                #expect(app.audibleTabs(for: first).map(\.id) == [heard.id], "what stops playing leaves the list")
                finish(app)
            }
        }
    }

    @Test func aPageInAMicroWindowIsListedOnceAndItsRowNever() async throws {
        try await withProfile("Audio micro") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = playing("https://song.example/", in: main)
            _ = main.browser.addPage("https://other.example/")
            let micro = try #require(main.moveToMicroWindow(tab))
            let row = try #require(main.browser.microPlaceholder(for: tab.id))
            row.isPlayingAudio = true

            let fromMain = app.audibleTabs(for: main)
            #expect(fromMain.map(\.id) == [tab.id], "the page, once")
            #expect(fromMain.first?.window === micro && fromMain.first?.isHere == false)
            #expect(!fromMain.contains { $0.id == row.id }, "the row that stands for it plays nothing")
            let fromMicro = app.audibleTabs(for: micro)
            #expect(fromMicro.map(\.id) == [tab.id] && fromMicro.first?.isHere == true)
            finish(app)
        }
    }

    // MARK: - When the speaker shows

    @Test func theSpeakerShowsWhileSomethingPlaysAndWhileWSurfIsMuted() {
        #expect(!AudioIndicator.isVisible(audibleCount: 0, isMuted: false))
        #expect(AudioIndicator.isVisible(audibleCount: 1, isMuted: false))
        #expect(AudioIndicator.isVisible(audibleCount: 3, isMuted: false))
        #expect(AudioIndicator.isVisible(audibleCount: 0, isMuted: true), "muted with nothing playing: it stays, to unmute")
        #expect(AudioIndicator.isVisible(audibleCount: 2, isMuted: true))
    }

    @Test func theSpeakerAndWhatVoiceOverSaysFollowTheState() {
        #expect(AudioIndicator.symbol(isMuted: false) == "speaker.wave.2")
        #expect(AudioIndicator.symbol(isMuted: true) == "speaker.slash")
        #expect(AudioIndicator.label(audibleCount: 1, isMuted: false) == String(localized: "1 tab playing audio"))
        #expect(AudioIndicator.label(audibleCount: 2, isMuted: false) == String(localized: "2 tabs playing audio"))
        #expect(AudioIndicator.label(audibleCount: 2, isMuted: true) == String(localized: "WSurf muted"), "muted says so, whatever plays")
        #expect(AudioIndicator.label(audibleCount: 0, isMuted: true) == String(localized: "WSurf muted"))
        #expect(AudioIndicator.help(isMuted: false) == String(localized: "Mute WSurf"))
        #expect(AudioIndicator.help(isMuted: true) == String(localized: "Unmute WSurf"))
    }

    // MARK: - Mute WSurf

    @Test func muteSilencesEveryPlayingTabOfEveryWindowAndUnmuteGivesEachItsOwnBack() async throws {
        try await withProfile("Audio mute") { profile in
            let app = run()
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let secret = app.newWindow(profile: .privateBrowsing(), settingsOwner: profile, show: false)
            let micro = app.newWindow(profile: profile, settingsOwner: profile, show: false, kind: .micro)
            let loud = playing("https://loud.example/", in: first)
            let alreadyMuted = playing("https://quiet-by-choice.example/", in: first, muted: true)
            let quiet = first.browser.addPage("https://idle.example/")
            let inSecond = playing("https://second.example/", in: second)
            let inPrivate = playing("https://private.example/", in: secret)
            let inMicro = micro.browser.activeTab ?? micro.browser.addPage("https://micro.example/")
            inMicro.isPlayingAudio = true
            let allPlaying = [loud, alreadyMuted, inSecond, inPrivate, inMicro]

            #expect(!app.isMuted)
            app.muteAll()

            #expect(app.isMuted)
            #expect(allPlaying.allSatisfy { $0.isMuted }, "every playing tab, in every window, private and micro too")
            #expect(allPlaying.allSatisfy { $0.isPlayingAudio }, "muted is not stopped: they stay listed, so they can be unmuted")
            #expect(!quiet.isMuted, "a tab that plays nothing carries no mark")

            app.unmuteAll()

            #expect(!app.isMuted)
            #expect([loud, inSecond, inPrivate, inMicro].allSatisfy { !$0.isMuted }, "each is back as it was")
            #expect(alreadyMuted.isMuted, "the tab muted on its own before stays muted")
            #expect(!quiet.isMuted)
            finish(app)
        }
    }

    @Test func theMuteToggleIsOneSwitchAndRepeatsAreHarmless() async throws {
        try await withProfile("Audio toggle") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = playing("https://loud.example/", in: main)

            main.toggleWSurfMute()
            #expect(main.isWSurfMuted && tab.isMuted)
            app.muteAll()
            #expect(tab.isMuted, "muting twice keeps what the first remembered")
            main.toggleWSurfMute()
            #expect(!main.isWSurfMuted && !tab.isMuted)
            app.unmuteAll()
            #expect(!tab.isMuted)
            finish(app)
        }
    }

    @Test func aTabUnmutedOnItsOwnWhileMutedStaysUnmutedAndTheOthersComeBackAsTheyWere() async throws {
        try await withProfile("Audio solo") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let solo = playing("https://solo.example/", in: main)
            let other = playing("https://other.example/", in: main)
            let chosen = playing("https://chosen.example/", in: main, muted: true)
            app.muteAll()

            main.toggleMute(tab: solo)
            main.toggleMute(tab: chosen)
            #expect(!solo.isMuted && !chosen.isMuted && other.isMuted, "the person's own choice while muted")

            // It stops and plays again, and it is not silenced behind the person's back.
            solo.isPlayingAudio = false
            solo.isPlayingAudio = true
            app.silenceIfMuted(solo, in: main)
            #expect(!solo.isMuted)

            app.unmuteAll()
            #expect(!solo.isMuted && !other.isMuted)
            #expect(!chosen.isMuted, "muted before, but unmuted by the person since: their last word stands")
            finish(app)
        }
    }

    @Test func aTabThatStartsToPlayWhileMutedIsSilencedAndComesBackUnmuted() async throws {
        try await withProfile("Audio late") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let late = main.browser.addPage("https://late.example/")
            app.muteAll()
            #expect(!late.isMuted)

            late.isPlayingAudio = true
            app.silenceIfMuted(late, in: main)
            #expect(late.isMuted, "it began to play after the mute, and takes it")

            app.unmuteAll()
            #expect(!late.isMuted, "it had no mute of its own to give back")
            finish(app)
        }
    }

    @Test func aNewDocumentOfTheMainFrameTellsTheWindowAndAFrameDoesNot() {
        let media = MediaCenter()
        var started: [BrowserPage] = []
        media.onPageStarted = { started.append($0) }
        let page = BrowserPage(webKit: WKWebView(), context: BrowserProfileContext(profile: .privateBrowsing()))

        media.receiveScriptMessage("hello", from: page, isMainFrame: false)
        #expect(started.isEmpty)

        media.receiveScriptMessage("hello", from: page, isMainFrame: true)
        #expect(started.count == 1 && started.first === page)
    }

    /// A page starts every document unmuted, so a loaded tab that owes a mute asks for it again with each new document: its
    /// own, if it was muted, and WSurf's, unless the person unmuted it on its own since.
    @Test func aNewDocumentAsksForTheMuteItsTabOwes() async throws {
        try await withProfile("Audio hello") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = main.browser.newTab(adopting: WKWebView())
            let page = tab.page
            @MainActor func asked() async -> Bool {
                let before = page.evaluations
                main.media.receiveScriptMessage("hello", from: page, isMainFrame: true)
                return await waitUntil(timeout: .milliseconds(500)) { page.evaluations > before }
            }

            #expect(await !asked(), "nothing owed: the page is left alone")

            tab.isMuted = true
            #expect(await asked(), "a tab muted on its own lost that with the old document")

            tab.isMuted = false
            app.muteAll()
            #expect(await asked(), "WSurf is muted, and this tab has not been told")

            tab.isPlayingAudio = true
            app.silenceIfMuted(tab, in: main)
            main.toggleMute(tab: tab)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!tab.isMuted)
            #expect(await !asked(), "the person unmuted it on its own while WSurf was muted: it stays as they chose")

            app.unmuteAll()
            try await Task.sleep(for: .milliseconds(300))
            #expect(await !asked())
            finish(app)
            await tab.waitForRetirement()
        }
    }

    @Test func theMediaPanelShowsTheMute() async throws {
        try await withProfile("Audio panel") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let docked = playing("https://song.example/", in: main)
            main.media.model.controlledTabID = docked.id
            main.media.model.isMuted = false

            app.muteAll()
            #expect(main.media.model.isMuted, "the docked player's speaker is crossed out")

            app.unmuteAll()
            #expect(!main.media.model.isMuted)
            finish(app)
        }
    }

    // MARK: - Jumping to a tab

    @Test func aTabOfAnotherWindowIsShownInItsWindowAndItsSpaceAndItsRowIsRevealed() async throws {
        try await withProfile("Audio jump") { profile in
            let app = run()
            let first = app.newWindow(profile: profile, show: false)
            let second = app.newWindow(profile: profile, show: false)
            let (home, recipes) = (UUID(), UUID())
            second.browser.adoptSpaces([home, recipes])
            second.browser.switchSpace(to: home)
            let homeTab = second.browser.addPage("https://home.example/")
            second.browser.activate(homeTab)
            second.browser.switchSpace(to: recipes)
            let song = playing("https://song.example/", in: second)
            let folder = second.browser.createFolder(named: "Music", containing: [song])
            folder.isExpanded = false
            second.browser.switchSpace(to: home)
            second.browser.activate(homeTab)
            let firstActive = first.browser.activeTabID
            first.showBrowser(activate: false)
            second.showBrowser(activate: false)
            let entry = try #require(app.audibleTabs(for: first).first)
            try #require(entry.id == song.id && entry.window === second)
            try #require(second.browser.currentSpaceID == home)

            app.show(entry, activating: false)

            #expect(second.browser.activeTabID == song.id, "the tab is in front in its own window")
            #expect(second.browser.currentSpaceID == recipes, "and its space is on screen")
            #expect(folder.isExpanded, "the folder it was in opened")
            #expect(second.browser.sidebarReveal?.tabID == song.id, "and the sidebar was asked to show its row")
            #expect(second.nativeWindow?.isVisible == true)
            #expect(first.browser.activeTabID == firstActive, "the window that asked is left alone")
            finish(app)
        }
    }

    @Test func aTabOfThisWindowIsShownInThisWindow() async throws {
        try await withProfile("Audio here") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let song = playing("https://song.example/", in: main)
            let other = main.browser.addPage("https://other.example/")
            main.browser.activate(other)
            main.showBrowser(activate: false)
            let entry = try #require(app.audibleTabs(for: main).first)
            #expect(entry.isHere)

            app.show(entry, activating: false)

            #expect(main.browser.activeTabID == song.id)
            #expect(main.browser.sidebarReveal?.tabID == song.id)
            finish(app)
        }
    }

    @Test func aMicroWindowIsBroughtForwardAndItsPageLeftWhereItIs() async throws {
        try await withProfile("Audio micro jump") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let song = playing("https://song.example/", in: main)
            let anchor = main.browser.addPage("https://anchor.example/")
            main.browser.activate(anchor)
            let micro = try #require(main.moveToMicroWindow(song))
            main.browser.activate(anchor)
            micro.nativeWindow?.orderOut(nil)
            let entry = try #require(app.audibleTabs(for: main).first)
            try #require(entry.window === micro)

            app.show(entry, activating: false)

            #expect(micro.nativeWindow?.isVisible == true, "the micro window is the one that comes forward")
            #expect(micro.browser.activeTabID == song.id)
            #expect(main.browser.activeTabID == anchor.id, "the main window stays as it was")
            #expect(micro.browser.sidebarReveal == nil, "a micro window has no sidebar to scroll")
            finish(app)
        }
    }

    @Test func aTabThatClosedBeforeTheClickIsNotShown() async throws {
        try await withProfile("Audio stale") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let song = playing("https://song.example/", in: main)
            let other = main.browser.addPage("https://other.example/")
            main.browser.activate(other)
            let entry = try #require(app.audibleTabs(for: main).first)

            main.browser.close(song)
            app.show(entry, activating: false)

            #expect(main.browser.activeTabID != song.id)
            finish(app)
        }
    }
}
