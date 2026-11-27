// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import MCP

/// Machine-readable tool outcomes. Human-readable content and existing status values remain wire compatible.
nonisolated enum MCPFailureCode: String {
    case accessDenied, actionFailed, busy, cancelled, connectionUnavailable, dialogPending, humanControl, invalidInput
    case noSavedLogin, ownershipConflict, pageUnavailable, protectedSecretPresent, scriptError, stale, tabNotFound
    case timeout, unsupported, vaultLocked, waitingForUser, webKitRequired

    var value: Value {
        .string(rawValue)
    }

    func result(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            structuredContent: Optional.some(.object(["code": value, "message": .string(message)])),
            isError: true)
    }
}
