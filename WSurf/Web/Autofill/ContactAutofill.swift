// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Observation
import WebKit

@MainActor
@Observable
final class ContactAutofill {
    static let shared = ContactAutofill()
    static let world = AutofillPage.world
    private static let handlerName = "wsurfContactAutofill"
    private(set) var profileID = Profile.originalID
    var isPrivate: Bool {
        profileID == Profile.privateID
    }

    func use(profile: Profile) {
        profileID = profile.id
        AutofillSuggestions.shared.reset()
    }
    func install(in page: BrowserPage) {
        page.installScript(AutofillFormScript.source + AutofillSuggestionScript.source, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(ContactAutofillScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in
            guard let self, self.profileID == message.page.profileID else { return }
            AutofillSuggestions.shared.receive(message, kind: .contact, profileID: self.profileID, world: Self.world, bridge: "__wsurfContactAutofill")
        }
    }
    static func isSecure(_ url: URL) -> Bool {
        SavedPassword.origin(for: url) != nil
    }
}
