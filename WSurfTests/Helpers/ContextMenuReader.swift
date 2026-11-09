// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

/// Reads and chooses from a context menu that has begun to track.
///
/// Chromium tracks its menu in a nested run loop inside a main-queue callout: the main queue is not drained there, so a `Task`
/// on the main actor waits until the menu closes, but common-mode timers still fire. So the menu is read and cancelled from a
/// timer, and the chosen item is performed once tracking has ended, in a task that runs when the main queue drains again.
/// A watchdog cancels a menu the reader never reaches, and reports it, so that case cannot pass unseen.
enum ContextMenuReader {
    /// What a reader did, touched only on the main thread.
    private nonisolated final class Outcome: @unchecked Sendable {
        var index: Int?
        var ended: NSObjectProtocol?
    }

    /// - Parameters:
    ///   - read: called from the timer with the titles ("—" for a separator), the identifiers and whether `choose` accepted an item.
    ///   - finished: called after tracking ended and the chosen item was performed; its flag says the watchdog ended the menu.
    @MainActor
    static func start(
        _ menu: NSMenu, after delay: TimeInterval, choosing choose: @escaping @MainActor (String) -> Bool,
        read: @escaping @MainActor ([String], [String], Bool) -> Void, finished: @escaping @MainActor (Bool) -> Void
    ) {
        let outcome = Outcome()
        // The timer and the observer callbacks run on the main run loop, the only place these two are touched.
        nonisolated(unsafe) let menu = menu
        let watchdog = WatchdogFlag()
        outcome.ended = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil) { _ in
            if let token = outcome.ended {
                NotificationCenter.default.removeObserver(token)
            }
            Task { @MainActor in
                if let index = outcome.index {
                    menu.performActionForItem(at: index)
                }
                finished(watchdog.fired)
            }
        }
        // Whatever the test does, the menu does not stay: a menu that stays holds the whole test run.
        nonisolated(unsafe) let guardTimer = Timer(timeInterval: 8, repeats: false) { _ in
            MainActor.assumeIsolated {
                watchdog.fired = true
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(guardTimer, forMode: .common)
        let reader = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                let identifiers = menu.items.map { $0.identifier?.rawValue ?? "-" }
                outcome.index = menu.items.firstIndex { !$0.isSeparatorItem && choose($0.title) }
                read(titles, identifiers, outcome.index != nil)
                guardTimer.invalidate()
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(reader, forMode: .common)
    }

    private nonisolated final class WatchdogFlag: @unchecked Sendable {
        var fired = false
    }
}
