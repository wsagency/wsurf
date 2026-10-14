// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension ChromiumPage {
    /// Viewport metrics, device scale factor, touch and mobile-viewport behavior for an MCP development lease. Either every
    /// override is applied or none is: a command that fails, is cancelled or times out may already have reached Chromium, so
    /// a failure of any of the three clears all of them.
    func setDeviceEmulation(width: Int, height: Int, scale: Double) async throws {
        do {
            _ = try await command(
                "Emulation.setDeviceMetricsOverride",
                params: ["width": width, "height": height, "deviceScaleFactor": scale, "mobile": true])
            _ = try await command("Emulation.setTouchEmulationEnabled", params: ["enabled": true, "maxTouchPoints": 5])
            _ = try await command("Emulation.setEmitTouchEventsForMouse", params: ["enabled": true, "configuration": "mobile"])
        } catch {
            await clearDeviceEmulation()
            throw error
        }
    }

    /// Best effort: the page may already be closing when a lease ends. The commands run in a fresh task that the caller's
    /// cancellation does not reach (DevTools commands fail at once under a cancelled task) and the caller waits for them, so a
    /// cleanup running inside the page's emulation turn finishes before the next turn starts.
    func clearDeviceEmulation() async {
        await Task { @MainActor [self] in
            _ = try? await command("Emulation.setEmitTouchEventsForMouse", params: ["enabled": false])
            _ = try? await command("Emulation.setTouchEmulationEnabled", params: ["enabled": false])
            _ = try? await command("Emulation.clearDeviceMetricsOverride")
        }.value
    }
}
