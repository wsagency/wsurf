// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurf

// Task 9: vault creation (spec §8) through the public `createVault`, asserted on files, the unlock result and the open state.

/// Every `vault`, `head`, `record` and `journal` row of one vault id, serialised: equal images mean no byte of it changed.
private nonisolated func rowImage(_ f: VaultStoreFixture, of vault: UUID) throws -> [String: String] {
    try f.read { db in
        var image: [String: String] = [:]
        for table in ["vault", "head", "record", "journal"] {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE vaultID = ? ORDER BY 1, 2", arguments: [vault.lowerText])
            image[table] = rows.map { row in row.columnNames.map { "\($0)=\(row[$0] as DatabaseValue)" }.joined(separator: "|") }.joined(separator: "\n")
        }
        return image
    }
}

private nonisolated func failClosedCause(_ error: (any Error)?) -> StoreFailClosed? {
    if case .failClosed(let closed)? = error as? CredentialStoreError {
        return closed
    }
    return nil
}

struct VaultStoreCreateTests {
    static let lockWait: Duration = .milliseconds(150)

    // MARK: First vault

    /// The first-vault bootstrap shares the migration's seam numbering: 4 pending built, 5 verified, 6 stub in `.swap`, 7 `.swap`
    /// renamed onto `Credentials.vault`, 9 pending renamed onto `Credentials.store`, 10 A3 set.
    @Test(arguments: [4, 5, 6, 7, 9, 10])
    func firstVaultBootstrapInterruptedAtEachStepNeverEnablesCreateOrDiscards(step: Int) async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let proof = VaultFixtures.proof()
            let crashing = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: stopping(after: step)))
            await #expect(throws: SeamStop(step: step)) {
                _ = try await crashing.createVault(name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID)))
            }
            let evaluate = { StoreAnchors.evaluate(directory: env.directory, profileID: env.profileID, defaults: env.defaults) }

            switch step {
            case 4, 5, 6:
                guard case .failClosed(let closed) = evaluate() else { throw VaultStoreCreateFailure("step \(step): not fail-closed") }
                #expect(closed.cause == .leftoversWithoutAuthority)
                #expect(closed.paths.contains(env.directory.appendingPathComponent("Credentials.store.migrating")))
                #expect(StoreAnchors.exists(anchorURL(env.directory, "Credentials.store.migrating")))
                #expect(!StoreAnchors.exists(anchorURL(env.directory, "Credentials.vault")))
                #expect(StoreAnchors.exists(anchorURL(env.directory, "Credentials.vault.swap")) == (step == 6))

                // No create path exists: a second bootstrap is refused and touches nothing.
                let image = try directoryImage(env.directory)
                let again = tracker.makeStore(env: env)
                let failure = await Result {
                    try await again.createVault(name: "Again", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID)))
                }.error
                #expect(failClosedCause(failure)?.cause == .leftoversWithoutAuthority)
                #expect(try directoryImage(env.directory) == image)
            case 7:
                guard case .resumeMigration = evaluate() else { throw VaultStoreCreateFailure("step 7: not resumable") }
            default:
                guard case .provisional = evaluate() else { throw VaultStoreCreateFailure("step \(step): not provisional") }
            }

            // Whatever the state, the vault the bootstrap built (when one exists) unlocks with the one proof.
            if step >= 7 {
                let source = step == 7 ? anchorURL(env.directory, "Credentials.store.migrating") : anchorURL(env.directory, "Credentials.store")
                let vaultID = try #require(try activeVaultIDs(inStoreAt: source).first)
                let store = tracker.makeStore(env: env)
                let access = newAccess(env.profileID)
                try await store.unlock(
                    vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, confirmMigration: true, access: access,
                    verifying: nil, scratchWarning: nil
                )
                #expect(try await store.snapshot(vaultID: vaultID, using: access).accounts.isEmpty)
            }
        }
    }

    /// The pending store's own self-verification fails (its wrapper no longer unwraps): that is evidence, not a cancelled creation, so
    /// the pending file stays byte for byte and the next bootstrap is refused instead of silently retrying over it.
    @Test func aSelfVerificationFailureOfTheNewPendingStoreIsPreservedAsFailClosedEvidence() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let pending = anchorURL(env.directory, "Credentials.store.migrating")
            let tampering: @Sendable (Int) throws -> Void = { step in
                guard step == 4 else { return }
                let queue = try PendingStore.open(at: pending)
                try queue.write { (db: Database) throws in
                    let stored: Data = try #require(try Data.fetchOne(db, sql: "SELECT wrappers FROM vault WHERE role = 'active'"))
                    let wrappers = try VaultWrapperList.decode(stored).map {
                        CredentialKeyWrapper(
                            credentialID: $0.credentialID, prfInput: $0.prfInput, nonce: $0.nonce, ciphertext: $0.ciphertext,
                            tag: VaultStoreFixture.flipped($0.tag)
                        )
                    }
                    try db.execute(sql: "UPDATE vault SET wrappers = ? WHERE role = 'active'", arguments: [try VaultWrapperList.encode(wrappers)])
                }
                try PendingStore.finish(queue, at: pending)
            }
            let store = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: tampering))
            let proof = VaultFixtures.proof()
            let failure = await Result {
                try await store.createVault(name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID)))
            }.error
            #expect(failure as? CredentialVaultError == .authenticationFailed)

            #expect(StoreAnchors.exists(pending), "the failed pending store is kept")
            #expect(!StoreAnchors.exists(anchorURL(env.directory, "Credentials.vault")))
            #expect(!StoreAnchors.exists(anchorURL(env.directory, "Credentials.vault.swap")))
            guard case .failClosed(let closed) = StoreAnchors.evaluate(directory: env.directory, profileID: env.profileID, defaults: env.defaults)
            else { throw VaultStoreCreateFailure("not fail-closed") }
            #expect(closed.cause == .leftoversWithoutAuthority)

            let image = try directoryImage(env.directory)
            let again = await Result {
                try await tracker.makeStore(env: env).createVault(name: "Again", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID)))
            }.error
            #expect(failClosedCause(again)?.cause == .leftoversWithoutAuthority)
            #expect(try directoryImage(env.directory) == image, "the refused retry touched nothing")
        }
    }

    /// A task cancelled after its pending store exists removes exactly what it created and the next creation succeeds.
    @Test func aCancellationAfterThePendingStoreExistsRemovesItAndAllowsARetry() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let pending = anchorURL(env.directory, "Credentials.store.migrating")
            let cancelling: @Sendable (Int) throws -> Void = { step in
                if step == 4 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let store = tracker.makeStore(env: env, fileOps: probingOps(in: env.directory, hook: cancelling))
            let proof = VaultFixtures.proof()
            // Its own task: the hook cancels the creation, never the test.
            let running = Task {
                try await store.createVault(name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID)))
            }
            let failure = await Result { try await running.value }.error
            #expect(failure is CancellationError)

            for name in ["Credentials.store.migrating", "Credentials.vault.swap", "Credentials.vault", "Credentials.store"] {
                #expect(!StoreAnchors.exists(anchorURL(env.directory, name)), "\(name)")
            }
            #expect(!StoreAnchors.exists(pending))
            #expect(pendingSidecars(in: env.directory).isEmpty)
            #expect(env.defaults.object(forKey: StoreAnchors.witnessKey) == nil)

            _ = try await tracker.makeStore(env: env).createVault(
                name: "Personal", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID))
            )
        }
    }

    @Test func completedBootstrapUnlocksAndLeavesNoSidecarOrLeftover() async throws {
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let proof = VaultFixtures.proof()
            let store = tracker.makeStore(env: env)
            let vaultID = try await store.createVault(
                name: "  Personal  ", unlock: proof, authorizedBy: .firstVault(lease: newAccess(env.profileID))
            )

            #expect(StoreAnchors.evaluate(directory: env.directory, profileID: env.profileID, defaults: env.defaults) == .provisional(
                storeID: try #require(UUID(uuidString: env.defaults.string(forKey: StoreAnchors.witnessKey) ?? "")), stubMissing: false
            ))
            for name in ["Credentials.store.migrating", "Credentials.vault.swap", "Credentials.vault.pre-v2"] {
                #expect(!StoreAnchors.exists(anchorURL(env.directory, name)), "\(name)")
            }
            #expect(pendingSidecars(in: env.directory).isEmpty)
            // The bootstrap publishes no grant.
            let access = newAccess(env.profileID)
            await expectNoGrant(store, vaultID, access)

            let reopened = tracker.makeStore(env: env)
            try await reopened.unlock(
                vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, confirmMigration: false, access: access,
                verifying: nil, scratchWarning: nil
            )
            let listing = try await reopened.listing()
            #expect(listing.map(\.ordinal) == [1])
            #expect(listing.first?.name == "Personal")
        }
    }

    @Test func firstVaultIsRefusedWhenAnyAuthorityAlreadyExists() async throws {
        try await VaultStoreFixture.with { f in
            let image = try settledImage(f)
            let failure = await Result {
                try await f.makeStore().createVault(name: "Again", unlock: VaultFixtures.proof(3), authorizedBy: .firstVault(lease: f.beginAccess()))
            }.error
            #expect(failure as? CredentialStoreError == .noAuthority)
            #expect(try settledImage(f) == image)
        }
    }

    // MARK: Authority

    @Test func newPasskeyVaultNeedsAnUnlockedVault() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let store = f.makeStore()
            let image = try f.recordAndJournalImage()
            let proof = VaultFixtures.proof(4)

            // Never unlocked.
            let never = f.beginAccess()
            #expect(await creationFailure(store, f, proof, access: never) == .noAuthority)

            // Unlocked, then revoked.
            let revoked = f.beginAccess()
            #expect(await unlockResult(f, store, access: revoked) == nil)
            revoked.revoke()
            #expect(await creationFailure(store, f, proof, access: revoked) == .noAuthority)

            // Another profile's access.
            let foreign = newAccess(UUID())
            #expect(await creationFailure(store, f, proof, access: foreign) == .noAuthority)

            // An unlocked vault the access holds no grant on.
            let live = f.beginAccess()
            #expect(await unlockResult(f, store, access: live) == nil)
            let failure = await Result {
                try await store.createVault(name: "N", unlock: proof, authorizedBy: .unlockedVault(vaultID: UUID(), access: live))
            }.error
            #expect(failure as? CredentialStoreError == .noAuthority)

            #expect(try f.recordAndJournalImage() == image)
            #expect(try await store.listing().count == 1)
        }
    }

    @Test func unlockedVaultCreationCreatesAnIndependentlyUnlockableVaultAndPublishesNoGrant() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let (store, access) = try await f.unlocked()
            let proof = VaultFixtures.proof(4)
            let created = try await store.createVault(
                name: "Work", unlock: proof, authorizedBy: .unlockedVault(vaultID: f.vaultID, access: access)
            )

            // The authorizing grant is untouched; the new vault holds none until it is unlocked with its own proof.
            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts == f.accounts)
            await expectNoGrant(store, created, access)
            let listing = try await store.listing()
            #expect(listing.map(\.ordinal) == [1, 2])
            #expect(listing.last?.isUnlocked == false)

            let fresh = f.makeStore()
            let other = f.beginAccess()
            try await fresh.unlock(
                vaultID: created, credentialID: proof.credentialID, prf: proof.prf, confirmMigration: false, access: other,
                verifying: nil, scratchWarning: nil
            )
            let snapshot = try await fresh.snapshot(vaultID: created, using: other)
            #expect(snapshot.accounts.isEmpty)
            #expect(snapshot.revision == 1)
            #expect(try await fresh.listing().last?.name == "Work")
            // Registry revision rose by one and the whole store verifies from scratch.
            #expect(try f.storedRegistry().revision == 2)
            try f.verify()
        }
    }

    /// The existingPasskey proof is verified on an ephemeral revoked access: a source vault that is already unlocked keeps exactly the access it had.
    @Test func existingPasskeyOnAnAlreadyUnlockedSourceLeavesItsAccessUsable() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let (store, access) = try await f.unlocked()
            let created = try await store.createVault(
                name: "Passkey", unlock: f.proof,
                authorizedBy: .existingPasskey(vaultID: f.vaultID, credentialID: f.proof.credentialID, prf: f.proof.prf, lease: f.beginAccess())
            )

            #expect(try await store.snapshot(vaultID: f.vaultID, using: access).accounts == f.accounts)  // the same grant, still usable
            await expectNoGrant(store, created, access)  // and nothing was granted for the new vault
            #expect(try await store.listing().map(\.isUnlocked) == [true, false])
            try f.verify()
        }
    }

    @Test func existingPasskeyRunsStepsOneToSevenAndPublishesNothing() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let store = f.makeStore()
            let access = f.beginAccess()
            let created = try await store.createVault(
                name: "Passkey", unlock: f.proof,
                authorizedBy: .existingPasskey(vaultID: f.vaultID, credentialID: f.proof.credentialID, prf: f.proof.prf, lease: f.beginAccess())
            )

            // Nothing was published for the source vault or the new one, and the fixture's A3 witness is kept.
            await expectNoGrant(store, f.vaultID, access)
            await expectNoGrant(store, created, access)
            #expect(try await store.listing().map(\.isUnlocked) == [false, false])

            // The new vault unlocks with the supplied proof alone.
            let fresh = f.makeStore()
            let other = f.beginAccess()
            try await fresh.unlock(
                vaultID: created, credentialID: f.proof.credentialID, prf: f.proof.prf, confirmMigration: false, access: other,
                verifying: nil, scratchWarning: nil
            )
            #expect(try await fresh.snapshot(vaultID: created, using: other).accounts.isEmpty)
            try f.verify()
        }
    }

    @Test func existingPasskeyWithAWrongPrfIsUnusableAndCreatesNothing() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            let store = f.makeStore()
            let image = try f.recordAndJournalImage()
            let before = try f.storedRegistry().revision
            let wrong = VaultUnlockProof(credentialID: f.proof.credentialID, prfInput: f.proof.prfInput, prf: SymmetricKey(size: .bits256))

            // Consistent but wrong: the source vault does not open.
            let wrongPRF = await Result {
                try await store.createVault(
                    name: "X", unlock: wrong,
                    authorizedBy: .existingPasskey(vaultID: f.vaultID, credentialID: wrong.credentialID, prf: wrong.prf, lease: f.beginAccess())
                )
            }.error
            #expect(wrongPRF as? CredentialStoreError == .passkeyUnusable)

            // The new vault's proof is not the passkey that authorizes it: no fallback path is tried.
            let mismatched = await Result {
                try await store.createVault(
                    name: "X", unlock: wrong,
                    authorizedBy: .existingPasskey(vaultID: f.vaultID, credentialID: f.proof.credentialID, prf: f.proof.prf, lease: f.beginAccess())
                )
            }.error
            #expect(mismatched as? CredentialStoreError == .passkeyUnusable)

            // Right credential id and PRF output but a PRF input the source vault never stored for that passkey: a vault wrapped that way
            // could not be reopened by the passkey, so it is refused before anything is written.
            let otherInput = VaultUnlockProof(
                credentialID: f.proof.credentialID, prfInput: Data(repeating: 0x77, count: 32), prf: f.proof.prf
            )
            let inputMismatch = await Result {
                try await store.createVault(
                    name: "X", unlock: otherInput,
                    authorizedBy: .existingPasskey(vaultID: f.vaultID, credentialID: f.proof.credentialID, prf: f.proof.prf, lease: f.beginAccess())
                )
            }.error
            #expect(inputMismatch as? CredentialStoreError == .passkeyUnusable)

            #expect(try f.recordAndJournalImage() == image)
            #expect(try f.storedRegistry().revision == before)
            #expect(try await store.listing().count == 1)
        }
    }

    @Test func creatingWithAnotherVaultLockedChangesNoneOfItsBytes() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true, secondAccounts: [VaultFixtures.account(username: "grace")]) { f in
            let second = try secondVault(of: f)
            let secondTrash = try #require(f.secondTrashID)
            let beforeSecond = try rowImage(f, of: second)
            let beforeSecondTrash = try rowImage(f, of: secondTrash)
            let (store, access) = try await f.unlocked()
            _ = try await store.createVault(
                name: "Third", unlock: VaultFixtures.proof(6), authorizedBy: .unlockedVault(vaultID: f.vaultID, access: access)
            )
            #expect(try rowImage(f, of: second) == beforeSecond)
            #expect(try rowImage(f, of: secondTrash) == beforeSecondTrash)
            #expect(try await store.listing().map(\.ordinal) == [1, 2, 3])
            try f.verify()
        }
    }

    // MARK: Limits

    @Test func ordinalNameAndCountLimits() async throws {
        // ordinal = max active + 1, so a gap left by a missing ordinal is never reused.
        try await VaultStoreFixture.with(secondVault: true) { f in
            let (store, access) = try await f.unlocked()
            let authority = VaultCreationAuthority.unlockedVault(vaultID: f.vaultID, access: access)
            _ = try await store.createVault(name: String(repeating: "n", count: 64), unlock: VaultFixtures.proof(6), authorizedBy: authority)
            #expect(try await store.listing().map(\.ordinal) == [1, 2, 3])

            for name in [String(repeating: "n", count: 65), "", "   \n"] {
                let failure = await Result { try await store.createVault(name: name, unlock: VaultFixtures.proof(7), authorizedBy: authority) }.error
                #expect(failure as? CredentialStoreError == .invalidVaultName, "\(name.count)")
            }
            #expect(try await store.listing().count == 3)
        }

        // The 17th active vault is refused.
        try await VaultStoreFixture.with(extraVaults: 14) { f in
            let (store, access) = try await f.unlocked()
            let authority = VaultCreationAuthority.unlockedVault(vaultID: f.vaultID, access: access)
            #expect(try await store.listing().count == 15)
            _ = try await store.createVault(name: "Sixteenth", unlock: VaultFixtures.proof(6), authorizedBy: authority)
            #expect(try await store.listing().map(\.ordinal) == Array(1...16))

            let image = try f.recordAndJournalImage()
            let failure = await Result { try await store.createVault(name: "Seventeenth", unlock: VaultFixtures.proof(7), authorizedBy: authority) }.error
            #expect(failure as? CredentialStoreError == .tooManyVaults)
            #expect(try f.recordAndJournalImage() == image)
            #expect(try await store.listing().count == 16)
        }
    }

    @Test func defaultVaultPreferenceRoundTripsAndMayNameALockedVault() async throws {
        try await VaultStoreFixture.with(secondVault: true) { f in
            let store = f.makeStore()
            #expect(await store.defaultVaultID() == nil)
            let locked = try secondVault(of: f)
            await store.setDefaultVault(locked)  // never unlocked in this store
            #expect(await store.defaultVaultID() == locked)
            #expect(f.env.defaults.string(forKey: "io.wsagency.wsurf.credentialVault.defaultVault") == locked.uuidString)

            // The value is not validated against the store.
            let unknown = UUID()
            await store.setDefaultVault(unknown)
            #expect(await f.makeStore().defaultVaultID() == unknown)

            await store.setDefaultVault(nil)
            #expect(await store.defaultVaultID() == nil)
            #expect(f.env.defaults.object(forKey: "io.wsagency.wsurf.credentialVault.defaultVault") == nil)
        }
    }

    // MARK: Plumbing

    private func creationFailure(
        _ store: ProfileVaultStore, _ f: VaultStoreFixture, _ proof: VaultUnlockProof, access: VaultAccess
    ) async -> CredentialStoreError? {
        let result = await Result {
            try await store.createVault(name: "New", unlock: proof, authorizedBy: .unlockedVault(vaultID: f.vaultID, access: access))
        }
        return result.error as? CredentialStoreError
    }
}

private nonisolated struct VaultStoreCreateFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The error of a `Result` built with the standard library's async `Result(catching:)`, so a test can look at it without `do`/`catch`.
nonisolated extension Result where Failure == any Error {
    var error: (any Error)? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
