// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// What a tab switch in a real window does besides showing the page (perf audit 0.1.22, item 3). The root view used to read the
/// window title, so every switch re-ran it, which rebuilt the window view and, with it, a settings workspace that reads the
/// Keychain; and the title was handed to AppKit twice, which redoes the title bar each time.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct TabSwitchWorkTests {
    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/first": .html("<!doctype html><title>First</title><p>One</p>"),
        "/second": .html("<!doctype html><title>Second</title><p>Two</p>"),
        "/third": .html("<!doctype html><title>Third</title><p>Three</p>"),
    ]

    private func draw(_ window: NSWindow) {
        RunLoop.current.run(until: Date())
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    @Test func aSwitchMakesNoSettingsWorkspaceAndSetsTheTitleOnce() async throws {
        try await LiveWindowRig.with(engine: .webKit, routes: Self.routes) { rig in
            let tabs = [
                try await rig.open("/first"),
                try await rig.open("/second"),
                try await rig.open("/third"),
            ]
            draw(rig.window)
            try #require(await waitUntil { tabs.allSatisfy { !$0.title.isEmpty } })
            draw(rig.window)

            var titlesSet = 0
            let watch = rig.window.observe(\.title) { _, _ in
                MainActor.assumeIsolated { titlesSet += 1 }
            }
            defer { watch.invalidate() }
            let made = SettingsWorkspace.madeCount
            var switches = 0
            for _ in 0..<3 {
                for tab in tabs {
                    rig.browser.activate(tab)
                    draw(rig.window)
                    draw(rig.window)
                    switches += 1
                    #expect(rig.window.title == rig.coordinator.windowTitle)
                    #expect(rig.window.title.hasPrefix(tab.title))
                }
            }

            #expect(SettingsWorkspace.madeCount == made, "a switch made a settings workspace")
            #expect(titlesSet == switches, "\(titlesSet) titles set for \(switches) switches")
        }
    }

    @Test func theWindowTitleFollowsTheFrontPagesTitle() async throws {
        try await LiveWindowRig.with(engine: .webKit, routes: Self.routes) { rig in
            let tab = try await rig.open("/first")
            draw(rig.window)
            try #require(await waitUntil { rig.window.title.hasPrefix("First") })

            _ = try await tab.page.evaluateJavaScript("document.title = 'Renamed'; true")

            #expect(await waitUntil {
                draw(rig.window)
                return rig.window.title.hasPrefix("Renamed") && rig.window.title == rig.coordinator.windowTitle
            })
        }
    }
}
