// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserSettings {
    var userAgentMode: UserAgentMode {
        get { globalValue(\.userAgentMode, storage: storedUserAgentMode) }
        set {
            setGlobal(\BrowserSettings.userAgentMode, storage: \BrowserSettings.storedUserAgentMode, value: newValue, key: Key.userAgent, encode: { $0.rawValue }) {
                $0.onWebPreferencesChanged?()
            }
        }
    }

    var customUserAgent: String {
        get { globalValue(\.customUserAgent, storage: storedCustomUserAgent) }
        set {
            setGlobal(\BrowserSettings.customUserAgent, storage: \BrowserSettings.storedCustomUserAgent, value: newValue, key: Key.customUserAgent, didChange: { settings in
                if settings.userAgentMode == .custom {
                    settings.onWebPreferencesChanged?()
                }
            })
        }
    }

    var userAgentString: String? {
        switch userAgentMode {
        case .safari:
            WebViewPool.safariUserAgent
        case .wsurf:
            "\(WebViewPool.safariUserAgent) WSurf/\(UpdateFeed.currentVersion)"
        case .custom:
            customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? WebViewPool.safariUserAgent
                : customUserAgent
        }
    }

    var webInspectorEnabled: Bool {
        get { globalValue(\.webInspectorEnabled, storage: storedWebInspectorEnabled) }
        set {
            setGlobal(\BrowserSettings.webInspectorEnabled, storage: \BrowserSettings.storedWebInspectorEnabled, value: newValue, key: Key.webInspector, didChange: {
                $0.onWebPreferencesChanged?()
            })
        }
    }
}
