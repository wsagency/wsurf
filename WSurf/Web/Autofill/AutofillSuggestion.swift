// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import WSurfVault

nonisolated struct AutofillSuggestion: Codable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let origin: String?
    let month: Int?
    let year: Int?

    init(_ candidate: AutofillSaveCandidate) {
        switch candidate {
        case .password(let login):
            id = login.id
            title = login.username.isEmpty ? login.origin : login.username
            detail = login.origin
            origin = login.origin
            month = nil; year = nil
        case .card(let card):
            id = card.id
            title = card.summary.label
            detail = card.cardholder
            origin = nil
            month = card.month; year = card.year
        case .contact(let contact):
            id = contact.id
            title = contact.title
            detail = AutofillContactValues(contact).rowDetail
            origin = nil
            month = nil; year = nil
        }
    }

    /// A card row of the vault (`AutofillCardRow`) as `.card` shows a card: its network and last four digits, and the name on it.
    init(id: UUID, card row: AutofillCardRow) {
        self.id = id
        title = "\(row.network?.name ?? String(localized: "Payment card")) •••• \(row.lastFour)"
        detail = row.cardholder
        origin = nil
        month = row.month; year = row.year
    }

    /// A contact row of the vault (`AutofillContactRow`) as `.contact` shows a contact.
    init(id: UUID, contact row: AutofillContactRow) {
        self.id = id
        title = row.title ?? String(localized: "Contact")
        detail = row.detail
        origin = nil
        month = nil; year = nil
    }

    var isExpired: Bool {
        guard let month, let year else { return false }
        let now = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: .now)
        guard let currentYear = now.year, let currentMonth = now.month else { return false }
        return year < currentYear || (year == currentYear && month < currentMonth)
    }
}
