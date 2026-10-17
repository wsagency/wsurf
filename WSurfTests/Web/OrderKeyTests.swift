// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import WSurf

struct OrderKeyTests {
    /// A fixed sequence, so a failure reproduces.
    private struct Sequence {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func below(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @Test func aKeyBetweenTwoNeighborsSortsStrictlyBetweenThem() {
        var sequence = Sequence()
        var keys = [OrderKey.between(nil, nil)]
        for _ in 0..<3_000 {
            let gap = sequence.below(keys.count + 1)
            let lower = gap == 0 ? nil : keys[gap - 1]
            let upper = gap == keys.count ? nil : keys[gap]
            let key = OrderKey.between(lower, upper)
            if let lower {
                #expect(lower < key)
            }
            if let upper {
                #expect(key < upper)
            }
            keys.insert(key, at: gap)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    @Test func appendingManyKeysStaysSortedAndShort() {
        var keys: [String] = []
        for _ in 0..<1_000 {
            keys.append(OrderKey.between(keys.last, nil))
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect((keys.last?.count ?? 0) <= 40)
    }

    @Test func prependingAndInsertingStaySorted() {
        var keys = [OrderKey.between(nil, nil)]
        for _ in 0..<200 {
            keys.insert(OrderKey.between(nil, keys[0]), at: 0)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)

        // Always inserting into the same gap is the worst case for key length.
        var upper = keys[1]
        let lower = keys[0]
        for _ in 0..<200 {
            let key = OrderKey.between(lower, upper)
            #expect(lower < key && key < upper)
            upper = key
        }
    }

    @Test func noKeyEndsInTheLowestDigit() {
        var sequence = Sequence()
        var keys = [OrderKey.between(nil, nil)]
        for _ in 0..<2_000 {
            let gap = sequence.below(keys.count + 1)
            keys.insert(
                OrderKey.between(gap == 0 ? nil : keys[gap - 1], gap == keys.count ? nil : keys[gap]),
                at: gap
            )
        }
        #expect(keys.allSatisfy { $0.last != "0" && !$0.isEmpty })
    }
}
