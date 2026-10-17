// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

/// Sortable string keys: a key between any two neighbors, so one move rewrites one row.
///
/// Keys use the digits `0-9A-Za-z`, whose character order is also their byte order, so a plain string
/// comparison and SQLite's default collation agree. No key ends in the lowest digit, so there is always
/// room between two keys.
nonisolated enum OrderKey {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    // ponytail: no jitter; two devices inserting at the same spot can tie, and a sync layer breaks ties by id.
    /// A key strictly between `lower` and `upper`; nil means unbounded. `lower` must sort before `upper`.
    static func between(_ lower: String?, _ upper: String?) -> String {
        String(midpoint(lower.map(values) ?? [], upper.map(values)).map { digits[$0] })
    }

    private static func values(_ key: String) -> [Int] {
        key.map { digits.firstIndex(of: $0) ?? 0 }
    }

    private static func midpoint(_ lower: [Int], _ upper: [Int]?) -> [Int] {
        guard let upper else {
            // Unbounded above: bump the first digit that can grow, which keeps appended keys short.
            if let index = lower.firstIndex(where: { $0 < digits.count - 1 }) {
                return Array(lower[..<index]) + [lower[index] + 1]
            }
            return lower + [digits.count / 2]
        }
        var prefix: [Int] = []
        for index in 0..<max(lower.count, upper.count) {
            let low = index < lower.count ? lower[index] : 0
            let high = index < upper.count ? upper[index] : 0
            if low == high {
                prefix.append(low)
                continue
            }
            if high - low > 1 {
                return prefix + [(low + high) / 2]
            }
            return prefix + [low] + midpoint(Array(lower.dropFirst(index + 1)), nil)
        }
        // Equal keys leave no room; the caller broke the ordering rule, so still return a key above `lower`.
        return midpoint(lower, nil)
    }
}
