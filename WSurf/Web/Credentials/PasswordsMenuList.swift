// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// What the menu bar popover lists, from the summaries of the selected vault. Pure and secret-free: it reads only what a
/// `CredentialSummary` carries (never a password, a code or a note), and it runs outside the view body, once per query or revision.
nonisolated enum PasswordsMenuList {
    /// How many rows the popover draws. The vault allows 25,000 accounts; the rest is one "Show All in Passwords" away.
    static let limit = 50

    nonisolated struct Sections: Equatable, Sendable {
        /// Credentials of the front tab's website, best first.
        var matching: [CredentialSummary] = []
        /// The others, most recently changed first.
        var recent: [CredentialSummary] = []
        /// How many more credentials the query matches than the rows drawn.
        var more = 0

        static let empty = Sections()

        var rows: [CredentialSummary] {
            matching + recent
        }
    }

    /// The tab of the front browser window, as far as "Matching This Website" needs to know it.
    nonisolated struct FrontTab: Equatable, Sendable {
        let url: URL?
        let profileID: UUID
        let isPrivate: Bool
    }

    /// The origin "Matching This Website" follows: the front tab's HTTPS origin, only when its window shows the profile the popover
    /// shows and is not private. Another profile's tab and a private one are never matched against this vault.
    static func origin(of front: FrontTab?, shown profileID: UUID) -> String? {
        guard let front, !front.isPrivate, front.profileID == profileID, let url = front.url else { return nil }
        return CredentialAccountSelection.origin(for: url)
    }

    /// The credentials that match `query`, split into those of `origin` (the origin of the front tab, `CredentialAccountSelection.origin`;
    /// nil for none) and the rest by `updated ?? added`, newest first, with an unknown date last. At most `limit` rows, the matching
    /// ones first. The search reads only each summary's precomputed key, so a concealed username is never searched.
    static func sections(summaries: [CredentialSummary], query: String, origin: String?, limit: Int = limit) -> Sections {
        let found = CredentialListFilter.visible(summaries, query: query, filter: .all)
        var matching: [CredentialSummary] = []
        var others: [CredentialSummary] = []
        for summary in found {
            if let origin, summary.origins.contains(origin) {
                matching.append(summary)
            } else {
                others.append(summary)
            }
        }
        // `sorted` is not stable: the id breaks a tie, so two rows with one date never swap between two keystrokes.
        let recent = others.sorted { lhs, rhs in
            let (left, right) = (lhs.changed, rhs.changed)
            if left != right {
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let shownMatching = Array(matching.prefix(limit))
        let shownRecent = Array(recent.prefix(max(limit - shownMatching.count, 0)))
        return Sections(
            matching: shownMatching, recent: shownRecent, more: matching.count + recent.count - shownMatching.count - shownRecent.count
        )
    }
}

/// What a row of the popover offers, in order, by the same rules as the credentials page's row menu (`CredentialRowMoreItem`). Pure,
/// so which entries a row offers is tested without a view. Showing a password or a code is not among them: the popover only copies.
nonisolated enum PasswordsMenuAction: Equatable, Sendable {
    case copyUsername
    case copyPassword
    case copyCode
    case openWebsite

    static func offered(for summary: CredentialSummary) -> [Self] {
        var actions: [Self] = []
        if summary.usernameIsConcealed || summary.username != nil {
            actions.append(.copyUsername)
        }
        if summary.hasPassword {
            actions.append(.copyPassword)
        }
        if summary.hasTOTP {
            actions.append(.copyCode)
        }
        if summary.website != nil {
            actions.append(.openWebsite)
        }
        return actions
    }

    /// What Return does on a selected row: copy its password, else its username.
    static func primary(for summary: CredentialSummary) -> Self? {
        let actions = offered(for: summary)
        return actions.contains(.copyPassword) ? .copyPassword : actions.first { $0 == .copyUsername }
    }

    var title: String {
        switch self {
        case .copyUsername:
            String(localized: "Copy Username")
        case .copyPassword:
            String(localized: "Copy Password")
        case .copyCode:
            String(localized: "Copy Verification Code")
        case .openWebsite:
            String(localized: "Open Website")
        }
    }
}

nonisolated extension CredentialSummary {
    /// The last change, else when it was added; nil when neither is known.
    var changed: Date? {
        dates.updated ?? dates.added?.date
    }
}

/// What the popover draws, decided by the model's own `presentation` (a session the manager's current authorization backs).
enum PasswordsMenuPhase: Equatable {
    /// Private Browsing and removed profiles keep no vault.
    case unavailable
    case opening
    case locked
    case content
}

extension CredentialSettingsModel {
    var menuPhase: PasswordsMenuPhase {
        guard isAvailable else { return .unavailable }
        switch presentation {
        case .content:
            return .content
        case .opening:
            return .opening
        case .locked:
            return .locked
        }
    }

    /// What the popover may list: the sections while the vault is unlocked and read, and nil otherwise. The one gate of the popover's
    /// list: a locked, opening or unavailable vault yields nil, so no title, username or website is ever drawn from it.
    func menuSections(query: String, origin: String?) -> PasswordsMenuList.Sections? {
        guard menuPhase == .content else { return nil }
        return PasswordsMenuList.sections(summaries: summaries, query: query, origin: origin)
    }
}
