// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Observation
import WebKit

@MainActor
@Observable
final class PaymentCardAutofill {
    static let shared = PaymentCardAutofill()
    static let world = AutofillPage.world
    private static let handlerName = "wsurfCardAutofill"
    private(set) var profileID = Profile.originalID
    var isPrivate: Bool {
        profileID == Profile.privateID
    }

    func use(profileID: UUID) {
        self.profileID = profileID
        AutofillSuggestions.shared.reset()
    }
    func install(in page: BrowserPage) {
        page.installScript(AutofillFormScript.source + AutofillSuggestionScript.source, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(PaymentCardScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in
            guard let self, self.profileID == message.page.profileID else { return }
            AutofillSuggestions.shared.receive(message, kind: .card, profileID: self.profileID, world: Self.world, bridge: "__wsurfCardAutofill")
        }
    }
    static func isSecure(_ url: URL) -> Bool {
        SavedPassword.origin(for: url) != nil
    }
}
