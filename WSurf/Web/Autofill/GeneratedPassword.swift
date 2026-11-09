// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// A password the generator made. It prints and mirrors as "GeneratedPassword" without its value: `description`, `debugDescription`,
/// `dump`, string interpolation and a `Logger` interpolation (which uses `description`) never show it. The value is read only through
/// `revealed`, at the one place that fills or saves it. It is not Codable, so no encoder writes it out by accident.
nonisolated struct GeneratedPassword: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    /// The characters of a password the generator drew (ASCII).
    init(_ characters: [UInt8]) {
        value = String(decoding: characters, as: UTF8.self)
    }

    /// The password itself.
    var revealed: String {
        value
    }

    var count: Int {
        value.count
    }

    var description: String {
        "GeneratedPassword"
    }

    var debugDescription: String {
        "GeneratedPassword"
    }

    var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}
