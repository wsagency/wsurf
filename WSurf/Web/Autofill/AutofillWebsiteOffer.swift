// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension AutofillSaveSession {
    /// The page's website, to be added to a saved credential of a sibling website instead of saving a copy of that login. Identity
    /// only: no secret is held, and confirming reads the credential again under the unlock the offer was made under.
    nonisolated struct WebsiteOffer: Identifiable, Sendable {
        let id = UUID()
        /// The website to add: the page's origin.
        let origin: String
        let accountID: UUID
        /// What the dropdown calls the credential, and the username it must still have when the offer is confirmed.
        let name: String
        let username: String
        let managerEpoch: UInt64
        let documentID: String
        let liveOrigin: String
        let fingerprint: String
        /// The person picked this credential by hand for the page (Pick Credential…): it need not be a sibling's, and the popover asks
        /// whether to use it here.
        var isManual = false
        /// One of the credential's own websites that this page imitates (`WebsiteLookalike`), as the bar draws it: the popover warns
        /// and does not make adding the default.
        var lookalike: String?

        /// The website as the address bar draws it: punycode, no sign-in details (`offerWebsite` makes no offer without one).
        var host: String {
            WebsiteLookalike.displayHost(of: origin) ?? String(origin.dropFirst("https://".count))
        }
    }

    /// The credential the person last filled by hand here (Pick Credential…) for a website it is not saved for. Identity only. A
    /// submit of exactly its login is offered this website instead of a copy, until `deadline`.
    struct ManualPick {
        let accountID: UUID; let epoch: UInt64; let origin: String; let deadline: ContinuousClock.Instant
    }
}
