// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// A wrong `expectedRevision` relative to the head's current revision.
nonisolated enum StalePolicyRevision: CaseIterable, Sendable {
    case behind, ahead
    /// Sent twice with the revision the first (successful) update was based on.
    case replayed
}

struct VaultStorePolicyTests {
    private static let pair: Set<String> = ["https://a.example", "https://b.example"]

    private func withFixture(blockedOrigins: [String] = [], _ body: (VaultStoreFixture) async throws -> Void) async throws {
        try await VaultStoreFixture.with(
            accounts: [VaultFixtures.account(username: "ada", origin: "https://a.example"), VaultFixtures.account(username: "grace", origin: "https://b.example")],
            blockedOrigins: blockedOrigins,
            historyRows: 3,
            body
        )
    }

    @Test func policyRoundTripsThroughSnapshotAndUnlock() async throws {
        try await withFixture { f in
            let (store, access) = try await f.unlocked()
            let before = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(before.blockedPasswordOrigins.isEmpty)
            let headBefore = try f.headRevision(of: f.vaultID)
            #expect(before.revision == headBefore)
            let registryBefore = try f.storedRegistry()
            let rowsBefore = try f.recordAndJournalImage()

            let receipt = try await store.updatePasswordSavePolicy(
                vaultID: f.vaultID, Self.pair, expectedRevision: before.revision, using: access
            )

            #expect(receipt.revision == headBefore + 1)
            #expect(try f.headRevision(of: f.vaultID) == headBefore + 1)
            #expect(try f.storedRegistry().revision == registryBefore.revision + 1)
            #expect(try f.registryEntries(except: f.vaultID) == registryBefore.catalog.vaults.filter { $0.vaultID != f.vaultID })
            #expect(try f.recordAndJournalImage() == rowsBefore)
            let after = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(after.blockedPasswordOrigins == Self.pair)
            #expect(after.revision == headBefore + 1)
            #expect(after.stamps == before.stamps)
            #expect(Set(after.accounts.map(\.id)) == Set(before.accounts.map(\.id)))

            // A fresh store re-verifies the registry against the rewritten head and returns the same set.
            let (fresh, freshAccess) = try await f.reopenedStore(proving: f.proof)
            let reloaded = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            #expect(reloaded.blockedPasswordOrigins == Self.pair)
            #expect(reloaded.revision == headBefore + 1)

            // A later NON-policy head write on top of the policy write still leaves a registry a fresh unlock verifies.
            let second = VaultFixtures.proof(2)
            let added = try await fresh.addUnlock(vaultID: f.vaultID, second, using: freshAccess)
            #expect(added.revision == headBefore + 2)
            #expect(try f.storedRegistry().revision == registryBefore.revision + 2)
            let (again, againAccess) = try await f.reopenedStore(proving: second)
            let final = try await again.snapshot(vaultID: f.vaultID, using: againAccess)
            #expect(final.blockedPasswordOrigins == Self.pair)
            #expect(final.revision == headBefore + 2)
            #expect(try f.recordAndJournalImage() == rowsBefore)
        }
    }

    @Test func unchangedPolicyWritesNothing() async throws {
        try await withFixture(blockedOrigins: ["https://a.example", "https://b.example"]) { f in
            let (store, access) = try await f.unlocked()
            let revision = try f.headRevision(of: f.vaultID)
            let before = try f.headWriteImage()

            let receipt = try await store.updatePasswordSavePolicy(
                vaultID: f.vaultID, Self.pair, expectedRevision: revision, using: access
            )

            #expect(receipt.revision == revision)
            #expect(try f.headWriteImage() == before)
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).revision == revision)

