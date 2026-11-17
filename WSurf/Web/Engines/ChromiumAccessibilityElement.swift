// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

// D4-41 (out-of-process Chromium, phase 5): one node of the mirror, as VoiceOver sees it. `NSAccessibilityElement` is not main-actor
// isolated, so neither is this class (its initializers and overrides must match). The mirror answers under its own lock, from any
// thread; what needs the view (its frame on screen, a press) goes through the host, which AppKit's main-thread queries reach through
// `MainActor.assumeIsolated`. Elements hang off `ChromiumRemoteContentView` (plan C1a), never `ChromiumPage`.

nonisolated final class ChromiumAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    private weak var mirror: ChromiumAccessibilityMirror?
    private weak var host: ChromiumRemoteAccessibilityHost?
    let key: ChromiumAccessibilityKey

    init(mirror: ChromiumAccessibilityMirror, key: ChromiumAccessibilityKey, host: ChromiumRemoteAccessibilityHost?) {
        self.mirror = mirror
        self.key = key
        self.host = host
        super.init()
    }

    private var facts: ChromiumAccessibilityMirror.Description? {
        mirror?.describe(key)
    }

    /// Every query is a sign that something reads this page: it keeps the tree on (`ChromiumRemote.noteAccessibilityQuery`).
    private func noteQuery() {
        let host = host
        MainActor.assumeIsolated { host?.noteQuery() }
    }

    override func isAccessibilityElement() -> Bool {
        mirror?.exists(key) ?? false
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        noteQuery()
        return facts?.role
    }

    override func accessibilityRoleDescription() -> String? {
        facts?.roleDescription ?? super.accessibilityRoleDescription()
    }

    override func accessibilityTitle() -> String? {
        facts?.title
    }

    override func accessibilityLabel() -> String? {
        facts?.label
    }

    override func accessibilityValue() -> Any? {
        switch facts?.value {
        case let .string(string):
            string
        case let .number(number):
            number
        case nil:
            nil
        }
    }

    override func accessibilityURL() -> URL? {
        facts?.url
    }

    override func accessibilityChildren() -> [Any]? {
        noteQuery()
        let children: [ChromiumAccessibilityElement] = mirror?.childElements(of: key, host: host) ?? []
        return children
    }

    override func accessibilityParent() -> Any? {
        let (mirror, key, host) = (mirror, key, host)
        if let parent = mirror?.parentElement(of: key, host: host) {
            return parent
        }
        // The root, or a node that lost its place: what the view that hosts the mirror stands under (the view itself is ignored).
        nonisolated(unsafe) var parent: Any?
        MainActor.assumeIsolated { parent = host?.parentOfRoot() }
        return parent
    }

    override func accessibilityFrame() -> NSRect {
        let (mirror, key, host) = (mirror, key, host)
        return MainActor.assumeIsolated {
            guard let mirror, let host else { return .zero }
            return host.screenFrame(of: mirror.rectInPoints(key, unitsPerPoint: host.unitsPerPoint))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let (mirror, key, host) = (mirror, key, host)
        return MainActor.assumeIsolated {
            guard let mirror, let host else { return false }
            return host.press(mirror.rectInPoints(key, unitsPerPoint: host.unitsPerPoint))
        }
    }
}
