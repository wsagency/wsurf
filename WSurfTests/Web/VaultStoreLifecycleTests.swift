// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The store's lifecycle root guard: after `close()` no operation (started before or after) may touch the profile directory, because the
// directory may already have been erased and recreating it would resurrect the profile's credential files.

/// Every place the store takes the operation lock.
enum LockPath: CaseIterable, CustomTestStringConvertible {
    case listing, discovery, unlockProvisional, unlockMigrating, listingLegacy, createFirstVault, createUnlockedVault, createExistingPasskey

    var testDescription: String {
        "\(self)"
    }
}

private typealias StoreOperation = (ProfileVaultStore) async throws -> Void

/// A store (long `lockWait`: the operation must still be waiting when the test acts) and the one operation of `path` on it, on a directory
/// in the state that path needs.
private func withLockPath(
    _ path: LockPath, _ body: (VaultTestEnvironment, ProfileVaultStore, @escaping StoreOperation) async throws -> Void
) async throws {
    let lockWait = Duration.seconds(30)
    switch path {
    case .listing, .discovery, .unlockProvisional, .createUnlockedVault, .createExistingPasskey:
        try await VaultStoreFixture.with { f in
            let store = f.makeStore(lockWait: lockWait)
            let access = f.beginAccess()
            let proof = f.proof
            let operation: StoreOperation
            switch path {
            case .listing:
                operation = { _ = try await $0.listing() }
            case .discovery:
                operation = { _ = try await $0.discovery(vaultID: f.vaultID) }
            case .unlockProvisional:
                operation = {
                    try await $0.unlock(
                        vaultID: f.vaultID, credentialID: proof.credentialID, prf: proof.prf, confirmMigration: false, access: access,
                        verifying: nil, scratchWarning: nil
                    )
                }
            case .createUnlockedVault:
                try await store.unlock(
                    vaultID: f.vaultID, credentialID: proof.credentialID, prf: proof.prf, confirmMigration: false, access: access,
                    verifying: nil, scratchWarning: nil
                )
                operation = {
                    _ = try await $0.createVault(
                        name: "New", unlock: VaultFixtures.proof(9), authorizedBy: .unlockedVault(vaultID: f.vaultID, access: access)
                    )
                }
            default:
                operation = {
                    _ = try await $0.createVault(
                        name: "New", unlock: proof,
                        authorizedBy: .existingPasskey(vaultID: f.vaultID, credentialID: proof.credentialID, prf: proof.prf, lease: access)
                    )
                }
            }
            try await body(f.env, store, operation)
        }
    case .unlockMigrating, .listingLegacy:
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let legacy = try LegacyV1.make(profileID: env.profileID)
            try legacy.write(to: env.directory)
            let store = tracker.makeStore(env: env, lockWait: lockWait)
            try await body(env, store, path == .listingLegacy ? { _ = try await $0.listing() } : {
                try await $0.unlock(
                    vaultID: legacy.vaultID, credentialID: legacy.proof.credentialID, prf: legacy.proof.prf, confirmMigration: true,
                    access: newAccess(env.profileID), verifying: nil, scratchWarning: nil
                )
            })
        }
    case .createFirstVault:
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let store = tracker.makeStore(env: env, lockWait: lockWait)
            try await body(env, store, {
                _ = try await $0.createVault(
                    name: "Personal", unlock: VaultFixtures.proof(), authorizedBy: .firstVault(lease: newAccess(env.profileID))
                )
            })
        }
    }
}

private func fileListing(_ directory: URL) throws -> [String] {
    try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
}

struct VaultStoreLifecycleTests {
    /// An operation waiting for the operation lock when the store closes and the directory is erased wakes up to `unauthorized` and
    /// does not recreate the directory or its lock file.
    @Test(arguments: LockPath.allCases)
    func closeWhileWaitingForTheLockAbortsWithoutRecreatingTheDirectory(path: LockPath) async throws {
        try await withLockPath(path) { env, store, operation in
            let external = try await OperationLock.acquire(in: env.directory, mode: .exclusive)
            let (started, signal) = AsyncStream.makeStream(of: Void.self)
            let running = Task {
                signal.yield()  // no suspension between this and the call into the store: the operation is queued on the store before the test resumes
                try await operation(store)
            }
            for await _ in started {
                break
            }
            try await Task.sleep(for: .milliseconds(200))  // the operation is polling the held lock

            await store.close()
            try FileManager.default.removeItem(at: env.directory)
            external.release()

            let failure = await Result { try await running.value }.error
            #expect(failure as? CredentialVaultError == .unauthorized)
            #expect(!FileManager.default.fileExists(atPath: env.directory.path))
        }
    }

    /// `closed` is permanent: an operation started after `close()` throws `unauthorized` and changes nothing in a present directory.
    @Test(arguments: LockPath.allCases)
    func operationAfterCloseLeavesAPresentDirectoryByteIdentical(path: LockPath) async throws {
        try await withLockPath(path) { env, store, operation in
            await store.close()
            let image = try VaultStoreFixture.directoryImage(of: env.directory)
            let listing = try fileListing(env.directory)

            let failure = await Result { try await operation(store) }.error
            if path == .createUnlockedVault {  // `close()` revoked the source grant, which that path checks before it asks for the lock
                #expect(failure as? CredentialStoreError == .noAuthority)
            } else {
                #expect(failure as? CredentialVaultError == .unauthorized)
            }
            #expect(try VaultStoreFixture.directoryImage(of: env.directory) == image)
            #expect(try fileListing(env.directory) == listing)
        }
    }

    /// The paths that take the lock without any earlier state read must not create the directory either.
    @Test(arguments: [LockPath.createFirstVault, .createExistingPasskey])
    func operationAfterCloseNeverCreatesAnAbsentDirectory(path: LockPath) async throws {
        try await withLockPath(path) { env, store, operation in
            try FileManager.default.removeItem(at: env.directory)
            await store.close()

            let failure = await Result { try await operation(store) }.error
            #expect(failure as? CredentialVaultError == .unauthorized)
            #expect(!FileManager.default.fileExists(atPath: env.directory.path))
        }
    }
}
