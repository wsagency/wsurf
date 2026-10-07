// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated enum MCPInitializationCompatibility {
    static func normalize(_ message: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              capabilities["experimental"] is [String: Any]
        else { return message }

        // MCP allows object-valued experimental capabilities, but Swift SDK 0.12.1
        // decodes them as [String: String]. WSurf uses none of these extensions.
        // Ignore them before SDK decoding; leave malformed envelopes to the SDK.
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? message
    }
}
