// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The spellings of a value that a reader could look for in bytes that are meant to hold it only sealed.
nonisolated enum SyncNeedles {
    /// The bytes themselves, their base64 and base64url as they may fall at any of three offsets inside longer text, and their hex in
    /// both cases.
    static func spellings(_ marker: Data) -> [Data] {
        var found = [marker]
        for shift in 0..<3 {
            let encoded = (Data(repeating: 0x2E, count: shift) + marker + Data(repeating: 0x2E, count: 3)).base64EncodedString()
            let middle = String(encoded.dropFirst(4).dropLast(8))
            found.append(Data(middle.utf8))
            found.append(Data(middle.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").utf8))
        }
        let hex = marker.map { String(format: "%02x", $0) }.joined()
        return found + [Data(hex.utf8), Data(hex.uppercased().utf8)]
    }

    /// The first marker with a spelling in `bytes`, or nil.
    static func firstFound(of markers: [Data], in bytes: Data) -> Data? {
        markers.first { marker in spellings(marker).contains { bytes.range(of: $0) != nil } }
    }
}
