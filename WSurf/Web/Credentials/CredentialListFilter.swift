// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which kind of credential the list shows. Pure and secret-free: it reads only what a `CredentialSummary` carries, so searching and
/// filtering never touch a snapshot. A credential that holds several kinds is listed under each.
nonisolated enum CredentialListFilter: CaseIterable, Hashable, Sendable {
    case all
    case logins
    case passkeys
    case codes
    case notes
    case cards
    /// Addresses and names.
    case addresses
    /// Driver's licenses, passports and ID documents.
    case documents
    /// Wi-Fi networks, API and SSH keys, and custom fields.
    case otherItems

    /// A kind of item rather than a part every login can have: its chip is shown only while some credential holds one.
    var isItemKind: Bool {
        switch self {
        case .cards, .addresses, .documents, .otherItems:
            true
        case .all, .logins, .passkeys, .codes, .notes:
            false
        }
    }

    func includes(_ summary: CredentialSummary) -> Bool {
        switch self {
        case .all:
            true
        case .logins:
            summary.hasLogin
        case .passkeys:
            !summary.passkeys.isEmpty
        case .codes:
            summary.hasTOTP
        case .notes:
            summary.hasNotes
        case .cards:
            summary.itemKinds.contains(.creditCard)
        case .addresses:
            summary.itemKinds.contains { $0 == .address || $0 == .personName }
        case .documents:
            summary.itemKinds.contains { $0 == .driversLicense || $0 == .passport || $0 == .identityDocument }
        case .otherItems:
            summary.itemKinds.contains { $0 == .wifi || $0 == .apiKey || $0 == .sshKey || $0 == .customFields }
        }
    }

    /// The credentials of this kind whose title, username (unless concealed) or website holds `query`, in their order. An empty
    /// query matches every credential. One pass over the summaries' precomputed keys; never call it from a view body.
    static func visible(_ summaries: [CredentialSummary], query: String, filter: Self) -> [CredentialSummary] {
        let needle = CredentialSummary.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if needle.isEmpty, filter == .all {
            return summaries
        }
        return summaries.filter { filter.includes($0) && (needle.isEmpty || $0.searchKey.contains(needle)) }
    }

    /// How many credentials each kind holds, in one pass. A kind nobody holds is 0.
    static func counts(_ summaries: [CredentialSummary]) -> [Self: Int] {
        var counts = Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        for summary in summaries {
            for kind in allCases where kind.includes(summary) {
                counts[kind, default: 0] += 1
            }
        }
        return counts
    }
}

/// How many of each kind a vault holds, from the same summaries the list shows.
nonisolated struct CredentialStatistics: Equatable, Sendable {
    var credentials = 0
    var logins = 0
    /// Every passkey, not the credentials that hold one.
    var passkeys = 0
    var credentialsWithPasskeys = 0
    var codes = 0
    /// Credentials that hold notes, as the Notes filter counts them.
    var notes = 0
    /// Credentials that hold cards, addresses or other items.
    var items = 0
    var withoutWebsite = 0

    init(_ summaries: [CredentialSummary]) {
        credentials = summaries.count
        for summary in summaries {
            logins += summary.hasLogin ? 1 : 0
            passkeys += summary.passkeys.count
            credentialsWithPasskeys += summary.passkeys.isEmpty ? 0 : 1
            codes += summary.hasTOTP ? 1 : 0
            notes += summary.hasNotes ? 1 : 0
            items += summary.itemKinds.isEmpty ? 0 : 1
            withoutWebsite += summary.origins.isEmpty ? 1 : 0
        }
    }
}
