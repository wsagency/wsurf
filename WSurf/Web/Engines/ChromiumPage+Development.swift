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

    /// Media features for an MCP development lease. `command` replaces the whole set, so the call carries every feature the
    /// lease still wants and an empty set removes them all.
    func setEmulatedMedia(_ media: DevelopmentMedia) async throws {
        var features: [[String: String]] = []
        if let scheme = media.colorScheme {
            features.append(["name": "prefers-color-scheme", "value": scheme.rawValue])
        }
        if let reduced = media.reducedMotion {
            features.append(["name": "prefers-reduced-motion", "value": reduced ? "reduce" : "no-preference"])
        }
        _ = try await command("Emulation.setEmulatedMedia", params: ["features": features])
    }

    /// Offline only: no latency or throughput limit is ever applied.
    func setOffline(_ offline: Bool) async throws {
        _ = try await command(
            "Network.emulateNetworkConditions",
            params: ["offline": offline, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1])
    }

    /// Best effort and cancellation-proof, like `clearDeviceEmulation`: puts media and network emulation exactly at `media`.
    func forceMediaEmulation(_ media: DevelopmentMedia) async {
        await Task { @MainActor [self] in
            _ = try? await setEmulatedMedia(media)
            _ = try? await setOffline(media.offline)
        }.value
    }
}
