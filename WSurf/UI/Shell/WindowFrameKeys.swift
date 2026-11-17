// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The preference key AppKit keeps a window's saved frame under: one per window, named by `BrowserHost` after the window's
/// ID. A closed window's session rows stay so that Reopen Last Closed Window and the launch can bring it back, and its frame
/// stays with them. A key is dropped when its window ends for good (a micro window with no page left), and a launch drops the
/// keys of windows that no session row names, so the standard preferences do not grow with every window ever opened.
nonisolated enum WindowFrameKeys {
    static let autosaveNamePrefix = "wsurf.browser.window."
    private static let keyPrefix = "NSWindow Frame " + autosaveNamePrefix

    /// At most this many keys go in one launch; the rest wait for the next. A write into a large domain is not free.
    static let launchLimit = 200

    static func autosaveName(for windowID: UUID) -> String {
        autosaveNamePrefix + windowID.uuidString
    }

    static func key(for windowID: UUID) -> String {
        "NSWindow Frame " + autosaveName(for: windowID)
    }

    /// The windows whose saved frame is in `defaults` but that are not in `keeping`, at most `limit` of them.
    static func staleWindowIDs(in defaults: UserDefaults, keeping: Set<UUID>, limit: Int = launchLimit) -> [UUID] {
        guard limit > 0 else { return [] }
        var stale: [UUID] = []
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(keyPrefix) {
            guard let id = UUID(uuidString: String(name.dropFirst(keyPrefix.count))), !keeping.contains(id) else { continue }
            stale.append(id)
            if stale.count == limit {
                break
            }
        }
        return stale
    }

    static func remove(_ windowIDs: [UUID], from defaults: UserDefaults) {
        for id in windowIDs {
            defaults.removeObject(forKey: key(for: id))
        }
    }
}

/// `UserDefaults` may be read and written from any thread; the SDK does not say so in a way the compiler accepts here.
nonisolated struct ThreadSafeDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}
