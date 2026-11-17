// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

// D4-40 (out-of-process Chromium, phase 5): the vocabulary of the accessibility transport, and the rule for when the tree is on.
//
// CEF's accessibility tree costs work in the renderer, the service and WSurf, so it is built only while something wants it. The
// updates (several MB of JSON on a page's first one) travel on a connection of their own, `axHello`, which WSurf decodes on a
// queue of its own: decoding them on the control connection would run on WSurf's main thread (`plans/d4-phase345-plan.md` §6).

extension CefRemote.Op {
    /// The fourth connection's first message: the accessibility updates of every browser go to its sender. Accepted under the same
    /// rules as the input and frames connections (after a hello that got `ok`, from the host's process, not the control connection).
    public static let axHello = "axHello"
    /// Turns CEF's tree-only accessibility mode on or off for one browser (`flag`). Has a reply. Refused while no accessibility
    /// connection is attached, because the first update (the whole tree) would be lost, and every later one is incremental.
    public static let accessibility = "ax.enable"
}

extension CefRemote.Event {
    /// CEF's `on_accessibility_tree_change`, on the accessibility connection. Keys: `bid`, and `data`: the JSON of CEF's update
    /// (`{"ax_tree_id": ..., "updates": [{"root_id", "nodes", ...}]}`).
    public static let accessibilityTree = "ax.tree"
    /// CEF's `on_accessibility_location_change`, on the accessibility connection. Keys: `bid`, and `data`: a JSON array of changes
    /// (`{"ax_tree_id", "id", "new_location"}`).
    public static let accessibilityLocation = "ax.location"
}

/// When the accessibility tree is on (plan Q12). It is on while VoiceOver runs, or after an accessibility query by any client, and
/// it goes off again `graceSeconds` after the last query once VoiceOver is off. Pure: the caller passes the time.
public struct CefRemoteAccessibilityPolicy: Sendable {
    public static let defaultGraceSeconds: TimeInterval = 60

    public let graceSeconds: TimeInterval
    public private(set) var voiceOverIsOn = false
    private var lastQuery: TimeInterval?

    public init(graceSeconds: TimeInterval = defaultGraceSeconds) {
        self.graceSeconds = graceSeconds
    }

    public mutating func setVoiceOver(_ isOn: Bool) {
        voiceOverIsOn = isOn
    }

    /// An accessibility query (by VoiceOver, or by any other client) reached the page's view at `now`.
    public mutating func noteQuery(at now: TimeInterval) {
        lastQuery = now
    }

    public func wantsTree(at now: TimeInterval) -> Bool {
        voiceOverIsOn || secondsUntilQueryGraceEnds(at: now) != nil
    }

    /// How long until the last query's grace is over, or nil when there was none or it is over already. The caller looks again then.
    public func secondsUntilQueryGraceEnds(at now: TimeInterval) -> TimeInterval? {
        guard let lastQuery else { return nil }
        let left = graceSeconds - (now - lastQuery)
        return left > 0 ? left : nil
    }
}
