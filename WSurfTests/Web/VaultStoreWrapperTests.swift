// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

// MARK: - Helpers shared with VaultStorePolicyTests

nonisolated extension VaultStoreFixture {
    /// Every byte a head write may or may not change, read back from the file: both head rows, the registry row, the source
    /// vault's wrapper list and every `record`/`journal` row.
    func headWriteImage() throws -> [String: Data] {
        var image = try recordAndJournalImage()
        let stored = try read { db in
            (
                try [vaultID, trashID].map { ($0, try StoreTables.head(db, vaultID: $0)) },
                try StoreTables.registry(db)
            )
        }
        for (vault, head) in stored.0 {
            image["~head.\(vault)"] = head.map { Data(String($0.revision).utf8) + $0.sealed }
        }
        image["~registry"] = stored.1.map { Data(String($0.revision).utf8) + $0.catalog + $0.mac }
        image["~wrappers"] = try storedWrappersBytes(of: vaultID)
        return image
    }

    func registryEntry(of vault: UUID) throws -> RegistryEntry {
        try #require(try storedRegistry().catalog.vaults.first { $0.vaultID == vault })
    }

    /// Registry entries of every vault but `vault`: a head write on `vault` must leave them alone.
    func registryEntries(except vault: UUID) throws -> [RegistryEntry] {
        try storedRegistry().catalog.vaults.filter { $0.vaultID != vault }
    }
}

extension VaultStoreFixture {
    /// A FRESH store on the same files, unlocked with `proof`: the registry, head and wrapper digests are re-verified from disk.
    func reopenedStore(proving proof: VaultUnlockProof) async throws -> (ProfileVaultStore, VaultAccess) {
        let store = makeStore()
        let access = beginAccess()
        try await grant(on: store, proof: proof, access: access)
        return (store, access)
    }

    func grant(on store: ProfileVaultStore, proof: VaultUnlockProof, access: VaultAccess) async throws {
        try await store.unlockInitialized(
            vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, access: access, verifying: nil, scratchWarning: nil
        )
    }
}

nonisolated enum WrapperAccessFault: CaseIterable, Sendable {
    /// Another profile's access.
    case foreignProfile
    /// The granted access, revoked.
    case revoked
    /// The granted access, once the store's clock has passed its deadline.
    case lapsed
}

/// A controllable clock injected through `makeStore(now:)`; accesses built against `base` expire when `advance` passes them.
nonisolated final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    let base = ContinuousClock().now
    private var elapsed: Duration = .zero

    func now() -> ContinuousClock.Instant {
        lock.withLock { base.advanced(by: elapsed) }
    }

    func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }
}

// MARK: - Tests

struct VaultStoreWrapperTests {
    private static let accountOrigin = "https://a.example"

    private func withFixture(_ body: (VaultStoreFixture) async throws -> Void) async throws {
        try await VaultStoreFixture.with(
            accounts: [VaultFixtures.account(username: "ada", origin: Self.accountOrigin), VaultFixtures.account(username: "grace", origin: "https://b.example")],
            blockedOrigins: ["https://a.example", "https://b.example"],
            historyRows: 3,
            body
        )
    }

