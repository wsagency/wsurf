// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Looks for a password or payment field on the visible page, so a site without a choice of its own can still ask
/// before the assistant uses a sign-in or checkout page.
@MainActor
enum PageSensitiveProbe {
    /// Same-origin frames and open shadow roots are walked like any other part of the page. A frame from another site
    /// cannot be looked into, so a visible one that names a card or payment form counts instead.
    static let script = """
        if (!document.body) return JSON.stringify({ sensitive: false });
        const fields = 'input:not([type=hidden]), textarea, select, [contenteditable=""], [contenteditable="true"], [role="textbox"], [role="searchbox"]';
        const payment = /card|payment|cvc|cvv|credit|billing|stripe|adyen|braintree|hosted.?field/i;
        const text = value => typeof value === 'string' ? value : '';
        for (const el of R.walk(document.body)) {
          if (el.tagName === 'IFRAME') {
            if (R.visible(el) && payment.test([el.title, el.name, el.src].map(text).join(' '))) {
              return JSON.stringify({ sensitive: true });
            }
          } else if (el.matches(fields) && R.visible(el) && R.isSensitiveField(el)) {
            return JSON.stringify({ sensitive: true });
          }
        }
        return JSON.stringify({ sensitive: false });
        """

    /// A page that does not answer counts as sensitive: the assistant asks rather than guesses.
    static func hasSensitiveField(in page: BrowserPage) async -> Bool {
        let result = await PageDriver.evaluateJSON(PageDriver.scripted(script), in: page)
        return result?["sensitive"] as? Bool ?? true
    }
}
