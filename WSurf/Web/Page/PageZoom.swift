// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

@MainActor
final class PageZoomStore {
    private(set) var levels: [String: Double] = [:]
    private let writes: QueuedJSONFile
    private let persists: Bool

    init(file: URL, persists: Bool = true) {
        writes = QueuedJSONFile(file)
        self.persists = persists
        try? loadIfNeeded()
    }

    private func loadIfNeeded() throws {
        if persists {
            try writes.readIfNeeded([String: Double].self) { levels = $0 }
        }
    }

    func prepareForSync() throws {
        try loadIfNeeded()
        try writes.flushPending(levels)
    }

    func level(for host: String) -> CGFloat? {
        levels[host].map { CGFloat($0) }
    }

    func set(_ zoom: CGFloat, for host: String, defaultZoom: CGFloat) {
        guard (try? loadIfNeeded()) != nil else { return }
        let value = abs(zoom - defaultZoom) < 0.005 ? nil : Double(zoom)
        guard levels[host] != value else { return }
        setOverride(value, for: host, saving: writes.schedule)
    }

    func receiveOverride(_ value: Double?, for host: String) throws {
        guard persists else { throw CocoaError(.fileWriteNoPermission) }
        try loadIfNeeded()
        try setOverride(value, for: host, saving: writes.saveNow)
    }

    private func setOverride(_ value: Double?, for host: String, saving: ([String: Double]) throws -> Void) rethrows {
        guard !host.isEmpty else { return }
        var next = levels
        next[host] = value
        if persists {
            try saving(next)
        }
        levels = next
        if persists {
            MacSettingsChange.post(self)
        }
    }

    func forgetSessionLevels() {
        guard !persists else { return }
        levels.removeAll()
    }

    func waitForPendingSave() async {
        await writes.waitForPendingSave()
    }
}
