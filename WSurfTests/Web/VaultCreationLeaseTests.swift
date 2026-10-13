// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

// Creation authorization crosses the store boundary: every `VaultCreationAuthority` carries a creation-scoped `VaultAccess` that the
// caller can revoke. The store checks it under the operation lock before the first durable write and again at the commit point.

enum LeasePath: CaseIterable, CustomTestStringConvertible {
    case firstVault, existingPasskey, unlockedVault

    var testDescription: String {
        "\(self)"
    }
}

enum LeaseFault: CaseIterable, CustomTestStringConvertible {
    case revokedWhileWaiting, expiredWhileWaiting

    var testDescription: String {
        "\(self)"
    }
}

/// Everything durable a refused creation must leave alone, except the empty operation lock file and SQLite's own sidecars.
private struct StateImage: Equatable {
    var files: [String: Data]
    var names: [String]
    var rows: [String: [String]]
    var defaults: [String: String]
}

/// One creation path wired to a store on the shared test clock, and the lease it is authorized by.
private struct LeaseRig {
    let env: VaultTestEnvironment
    let lease: VaultAccess
    let create: () async throws -> UUID
    /// First-vault path only: a creation under another lease on the same store.
    var createUnder: ((VaultAccess) async throws -> UUID)?
    let listing: () async throws -> [Int]
    let rows: () throws -> [String: [String]]

    func image() throws -> StateImage {
        func isStoreSidecar(_ name: String) -> Bool {
            name.hasSuffix("-wal") || name.hasSuffix("-shm")
        }
        var files = try directoryImage(env.directory)
        for name in files.keys where isStoreSidecar(name) {
            files[name] = nil
        }
        files["Credentials.store"] = nil  // compared as rows: a closed pool may rewrite header bytes
        let names = try FileManager.default.subpathsOfDirectory(atPath: env.directory.path)
            .filter { !isStoreSidecar($0) && $0 != "Credentials.lock" }.sorted()
        return StateImage(files: files, names: names, rows: try rows(), defaults: VaultStoreFixture.defaultsImage(of: env.defaults))
    }
}

private let lockWait = Duration.seconds(30)

/// `leaseProfile`: the profile the creation lease names (`nil` = the store's own). For `.unlockedVault` the lease is the source vault's
/// grant, so a foreign profile is a foreign access presented next to a good grant.
private func withLeaseRig(
    _ path: LeasePath, leaseProfile: UUID?, fileOps: (VaultAccess) -> StoreFileOps, _ body: (LeaseRig) async throws -> Void
) async throws {
    func lease(_ env: VaultTestEnvironment, profile: UUID? = nil) -> VaultAccess {
        VaultAccess(profileID: profile ?? env.profileID, epoch: 1, deadline: env.clock.now.advanced(by: .seconds(60)))
    }
    switch path {
    case .firstVault:
        try await VaultStoreFixture.withEnvironment { env, tracker in
            let lease = lease(env, profile: leaseProfile)
            let clock = env.clock
            let store = tracker.makeStore(env: env, fileOps: fileOps(lease), lockWait: lockWait, now: { clock.now })
            try await body(
                LeaseRig(
                    env: env, lease: lease,
                    create: { try await store.createVault(name: "Personal", unlock: VaultFixtures.proof(), authorizedBy: .firstVault(lease: lease)) },
                    createUnder: {
                        try await store.createVault(name: "Personal", unlock: VaultFixtures.proof(), authorizedBy: .firstVault(lease: $0))
                    },
                    listing: { try await store.listing().map(\.ordinal) },
                    rows: { [:] }
                )
            )
        }
    case .existingPasskey, .unlockedVault:
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let grantAccess = lease(f.env)
            let presented = path == .unlockedVault ? (leaseProfile.map { lease(f.env, profile: $0) } ?? grantAccess) : lease(f.env, profile: leaseProfile)
            let clock = f.env.clock
            let store = f.makeStore(fileOps: fileOps(presented), lockWait: lockWait, now: { clock.now })
            let proof = f.proof
            let created = path == .existingPasskey ? proof : VaultFixtures.proof(9)  // an existing-passkey creation wraps for that passkey
            let authority: VaultCreationAuthority
            if path == .unlockedVault {
                try await store.unlockInitialized(
                    vaultID: f.vaultID, credentialID: proof.credentialID, prf: proof.prf, access: grantAccess, verifying: nil, scratchWarning: nil
                )
                authority = .unlockedVault(vaultID: f.vaultID, access: presented)
            } else {
                authority = .existingPasskey(vaultID: f.vaultID, credentialID: proof.credentialID, prf: proof.prf, lease: presented)
            }
            try await body(
                LeaseRig(
                    env: f.env, lease: presented,
                    create: { try await store.createVault(name: "Created", unlock: created, authorizedBy: authority) },
                    listing: { try await store.listing().map(\.ordinal) },
                    rows: {
                        try f.read { db in
                            var image: [String: [String]] = [:]
                            for table in ["vault", "head", "record", "journal", "registry"] {
                                image[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2").map { row in
                                    row.columnNames.map { "\($0)=\(row[$0] as DatabaseValue)" }.joined(separator: "|")
                                }
                            }
                            return image
                        }
                    }
                )
            )
        }
    }
}