            // Also after a real change: the same set again is a no-op at the new revision.
            let changed = try await store.updatePasswordSavePolicy(
                vaultID: f.vaultID, ["https://a.example"], expectedRevision: revision, using: access
            )
            #expect(changed.revision == revision + 1)
            let afterChange = try f.headWriteImage()
            let repeated = try await store.updatePasswordSavePolicy(
                vaultID: f.vaultID, ["https://a.example"], expectedRevision: revision + 1, using: access
            )
            #expect(repeated.revision == revision + 1)
            #expect(try f.headWriteImage() == afterChange)
        }
    }

    @Test(arguments: StalePolicyRevision.allCases)
    func stalePolicyUpdateIsRefused(_ staleness: StalePolicyRevision) async throws {
        try await withFixture { f in
            let (store, access) = try await f.unlocked()
            let revision = try f.headRevision(of: f.vaultID)
            let stale: UInt64
            switch staleness {
            case .behind:
                stale = revision - 1
            case .ahead:
                stale = revision + 1
            case .replayed:
                _ = try await store.updatePasswordSavePolicy(vaultID: f.vaultID, ["https://a.example"], expectedRevision: revision, using: access)
                stale = revision
            }
            let before = try f.headWriteImage()

            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await store.updatePasswordSavePolicy(vaultID: f.vaultID, Self.pair, expectedRevision: stale, using: access)
            }

            #expect(try f.headWriteImage() == before)
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(snapshot.blockedPasswordOrigins == (staleness == .replayed ? ["https://a.example"] : []))
        }
    }

    @Test func policyLimitsAreTheSourceLimits() async throws {
        try await withFixture { f in
            let (store, access) = try await f.unlocked()
            let revision = try f.headRevision(of: f.vaultID)
            func origins(_ count: Int) -> Set<String> {
                Set((1...count).map { "https://o\(String(format: "%04d", $0)).example" })
            }

            let full = origins(4_096)
            let receipt = try await store.updatePasswordSavePolicy(vaultID: f.vaultID, full, expectedRevision: revision, using: access)
            #expect(receipt.revision == revision + 1)
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).blockedPasswordOrigins == full)
            let (fresh, freshAccess) = try await f.reopenedStore(proving: f.proof)
            #expect(try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess).blockedPasswordOrigins == full)

            let accepted = try f.headWriteImage()
            await #expect(throws: CredentialStoreError.limit(.blockedOrigins)) {
                try await store.updatePasswordSavePolicy(vaultID: f.vaultID, origins(4_097), expectedRevision: revision + 1, using: access)
            }
            #expect(try f.headWriteImage() == accepted)
            await #expect(throws: CredentialStoreError.malformed) {
                try await store.updatePasswordSavePolicy(vaultID: f.vaultID, ["https://a.example/x"], expectedRevision: revision + 1, using: access)
            }
            #expect(try f.headWriteImage() == accepted)
            #expect(try f.headRevision(of: f.vaultID) == revision + 1)
        }
    }

    @Test func wrapperChangesPreservePolicy() async throws {
        try await withFixture(blockedOrigins: ["https://a.example", "https://b.example"]) { f in
            let (store, access) = try await f.unlocked()
            let second = VaultFixtures.proof(2)
            let revision = try f.headRevision(of: f.vaultID)

            _ = try await store.addUnlock(vaultID: f.vaultID, second, using: access)
            let afterAdd = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(afterAdd.blockedPasswordOrigins == Self.pair)
            #expect(afterAdd.revision == revision + 1)

            let secondAccess = f.beginAccess()
            try await f.grant(on: store, proof: second, access: secondAccess)
            _ = try await store.removeUnlock(
                vaultID: f.vaultID, credentialID: f.proof.credentialID, verifiedRemaining: second, using: secondAccess
            )
            let afterRemove = try await store.snapshot(vaultID: f.vaultID, using: secondAccess)
            #expect(afterRemove.blockedPasswordOrigins == Self.pair)
            #expect(afterRemove.revision == revision + 2)

            let (fresh, freshAccess) = try await f.reopenedStore(proving: second)
            #expect(try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess).blockedPasswordOrigins == Self.pair)
        }
    }
}
