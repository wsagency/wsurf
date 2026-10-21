// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// AppKit keeps a window that has been ordered on screen in `NSApp.windows` until it is closed or ordered out; dropping the last
/// Swift reference does not free it. A closed window can still be held by an autorelease pool for a moment (see `MainEventLoop`),
/// which is not a leak: `live` asks for the waiting event call to return, so a window it counts after that is one something retains.
///
/// Counts only the windows handed to `track`, so suites running alongside cannot move the number.
@MainActor
final class WindowLeakCheck {
    private var tracked: [() -> NSWindow?] = []

    init() {
        MainEventLoop.install()
    }

    func track(_ window: NSWindow?) {
        guard let window else { return }
        tracked.append { [weak window] in window }
    }

    /// Tracked windows the app still holds. Zero is the baseline before any fixture ran. While any is left it makes the waiting event
    /// call return, so a later look (the next `waitUntil` tick) no longer counts a window only that call's pool held.
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

/// Why closed test windows stayed alive for the rest of a run (about 800 by the end of a full suite, 1,087 in 0.1.5, and pages
/// 0.4 s fresh, 12.5 s late). XCTest starts the run from a run loop callout (`_XCTestMain`) and waits out the whole Swift Testing
/// session in `+[XCTWaiter _synchronouslyWaitForTimeInterval:]`, which takes each event with `nextEventMatchingMask` and sends it
/// with `sendEvent` with no autorelease pool of its own (and is a direct method, so it cannot be swizzled). Taking or handling an
/// event that names a window (the window server sends them as a window orders in, moves, is covered or closes) looks the window
/// up, and AppKit autoreleases it into the pool around that callout, which ends only with the run. Found natively with a retain
/// and autorelease tracker and `_objc_autoreleasePoolPrint` (branch `diag/test-infra-leak-20261021`).
///
/// `install` gives every `nextEventMatchingMask` and `sendEvent` call its own pool, the way `NSApp.run` gives each event one: what
/// the call autoreleases (the window lookups, and the main-queue work that ran while it waited) is released when it returns, and
/// the event it returns is kept alive for its caller (an event does not retain its window; a freed one reads as nil). Test host
/// only. `drainSoon` posts an application-defined event (never a mouse or key event, so nothing reaches a window or a monitor),
/// which makes a waiting call return and its pool end.
@MainActor
enum MainEventLoop {
    private static let subtype: Int16 = 0x5753
    private static var posted = 0
    private static var installed = false

    /// Idempotent. `.boundedWebViews` and `WindowLeakCheck` install it before their first test.
    static func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(NSApplication.nextEvent(matching:until:inMode:dequeue:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        // Raw pointers throughout: the wrapper adds no retain or release of its own beyond keeping the returned event.
        typealias NextEvent = @convention(c) (
            UnsafeRawPointer, Selector, UInt64, UnsafeRawPointer?, UnsafeRawPointer?, ObjCBool
        ) -> UnsafeRawPointer?
        let original = unsafeBitCast(method_getImplementation(method), to: NextEvent.self)
        typealias Pooled = @convention(block) (UnsafeRawPointer, UInt64, UnsafeRawPointer?, UnsafeRawPointer?, ObjCBool) -> UnsafeRawPointer?
        let pooled: Pooled = { app, mask, until, mode, dequeue in
            var event: Unmanaged<AnyObject>?
            autoreleasepool {
                if let raw = original(app, selector, mask, until, mode, dequeue) {
                    event = Unmanaged<AnyObject>.fromOpaque(raw).retain()
                }
            }
            return event.map { UnsafeRawPointer($0.autorelease().toOpaque()) }
        }
        method_setImplementation(method, imp_implementationWithBlock(pooled))

        // XCTWaiter sends each event it took itself, outside any pool, and handling a window's event looks the window up again.
        let send = #selector(NSApplication.sendEvent(_:))
        if let sendMethod = class_getInstanceMethod(NSApplication.self, send) {
            typealias SendEvent = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer?) -> Void
            let originalSend = unsafeBitCast(method_getImplementation(sendMethod), to: SendEvent.self)
            let pooledSend: @convention(block) (UnsafeRawPointer, UnsafeRawPointer?) -> Void = { app, event in
                autoreleasepool {
                    originalSend(app, send, event)
                }
            }
            method_setImplementation(sendMethod, imp_implementationWithBlock(pooledSend))
        }
        // The call already waiting is the original one: let it return so the next one is pooled.
        drainSoon()
    }

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

    /// Returns once the loop has taken an event posted now, which ends the pool of the call that took it. Gives up after a second
    /// (a modal session in another mode holds the event back).
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
