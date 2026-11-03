// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Short, stable names for the other devices, from the names their owners gave them. "This Mac" is never derived here.
nonisolated public enum DeviceLabels {
    /// Product names a device name may contain, tried in this order. The first match wins, so `MacBook Air` is `Air`.
    private static let productNames: [(contains: String, label: String)] = [
        ("MacBook Air", "Air"),
        ("MacBook Pro", "Pro"),
        ("MacBook", "MacBook"),
        ("Mac mini", "Mac mini"),
        ("Mac Studio", "Studio"),
        ("Mac Pro", "Mac Pro"),
        ("iMac", "iMac"),
        ("iPhone", "iPhone"),
        ("iPad", "iPad"),
    ]
    private static let possessives = ["\u{2019}s ", "'s "]
    private static let maxPlainCharacters = 14

    public static func shortName(_ name: String, fallback: String) -> String {
        var stripped = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cuts = possessives.compactMap { stripped.range(of: $0) }
        if let first = cuts.min(by: { $0.lowerBound < $1.lowerBound }) {
            let rest = String(stripped[first.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                stripped = rest
            }
        }
        if let product = productNames.first(where: { stripped.range(of: $0.contains, options: .caseInsensitive) != nil }) {
            return product.label
        }
        guard !stripped.isEmpty else { return fallback }
        guard stripped.count > maxPlainCharacters else { return stripped }
        return String(stripped.prefix(maxPlainCharacters - 1)) + "\u{2026}"
    }

    /// One label per device. Devices that share a short name are numbered in order of their IDs, so a label does not
    /// change between launches: the first keeps the name, the others get ` 2`, ` 3`, and so on.
    public static func labels(for devices: [(id: String, name: String)], fallback: String) -> [String: String] {
        let groups = Dictionary(grouping: devices) { shortName($0.name, fallback: fallback) }
        var labels: [String: String] = [:]
        for (short, members) in groups {
            for (index, member) in members.sorted(by: { $0.id < $1.id }).enumerated() {
                labels[member.id] = index == 0 ? short : "\(short) \(index + 1)"
            }
        }
        return labels
    }
}

/// Whether a device's tabs are live, or only the last thing it said.
nonisolated public enum Presence: Equatable, Sendable {
    case current
    case lastSeen(Date)

    public static let staleAfter: TimeInterval = 30 * 60

    /// `current` while the device says a window is open and its record is at most 30 minutes old. A modification date
    /// ahead of this Mac's clock counts as fresh.
    public static func of(lastSeen: Date, running: Bool, now: Date) -> Presence {
        running && now.timeIntervalSince(lastSeen) <= staleAfter ? .current : .lastSeen(lastSeen)
    }
}
