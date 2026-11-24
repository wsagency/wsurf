// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Who currently owns input and automation in an Agent Micro Window.
nonisolated enum AgentWindowOwner: String, Codable, Sendable, Equatable {
    case agent
    case human
    case unclaimed
}

/// Pre-approved MCP access tier scoped exclusively to an Agent Micro Window.
nonisolated enum AgentWindowAccess: String, Codable, Sendable, Equatable {
    case control
    case development
    case developer

    @MainActor var mcpAccess: MCPAccessConsent.Access {
        switch self {
        case .control:
            .control
        case .development:
            .development
        case .developer:
            .developer
        }
    }
}

/// Companion metadata attached to an Agent Micro Window controlled by an external host such as T3 Code.
nonisolated struct AgentCompanionInfo: Equatable, Sendable {
    var hostName: String
    var threadId: String
    var threadTitle: String?
    var owner: AgentWindowOwner = .agent
    var generation: Int = 1
    var isWorking: Bool = false
    var allowsMultipleTabs: Bool = true
    var defaultEngine: BrowserEngine = .chromium
    var access: AgentWindowAccess = .control

    var displayHostName: String {
        let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "t3-code" || lowered == "t3" || lowered == "t3 code" {
            return "T3"
        }
        return trimmed.isEmpty ? "Agent" : trimmed
    }

    var displayThreadTitle: String? {
        guard let title = threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title.count > 36 ? String(title.prefix(35)) + "…" : title
    }
}

/// Wire error codes returned by the external host bridge (`host-bridge.sock`).
nonisolated enum MCPAgentWindowErrorCode: String, Sendable, Equatable {
    case unauthorized
    case invalidRequest
    case invalidParams
    case unknownOperation
    case notFound
    case forbidden
    case unsupported
    case agentMismatch
    case humanControl
    case staleGeneration
    case actionFailed
    case scriptError
    case timedOut
    case cancelled
    case internalError
}

nonisolated struct MCPAgentWindowError: Error, Sendable, Equatable {
    let code: MCPAgentWindowErrorCode
    let message: String

    init(_ code: MCPAgentWindowErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Wire protocol v1 helpers for `host-bridge.sock` (newline-delimited JSON).
nonisolated enum MCPAgentBridgeProtocol {
    static let protocolName = "wsurf-host-bridge"
    static let version = 1
    static let backendName = "wsurf-micro"

    static func hostCapabilities() -> [String: Any] {
        [
            "agentMicroWindow": true,
            "backgroundPointer": true,
            "vaultLoginPrompt": true,
            "engines": ["chromium", "webkit"],
        ]
    }

    static func windowCapabilities() -> [String: Any] {
        [
            "pointer": true,
            "backgroundPointer": true,
            "engines": ["chromium", "webkit"],
        ]
    }

    static func parseHello(_ data: Data) -> (token: String, host: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["wsurf"] as? String == "host-hello",
              object["v"] as? Int == version,
              let token = object["token"] as? String,
              MCPPairing.isWellFormed(token),
              let rawHost = object["host"] as? String
        else {
            return nil
        }
        let cleaned = cleanText(rawHost, maxLength: 60)
        guard !cleaned.isEmpty else { return nil }
        return (token, cleaned)
    }

    static func helloSuccessLine() -> Data {
        encodeLine([
            "ok": true,
            "v": version,
            "protocol": protocolName,
            "capabilities": hostCapabilities(),
        ])
    }

    static func helloFailureLine(code: MCPAgentWindowErrorCode = .unauthorized, message: String) -> Data {
        encodeLine([
            "ok": false,
            "error": [
                "code": code.rawValue,
                "message": message,
            ],
        ])
    }

    static func responseSuccessLine(id: String, result: [String: Any]) -> Data {
        encodeLine([
            "id": id,
            "ok": true,
            "result": result,
        ])
    }

    static func responseErrorLine(id: String, code: MCPAgentWindowErrorCode, message: String) -> Data {
        encodeLine([
            "id": id,
            "ok": false,
            "error": [
                "code": code.rawValue,
                "message": message,
            ],
        ])
    }

    static func eventLine(name: String, payload: [String: Any]) -> Data {
        encodeLine([
            "event": name,
            "payload": payload,
        ])
    }

    static func encodeLine(_ object: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"error":{"code":"internalError","message":"Encoding failed."}}"#.utf8)
        return data + Data([10])
    }

    static func cleanText(_ text: String, maxLength: Int) -> String {
        let visible = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(visible.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    /// Parses a valid HTTP(S) URL with no embedded user/password credentials.
    static func parseWebURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil,
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        return url
    }
}
