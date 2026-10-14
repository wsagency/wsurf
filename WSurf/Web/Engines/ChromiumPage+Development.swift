// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension ChromiumPage {
    /// Viewport metrics, device scale factor, touch and mobile-viewport behavior for an MCP development lease. Either every
    /// override is applied or none is.
    func setDeviceEmulation(width: Int, height: Int, scale: Double) async throws {
        _ = try await command(
            "Emulation.setDeviceMetricsOverride",
            params: ["width": width, "height": height, "deviceScaleFactor": scale, "mobile": true])
        do {
            _ = try await command("Emulation.setTouchEmulationEnabled", params: ["enabled": true, "maxTouchPoints": 5])
            _ = try await command("Emulation.setEmitTouchEventsForMouse", params: ["enabled": true, "configuration": "mobile"])
        } catch {
            await clearDeviceEmulation()
            throw error
        }
    }

    /// Best effort: the page may already be closing when a lease ends.
    func clearDeviceEmulation() async {
        _ = try? await command("Emulation.setEmitTouchEventsForMouse", params: ["enabled": false])
        _ = try? await command("Emulation.setTouchEmulationEnabled", params: ["enabled": false])
        _ = try? await command("Emulation.clearDeviceMetricsOverride")
    }
}
