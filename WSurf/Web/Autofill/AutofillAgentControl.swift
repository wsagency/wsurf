// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// No autofill offer in a tab an agent controls: while the assistant works there or a connected app is in a call on it or holds it
/// (`BrowserTab.isAgentControlled`, the predicate Pick Credential… uses too), the dropdown opens for no field of any frame, a fill
/// under way is refused at its dispatch (`requireAuthority`), and nothing is staged or offered for saving
/// (`AutofillSaveSession.isAgentControlled`). An agent could otherwise open the dropdown, pick a row and read the field back.
extension AutofillSuggestions {
    /// Whether the tab of `page` is controlled by an agent now, as its save session reports it. A page with no session of its own
    /// is not known to be the person's, so it counts as controlled.
    static func isAgentControlled(_ page: BrowserPage) -> Bool {
        AutofillSaveCoordinator.shared.session(for: page)?.isAgentControlled() ?? true
    }

    /// The origin a `select` from a frame may be offered suggestions for, before anything is read or shown: the feature on, a secure
    /// page, the frame's own verified HTTPS origin (`BrowserFrame.autofillOrigin`) and no agent controlling the tab. Nil: no dropdown.
    static func offerOrigin(for message: BrowserScriptMessage, kind: AutofillSaveKind) -> String? {
        let page = message.page
        guard let body = message.body as? [String: Any], let rawURL = body["url"] as? String, let frameURL = URL(string: rawURL) else {
            return nil
        }
        let origin = message.frameInfo.autofillOrigin(reportedURL: frameURL)
        let enabled = AutofillSaveCoordinator.shared.isEnabled(kind, context: page.context)
        let topIsSecure = page.url.flatMap(SavedPassword.origin(for:)) != nil
        let refusal = AutofillDiagnostics.offerRefusal(
            enabled: enabled, topIsSecure: topIsSecure, hasOnlySecureContent: page.hasOnlySecureContent,
            agentControlled: isAgentControlled(page), frameOriginTrusted: origin != nil
        )
        if let refusal {
            AutofillDiagnostics.refused(refusal, by: page)
            return nil
        }
        return origin
    }
}
