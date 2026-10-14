// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// A live account row read back from the file and opened under the held DEK.
nonisolated struct CommitLiveRow {
    let account: CredentialAccount
    let version: UInt64
    let plaintext: Data
}

/// Read-back helpers over one `VaultStoreFixture` for the commit suites: everything is read from the file, never from the
/// engine under test.
nonisolated struct CommitProbe {
    let f: VaultStoreFixture

    func recordKey(_ vault: UUID, _ recordID: UUID) -> String {
        "record/\(vault.lowerText)/\(recordID.lowerText)"
    }

    /// The stored row and its plaintext, opened with the vault's own key and the row's own identity as AAD.
    func opened(_ vault: UUID, _ recordID: UUID) throws -> (row: StoreTables.RecordRow, plaintext: Data) {
        let row = try f.storedRecord(vault, recordID)
        let aad = RowAAD(
            ids: f.ids, vaultID: vault, recordID: recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject, version: row.version
        )
        return (row, try StoreSeal.openRow(row.sealed, key: f.key(of: vault), aad: aad))
    }

    func liveRow(_ id: UUID) throws -> CommitLiveRow {
        let stored = try opened(f.vaultID, id)
        return CommitLiveRow(
            account: try JSONDecoder().decode(CredentialAccount.self, from: stored.plaintext),
            version: stored.row.version,
            plaintext: stored.plaintext
        )
    }

    /// The heads as stored now, opened with the real `StoreSeal.openHead` (the fixture's own copies are from build time).
    func heads() throws -> (source: VaultHead, trash: VaultHead) {
        try f.read { try f.openStoredHeads(in: $0) }
    }

    /// Keys of every `record`/`journal` row that was added, removed or rewritten since `before`.
    func rowsChanged(since before: [String: Data]) throws -> Set<String> {
        let after = try f.recordAndJournalImage()
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// The stored registry is MAC-valid under the registry key and equals the catalog a correct writer derives from the rows
    /// and heads now on disk (every vault's entry carries its head's revision and digest).
    func expectRegistryMatchesStore(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let stored = try #require(try f.read { try StoreTables.registry($0) }, sourceLocation: sourceLocation)
        #expect(stored.mac == StoreSeal.registryMAC(rk: f.registryKey, catalog: stored.catalog), sourceLocation: sourceLocation)
        let catalog = try RegistryCatalog.decode(stored.catalog)
        let rebuilt = try f.rebuiltRegistry(revision: stored.revision)
        #expect(catalog.revision == stored.revision, sourceLocation: sourceLocation)
        #expect(catalog == rebuilt, sourceLocation: sourceLocation)
    }

    /// Every row of `vault` (records and journal) keyed as in `recordAndJournalImage`.
    func rows(of vault: UUID) throws -> [String: Data] {
        try f.recordAndJournalImage().filter { $0.key.contains("/\(vault.lowerText)/") }
    }
}

nonisolated extension VaultStoreFixture {
    /// An access on this fixture's profile that no unlock ever granted when its `epoch` is new to the store.
    func makeAccess(epoch: UInt64, profileID: UUID? = nil) -> VaultAccess {
        VaultAccess(profileID: profileID ?? env.profileID, epoch: epoch, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
    }
}

extension ProfileVaultStore {
    /// The error `commit` throws, or nil when it returned.
    func vaultCommitFailure(
        vaultID: UUID, _ accounts: [CredentialAccount], expectedRevision: UInt64, using access: VaultAccess
    ) async -> (any Error)? {
        do {
            _ = try await commit(vaultID: vaultID, accounts, expectedRevision: expectedRevision, cause: nil, using: access)
            return nil
        } catch {
            return error
        }
    }
}

/// `accounts` with the one whose id is `id` changed by `change` (the account must be present).
nonisolated func commitEditing(_ accounts: [CredentialAccount], _ id: UUID, _ change: (inout CredentialAccount) -> Void) -> [CredentialAccount] {
    var edited = accounts
    guard let index = edited.firstIndex(where: { $0.id == id }) else {
        Issue.record("no account \(id) to edit")
        return accounts
    }
    change(&edited[index])
    return edited
}
