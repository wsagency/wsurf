// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Choosing a theme changes the setting in memory at once and writes it to the defaults on the next turn of the main
/// run loop. A defaults write is a synchronous round trip to the preferences daemon, about 40% of the time of a
/// switch, and a click must not wait for it. Writes of the same key in one turn replace each other: the last value wins.
///
/// What a crash can lose: the choice of the turn it happens in, never an earlier one. A pending write is persisted when
/// the app resigns active or terminates, when its settings object goes away, and before any other settings object reads
/// the defaults, so no object reads a theme older than the last one chosen. Only the theme selection waits; every other
/// setting is written as before.
extension BrowserSettings {
    private struct WeakSettings {
        weak var settings: BrowserSettings?
    }

    private static var withPendingWrites: [WeakSettings] = []

    /// After these, the pending writes are persisted.
    static let flushingNotifications = [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification]

    /// Persists the pending writes when one of `flushingNotifications` is posted to `center`. The app posts them on the
    /// main thread and the observer runs there before the post returns, so the write is done before the app quits.
    static func flushWhenPosted(to center: NotificationCenter) -> [NSObjectProtocol] {
        flushingNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { BrowserSettings.flushAllPendingWrites() }
            }
        }
    }

    static let flushObservers = flushWhenPosted(to: .default)

    /// Persists the pending writes of every settings object.
    static func flushAllPendingWrites() {
        let pending = withPendingWrites.compactMap(\.settings)
        withPendingWrites = []
        for settings in pending {
            settings.flushPendingWrites()
        }
    }

    /// Keeps `value` for `key` and schedules the write. A later value for the same key replaces it.
    func writeSoon(_ value: Any, forKey key: String) {
        pendingWrites[key] = value
        if !Self.withPendingWrites.contains(where: { $0.settings === self }) {
            Self.withPendingWrites.append(WeakSettings(settings: self))
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let self else { return }
            flushPendingWrites()
        }
    }

    func flushPendingWrites() {
        flushTask = nil
        let writes = pendingWrites
        pendingWrites = [:]
        for (key, value) in writes {
            write(value, forKey: key)
        }
    }
}
