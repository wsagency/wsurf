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
}
