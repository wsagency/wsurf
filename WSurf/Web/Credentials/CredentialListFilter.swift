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
    var withoutWebsite = 0

    init(_ summaries: [CredentialSummary]) {
        credentials = summaries.count
        for summary in summaries {
            logins += summary.hasLogin ? 1 : 0
            passkeys += summary.passkeys.count
            credentialsWithPasskeys += summary.passkeys.isEmpty ? 0 : 1
            codes += summary.hasTOTP ? 1 : 0
            notes += summary.hasNotes ? 1 : 0
            withoutWebsite += summary.origins.isEmpty ? 1 : 0
        }
    }
}
