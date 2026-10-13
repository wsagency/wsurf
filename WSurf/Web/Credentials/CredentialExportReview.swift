// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a re-read vault did to the parts the user chose for export. The export sheet applies it to the selection it
/// shows, so what the next click sends is exactly what the sheet then displays: a part that no longer exists is dropped
/// and named, a credential that changed keeps its still-valid parts and is named, and nothing is sent until the user clicks.
nonisolated struct CredentialExportReview: Sendable {
    var selection: [UUID: CredentialExportSelection]
    /// Titles of selected credentials that changed, as they are now.
    var changed: [String]
    /// Titles of selected credentials that are gone, as they were shown.
    var deleted: [String]

    var isEmpty: Bool {
        changed.isEmpty && deleted.isEmpty
    }

    /// `shown` is what the user saw when choosing; `fresh` is the vault now. Credentials nobody selected are not reported.
    static func reconcile(
        selection: [UUID: CredentialExportSelection],
        shown: [CredentialSummary],
        fresh: [CredentialSummary]
    ) -> Self {
        var result = Self(selection: [:], changed: [], deleted: [])
        for before in shown {
            guard let chosen = selection[before.id], chosen.hasParts else { continue }
            guard let now = fresh.first(where: { $0.id == before.id }) else {
                result.deleted.append(before.title)
                continue
            }
            var kept = chosen
            kept.password = chosen.password && now.hasLogin
            kept.totp = chosen.totp && now.hasTOTP
            kept.passkeyIDs = chosen.passkeyIDs.intersection(now.passkeys.map(\.id))
            let partsChanged = kept.password != chosen.password || kept.totp != chosen.totp
                || kept.passkeyIDs != chosen.passkeyIDs
            if partsChanged || now != before {
                result.changed.append(now.title)
            }
            if kept.hasParts {
                result.selection[before.id] = kept
            }
        }
        return result
    }
}

nonisolated extension CredentialExportSelection {
    var hasParts: Bool {
        password || totp || !passkeyIDs.isEmpty
    }
}