    @Test func addUnlockRewritesWrappersHeadAndRegistryOnly() async throws {
        try await withFixture { f in
            let (store, access) = try await f.unlocked()
            let headBefore = try f.headRevision(of: f.vaultID)
            let trashHeadBefore = try f.headRevision(of: f.trashID)
            let registryBefore = try f.storedRegistry()
            let rowsBefore = try f.recordAndJournalImage()
            let wrappersBefore = try f.storedWrappersBytes(of: f.vaultID)
            let second = VaultFixtures.proof(2)

            let receipt = try await store.addUnlock(vaultID: f.vaultID, second, using: access)

            #expect(receipt.revision == headBefore + 1)
            #expect(try f.headRevision(of: f.vaultID) == headBefore + 1)
            #expect(try f.headRevision(of: f.trashID) == trashHeadBefore)
            let registryAfter = try f.storedRegistry()
            #expect(registryAfter.revision == registryBefore.revision + 1)
            #expect(registryAfter.mac != registryBefore.mac)
            #expect(try f.registryEntries(except: f.vaultID) == registryBefore.catalog.vaults.filter { $0.vaultID != f.vaultID })
            #expect(try f.registryEntry(of: f.vaultID).headRevision == headBefore + 1)
            #expect(try f.recordAndJournalImage() == rowsBefore)

            let wrappersAfter = try f.storedWrappersBytes(of: f.vaultID)
            #expect(wrappersAfter != wrappersBefore)
            #expect(try f.wrapperRows(of: f.vaultID).map(\.credentialID) == [f.proof.credentialID, second.credentialID])
            #expect(try f.registryEntry(of: f.vaultID).wrappersDigest == Data(SHA256.hash(data: wrappersAfter)))

            // The session that wrote keeps working and sees the new head revision.
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).revision == headBefore + 1)
            #expect(try await store.discovery(vaultID: f.vaultID).unlocks.map(\.credentialID) == [f.proof.credentialID, second.credentialID])

