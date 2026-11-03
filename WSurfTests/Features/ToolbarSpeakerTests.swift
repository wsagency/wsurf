// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The speaker when the Standard window's sidebar is not on screen: the toolbar carries it, by the same rule as the sidebar's, and
/// never both at once. What it lists and mutes is `AudioIndicatorTests`.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ToolbarSpeakerTests {
    // MARK: - The rule

    @Test func theSpeakerIsInTheSidebarWhileItIsOnScreenAndInTheToolbarWhileItIsNot() {
        #expect(AudioIndicator.place(audibleCount: 1, isMuted: false, isSidebarShowing: true) == .sidebar)
        #expect(AudioIndicator.place(audibleCount: 1, isMuted: false, isSidebarShowing: false) == .toolbar)
        #expect(AudioIndicator.place(audibleCount: 3, isMuted: true, isSidebarShowing: true) == .sidebar)
        #expect(AudioIndicator.place(audibleCount: 3, isMuted: true, isSidebarShowing: false) == .toolbar)
    }

    @Test func itShowsOnlyWhileATabPlaysOrWSurfIsMuted() {
        for showing in [true, false] {
            #expect(AudioIndicator.place(audibleCount: 0, isMuted: false, isSidebarShowing: showing) == nil, "nothing plays, not muted")
            #expect(AudioIndicator.place(audibleCount: 0, isMuted: true, isSidebarShowing: showing) != nil, "muted with nothing playing: still there, to unmute")
            #expect(AudioIndicator.place(audibleCount: 2, isMuted: false, isSidebarShowing: showing) != nil)
        }
    }

    @Test func thereIsNeverOneInEachPlace() {
        for count in [0, 1, 4] {
            for muted in [false, true] {
                for showing in [false, true] {
                    let place = AudioIndicator.place(audibleCount: count, isMuted: muted, isSidebarShowing: showing)
                    let shown = AudioIndicator.isVisible(audibleCount: count, isMuted: muted)
                    #expect((place == nil) == !shown, "one place exactly when it shows")
                    #expect(!(place == .sidebar && !showing) && !(place == .toolbar && showing), "and never the place that is not on screen")
                }
            }
        }
    }

    // MARK: - The view

    private func withWindow(_ body: @MainActor (BrowserApplication, AppCoordinator) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Toolbar speaker")
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let main = app.newWindow(profile: profile, show: false)
        // The sidebar keeps its visibility in the defaults: put it back as it was found.
        let wasVisible = main.sidebar.isVisible
        var failure: (any Error)?
        do {
            try await body(app, main)
        } catch {
            failure = error
        }
        main.sidebar.isPeeking = false
        main.sidebar.setVisible(wasVisible)
        for coordinator in app.windows {
            coordinator.closeWindow()
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    private func isDrawn(_ host: NSHostingView<some View>) -> Bool {
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width > 0 && host.fittingSize.height > 0
    }

    /// The real view the toolbar holds: drawn while the sidebar is hidden and a tab plays or WSurf is muted, and not while the
    /// sidebar is docked or peeking over the page, which carries the speaker then.
    @Test func theToolbarsSpeakerFollowsTheSidebarAndWhatPlays() async throws {
        try await withWindow { app, main in
            main.sidebar.setVisible(false)
            let tab = main.browser.addPage("https://song.example/")
            let host = NSHostingView(rootView: ToolbarAudioIndicator(coordinator: main))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }

            #expect(!isDrawn(host), "the sidebar is hidden, but nothing plays")

            tab.isPlayingAudio = true
            #expect(await waitUntil { isDrawn(host) }, "a tab plays")

            main.sidebar.isPeeking = true
            #expect(await waitUntil { !isDrawn(host) }, "the sidebar peeks over the page, and carries the speaker")
            main.sidebar.isPeeking = false
            #expect(await waitUntil { isDrawn(host) }, "it went again")

            main.sidebar.setVisible(true)
            #expect(await waitUntil { !isDrawn(host) }, "the sidebar is docked: the speaker is its own")
            main.sidebar.setVisible(false)
            #expect(await waitUntil { isDrawn(host) })

            tab.isPlayingAudio = false
            #expect(await waitUntil { !isDrawn(host) }, "it stopped")

            app.muteAll()
            #expect(await waitUntil { isDrawn(host) }, "muted with nothing playing: still there, to unmute")
            app.unmuteAll()
            #expect(await waitUntil { !isDrawn(host) })
        }
    }

    @Test func theToolbarsSpeakerSaysTheSameThingsAsTheSidebarsAndMutesAllOfWSurf() async throws {
        try await withWindow { app, main in
            main.sidebar.setVisible(false)
            let tab = main.browser.addPage("https://song.example/")
            tab.isPlayingAudio = true
            #expect(ToolbarAudioIndicator.isShown(in: main))
            #expect(main.audibleTabs.map(\.id) == [tab.id], "the list it opens is the sidebar's")

            main.toggleWSurfMute()
            #expect(app.isMuted && tab.isMuted, "pressing it mutes every tab of every window")
            #expect(ToolbarAudioIndicator.isShown(in: main))
            main.toggleWSurfMute()
            #expect(!app.isMuted && !tab.isMuted)
        }
    }
}
