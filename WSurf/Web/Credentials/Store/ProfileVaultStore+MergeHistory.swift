// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A History row a merge writes for its survivor: the owner and subject it is filed under, and its body (date, cause and value).
nonisolated struct CarriedRevision {
    let ownerID: UUID
    let subject: RecordSubject
    let body: RevisionBody
}

/// Merge (§11.2): no password and no verification code of a credential merged away is lost from the credential that stays.
nonisolated extension CommitTransaction {
    /// The History rows a merge adds to its survivors, read before the MOVE takes the absorbed accounts to the Trash. For each
    /// absorbed account (`merging` maps it to its survivor): a copy of every earlier password and code version it owns, oldest
    /// first, with the original date and cause, then its current login and code (cause `mergedFrom`). A password the survivor
    /// already holds (live, in its History, superseded by this commit, or carried from another absorbed account) is not added
    /// again, nor is a login without a password, nor a code with the same secret, algorithm, period and digits. The plan must remove
    /// each absorbed account whole and keep its survivor live, else `invalidData` with nothing written.
    func carriedRevisions(
        _ merging: [UUID: UUID], plan: CredentialChangePlan, proposed: [CredentialAccount]
    ) throws -> [CarriedRevision] {
        guard !merging.isEmpty else { return [] }
        var live: [UUID: CredentialAccount] = [:]
        for account in proposed {
            live[account.id] = account
        }
        var held: [UUID: Set<Data>] = [:]
        var carried: [CarriedRevision] = []
        // A fixed order, so the same merge always writes the same rows. Each absorbed account's current values get their own time
        // (a millisecond apart): History makes one version of adjacent rows with the same time and cause, so two accounts' values
        // never show as one credential.
        for (index, (absorbedID, survivorID)) in merging.sorted(by: { $0.key.uuidString < $1.key.uuidString }).enumerated() {
            guard absorbedID != survivorID, plan.removals.contains(.account(absorbedID)), let survivor = live[survivorID],
                  let absorbed = previous[absorbedID] else { throw CredentialVaultError.invalidData }
            if held[survivorID] == nil {
                held[survivorID] = try heldKeys(of: survivor, plan: plan)
            }
            let earlier = try ownedRevisions(of: absorbedID).sorted { $0.body.recordedAt < $1.body.recordedAt }
            let mergedAt = wall.addingTimeInterval(Double(index) * 0.001)
            let current = try Self.currentValues(of: absorbed).map { subject, value in
                CarriedRevision(
                    ownerID: absorbedID, subject: subject, body: RevisionBody(recordedAt: mergedAt, cause: CredentialChangeCause.mergedFrom, value: value)
                )
            }
            // The current values win a tie with an earlier version of the same value, but are written last, so History lists them first.
            var kept: [(row: CarriedRevision, isCurrent: Bool)] = []
            for (row, isCurrent) in current.map({ ($0, true) }) + earlier.map({ ($0, false) }) {
                guard let key = Self.mergeKey(row.subject, row.body.value), held[survivorID, default: []].insert(key).inserted else {
                    continue
                }
                kept.append((CarriedRevision(ownerID: survivorID, subject: row.subject, body: row.body), isCurrent))
            }
            carried += kept.filter { !$0.isCurrent }.map { $0.row } + kept.filter { $0.isCurrent }.map { $0.row }
        }
        return carried
    }

    /// The passwords and codes `survivor` already has: live in the proposal, in its stored History, or superseded by this commit.
    private func heldKeys(of survivor: CredentialAccount, plan: CredentialChangePlan) throws -> Set<Data> {
        var values = try Self.currentValues(of: survivor)
        values += try ownedRevisions(of: survivor.id).map { ($0.subject, $0.body.value) }
        values += plan.revisions.filter { $0.ownerID == survivor.id }.map { ($0.subject, $0.superseded) }
        return Set(values.compactMap { Self.mergeKey($0.0, $0.1) })
    }

    /// The account's own login and code, as the History stores them.
    private static func currentValues(of account: CredentialAccount) throws -> [(RecordSubject, Data)] {
        var values: [(RecordSubject, Data)] = []
        if account.password != nil {
            let login = PasswordValue(
                username: account.username, password: account.password, basicAuthenticationMetadata: account.basicAuthenticationMetadata
            )
            values.append((.password, try CredentialContent.canonicalJSON(login)))
        }
        if let totp = account.totp {
            values.append((.totp, try CredentialContent.canonicalJSON(totp)))
        }
        return values
    }

    /// The password and code revision rows `ownerID` owns in this vault, opened. Read after `verifyHistories`, like a MOVE's rows.
    private func ownedRevisions(of ownerID: UUID) throws -> [CarriedRevision] {
        var rows: [CarriedRevision] = []
        for subject in [RecordSubject.password, .totp] {
            var after: UUID?
            while let row = try mapIntegrity(grant.ordinal, {
                try StoreTables.nextOwnedRevision(db, vaultID: source.vaultID, ownerID: ownerID, subject: subject, after: after)
            }) {
                try Task.checkCancellation()
                after = row.recordID
                let body = try mapIntegrity(grant.ordinal) {
                    try JSONDecoder().decode(RevisionBody.self, from: row.opened(key: source.key, ids: ids))
                }
                rows.append(CarriedRevision(ownerID: ownerID, subject: row.subject, body: body))
            }
        }
        return rows
    }

    /// What makes two History values the same to a merge: a password's bytes, or a code's secret and settings. `nil` for a login
    /// without a password, which holds nothing the merged credential would miss. A value that does not decode is kept by its bytes:
    /// it is copied rather than lost, and it never blocks the merge.
    private static func mergeKey(_ subject: RecordSubject, _ value: Data) -> Data? {
        switch subject {
        case .password:
            guard let login = try? JSONDecoder().decode(PasswordValue.self, from: value) else { return Data("r".utf8) + value }
            return login.password.map { Data("p".utf8) + Data($0.utf8) }
        case .totp:
            guard let code = try? JSONDecoder().decode(TOTPGenerator.self, from: value) else { return Data("r".utf8) + value }
            return Data("t\(code.algorithm.rawValue)/\(code.period)/\(code.digits)/".utf8) + code.secret
        case .account, .passkey, .metadata, .note, .secureItem, .attachment:
            return nil
        }
    }
}
