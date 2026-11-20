// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

@MainActor
final class PageZoomStore {
    private(set) var levels: [String: Double]
    private let file: URL
    private let persists: Bool
    private var saveTask: Task<Void, Never>?

    init(file: URL, persists: Bool = true) {
        self.file = file
        self.persists = persists
        levels = persists
            ? ((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:])
            : [:]
    }

    func level(for host: String) -> CGFloat? {
        levels[host].map { CGFloat($0) }
    }

    func set(_ zoom: CGFloat, for host: String, defaultZoom: CGFloat) {
        setOverride(abs(zoom - defaultZoom) < 0.005 ? nil : Double(zoom), for: host)
    }

    func setOverride(_ value: Double?, for host: String) {
        guard !host.isEmpty, levels[host] != value else { return }
        levels[host] = value
        guard persists else { return }
        MacSettingsChange.post(self)
        let snapshot = levels
        let previous = saveTask
        previous?.cancel()
        let file = self.file
        saveTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await JSONFileStore.shared.write(snapshot, to: file)
        }
    }

    func waitForPendingSave() async {
        await saveTask?.value
    }
}
