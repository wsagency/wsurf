// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// What a WebKit page's certificates add to WebKit's own `hasOnlySecureContent`, so the page is secure for credentials by the
/// same rule as a Chromium page (`ChromiumPage.hasOnlySecureContent`): WebKit keeps its flag on a page reached past a
/// certificate warning, because accepting the exception (`URLCredential(trust:)`) never reaches that flag.
///
/// - The main frame's committed certificate (`WKWebView.serverTrust`) must pass the system's evaluation, which an accepted
///   exception does not change. That also covers a later page of the same host, whose connection reuses the exception without
///   asking, and a page restored from the back-forward cache, which brings its own certificate back.
/// - A subresource accepted past a warning taints the document it loaded in: an exception accepted while a navigation is
///   provisional counts for both the current and the coming document, so it is never lost at the commit.
/// ponytail: a subresource whose connection reuses an earlier exception without asking again, or a document restored from the
/// back-forward cache with such subresources, is not seen; recording the page's subresource hosts would close that.
struct CertificateStanding {
    var webKitSecure = false
    fileprivate(set) var trust: SecTrust?
    fileprivate(set) var trustPassed = false
    private(set) var exception = false
    private var pendingException = false

    var isSecure: Bool {
        webKitSecure && trust != nil && trustPassed && !exception
    }

    mutating func navigationStarted() {
        pendingException = false
    }

    mutating func navigationCommitted() {
        exception = pendingException
        pendingException = false
    }

    mutating func exceptionAccepted() {
        exception = true
        pendingException = true
    }
}

extension BrowserPage {
    /// The main frame's certificate changed: not secure until this one passes evaluation.
    func serverTrustChanged(_ trust: SecTrust?) {
        certificateStanding.trust = trust
        certificateStanding.trustPassed = false
        guard let trust else { return }
        Task { [weak self] in
            let passed = (try? await CertificateTrust.evaluate(trust)) == true
            guard let self, self.certificateStanding.trust === trust else { return }
            self.certificateStanding.trustPassed = passed
        }
    }
}
