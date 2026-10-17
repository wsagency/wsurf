// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Security

/// Pairing tokens let WSurf recognize one installed MCP client across connections.
///
/// The installer writes a random token into that client's entry as an environment variable and WSurf keeps only its
/// SHA-256 hash. The relay presents the token in a single hello line before any MCP traffic. A token never enters the
/// MCP layer, a log, a command-line argument or UserDefaults. It identifies a configured client; it does not defend
/// against malware that runs as the same user and can read that client's configuration.
nonisolated enum MCPPairing {
    static let environmentName = "WSURF_MCP_TOKEN"
    /// 32 random bytes in unpadded base64url.
    static let tokenLength = 43

    /// The token the launching client passed to this relay, if any.
    static func environmentToken(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[environmentName].flatMap { isWellFormed($0) ? $0 : nil }
    }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPClientSetupError.pairingUnavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == tokenLength && token.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    /// Compares without stopping at the first difference. Lengths are public (both sides are digests).
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    /// The first line a paired relay writes on the socket. The field order is fixed so the server can recognize it
    /// from its first bytes without parsing JSON. `nil` for a malformed token.
    static func helloMessage(token: String) -> Data? {
        guard isWellFormed(token) else { return nil }
        return Data(#"{"wsurf":"hello","v":1,"token":"\#(token)"}"#.utf8)
    }
}

/// Recognizes the optional hello line at the start of a connection.
///
/// Anything that does not begin with the hello marker is handed back byte for byte, so an unpaired client, an old
/// relay and a direct socket client reach MCP unchanged. A hello that is too long is refused.
nonisolated struct MCPHelloGate {
    nonisolated enum Outcome: Equatable {
        /// More bytes are needed to decide.
        case undecided
        /// A hello line. `token` is nil when it carries no valid token; `rest` follows the line.
        case hello(token: String?, rest: Data)
        /// Not a hello: every byte received so far, to feed to MCP.
        case passthrough(Data)
        case rejected
    }

    static let maximumBytes = 512
    private static let marker = Data(#"{"wsurf":"hello""#.utf8)
    private var pending = Data()

    mutating func append(_ chunk: Data) -> Outcome {
        pending.append(chunk)
        let compared = min(pending.count, Self.marker.count)
        guard pending.prefix(compared) == Self.marker.prefix(compared) else { return .passthrough(pending) }
        guard let newline = pending.firstIndex(of: 10) else {
            return pending.count > Self.maximumBytes ? .rejected : .undecided
        }
        let line = Data(pending[..<newline])
        guard line.count <= Self.maximumBytes else { return .rejected }
        return .hello(token: Self.token(in: line), rest: Data(pending[pending.index(after: newline)...]))
    }

    private static func token(in line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["wsurf"] as? String == "hello", object["v"] as? Int == 1,
              let token = object["token"] as? String, MCPPairing.isWellFormed(token) else { return nil }
        return token
    }
}
