// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// A sliding-window limit on how often something a page can trigger (a link to `mailto:`, in a loop) may reach WSurf: at most
/// `maxEvents` in any `window` seconds. Pure: the caller passes the time, so a test needs no clock. D4-8 uses it for the one-way
/// `nav.external` event (``CefRemote/Event/externalScheme``).
public struct CefRemoteRateLimit: Sendable {
    public let maxEvents: Int
    public let window: TimeInterval
    private var stamps: [TimeInterval] = []

    public init(maxEvents: Int, window: TimeInterval) {
        self.maxEvents = max(0, maxEvents)
        self.window = window
    }

    /// Whether an event at `now` may go. A refused one is not counted, so a page that keeps trying is let through again as soon
    /// as the oldest allowed event leaves the window.
    public mutating func allow(at now: TimeInterval) -> Bool {
        stamps.removeAll { now - $0 >= window || $0 > now }
        guard stamps.count < maxEvents else { return false }
        stamps.append(now)
        return true
    }
}
