// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import Testing

@testable import WSurfVault

// iCloud sync, the store half (spec amendment 2026-10-22): the sync key under a grant, the name and wrapper list a `Vault` record
// carries, and adopting another Mac's vault into this Mac's own store. Two Macs are two stores of one profile id in two directories,
// each with its own defaults (its own store id and witness). Serial: real stores.

/// One Mac of a profile: its own directory, defaults and store; the profile id every Mac of the profile shares.
private nonisolated struct Mac {
    let env: VaultTestEnvironment
    let profileID: UUID
    let store: ProfileVaultStore

    var directory: URL {
        env.directory
    }

    func lease() -> VaultAccess {
        VaultAccess(profileID: profileID, epoch: 1, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
    }

    /// The first vault of an empty directory.
    func create(_ name: String, _ proof: VaultUnlockProof) async throws -> UUID {
        try await store.createVault(name: name, unlock: proof, authorizedBy: .firstVault(lease: lease()))
    }

    func unlock(_ vaultID: UUID, _ proof: VaultUnlockProof) async throws -> VaultAccess {
        let access = lease()
        try await store.unlockInitialized(
            vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, access: access, verifying: nil, scratchWarning: nil
        )
        return access
    }

    /// What the `Vault` record of `vaultID` holds, and the passkey that opens it.
    func record(of vaultID: UUID, _ proof: VaultUnlockProof, access: VaultAccess) async throws -> VaultAdoption {
        let state = try await store.syncVaultState(vaultID: vaultID, using: access)
        let wrappers = try VaultWrapperList.encode(state.wrappers)
        let key = try await store.syncKey(vaultID: vaultID, using: access)
        return VaultAdoption(
            vaultID: vaultID, wrappers: wrappers, sealed: try VaultSyncCodec.sealVault(name: state.name, wrappers: wrappers, key: key),
            generation: VaultSyncCodec.generation, credentialID: proof.credentialID, prf: proof.prf
        )
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

private nonisolated func withMacs(_ body: (_ one: Mac, _ other: Mac) async throws -> Void) async throws {
    let profileID = UUID()
    var macs: [Mac] = []
    for _ in 0..<2 {
        let env = try VaultTestEnvironment.make()
        macs.append(Mac(env: env, profileID: profileID, store: ProfileVaultStore(profileID: profileID, directory: env.directory, defaults: env.defaults)))
    }
    do {
        try await body(macs[0], macs[1])
    } catch {
        for mac in macs {
            await mac.store.close()
            mac.env.cleanUp()
        }
        throw error
    }
    for mac in macs {
        await mac.store.close()
        mac.env.cleanUp()
    }
}

private nonisolated func bytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

private nonisolated func commit(_ accounts: [CredentialAccount], to vaultID: UUID, on mac: Mac, access: VaultAccess) async throws {
    let snapshot = try await mac.store.snapshot(vaultID: vaultID, using: access)
    _ = try await mac.store.commit(vaultID: vaultID, accounts, expectedRevision: snapshot.revision, cause: nil, using: access)
}

private nonisolated enum Authority: CaseIterable, CustomTestStringConvertible {
    case firstVault, unlockedVault

    var testDescription: String {
        "\(self)"
    }
}

struct VaultSyncStoreTests {
    // MARK: The sync key and the vault's state

    @Test func syncKeyNeedsTheGrant() async throws {
        try await withMacs { a, _ in
            let proof = VaultFixtures.proof()
            let vaultID = try await a.create("Personal", proof)
            let stranger = a.lease()
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncKey(vaultID: vaultID, using: stranger) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncVaultState(vaultID: vaultID, using: stranger) }

            let access = try await a.unlock(vaultID, proof)
            let key = try await a.store.syncKey(vaultID: vaultID, using: access)
            #expect(key.profileID == a.profileID && key.vaultID == vaultID && key.generation == VaultSyncCodec.generation)
            let dek = try #require(await a.store.grants[vaultID]).dek
            #expect(bytes(key.key) != bytes(dek), "never the vault's own key")
            #expect(bytes(key.key) == bytes(VaultSyncKey.derive(dek: dek, profileID: a.profileID, vaultID: vaultID).key))

            // Another access, another vault id, a revoked access and a locked vault give nothing.
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncKey(vaultID: vaultID, using: stranger) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncKey(vaultID: UUID(), using: access) }
            access.revoke()
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncKey(vaultID: vaultID, using: access) }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncVaultState(vaultID: vaultID, using: access) }

            let again = try await a.unlock(vaultID, proof)
            _ = try await a.store.syncKey(vaultID: vaultID, using: again)
            await a.store.lock(vaultID: vaultID)
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await a.store.syncKey(vaultID: vaultID, using: again) }
        }
    }

    @Test func syncVaultStateFollowsRenameAndUnlockChanges() async throws {
        try await withMacs { a, _ in
            let (first, second) = (VaultFixtures.proof(1), VaultFixtures.proof(2))
            let vaultID = try await a.create("Personal", first)
            let access = try await a.unlock(vaultID, first)

            let start = try await a.store.syncVaultState(vaultID: vaultID, using: access)
            #expect(start.name == "Personal" && start.wrappers.map(\.credentialID) == [first.credentialID])
            let again = try await a.store.syncVaultState(vaultID: vaultID, using: access)
            #expect(try VaultWrapperList.encode(start.wrappers) == VaultWrapperList.encode(again.wrappers), "the same bytes every time")

            _ = try await a.store.renameVault(vaultID: vaultID, name: "  Renamed ", using: access)
            #expect(try await a.store.syncVaultState(vaultID: vaultID, using: access).name == "Renamed")

            _ = try await a.store.addUnlock(vaultID: vaultID, second, using: access)
            let added = try await a.store.syncVaultState(vaultID: vaultID, using: access)
            #expect(added.wrappers.map(\.credentialID) == [first.credentialID, second.credentialID])
            #expect(try VaultWrapperList.encode(added.wrappers) != VaultWrapperList.encode(start.wrappers))

            _ = try await a.store.removeUnlock(vaultID: vaultID, credentialID: second.credentialID, verifiedRemaining: first, using: access)
            let removed = try await a.store.syncVaultState(vaultID: vaultID, using: access)
            #expect(removed.wrappers.map(\.credentialID) == [first.credentialID])
        }
    }

    // MARK: Adoption

    @Test func addingWithTheSamePasskeyOpensTheSameVault() async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof()
            let vaultID = try await a.create("Shared", proof)
            let accessA = try await a.unlock(vaultID, proof)
            let account = VaultFixtures.account()
            try await commit([account], to: vaultID, on: a, access: accessA)
            let keyA = try await a.store.syncKey(vaultID: vaultID, using: accessA)
            let record = try await a.record(of: vaultID, proof, access: accessA)

            let adopted = try await b.store.adoptVault(record, authorizedBy: .firstVault(lease: b.lease()))
            #expect(adopted.vaultID == vaultID && adopted.name == "Shared")

            // Added locked, like a created vault: nothing is granted and the name stays sealed until it is unlocked.
            let listed = try await b.store.listing()
            #expect(listed.map(\.vaultID) == [vaultID] && listed.map(\.ordinal) == [1])
            #expect(listed.first?.name == nil)
            guard case .provisional(let storeA, _) = await a.store.openState(), case .provisional(let storeB, _) = await b.store.openState() else {
                throw SyncStoreFailure("no provisional store")
            }
            #expect(storeA != storeB, "its own store id")

            // The same passkey opens it; the store verified every row on the way; no account came with it.
            let accessB = try await b.unlock(vaultID, proof)
            #expect(try await b.store.listing().first?.name == "Shared")
            #expect(try await b.store.snapshot(vaultID: vaultID, using: accessB).accounts.isEmpty)
            let keyB = try await b.store.syncKey(vaultID: vaultID, using: accessB)
            #expect(bytes(keyB.key) == bytes(keyA.key))

            // An entry sealed on one Mac opens on the other.
            let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 1, account: account), key: keyA)
            #expect(try VaultSyncCodec.openItem(envelope, accountID: account.id, key: keyB).account == account)

            // The wrappers are the same wrappers.
            let (listA, listB) = (try await a.store.syncVaultState(vaultID: vaultID, using: accessA), try await b.store.syncVaultState(vaultID: vaultID, using: accessB))
            #expect(listA.name == listB.name)
            #expect(listA.wrappers.count == 1 && listB.wrappers.count == 1)
            let (wrapperA, wrapperB) = (listA.wrappers[0], listB.wrappers[0])
            #expect(wrapperA.credentialID == wrapperB.credentialID && wrapperA.prfInput == wrapperB.prfInput)
            #expect(wrapperA.nonce == wrapperB.nonce && wrapperA.ciphertext == wrapperB.ciphertext && wrapperA.tag == wrapperB.tag)
        }
    }

    @Test(arguments: Authority.allCases)
    private func anotherPRFChangesNothing(authority: Authority) async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof(1)
            let vaultID = try await a.create("Shared", proof)
            let record = try await a.record(of: vaultID, proof, access: try await a.unlock(vaultID, proof))

            // This Mac holds a vault of its own, or nothing at all.
            let own = VaultFixtures.proof(2)
            let ownID: UUID?
            if authority == .unlockedVault {
                ownID = try await b.create("Own", own)
            } else {
                ownID = nil
            }
            func authorized() async throws -> VaultCreationAuthority {
                guard let ownID else { return .firstVault(lease: b.lease()) }
                return .unlockedVault(vaultID: ownID, access: try await b.unlock(ownID, own))
            }
            let refusing = try await authorized()
            let (image, names) = (try directoryImage(b.directory), try b.names())

            // The same credential and PRF input, another PRF output: the wrapper does not open.
            let other = VaultAdoption(
                vaultID: vaultID, wrappers: record.wrappers, sealed: record.sealed, generation: record.generation,
                credentialID: proof.credentialID, prf: SymmetricKey(size: .bits256)
            )
            await #expect(throws: CredentialVaultError.authenticationFailed) { _ = try await b.store.adoptVault(other, authorizedBy: refusing) }
            #expect(try directoryImage(b.directory) == image, "not one byte of this Mac's files changed")
            #expect(try b.names() == names, "and no file appeared, not even the lock")
            #expect(try await b.store.listing().map(\.vaultID) == (ownID.map { [$0] } ?? []))

            // This Mac's own vault still opens, and the right output adds the vault.
            _ = try await b.store.adoptVault(record, authorizedBy: try await authorized())
            #expect(try await b.store.listing().map(\.vaultID) == (ownID.map { [$0] } ?? []) + [vaultID])
        }
    }

    @Test func addingNeedsAnAuthorizedVaultWhenTheStoreExists() async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof(1)
            let vaultID = try await a.create("Shared", proof)
            let record = try await a.record(of: vaultID, proof, access: try await a.unlock(vaultID, proof))
            let own = VaultFixtures.proof(2)
            let ownID = try await b.create("Own", own)
            let image = try directoryImage(b.directory)

            // Past the first run there is no first-vault approval, and a locked vault approves nothing.
            await #expect(throws: CredentialStoreError.noAuthority) {
                _ = try await b.store.adoptVault(record, authorizedBy: .firstVault(lease: b.lease()))
            }
            await #expect(throws: CredentialStoreError.noAuthority) {
                _ = try await b.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: ownID, access: b.lease()))
            }
            #expect(try directoryImage(b.directory) == image, "nothing was read or written")
            #expect(try await b.store.listing().map(\.vaultID) == [ownID])

            let access = try await b.unlock(ownID, own)
            let adopted = try await b.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: ownID, access: access))
            #expect(adopted.vaultID == vaultID)
            #expect(try await b.store.listing().map(\.vaultID) == [ownID, vaultID])
        }
    }

    @Test func addingWithAnEnrolledPasskeyNeedsNoUnlockedVault() async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof(1)
            let vaultID = try await a.create("Shared", proof)
            let record = try await a.record(of: vaultID, proof, access: try await a.unlock(vaultID, proof))

            // This Mac's own vault enrols the same passkey with the same PRF input: one assertion approves the new vault.
            let ownID = try await b.create("Own", proof)
            let adopted = try await b.store.adoptVault(
                record, authorizedBy: .existingPasskey(vaultID: ownID, credentialID: proof.credentialID, prf: proof.prf, lease: b.lease())
            )
            #expect(adopted.vaultID == vaultID && adopted.name == "Shared")
            _ = try await b.unlock(vaultID, proof)
        }
    }

    @Test func anEnrolledPasskeyWithAnotherPRFInputIsNotTheSamePasskey() async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof(1)
            let vaultID = try await a.create("Shared", proof)
            let record = try await a.record(of: vaultID, proof, access: try await a.unlock(vaultID, proof))
            // The same credential and PRF output, enrolled here with another PRF input: its assertion would not reproduce the output.
            let different = VaultUnlockProof(credentialID: proof.credentialID, prfInput: Data(repeating: 99, count: 32), prf: proof.prf)
            let ownID = try await b.create("Own", different)
            let names = try b.names().filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
            await #expect(throws: CredentialStoreError.passkeyUnusable) {
                _ = try await b.store.adoptVault(
                    record, authorizedBy: .existingPasskey(vaultID: ownID, credentialID: proof.credentialID, prf: proof.prf, lease: b.lease())
                )
            }
            // The refusal comes after the passkey was verified against the source vault, which opens the store: no file appears, the
            // lock aside, and no vault is added.
            #expect(try b.names().filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") } == names)
            #expect(try await b.store.listing().map(\.vaultID) == [ownID])
        }
    }

    @Test func addingRefusesATamperedListOrName() async throws {
        try await withMacs { a, b in
            let (proof, second) = (VaultFixtures.proof(1), VaultFixtures.proof(2))
            let vaultID = try await a.create("Shared", proof)
            let access = try await a.unlock(vaultID, proof)
            _ = try await a.store.addUnlock(vaultID: vaultID, second, using: access)
            let record = try await a.record(of: vaultID, proof, access: access)
            let wrappers = try VaultWrapperList.decode(record.wrappers)
            #expect(wrappers.count == 2)

            func adoption(wrappers: Data? = nil, sealed: Data? = nil, vault: UUID? = nil, generation: UInt64? = nil, credential: Data? = nil) -> VaultAdoption {
                VaultAdoption(
                    vaultID: vault ?? vaultID, wrappers: wrappers ?? record.wrappers, sealed: sealed ?? record.sealed,
                    generation: generation ?? record.generation, credentialID: credential ?? proof.credentialID, prf: proof.prf
                )
            }
            func tampered(_ index: Int) throws -> Data {
                var list = wrappers
                let wrapper = list[index]
                list[index] = CredentialKeyWrapper(
                    credentialID: wrapper.credentialID, prfInput: wrapper.prfInput, nonce: wrapper.nonce, ciphertext: wrapper.ciphertext,
                    tag: VaultStoreFixture.flipped(wrapper.tag)
                )
                return try VaultWrapperList.encode(list)
            }
            let elsewhere = try VaultSyncCodec.sealVault(
                name: "Shared", wrappers: record.wrappers, key: VaultSyncKey.derive(dek: SymmetricKey(size: .bits256), profileID: a.profileID, vaultID: vaultID)
            )

            let refusals: [(VaultAdoption, any Error)] = [
                (adoption(wrappers: try tampered(0)), CredentialVaultError.authenticationFailed),  // the wrapper that opens
                (adoption(wrappers: try tampered(1)), VaultSyncError.authenticationFailed),  // another wrapper of the list
                (adoption(wrappers: try VaultWrapperList.encode(Array(wrappers.dropLast()))), VaultSyncError.authenticationFailed),
                (adoption(sealed: VaultStoreFixture.flipped(record.sealed)), VaultSyncError.authenticationFailed),
                (adoption(sealed: elsewhere), VaultSyncError.authenticationFailed),  // sealed by someone without the key
                (adoption(vault: UUID()), CredentialVaultError.authenticationFailed),  // the wrapper is bound to its vault
                (adoption(generation: 2), VaultSyncError.unsupportedGeneration),
                (adoption(wrappers: Data("not a list".utf8)), CredentialStoreError.malformed),
                (adoption(credential: Data(repeating: 77, count: 32)), CredentialVaultError.invalidData),
            ]
            func label(_ error: (any Error)?) -> String {
                error.map { "\(type(of: $0)).\($0)" } ?? "no error"
            }
            for (index, (refused, expected)) in refusals.enumerated() {
                let failure = await Result { try await b.store.adoptVault(refused, authorizedBy: .firstVault(lease: b.lease())) }.error
                #expect(label(failure) == label(expected), "case \(index): \(label(failure))")
                #expect(try b.names().isEmpty, "case \(index): this Mac's directory is untouched")
            }
            // The control: the untouched record is taken.
            _ = try await b.store.adoptVault(adoption(), authorizedBy: .firstVault(lease: b.lease()))
        }
    }

    @Test func addingRefusesAVaultIDTheStoreHolds() async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof(1)
            let vaultID = try await a.create("Shared", proof)
            let accessA = try await a.unlock(vaultID, proof)
            let record = try await a.record(of: vaultID, proof, access: accessA)

            // Into the very store that holds it.
            await #expect(throws: CredentialVaultError.alreadyExists) {
                _ = try await a.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: vaultID, access: accessA))
            }
            #expect(try await a.store.listing().map(\.vaultID) == [vaultID])
            _ = try await a.unlock(vaultID, proof)  // still verifies

            // Into another Mac's store, once.
            let own = VaultFixtures.proof(2)
            let ownID = try await b.create("Own", own)
            let accessB = try await b.unlock(ownID, own)
            _ = try await b.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: ownID, access: accessB))
            await #expect(throws: CredentialVaultError.alreadyExists) {
                _ = try await b.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: ownID, access: accessB))
            }
            #expect(try await b.store.listing().map(\.vaultID) == [ownID, vaultID])
        }
    }

    @Test func addedVaultIsLockedAndCountsAsAnyVault() async throws {
        try await withMacs { a, b in
            let proof = VaultFixtures.proof(1)
            let vaultID = try await a.create("Shared", proof)
            let accessA = try await a.unlock(vaultID, proof)
            let record = try await a.record(of: vaultID, proof, access: accessA)
            let own = VaultFixtures.proof(2)
            let ownID = try await b.create("Own", own)
            let accessB = try await b.unlock(ownID, own)

            _ = try await b.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: ownID, access: accessB))
            let listed = try await b.store.listing()
            #expect(listed.map(\.ordinal) == [1, 2] && listed.map(\.vaultID) == [ownID, vaultID], "the next ordinal")
            #expect(listed[1].name == nil, "locked, and the other Mac's grant is no grant here")
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await b.store.syncKey(vaultID: vaultID, using: accessB) }

            // Unlocked, it is a vault like any other: an empty one is deleted without asking, and its id is free again.
            let adoptedAccess = try await b.unlock(vaultID, proof)
            #expect(try await b.store.listing()[1].name == "Shared")
            try await b.store.deleteEmptyVault(vaultID: vaultID, using: adoptedAccess)
            #expect(try await b.store.listing().map(\.vaultID) == [ownID])
            _ = try await b.store.adoptVault(record, authorizedBy: .unlockedVault(vaultID: ownID, access: accessB))
            #expect(try await b.store.listing().count == 2)

            // The limit of vaults per profile applies to an added vault.
            for number in 3...StoreFormat.activeVaultLimit {
                _ = try await b.store.createVault(
                    name: "Vault \(number)", unlock: VaultFixtures.proof(UInt8(10 + number)),
                    authorizedBy: .unlockedVault(vaultID: ownID, access: accessB)
                )
            }
            #expect(try await b.store.listing().count == StoreFormat.activeVaultLimit)
            let second = VaultFixtures.proof(3)
            let secondID = try await a.store.createVault(name: "Second", unlock: second, authorizedBy: .unlockedVault(vaultID: vaultID, access: accessA))
            let secondAccess = try await a.unlock(secondID, second)
            let more = try await a.record(of: secondID, second, access: secondAccess)
            await #expect(throws: CredentialStoreError.tooManyVaults) {
                _ = try await b.store.adoptVault(more, authorizedBy: .unlockedVault(vaultID: ownID, access: accessB))
            }
            #expect(try await b.store.listing().count == StoreFormat.activeVaultLimit)
        }
    }
}

private struct SyncStoreFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
