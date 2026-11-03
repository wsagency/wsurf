// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The base64url buffers of the WebAuthn page messages. The vault stores an SSH key's bytes in this form, so the helpers are
/// here; the app extends the type with the rest, which turns page messages into authenticator requests (`WebAuthnWire.swift`).
public nonisolated enum WebAuthnWire {
    /// A malformed message maps to `TypeError`; the page script already rejects most of these before sending.
    public struct Malformed: Error {
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    public static func base64URLDecode(_ value: Any?, maximum: Int = 65_536) throws -> Data {
        guard let value = value as? String, value.utf8.count <= maximum * 2,
              value.utf8.allSatisfy({ $0 != 0x2B && $0 != 0x2F && $0 != 0x3D }) else { throw Malformed(reason: "buffer") }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), data.count <= maximum,
              base64URL(data) == value else { throw Malformed(reason: "buffer") }
        return data
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
