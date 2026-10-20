// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import WebKit

nonisolated enum AutoplayPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case allow
    case silent
    case block

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .allow:
            "Allow"
        case .silent:
            "Muted"
        case .block:
            "Never"
        }
    }

    var caption: LocalizedStringResource {
        switch self {
        case .allow:
            "Video and audio may start playing as soon as a page loads."
        case .silent:
            "Video plays without sound until you click."
        case .block:
            "Nothing plays until you press play."
        }
    }

    var mediaTypes: WKAudiovisualMediaTypes {
        switch self {
        case .allow:
            []
        case .silent:
            .audio
        case .block:
            .all
        }
    }
}

extension BrowserSettings {
    func apply(to configuration: WKWebViewConfiguration) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScriptEnabled
        // A tab decides each pop-up as WebKit asks for its window, so WebKit hands them all over. A WebKit that cannot say
        // who started one keeps its own blocker for the setting.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = TabNavigationDelegate.decidesPopUps || !blocksPopups
        // A tab's navigations set the website's own answer (`SiteContentGuard.apply`), so the view itself asks nothing; a
        // website's Allow under a global Never did not play otherwise. A WebKit without that hook keeps the setting.
        configuration.mediaTypesRequiringUserActionForPlayback = SiteContentGuard.decidesAutoplay ? [] : autoplay.mediaTypes
        configuration.preferences.isElementFullscreenEnabled = true
        // `isInspectable` only lets an external inspector attach. This private
        // preference enables the page's own Inspect Element item.
        configuration.preferences.setValue(webInspectorEnabled, forKey: "developerExtrasEnabled")
        WebKitFeatures.apply(to: configuration.preferences)
        NativeApplePay.apply(to: configuration.preferences)
    }

    func apply(to webView: WKWebView) {
        apply(to: webView.configuration)
        if webView.pageZoom != pageZoom {
            webView.pageZoom = pageZoom
        }
        webView.customUserAgent = userAgentString
        webView.isInspectable = webInspectorEnabled
    }

    func apply(to page: BrowserPage) {
        if let webKit = page.webKit {
            apply(to: webKit)
            return
        }
        guard let chromium = page.chromium, chromium.browserID >= 0 else { return }
        Task { [weak page, weak chromium] in
            guard let page, let chromium, !page.isClosed else { return }
            do {
                try await chromium.applySettings(self)
            } catch {
                guard !page.isClosed else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Website preferences could not be applied.")
                alert.informativeText = error.localizedDescription
                if let window = page.window {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}
