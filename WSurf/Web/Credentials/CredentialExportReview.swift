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
    /// The stamps are the vault's own per-account version and digest, so a secret-only change, which no summary shows,
    /// still counts as changed. `freshStamps` is nil when the page cannot vouch for them (after its own write); the summaries
    /// alone decide then, and the next fresh stamps are compared against `shownStamps`, which are kept from the last known read.
    static func reconcile(
        selection: [UUID: CredentialExportSelection],
        shown: [CredentialSummary],
        fresh: [CredentialSummary],
        shownStamps: [UUID: AccountStamp],
        freshStamps: [UUID: AccountStamp]?
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
            kept.notes = chosen.notes && now.hasNotes
            kept.passkeyIDs = chosen.passkeyIDs.intersection(now.passkeys.map(\.id))
            let partsChanged = kept.password != chosen.password || kept.totp != chosen.totp
                || kept.notes != chosen.notes || kept.passkeyIDs != chosen.passkeyIDs
            let stampChanged = freshStamps.map { $0[before.id] != shownStamps[before.id] } ?? false
            if partsChanged || now != before || stampChanged {
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
        password || totp || notes || !passkeyIDs.isEmpty
    }
}

// MARK: - A credential as one unit

nonisolated extension CredentialExportSelection {
    /// Everything of `summary` the export can carry: its login, every passkey, its code setup and its notes. A CSV file carries only a
    /// login and its notes.
    init(allOf summary: CredentialSummary, csv: Bool = false) {
        self.init(
            accountID: summary.id,
            password: summary.hasLogin,
            passkeyIDs: csv ? [] : Set(summary.passkeys.map(\.id)),
            totp: !csv && summary.hasTOTP,
            notes: summary.hasNotes
        )
    }

    /// How many of the parts `summary` offers for this export are selected, and how many it offers.
    func parts(of summary: CredentialSummary, csv: Bool = false) -> (selected: Int, offered: Int) {
        let offered = Self(allOf: summary, csv: csv)
        let selected = Self(
            accountID: summary.id, password: password && offered.password, passkeyIDs: passkeyIDs.intersection(offered.passkeyIDs),
            totp: totp && offered.totp, notes: notes && offered.notes
        )
        func count(_ selection: Self) -> Int {
            [selection.password, selection.totp, selection.notes].filter { $0 }.count + selection.passkeyIDs.count
        }
        return (count(selected), count(offered))
    }

    /// `selection` with every credential of `summaries` selected whole (`on`) or not selected at all.
    static func setting(
        _ on: Bool, for summaries: [CredentialSummary], csv: Bool = false, in selection: [UUID: CredentialExportSelection]
    ) -> [UUID: CredentialExportSelection] {
        var result = selection
        for summary in summaries {
            result[summary.id] = on ? Self(allOf: summary, csv: csv) : nil
        }
        return result
    }
}