/// The error a dead lease produces. The unlocked-vault path re-checks its source grant first and reports `noAuthority` for any failure of it.
private func expectDeadLease(_ failure: (any Error)?, path: LeasePath, _ expected: CredentialVaultError, sourceLocation: SourceLocation = #_sourceLocation) {
    if path == .unlockedVault {
        #expect(failure as? CredentialStoreError == .noAuthority, sourceLocation: sourceLocation)
    } else {
        #expect(failure as? CredentialVaultError == expected, sourceLocation: sourceLocation)
    }
}

struct VaultCreationLeaseTests {
    private static let noHooks: (VaultAccess) -> StoreFileOps = { _ in .live }

    /// The lease dies while creation waits for the operation lock: it writes nothing (no pending or stub file, no row, no A3).
    @Test(arguments: LeasePath.allCases, LeaseFault.allCases)
    func leaseThatDiesWhileCreationWaitsForTheLockWritesNothing(path: LeasePath, fault: LeaseFault) async throws {
        try await withLeaseRig(path, leaseProfile: nil, fileOps: Self.noHooks) { rig in
            let external = try await OperationLock.acquire(in: rig.env.directory, mode: .exclusive)
            let before = try rig.image()
            let running = Task { try await rig.create() }
            try await Task.sleep(for: .milliseconds(200))  // the creation is polling the held lock

            switch fault {
            case .revokedWhileWaiting:
                rig.lease.revoke()
            case .expiredWhileWaiting:
                rig.env.clock.advance(by: .seconds(61))
            }
            external.release()

            let failure = await Result { try await running.value }.error
            expectDeadLease(failure, path: path, fault == .revokedWhileWaiting ? .unauthorized : .expired)
            #expect(try rig.image() == before)
            #expect(try await rig.listing() == (path == .firstVault ? [] : [1, 2]))
        }
    }

    @Test(arguments: LeasePath.allCases)
    func leaseOfAnotherProfileWritesNothing(path: LeasePath) async throws {
        try await withLeaseRig(path, leaseProfile: UUID(), fileOps: Self.noHooks) { rig in
            let before = try rig.image()
            let failure = await Result { try await rig.create() }.error
            expectDeadLease(failure, path: path, .unauthorized)
            #expect(try rig.image() == before)
            #expect(try await rig.listing() == (path == .firstVault ? [] : [1, 2]))
        }
    }

    /// A revocation after the first check and before the publish rename: the vault file that makes the bootstrap observable is never
    /// created and A3 is never set, and the pending store and stub this call created are removed, so the directory is `.firstRun` again
    /// and a creation under a fresh lease succeeds.
    @Test func leaseRevokedBeforeTheBootstrapPublishRenamePublishesNothing() async throws {
        try await withLeaseRig(
            .firstVault, leaseProfile: nil,
            fileOps: { lease in
                var ops = StoreFileOps.live
                ops.afterMigrationStep = { if $0 == 6 { lease.revoke() } }  // after the stub is in `.swap`, before `.swap` -> `Credentials.vault`
                return ops
            }
        ) { rig in
            let failure = await Result { try await rig.create() }.error
            #expect(failure as? CredentialVaultError == .unauthorized)
            for name in ["Credentials.vault", "Credentials.store", "Credentials.store.migrating", "Credentials.vault.swap"] {
                #expect(!StoreAnchors.exists(anchorURL(rig.env.directory, name)), "\(name)")
            }
            #expect(rig.env.defaults.object(forKey: StoreAnchors.witnessKey) == nil)

            let createUnder = try #require(rig.createUnder)
            _ = try await createUnder(VaultAccess(profileID: rig.env.profileID, epoch: 2, deadline: rig.env.clock.now.advanced(by: .seconds(60))))
            #expect(try await rig.listing() == [1])
            #expect(StoreAnchors.exists(anchorURL(rig.env.directory, "Credentials.store")))
        }
    }

    /// A task that is already cancelled stops at the lease check, before the first durable write.
    @Test func cancelledCreationWritesNothingAndTheNextOneSucceeds() async throws {
        try await withLeaseRig(.firstVault, leaseProfile: nil, fileOps: Self.noHooks) { rig in
            let before = try rig.image()
            let running = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await rig.create()
            }
            let failure = await Result { try await running.value }.error
            #expect(failure is CancellationError)
            #expect(try rig.image() == before)
            _ = try await rig.create()
            #expect(try await rig.listing() == [1])
        }
    }

    /// A revocation that lands during the source vault's verification (here: while the missing stub is repaired) stops the insert, so the
    /// other vaults' rows and the listing stay exactly as they were.
    @Test func leaseRevokedBetweenVerificationAndTheInsertWritesNoVault() async throws {
        try await withLeaseRig(
            .existingPasskey, leaseProfile: nil,
            fileOps: { lease in
                var ops = StoreFileOps.live
                ops.fsyncDirectory = { directory in
                    lease.revoke()
                    try StoreFileOps.live.fsyncDirectory(directory)
                }
                return ops
            }
        ) { rig in
            // The fixture's stub exists, so remove it: the verification then repairs it and fsyncs the directory.
            try FileManager.default.removeItem(at: anchorURL(rig.env.directory, "Credentials.vault"))
            let before = try rig.image()
            let failure = await Result { try await rig.create() }.error
            #expect(failure as? CredentialVaultError == .unauthorized)
            #expect(try rig.image().rows == before.rows)
            #expect(try await rig.listing() == [1, 2])
        }
    }
}
