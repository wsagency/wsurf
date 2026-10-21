// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Fixtures hand back every window they put on screen, so the test host's window list returns to where it started.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct WindowLeakCheckTests {
    /// The check has to see a window that is still open, or its zero would mean nothing.
    @Test func anOpenWindowCountsUntilItIsClosedAndReleased() async {
        let check = WindowLeakCheck()
        do {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            check.track(window)
            window.orderBack(nil)
            #expect(check.live == 1)
            window.close()
        }

        #expect(await waitUntil(timeout: .seconds(10)) { check.live == 0 })
    }

    /// A browser tab served by `HTTPFixtureServer` in an on-screen window, and a shown browser window: the two shapes most
    /// tests build on. Each is checked on its own, so a failure names the fixture that kept its window.
    @Test func representativeFixturesLeaveNoWindowBehind() async throws {
        let harnessWindows = WindowLeakCheck()
        let browserWindows = WindowLeakCheck()
        do {
            let fixture = try await ComputerWorkflowFixture()
            harnessWindows.track(fixture.window)

            let app = BrowserApplication()
            let coordinator = AppCoordinator(
                browser: BrowserModel(context: BrowserProfileContext.shared(for: .original()), windowID: UUID())
            )
            app.register(coordinator)
            coordinator.showBrowser(activate: false)
            browserWindows.track(coordinator.nativeWindow)
            #expect(harnessWindows.live == 1)
            #expect(browserWindows.live == 1)

            fixture.close()
            coordinator.closeWindow()
        }

        #expect(
            await waitUntil(timeout: .seconds(10)) { harnessWindows.live == 0 },
            "the tab harness window outlived its test: \(harnessWindows.liveDescription)"
        )
        #expect(
            await waitUntil(timeout: .seconds(10)) { browserWindows.live == 0 },
            "the closed browser window outlived its test: \(browserWindows.liveDescription)"
        )
    }
}
