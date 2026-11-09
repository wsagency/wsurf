// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Which kind of entry the Vault tab shows: its sections. Pure and secret-free: it reads only what a `CredentialSummary` carries, so
/// searching and filtering never touch a snapshot. An entry that holds several kinds is listed under each.
nonisolated enum CredentialListFilter: CaseIterable, Hashable, Sendable {
    case all
    case logins
    case passkeys
    case codes
    /// Entries without a sign-in or a passkey that hold a person's name or an identity document.
    case identities
    case cards
    case addresses
    /// A person with an address: a name and an address in one entry.
    case contacts
    case notes
    /// Driver's licenses, passports and ID documents.
    case documents
    /// Wi-Fi networks, API and SSH keys, and custom fields.
    case otherItems
    /// Entries with attached files. Its chip shows while one does.
    case files
    /// Logins whose saved password the vault's health report finds weak (S4). Its chip shows while one is.
    case weak
    /// Logins whose saved password is also saved for another website (S4). Its chip shows while one is.
    case reused

    /// A narrower kind whose chip is shown only while some entry holds one. The sections (Logins, Identities, Cards, Addresses,
    /// Contacts, Notes) and Passkeys and Codes are always there.
    var hidesWhenEmpty: Bool {
        switch self {
        case .documents, .otherItems, .files, .weak, .reused:
            true
        case .all, .logins, .passkeys, .codes, .identities, .cards, .addresses, .contacts, .notes:
            false
        }
    }

    /// The chips the Vault tab shows, in order: every kind that is always there, and one that hides when empty while some entry holds
    /// one or while it is the filter in use. `counts` is nil while the vault is not open.
    static func chips(counts: [Self: Int]?, selected: Self) -> [Self] {
        allCases.filter { !$0.hidesWhenEmpty || $0 == selected || (counts?[$0] ?? 0) > 0 }
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
        case .identities:
            !summary.hasLogin && summary.passkeys.isEmpty && summary.itemKinds.contains(where: \.isIdentity)
        case .cards:
            summary.itemKinds.contains(.creditCard)
        case .addresses:
            summary.itemKinds.contains(.address)
        case .contacts:
            summary.itemKinds.contains(.personName) && summary.itemKinds.contains(.address)
        case .documents:
            summary.itemKinds.contains { $0 == .driversLicense || $0 == .passport || $0 == .identityDocument }
        case .otherItems:
            summary.itemKinds.contains { $0 == .wifi || $0 == .apiKey || $0 == .sshKey || $0 == .customFields }
        case .files:
            summary.fileCount > 0
        case .weak:
            summary.health?.weaknesses.isEmpty == false
        case .reused:
            summary.health?.reuse != nil
        }
    }

    /// The credentials of this kind whose title, username (unless concealed) or website holds `query`, in their order. An empty
    /// query matches every credential. One pass over the summaries' precomputed keys; never call it from a view body.
    static func visible(_ summaries: [CredentialSummary], query: String, filter: Self) -> [CredentialSummary] {
        let needle = needle(query)
        if needle.isEmpty, filter == .all {
            return summaries
        }
        return summaries.filter { filter.includes($0) && (needle.isEmpty || $0.searchKey.contains(needle)) }
    }

    /// Where the credentials `visible` returns are in `summaries`: the same pass, as positions, which compare far more cheaply than
    /// the summaries do.
    static func visibleIndices(_ summaries: [CredentialSummary], query: String, filter: Self) -> [Int] {
        let needle = needle(query)
        if needle.isEmpty, filter == .all {
            return Array(summaries.indices)
        }
        return summaries.indices.filter { filter.includes(summaries[$0]) && (needle.isEmpty || summaries[$0].searchKey.contains(needle)) }
    }

    private static func needle(_ query: String) -> String {
        CredentialSummary.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
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
