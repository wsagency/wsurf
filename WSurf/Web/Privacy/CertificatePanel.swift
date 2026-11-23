// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

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

    /// The window the sheet for a page hangs from: the page's own window, never whichever window happens to be key (a click in
    /// a window's floating bar does not make that window key before the action runs).
    static func sheetWindow(for window: NSWindow?) -> NSWindow? {
        window?.sheetHost ?? NSApp.keyWindow?.sheetHost ?? NSApp.mainWindow
    }

    static func show(for tab: BrowserTab, in window: NSWindow? = nil) {
        guard let trust = trust(of: tab),
              let window = sheetWindow(for: window ?? tab.liveView?.window)
        else { return }
        let host = URL(string: tab.urlString)?.host()
        Task { _ = await inspect(trust, host: host, in: window) }
    }

    static func inspect(_ trust: SecTrust, host: String?, in window: NSWindow?) async -> Bool {
        let panel = SFCertificatePanel()
        panel.setPolicies(SecPolicyCreateSSL(true, host as CFString?))
        guard let window else {
            return panel.runModal(for: trust, showGroup: true) == NSApplication.ModalResponse.OK.rawValue
        }
        return await withCheckedContinuation { continuation in
            let presentation = SheetPresentation(panel: panel, continuation: continuation)
            presentation.begin(on: window, trust: trust)
        }
    }

    @MainActor
    private final class SheetPresentation: NSObject {
        let panel: SFCertificatePanel
        private var continuation: CheckedContinuation<Bool, Never>?

        init(panel: SFCertificatePanel, continuation: CheckedContinuation<Bool, Never>) {
            self.panel = panel
            self.continuation = continuation
        }

        func begin(on window: NSWindow, trust: SecTrust) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentClosed), name: NSWindow.willCloseNotification, object: window
            )
            panel.beginSheet(
                for: window, modalDelegate: self, didEnd: #selector(didEnd(_:returnCode:context:)),
                contextInfo: Unmanaged.passRetained(self).toOpaque(), trust: trust, showGroup: true
            )
        }

        @objc private func parentClosed() {
            finish(inspected: false)
            panel.sheetParent?.endSheet(panel, returnCode: .abort)
        }

        @objc private func didEnd(_: NSWindow, returnCode: Int, context: UnsafeMutableRawPointer) {
            let presentation = Unmanaged<SheetPresentation>.fromOpaque(context).takeRetainedValue()
            presentation.finish(inspected: returnCode == NSApplication.ModalResponse.OK.rawValue)
        }

        private func finish(inspected: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: inspected)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
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
