// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import Foundation

extension ChromiumPage {
    /// `hasOnlySecureContent` of the visible navigation entry, by the rule below.
    func updateNativeSecurity() {
        let secure = withHost { host -> Bool in
            guard let entry = host.pointee.get_visible_navigation_entry?(host) else { return false }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(entry)) }
            let url = URL(string: ChromiumInterop.takeString(entry.pointee.get_url?(entry)))
            guard let ssl = entry.pointee.get_sslstatus?(entry) else { return false }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(ssl)) }
            return Self.hasOnlySecureContent(
                url: url, isSecureConnection: ssl.pointee.is_secure_connection?(ssl) == 1,
                certStatus: ssl.pointee.get_cert_status?(ssl).rawValue ?? ~0, contentStatus: ssl.pointee.get_content_status?(ssl).rawValue ?? ~0
            )
        } ?? false
        owner?.hasOnlySecureContent = secure
    }

    /// `hasOnlySecureContent` for a Chromium page: WebKit's rule for the same property, never looser. Saved logins are offered,
    /// filled and saved only while it holds (see `CredentialPicker.isOffered`, `AutofillSuggestions`, `AutofillSaveCoordinator`).
    ///
    /// WebKit: the main frame's address is HTTPS, and no insecure content has been shown or run in the page.
    /// Here, from the visible navigation entry's SSL status:
    /// - the entry's address is HTTPS (so never an `http:`, `file:` or internal page);
    /// - CEF calls the connection secure (`is_secure_connection`: the entry has a server certificate);
    /// - the certificate has no error bit, by `net::CERT_STATUS_ALL_ERRORS` (CEF passes Chromium's status through; its header's
    ///   "bits 16 to 31 are non-error" is out of date: bits 24 and up are errors again, such as CERTIFICATE_TRANSPARENCY_REQUIRED
    ///   and KNOWN_INTERCEPTION_BLOCKED). A certificate accepted after a warning keeps its error bits, so a page reached past one
    ///   is not secure, which may be stricter than WebKit, never looser;
    /// - the content status carries no flag at all: nothing insecure was shown or run, nor anything with a certificate error.
    /// A form's target is not part of this: the page script fills a password only into a form that submits to the page's own
    /// origin (`forms.safe`), so on a page that passes here, only to HTTPS.
    /// Chromium's DevTools rating ("secure", "neutral", "info", ...) is not used: it is another scale, and it used to overwrite
    /// this rule whenever it arrived last, so any rating but "secure" hid saved logins on a page WebKit offers them on.
    nonisolated static func hasOnlySecureContent(url: URL?, isSecureConnection: Bool, certStatus: UInt32, contentStatus: UInt32) -> Bool {
        url?.scheme?.lowercased() == "https" && isSecureConnection && certStatus & certStatusAllErrors == 0 && contentStatus == 0
    }

    private nonisolated static let certStatusAllErrors: UInt32 = 0xFF00_FFFF // net::CERT_STATUS_ALL_ERRORS
}
