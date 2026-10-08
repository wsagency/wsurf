// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

@MainActor
final class PageZoomStore {
    private var levels: [String: Double]
    private let file: URL
    private let persists: Bool

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
        guard !host.isEmpty else { return }
        if abs(zoom - defaultZoom) < 0.005 {
            guard levels.removeValue(forKey: host) != nil else { return }
        } else {
            let value = Double(zoom)
            guard levels[host] != value else { return }
            levels[host] = value
        }
        guard persists else { return }
        let snapshot = levels
        Task { await JSONFileStore.shared.write(snapshot, to: file) }
    }

}
