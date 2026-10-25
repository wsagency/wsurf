// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// A tab that is playing sound, and the window it is in.
struct AudibleTab: Identifiable {
    let tab: BrowserTab
    let window: AppCoordinator
    /// It is in the window the list was asked for, not in another window of the profile.
    let isHere: Bool

    var id: UUID {
        tab.id
    }
}

/// What the speaker in the sidebar, the Minimal bar and the micro bar knows, built on the audio state a tab already keeps:
/// `BrowserTab.isPlayingAudio` from the page's own report, and `BrowserTab.isMuted` with the page's mute. Nothing here tracks
/// sound a second time; it lists, and it sets the mute of every tab at once.
enum AudioIndicator {
    /// The speaker shows while something plays, and while WSurf is muted so that it can be unmuted.
    static func isVisible(audibleCount: Int, isMuted: Bool) -> Bool {
        audibleCount > 0 || isMuted
    }

    static func symbol(isMuted: Bool) -> String {
        isMuted ? "speaker.slash" : "speaker.wave.2"
    }

    /// What VoiceOver says: that WSurf is muted, else how many tabs play.
    static func label(audibleCount: Int, isMuted: Bool) -> String {
        if isMuted {
            return String(localized: "WSurf muted")
        }
        return audibleCount == 1
            ? String(localized: "1 tab playing audio")
            : String(localized: "\(audibleCount) tabs playing audio")
    }

    static func help(isMuted: Bool) -> String {
        isMuted ? String(localized: "Unmute WSurf") : String(localized: "Mute WSurf")
    }
}

extension BrowserApplication {
    // MARK: - Which tabs play

    /// The tabs playing sound in `coordinator`'s window and in the other windows of its profile, a micro window among them:
    /// the window's own first. Windows share a context when they share a profile; a private window has a context of its own,
    /// so its list is its private session and nobody else's list names a private tab. A row that stands for a page in a micro
    /// window is not a tab and plays nothing; the page is listed once, from the micro window.
    func audibleTabs(for coordinator: AppCoordinator) -> [AudibleTab] {
        let others = windows.filter { $0 !== coordinator && !$0.isClosed && $0.context === coordinator.context }
        return ([coordinator] + others).flatMap { window in
            window.browser.tabs
                .filter { $0.isPlayingAudio && $0.microTabID == nil && !$0.isClosed }
                .map { AudibleTab(tab: $0, window: window, isHere: window === coordinator) }
        }
    }

    /// Brings a playing tab forward: its window, the space it is in, the tab, and its row into view in the sidebar
    /// (`revealInSidebar`: it opens the folders around it, scrolls and pulses once). A micro window holds one page, so
    /// bringing the window forward is all there is to do. `activating: false` leaves the app where it is, for tests.
    func show(_ audible: AudibleTab, activating: Bool = true) {
        let (tab, window) = (audible.tab, audible.window)
        guard !window.isClosed, window.browser.tabsByID[tab.id] === tab else { return }
        window.showBrowser(activate: activating)
        guard !window.isMicro else { return }
        window.browser.activate(tab)
        window.browser.revealInSidebar(tab)
    }

    // MARK: - Mute WSurf

    func toggleMute() {
        if isMuted {
            unmuteAll()
        } else {
            muteAll()
        }
    }

    /// Silences every tab of every window, private and micro windows too, in both engines. Every page is told, so a player
    /// it starts later is silent from its first sound. A tab playing now also takes the muted state its row, its menu and
    /// the media panel show, and what its own mute was is kept: a tab muted before stays muted when WSurf is unmuted.
    func muteAll() {
        guard !isMuted else { return }
        isMuted = true
        mutedBefore = [:]
        for (window, tab) in everyTab {
            if tab.isPlayingAudio, !tab.isMuted {
                mutedBefore[tab.id] = false
                window.setMuted(true, tab: tab)
                continue
            }
            if tab.isMuted {
                mutedBefore[tab.id] = true
            }
            if tab.isMaterialised {
                MediaCenter.setMuted(true, on: tab.page)
            }
        }
    }

    /// Gives every tab its own mute back. A tab the person unmuted on its own meanwhile stays unmuted, and one that began
    /// to play while WSurf was muted had none to give back.
    func unmuteAll() {
        guard isMuted else { return }
        isMuted = false
        for (window, tab) in everyTab {
            window.setMuted(tab.isMuted && mutedBefore[tab.id] == true, tab: tab)
        }
        mutedBefore = [:]
    }

    /// A tab that begins to play while WSurf is muted is silenced and marked like the others. One the person already
    /// unmuted on its own (it has an entry in `mutedBefore`) is left as they chose.
    func silenceIfMuted(_ tab: BrowserTab, in window: AppCoordinator) {
        guard isMuted, !tab.isMuted, mutedBefore[tab.id] == nil else { return }
        mutedBefore[tab.id] = false
        window.setMuted(true, tab: tab)
    }

    /// A page starts every document unmuted, so its tab asks again: for its own mute, and for WSurf's.
    func carryMute(into tab: BrowserTab) {
        guard tab.isMuted || (isMuted && mutedBefore[tab.id] == nil), tab.isMaterialised else { return }
        MediaCenter.setMuted(true, on: tab.page)
    }

    /// Every page there is to silence, with the window that holds it: the tabs, not the rows that stand for a page of a
    /// micro window, and the link preview a window may have open.
    private var everyTab: [(window: AppCoordinator, tab: BrowserTab)] {
        windows.filter { !$0.isClosed }.flatMap { window in
            (window.browser.tabs.filter { $0.microTabID == nil } + [window.peek.tab].compactMap { $0 })
                .map { (window, $0) }
        }
    }
}

extension AppCoordinator {
    /// Where this window's mute and list of playing tabs come from: the application its windows belong to. A window not
    /// registered with one (a test's) stands with the shared application.
    var audioScope: BrowserApplication {
        application ?? .shared
    }

    var audibleTabs: [AudibleTab] {
        audioScope.audibleTabs(for: self)
    }

    var isWSurfMuted: Bool {
        audioScope.isMuted
    }

    func toggleWSurfMute() {
        audioScope.toggleMute()
    }

    /// Something a peeking sidebar or tab list opened, which it waits for before it closes: the profile switcher, the list of
    /// what plays.
    var holdsPeek: Bool {
        isProfileSwitcherOpen || isAudioListOpen
    }
}
