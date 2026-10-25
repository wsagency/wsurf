// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// Who can lift a mute. A page script can set `muted = false` on any player of its own, an advertisement in a frame of another
/// site included, so a page's report that a player was unmuted lifts the tab's mute only when it is the person's (user activation
/// in the frame, from the page's own frame or the frame they pointed at), and never lifts Mute WSurf, which only the speaker, ⌃⌘M
/// and the menu lift. The script half is `MediaScriptTests`'s, on real pages `AudioFrameEngineTests`'s.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct TabUnmuteTests {
    // MARK: - The decisions

    @Test func aReportIsTheUsersFromThePagesOwnFrameOrFromAFrameThatSaysTheInputWasItsOwn() {
        #expect(MediaCenter.isUsersUnmute("tabunmuted", isMainFrame: true))
        #expect(MediaCenter.isUsersUnmute("tabunmuted:direct", isMainFrame: true))
        #expect(MediaCenter.isUsersUnmute("tabunmuted:direct", isMainFrame: false), "the frame the person pointed at")
        #expect(!MediaCenter.isUsersUnmute("tabunmuted", isMainFrame: false), "another frame's plain report: which frame they pressed is not known")
        #expect(!MediaCenter.isUsersUnmute("tabunmuted:other", isMainFrame: false))
    }

    @Test func whatTheAppDoesWithAReportThatAPlayerWasUnmuted() {
        for isTheUsers in [false, true] {
            for isWSurfMuted in [false, true] {
                for isTabMuted in [false, true] {
                    let answer = MediaCenter.answer(toUnmute: isTheUsers, isWSurfMuted: isWSurfMuted, isTabMuted: isTabMuted)
                    let which = "users \(isTheUsers), WSurf muted \(isWSurfMuted), tab muted \(isTabMuted)"
                    if isWSurfMuted {
                        #expect(answer == .putMuteBack, "nothing in a page lifts Mute WSurf, the person's press included: \(which)")
                    } else if !isTabMuted {
                        #expect(answer == .ignore, "there is no mute of the tab to lift: \(which)")
                    } else if isTheUsers {
                        #expect(answer == .liftTabMute, "the person pressed the player's own control: \(which)")
                    } else {
                        #expect(answer == .putMuteBack, "a script's own unmute does not lift the tab's mute: \(which)")
                    }
                }
            }
        }
    }

    // MARK: - On a window

    private func withWindow(_ body: @MainActor (BrowserApplication, AppCoordinator, BrowserTab) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Tab unmute")
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

    /// Waits for the page to be told (a script call) after `body`, or reports that it was not.
    private func pageIsToldAgain(_ page: BrowserPage, after body: () -> Void) async -> Bool {
        let before = page.evaluations
        body()
        return await waitUntil(timeout: .milliseconds(800)) { page.evaluations > before }
    }

    @Test func thePersonsUnmuteOfATabLiftsItsMute() async throws {
        try await withWindow { _, main, tab in
            main.toggleMute(tab: tab)
            #expect(tab.isMuted)
            main.media.receiveScriptMessage("tabunmuted", from: tab.page, isMainFrame: true)
            #expect(!tab.isMuted)

            main.toggleMute(tab: tab)
            main.media.receiveScriptMessage("tabunmuted:direct", from: tab.page, isMainFrame: false)
            #expect(!tab.isMuted, "a frame the person pointed at")
        }
    }

    @Test func aReportThatIsNotTheUsersLeavesTheTabMutedAndTellsThePageToBeMutedAgain() async throws {
        try await withWindow { _, main, tab in
            main.toggleMute(tab: tab)
            let told = await pageIsToldAgain(tab.page) {
                main.media.receiveScriptMessage("tabunmuted", from: tab.page, isMainFrame: false)
            }
            #expect(tab.isMuted, "another frame's plain report is not the person's")
            #expect(told, "its players are silenced again")
        }
    }

    @Test func nothingInAPageLiftsMuteWSurfAndThePageIsMutedAgain() async throws {
        try await withWindow { app, main, tab in
            tab.isPlayingAudio = true
            app.muteAll()
            #expect(app.isMuted && tab.isMuted)

            for (message, isMain) in [("tabunmuted", true), ("tabunmuted:direct", false), ("tabunmuted", false)] {
                let told = await pageIsToldAgain(tab.page) {
                    main.media.receiveScriptMessage(message, from: tab.page, isMainFrame: isMain)
                }
                #expect(app.isMuted && tab.isMuted, "\(message) from \(isMain ? "the page" : "a frame"): WSurf stays muted")
                #expect(told, "and the page's players are silenced again")
            }

            app.unmuteAll()
            #expect(!app.isMuted && !tab.isMuted, "the speaker and ⌃⌘M still lift it")
        }
    }

    @Test func aTabThatPlaysNothingIsMutedAgainToo() async throws {
        try await withWindow { app, main, tab in
            app.muteAll()
            #expect(!tab.isMuted, "nothing plays, so no mark")
            let told = await pageIsToldAgain(tab.page) {
                main.media.receiveScriptMessage("tabunmuted", from: tab.page, isMainFrame: true)
            }
            #expect(told, "a player that was unmuted in it is silenced again, marked or not")
            #expect(app.isMuted)
        }
    }

    @Test func aReportOnATabThatIsNotMutedAndNotUnderMuteWSurfDoesNothing() async throws {
        try await withWindow { _, main, tab in
            let told = await pageIsToldAgain(tab.page) {
                main.media.receiveScriptMessage("tabunmuted", from: tab.page, isMainFrame: true)
            }
            #expect(!told)
            #expect(!tab.isMuted)
        }
    }
}
