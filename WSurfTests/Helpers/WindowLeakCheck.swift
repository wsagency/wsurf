// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// AppKit keeps a window that has been ordered on screen in `NSApp.windows` until it is closed or ordered out; dropping the last
/// Swift reference does not free it. Each one a test forgot kept its web views and content processes for the rest of the run:
/// about 970 by the end of a full suite, and page creation slowed from 0.4 s to 12.5 s.
///
/// Counts only the windows handed to `track`, so suites running alongside cannot move the number.
@MainActor
final class WindowLeakCheck {
    private var tracked: [() -> NSWindow?] = []

    func track(_ window: NSWindow?) {
        guard let window else { return }
        tracked.append { [weak window] in window }
    }

    /// Tracked windows the app still holds. Zero is the baseline before any fixture ran.
    var live: Int {
        liveWindows.count
    }

    /// What a failure needs to find the holder: each live window's class, whether it is still on screen, and whether it
    /// still has a delegate and content.
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

/// Names the tests that leave windows alive, for a native run: pass `TEST_RUNNER_WSURF_WINDOW_CENSUS=1` to xcodebuild with
/// `-parallel-testing-enabled NO` (in parallel a neighbour's windows are charged to whichever test ends first). Every
/// `.boundedWebViews` test then prints the windows it added that are still alive shortly after it ends. Off, it costs nothing.
nonisolated enum WindowCensus {
    static let isEnabled = ProcessInfo.processInfo.environment["WSURF_WINDOW_CENSUS"] == "1"

    @MainActor
    static func snapshot() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.map(ObjectIdentifier.init))
    }

    @MainActor
    static func report(_ test: String, since before: Set<ObjectIdentifier>) async {
        try? await Task.sleep(for: .milliseconds(200))
        let windows = NSApp.windows
        let left = windows.filter { !before.contains(ObjectIdentifier($0)) }
        guard !left.isEmpty else { return }
        let names = left.map { "\(type(of: $0))\($0.isVisible ? " (on screen)" : "")" }
        print("window census: \(test) left \(left.count) of \(windows.count): \(names.joined(separator: ", "))")
    }
}