            // Fresh stores re-verify registry, head and wrapper digests from disk: the new proof and the old one both open the vault.
            for proof in [second, f.proof] {
                let (fresh, freshAccess) = try await f.reopenedStore(proving: proof)
                let snapshot = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
                #expect(snapshot.revision == headBefore + 1)
                #expect(Set(snapshot.accounts.map(\.id)) == Set(f.accounts.map(\.id)))
                let listing = try await fresh.listing()
                #expect(listing.map(\.vaultID) == [f.vaultID])
                #expect(listing.first?.isUnlocked == true)
                #expect(listing.first?.name == "Personal")
            }
        }
    }

    @Test func removeUnlockStopsOpeningSourceAndTrash() async throws {
        try await withFixture { f in
            let (store, accessA) = try await f.unlocked()  // credential A, the one about to be removed
            let remaining = VaultFixtures.proof(2)  // credential B
            _ = try await store.addUnlock(vaultID: f.vaultID, remaining, using: accessA)
            #expect(try await store.snapshot(vaultID: f.vaultID, using: accessA).accounts.count == f.accounts.count)  // A is authorized before
            let headBefore = try f.headRevision(of: f.vaultID)
            let registryBefore = try f.storedRegistry()
            let rowsBefore = try f.recordAndJournalImage()

            let receipt = try await store.removeUnlock(
                vaultID: f.vaultID, credentialID: f.proof.credentialID, verifiedRemaining: remaining, using: accessA
            )

            #expect(receipt.revision == headBefore + 1)
            #expect(try f.headRevision(of: f.vaultID) == headBefore + 1)
            #expect(try f.storedRegistry().revision == registryBefore.revision + 1)
            #expect(try f.registryEntries(except: f.vaultID) == registryBefore.catalog.vaults.filter { $0.vaultID != f.vaultID })
            #expect(try f.recordAndJournalImage() == rowsBefore)
            #expect(try f.wrapperRows(of: f.vaultID).map(\.credentialID) == [remaining.credentialID])
            #expect(try f.registryEntry(of: f.vaultID).wrappersDigest == Data(SHA256.hash(data: try f.storedWrappersBytes(of: f.vaultID))))
            #expect(try await store.discovery(vaultID: f.vaultID).unlocks.map(\.credentialID) == [remaining.credentialID])

            // The access the removed credential held is revoked.
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await store.snapshot(vaultID: f.vaultID, using: accessA) }
            #expect(throws: CredentialVaultError.unauthorized) { try accessA.checkAuthorization(at: ContinuousClock().now) }

            // The removed credential no longer unlocks, on the same store or a fresh one.
            for candidate in [store, f.makeStore()] {
                let attempt = f.beginAccess()
                await #expect(throws: CredentialVaultError.authenticationFailed) { try await f.grant(on: candidate, proof: f.proof, access: attempt) }
                await #expect(throws: CredentialVaultError.unauthorized) { _ = try await candidate.snapshot(vaultID: f.vaultID, using: attempt) }
            }

            // The remaining credential opens the vault AND its linked Trash: unlock verifies the pair from disk.
            let (fresh, freshAccess) = try await f.reopenedStore(proving: remaining)
            let snapshot = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            #expect(snapshot.revision == headBefore + 1)
            #expect(Set(snapshot.accounts.map(\.id)) == Set(f.accounts.map(\.id)))
        }
    }

    @Test func wrapperCapIs32() async throws {
        try await withFixture { f in
            let (store, access) = try await f.unlocked()
            let headStart = try f.headRevision(of: f.vaultID)
            var proofs = [f.proof]
            for number in 2...32 {
                let proof = VaultFixtures.proof(UInt8(number))
                let receipt = try await store.addUnlock(vaultID: f.vaultID, proof, using: access)
                proofs.append(proof)
                #expect(receipt.revision == headStart + UInt64(number - 1))
            }
            #expect(try f.wrapperRows(of: f.vaultID).count == 32)
            let before = try f.headWriteImage()

            let overflow = VaultFixtures.proof(33)
            await #expect(throws: CredentialStoreError.limit(.wrappers)) {
                try await store.addUnlock(vaultID: f.vaultID, overflow, using: access)
            }

            #expect(try f.headWriteImage() == before)
            #expect(try f.wrapperRows(of: f.vaultID).map(\.credentialID) == proofs.map(\.credentialID))
            #expect(try f.headRevision(of: f.vaultID) == headStart + 31)
            // Every one of the 32 wrappers is real: the last-added opens the vault on a fresh store.
            let (fresh, freshAccess) = try await f.reopenedStore(proving: proofs[31])
            #expect(try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess).revision == headStart + 31)
        }
    }

    @Test(arguments: WrapperAccessFault.allCases)
    func staleOrForeignAccessCannotChangeWrappers(_ fault: WrapperAccessFault) async throws {
        try await withFixture { f in
            let clock = ManualClock()
            let store = f.makeStore(now: { clock.now() })
            let access = VaultAccess(profileID: f.env.profileID, epoch: 1, deadline: clock.base.advanced(by: .seconds(300)))
            try await f.grant(on: store, proof: f.proof, access: access)
            let enrolled = VaultFixtures.proof(2)
            _ = try await store.addUnlock(vaultID: f.vaultID, enrolled, using: access)  // gives removeUnlock something it could remove
            // The access is good before the fault: a read succeeds.
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.count == f.accounts.count)

            let bad: VaultAccess
            let expected: CredentialVaultError
            switch fault {
            case .foreignProfile:
                bad = VaultAccess(profileID: UUID(), epoch: 1, deadline: clock.base.advanced(by: .seconds(300)))
                expected = .unauthorized
            case .revoked:
                access.revoke()
                bad = access
                expected = .unauthorized
            case .lapsed:
                clock.advance(by: .seconds(301))
                bad = access
                expected = .expired
            }
            let before = try f.headWriteImage()

            await #expect(throws: expected) { _ = try await store.addUnlock(vaultID: f.vaultID, VaultFixtures.proof(3), using: bad) }
            await #expect(throws: expected) {
                _ = try await store.removeUnlock(
                    vaultID: f.vaultID, credentialID: f.proof.credentialID, verifiedRemaining: enrolled, using: bad
                )
            }

            #expect(try f.headWriteImage() == before)
            #expect(try f.wrapperRows(of: f.vaultID).map(\.credentialID) == [f.proof.credentialID, enrolled.credentialID])
            if fault == .foreignProfile {  // the legitimate access is untouched by the refusals
                #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.count == f.accounts.count)
            }
        }
    }
}
