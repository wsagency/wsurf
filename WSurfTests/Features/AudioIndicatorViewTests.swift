// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The speaker as the person meets it: the view that shows and hides, the View menu's item and its shortcut, and pictures of
/// both for looking at. What it lists and mutes is `AudioIndicatorTests`.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AudioIndicatorViewTests {
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

    /// The real view: nothing drawn while nothing plays, the button once a tab does, and still the button, now crossed, when
    /// WSurf is muted and the tab has stopped.
    @Test(arguments: [AudioIndicatorButton.Style.sidebar, .bar])
    func theViewDrawsNothingUntilThereIsSomethingToShow(style: AudioIndicatorButton.Style) async throws {
        try await withProfile("Audio view") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = main.browser.addPage("https://song.example/")
            let host = NSHostingView(rootView: AudioIndicatorButton(coordinator: main, style: style))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }

            func isDrawn() -> Bool {
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.width > 0 && host.fittingSize.height > 0
            }
            #expect(!isDrawn(), "nothing plays and WSurf is not muted")

            tab.isPlayingAudio = true
            #expect(await waitUntil { isDrawn() }, "a tab plays")

            tab.isPlayingAudio = false
            #expect(await waitUntil { !isDrawn() }, "it stopped")

            app.muteAll()
            #expect(await waitUntil { isDrawn() }, "muted, it stays so that it can be unmuted")

            app.unmuteAll()
            #expect(await waitUntil { !isDrawn() }, "unmuted and quiet, it goes")
            finish(app)
        }
    }

    // MARK: - The menu

    @Test func theViewMenuHasMuteWSurfOnAShortcutNothingElseUses() async throws {
        let savedMainMenu = NSApp.mainMenu
        let savedWindowsMenu = NSApp.windowsMenu
        let savedHelpMenu = NSApp.helpMenu
        NSApp.mainMenu = nil
        NSApp.windowsMenu = nil
        defer {
            NSApp.mainMenu = savedMainMenu
            NSApp.windowsMenu = savedWindowsMenu
            NSApp.helpMenu = savedHelpMenu
        }
        try await withProfile("Audio menu") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let tab = playing("https://song.example/", in: main)
            let menu = MainMenu(application: app)
            menu.install()
            let root = try #require(NSApp.mainMenu)
            let view = try #require(root.items.first { $0.submenu?.title == String(localized: "View") }?.submenu)
            let item = try #require(view.items.first { $0.title == String(localized: "Mute WSurf") })

            #expect(item.keyEquivalent == "m")
            #expect(item.keyEquivalentModifierMask == [.command, .control])
            let everyItem = root.items.compactMap(\.submenu).flatMap(\.items)
            let sameKey = everyItem.filter {
                $0.keyEquivalent.lowercased() == "m" && $0.keyEquivalentModifierMask == [.command, .control]
            }
            #expect(sameKey.count == 1, "⌃⌘M is the only item on it")
            #expect(menu.validateMenuItem(item))

            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            #expect(app.isMuted && tab.isMuted)
            #expect(menu.validateMenuItem(item))
            #expect(item.title == String(localized: "Unmute WSurf"), "the item says what it will do")
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            #expect(!app.isMuted && !tab.isMuted)
            #expect(menu.validateMenuItem(item))
            #expect(item.title == String(localized: "Mute WSurf"))
            finish(app)
        }
    }

    // MARK: - For looking at

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            return true
        }
    }

    /// Writes pictures of the speaker and of its list to the folder in `WSURF_AUDIO_EVIDENCE`, for looking at: real views in a
    /// test host, not the running app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WSURF_AUDIO_EVIDENCE"] != nil))
    func theSpeakerAndItsListAreDrawnForReview() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WSURF_AUDIO_EVIDENCE"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await withProfile("Audio evidence") { profile in
            let app = run()
            let main = app.newWindow(profile: profile, show: false)
            let other = app.newWindow(profile: profile, show: false)
            let rig = SidebarRowRig(space: "AudioIndicatorTests")
            defer { rig.restore() }
            @MainActor func write(_ view: some View, _ name: String) throws {
                let picture = try rig.picture(of: view)
                guard let data = picture.bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: directory.appendingPathComponent("\(name).png"))
            }
            let song = playing("https://music.example/album", in: main)
            song.title = "Kind of Blue \u{2014} Miles Davis"
            song.favicon = swatch(.systemOrange)
            let talk = playing("https://meet.example/planning", in: other, muted: true)
            talk.title = "Quarterly planning call"
            talk.favicon = swatch(.systemBlue)
            let long = playing("https://video.example/watch", in: other)
            long.title = "A very long title of a video that goes on and on until the list has to cut it short"
            long.favicon = swatch(.systemGreen)

            @MainActor func strip(style: AudioIndicatorButton.Style = .sidebar) -> some View {
                HStack(spacing: 6) {
                    SidebarProfileControl(coordinator: main)
                        .padding(.leading, SidebarMetrics.profileLeading)
                    AudioIndicatorButton(coordinator: main, style: style)
                    Spacer(minLength: 0)
                    SidebarDownloadsButton(coordinator: main)
                    SidebarSettingsRow(coordinator: main)
                }
            }
            @MainActor func list(light: Bool) -> some View {
                AudioTabsList(coordinator: main) {}
                    .environment(\.windowColorScheme, light ? .light : .dark)
                    .background(light ? Color.white : Color(white: 0.16))
            }
            try write(rig.sidebar(strip(), height: 40), "speaker-playing")
            try write(rig.sidebar(strip(style: .bar), height: 40), "speaker-playing-bar")
            try write(list(light: false), "list-dark")
            try write(list(light: true), "list-light")

            app.muteAll()
            try write(rig.sidebar(strip(), height: 40), "speaker-muted")
            try write(list(light: false), "list-muted-dark")

            for tab in [song, talk, long] {
                tab.isPlayingAudio = false
            }
            try write(rig.sidebar(strip(), height: 40), "speaker-muted-nothing-playing")
            try write(list(light: false), "list-muted-nothing-playing")
            finish(app)
        }
    }
}
