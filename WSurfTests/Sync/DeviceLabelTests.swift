// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

/// The short names that tell the person's devices apart, and when a device counts as live.
struct DeviceLabelTests {
    @Test(arguments: [
        ("Kristijan’s MacBook Air", "Air"),
        ("Ana's MacBook Pro", "Pro"),
        ("MacBook Air", "Air"),
        ("MacBook", "MacBook"),
        ("Mac mini", "Mac mini"),
        ("Mac Studio", "Studio"),
        ("Mac Pro", "Mac Pro"),
        ("Office iMac", "iMac"),
        ("Ana’s iPhone 16 Pro", "iPhone"),
        ("iPad Air", "iPad"),
        ("MACBOOK PRO 14", "Pro"),
        ("Build box", "Build box"),
        ("Fourteen chars", "Fourteen chars"),
        ("A name of twenty ch", "A name of twe…"),
        ("", "Device"),
        ("   ", "Device"),
    ])
    func shortNameComesFromTheModel(name: String, label: String) {
        #expect(DeviceLabels.shortName(name, fallback: "Device") == label)
    }

    @Test func equalShortNamesAreNumberedByInstallID() {
        let labels = DeviceLabels.labels(
            for: [(id: "B-2", name: "Ana’s MacBook Air"), (id: "A-1", name: "Ivo’s MacBook Air"), (id: "C-3", name: "Ana’s iPhone")],
            fallback: "Device"
        )

        #expect(labels == ["A-1": "Air", "B-2": "Air 2", "C-3": "iPhone"])
    }

    @Test func threeEqualNamesGetThreeLabelsWhateverTheOrderGiven() {
        let ids = ["c", "a", "b"]
        let forward = DeviceLabels.labels(for: ids.map { (id: $0, name: "Mac mini") }, fallback: "Device")
        let backward = DeviceLabels.labels(for: ids.reversed().map { (id: $0, name: "Mac mini") }, fallback: "Device")

        #expect(forward == ["a": "Mac mini", "b": "Mac mini 2", "c": "Mac mini 3"])
        #expect(backward == forward)
    }

    @Test func presenceIsCurrentForThirtyMinutes() {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(Presence.of(lastSeen: seen, running: true, now: seen.addingTimeInterval(29 * 60 + 59)) == .current)
        #expect(Presence.of(lastSeen: seen, running: true, now: seen.addingTimeInterval(30 * 60 + 1)) == .lastSeen(seen))
        // The server's clock may be ahead of this Mac's.
        #expect(Presence.of(lastSeen: seen, running: true, now: seen.addingTimeInterval(-90)) == .current)
    }

    @Test func quitDeviceIsShownAsLastSeenAtOnce() {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(Presence.of(lastSeen: seen, running: false, now: seen.addingTimeInterval(1)) == .lastSeen(seen))
    }
}
