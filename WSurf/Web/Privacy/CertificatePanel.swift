// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CCef
import Foundation
import Security
import SecurityInterface
import WebKit

@MainActor
enum CertificatePanel {
    static func trust(of tab: BrowserTab) -> SecTrust? {
        guard tab.isMaterialised, tab.security != .none, tab.security != .insecure else { return nil }
        if let chromium = tab.page.chromium, let trust = chromium.certificateTrust() {
            return trust
        }
        return tab.page.webKit?.serverTrust
    }

    static func canShow(for tab: BrowserTab) -> Bool {
        trust(of: tab) != nil
    }

    static func show(for tab: BrowserTab, in window: NSWindow? = nil) {
        guard let trust = trust(of: tab),
              let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        guard let panel = SFCertificatePanel.shared() else { return }
        if let host = URL(string: tab.urlString)?.host() {
            panel.setPolicies(SecPolicyCreateSSL(true, host as CFString))
        }
        panel.beginSheet(
            for: window,
            modalDelegate: nil,
            didEnd: nil,
            contextInfo: nil,
            trust: trust,
            showGroup: true
        )
    }
}

extension ChromiumPage {
    func certificateTrust() -> SecTrust? {
        guard let chain = withHost({ host -> [Data] in
            guard let entry = host.pointee.get_visible_navigation_entry?(host) else { return [] }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(entry)) }
            guard let ssl = entry.pointee.get_sslstatus?(entry) else { return [] }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(ssl)) }
            guard let certificate = ssl.pointee.get_x509_certificate?(ssl) else { return [] }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(certificate)) }
            return CertificateTrust.chainData(from: certificate)
        }), !chain.isEmpty else { return nil }
        return CertificateTrust.makeTrust(from: chain, host: owner?.url?.host)
    }
}
