// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// AppKit keeps a window that has been ordered on screen in `NSApp.windows` until it is closed or ordered out; dropping the last
/// Swift reference does not free it. A closed window can still be held by the main autorelease pool (see `MainEventLoop`), which
/// is not a leak: `live` asks for that pool to be drained, so a window it counts after the next drain is one something retains.
///
/// Counts only the windows handed to `track`, so suites running alongside cannot move the number.
@MainActor
final class WindowLeakCheck {
    private var tracked: [() -> NSWindow?] = []

    func track(_ window: NSWindow?) {
        guard let window else { return }
        tracked.append { [weak window] in window }
    }

    /// Tracked windows the app still holds. Zero is the baseline before any fixture ran. While any is left it asks the event loop
    /// to drain the main autorelease pool, so a later look (the next `waitUntil` tick) no longer counts a window only the pool held.
    var live: Int {
        let count = liveWindows.count
        if count > 0 {
            MainEventLoop.drainSoon()
        }
        return count
    }

    /// What a failure needs to find the holder: each live window's class, whether it is still on screen, and whether it still has
    /// a delegate and content.
    var liveDescription: String {
        liveWindows.map { window in
            "\(type(of: window)) (on screen \(window.isVisible), delegate \(window.delegate != nil), content \(window.contentView != nil))"
        }.joined(separator: ", ")
    }

    private var liveWindows: [NSWindow] {
        let windows = NSApp.windows
        return tracked.compactMap { $0() }.filter { window in windows.contains { $0 === window } }
    }
}

/// AppKit drains the main thread's autorelease pool once per event its loop takes from the queue. A test host in the background
/// takes none, so for a whole run nothing autoreleased on the main thread was freed: WebKit autoreleases the window of a web view
/// that loads a page, so every closed test window stayed alive (off screen, no content, no delegate; about 800 by the end of a
/// full suite) with its backing store, the alerts shown on it and any web view it still held, and page creation slowed from
/// 0.4 s to 12.5 s. A standalone AppKit probe reproduces it, and one application-defined event frees them.
///
/// `drainSoon` posts that event (never a mouse or key event, so nothing reaches a window or a monitor); the loop takes it as soon
/// as the main actor next waits. `.boundedWebViews` posts one when each test starts and ends, so a test's windows are gone by the
/// end of the next one.
@MainActor
enum MainEventLoop {
    private static let subtype: Int16 = 0x5753
    private static var posted = 0

    @discardableResult
    static func drainSoon() -> Int {
        posted += 1
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: subtype, data1: posted, data2: 0
        ) else { return posted }
        NSApp.postEvent(event, atStart: false)
        return posted
    }

    /// Returns once the loop has taken an event posted now, which ends the pool everything before it went into. Gives up after
    /// a second (a modal session in another mode holds the event back).
    static func drain() async {
        let tag = drainSoon()
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(10))
            if let event = NSApp.currentEvent, event.type == .applicationDefined, event.subtype.rawValue == subtype, event.data1 >= tag {
                return
            }
        }
    }
}

/// Names the tests that leave windows alive, for a native run: pass `TEST_RUNNER_WSURF_WINDOW_CENSUS=1` to xcodebuild with
/// `-parallel-testing-enabled NO` (in parallel a neighbour's windows are charged to whichever test ends first). Every
/// `.boundedWebViews` test then prints the windows it added that something still retains after it ends. Off, it costs nothing.
nonisolated enum WindowCensus {
    static let isEnabled = ProcessInfo.processInfo.environment["WSURF_WINDOW_CENSUS"] == "1"

    @MainActor
    static func snapshot() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.map(ObjectIdentifier.init))
    }

    @MainActor
    static func report(_ test: String, since before: Set<ObjectIdentifier>) async {
        // What only the autorelease pool holds is not a leak: drain it, give a closed window's deferred work time to run (it
        // autoreleases the window again), and drain once more.
        await MainEventLoop.drain()
        try? await Task.sleep(for: .milliseconds(200))
        await MainEventLoop.drain()
        let windows = NSApp.windows
        let left = windows.filter { !before.contains(ObjectIdentifier($0)) }
        guard !left.isEmpty else { return }
        let names = left.map { "\(type(of: $0))\($0.isVisible ? " (on screen)" : "")" }
        print("window census: \(test) left \(left.count) of \(windows.count): \(names.joined(separator: ", "))")
    }
}
