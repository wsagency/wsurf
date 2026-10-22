// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The credentials that belong to one website, for the "By Site" view of the list. `site` is `nil` for the credentials that name no
/// website at all.
nonisolated struct SiteGroup: Equatable, Identifiable, Sendable {
    let site: String?
    /// The credentials' ids in the order the vault lists them.
    let ids: [UUID]

    /// A group id never collides with another group's: a website is never empty.
    var id: String {
        site ?? ""
    }
}

/// Groups a vault's credentials by the website they are for. Pure and secret-free: it reads only what a `CredentialSummary` carries.
nonisolated enum CredentialSiteGroups {
    /// A credential's site: the registrable domain of its first website, else of its first passkey's relying party, else `nil`.
    /// Sorted by site, with the credentials that have none last; each group keeps the vault's order. One pass over the summaries, and
    /// each host is resolved once however many credentials share it.
    static func groups(_ summaries: [CredentialSummary]) -> [SiteGroup] {
        var sites = ImportDuplicates.Sites()
        var bySite: [String: [UUID]] = [:]
        var withoutWebsite: [UUID] = []
        for summary in summaries {
            if let site = site(of: summary, &sites) {
                bySite[site, default: []].append(summary.id)
            } else {
                withoutWebsite.append(summary.id)
            }
        }
        let named = bySite.map { SiteGroup(site: $0.key, ids: $0.value) }.sorted { $0.id < $1.id }
        return withoutWebsite.isEmpty ? named : named + [SiteGroup(site: nil, ids: withoutWebsite)]
    }

    private static func site(of summary: CredentialSummary, _ sites: inout ImportDuplicates.Sites) -> String? {
        for origin in summary.origins {
            if let site = sites.site(ofOrigin: origin) {
                return site
            }
        }
        return summary.passkeys.first.map { sites.site(ofHost: $0.rpID) }
    }
}
