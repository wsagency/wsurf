// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension ChromiumPage {
    /// `hasOnlySecureContent` for a Chromium page: WebKit's rule for the same property, never looser. Saved logins are offered,
    /// filled and saved only while it holds (see `CredentialPicker.isOffered`, `AutofillSuggestions`, `AutofillSaveCoordinator`).
    ///
    /// WebKit: the main frame's address is HTTPS, and no insecure content has been shown or run in the page.
    /// Here, from the visible navigation entry's SSL status:
    /// - the entry's address is HTTPS (so never an `http:`, `file:` or internal page);
    /// - CEF calls the connection secure (`is_secure_connection`: the entry has a server certificate);
    /// - the certificate has no error bit (Chromium's error bits are the low 16; a certificate accepted after a warning keeps
    ///   its error bits, so a page reached past one is not secure, which may be stricter than WebKit, never looser);
    /// - the content status carries no flag at all: nothing insecure was shown or run, nor anything with a certificate error.
    /// A form's target is not part of this: the page script fills a password only into a form that submits to the page's own
    /// origin (`forms.safe`), so on a page that passes here, only to HTTPS.
    /// Chromium's DevTools rating ("secure", "neutral", "info", ...) is not used: it is another scale, and it used to overwrite
    /// this rule whenever it arrived last, so any rating but "secure" hid saved logins on a page WebKit offers them on.
    nonisolated static func hasOnlySecureContent(url: URL?, isSecureConnection: Bool, certStatus: UInt32, contentStatus: UInt32) -> Bool {
        url?.scheme?.lowercased() == "https" && isSecureConnection && certStatus & 0xFFFF == 0 && contentStatus == 0
    }
}
