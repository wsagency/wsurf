// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation

@MainActor
extension ChromiumPage {
    /// Applies settings that CEF reads only while creating a browser. The
    /// product override stays untouched so a default Chromium page reports
    /// the genuine engine user agent.
    static func configureBrowserSettings(
        _ native: inout cef_browser_settings_t,
        settings: BrowserSettings
    ) {
        native.javascript = settings.javaScriptEnabled ? STATE_ENABLED : STATE_DISABLED
    }

    /// Applies settings that can be changed through the already-attached CEF
    /// DevTools transport. The caller may safely invoke this after
    /// `ensureReady`; retaining the guard here also makes direct callers safe.
    func applySettings(_ settings: BrowserSettings) async throws {
        try await ensureReady()
        guard !isClosed, let client else { throw ChromiumError.closed }
        client.updateSettings(settings)

        let version = try await command("Browser.getVersion")
        guard let genuineUserAgent = version["userAgent"] as? String, !genuineUserAgent.isEmpty else {
            throw ChromiumError.protocolFailure("Chromium did not return its user agent.")
        }
        let userAgent: String
        switch settings.userAgentMode {
        case .safari:
            userAgent = genuineUserAgent
        case .wsurf:
            userAgent = "\(genuineUserAgent) WSurf/\(UpdateFeed.currentVersion)"
        case .custom:
            let custom = settings.customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            userAgent = custom.isEmpty ? genuineUserAgent : custom
        }
        _ = try await command("Network.setUserAgentOverride", params: ["userAgent": userAgent])
        _ = try await command(
            "Emulation.setScriptExecutionDisabled",
            params: ["value": !settings.javaScriptEnabled]
        )

        let autoplayValue: cef_content_setting_values_t
        switch settings.autoplay {
        case .allow:
            autoplayValue = CEF_CONTENT_SETTING_VALUE_ALLOW
        case .silent:
            autoplayValue = CEF_CONTENT_SETTING_VALUE_ASK
        case .block:
            autoplayValue = CEF_CONTENT_SETTING_VALUE_BLOCK
        }
        try ChromiumRuntime.shared.withContext(for: context) { context in
            context.pointee.set_content_setting?(
                context,
                nil,
                nil,
                CEF_CONTENT_SETTING_TYPE_AUTOPLAY,
                autoplayValue
            )
        }
    }
}
