// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Synchronization

@testable import WSurf

// Task 9 shared test plumbing: a real v1 vault file, a file-ops wrapper that records and injects, and directory images.

/// Thrown from the `afterMigrationStep` seam to stop an operation after a chosen step (a crash at that point).
nonisolated struct SeamStop: Error, Equatable {
    let step: Int
}

nonisolated final class ProbeLog: Sendable {
    private let items = Mutex<[String]>([])

    func add(_ value: String) {
        items.withLock { $0.append(value) }
    }

    var all: [String] {
        items.withLock { $0 }
    }
}

/// A real v1 vault file built with `CredentialVaultCrypto`: B0 plus everything its payload holds.
nonisolated struct LegacyV1 {
    let profileID: UUID
    let vaultID: UUID
    let dek: SymmetricKey
    let proof: VaultUnlockProof
    let accounts: [CredentialAccount]
    let blocked: Set<String>
    let wrappers: [CredentialKeyWrapper]
    let bytes: Data

    static func make(
        profileID: UUID,
        accounts: [CredentialAccount] = [VaultFixtures.account()],
        blocked: Set<String> = [],
        proof: VaultUnlockProof = VaultFixtures.proof(),
        extraProofs: [VaultUnlockProof] = [],
        vaultID: UUID = UUID()
    ) throws -> LegacyV1 {
        let dek = SymmetricKey(size: .bits256)
        let wrappers = try ([proof] + extraProofs).map {
            try CredentialVaultCrypto.wrap(dek, with: $0, profileID: profileID, vaultID: vaultID)
        }
        let payload = CredentialVaultPayload(revision: 7, accounts: accounts, blockedPasswordOrigins: blocked)
        let sealed = try CredentialVaultCrypto.sealPayload(payload, key: dek, profileID: profileID, vaultID: vaultID, wrappers: wrappers)
        let envelope = CredentialVaultEnvelope(format: CredentialVaultCrypto.format, profileID: profileID, vaultID: vaultID, wrappers: wrappers, payload: sealed)
        return LegacyV1(
            profileID: profileID, vaultID: vaultID, dek: dek, proof: proof, accounts: accounts, blocked: blocked, wrappers: wrappers,
            bytes: try CredentialVaultCrypto.encodeEnvelope(envelope)
        )
    }

    func write(to directory: URL) throws {
        try bytes.write(to: directory.appendingPathComponent("Credentials.vault", isDirectory: false))
    }
}

/// The names of every `-wal`/`-shm` beside the pending store.
nonisolated func pendingSidecars(in directory: URL) -> [String] {
    ["Credentials.store.migrating-wal", "Credentials.store.migrating-shm"].filter {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
}

/// `StoreFileOps.live` that records the pending sidecars at every call and runs `hook` after each step. `onRenameSwap` replaces the swap.
nonisolated func probingOps(
    in directory: URL,
    log: ProbeLog? = nil,
    hook: (@Sendable (Int) throws -> Void)? = nil,
    renameSwap: (@Sendable (URL, URL) throws -> Void)? = nil
) -> StoreFileOps {
    let live = StoreFileOps.live
    let observe: @Sendable (String) -> Void = { log?.add("\($0): \(pendingSidecars(in: directory))") }
    var ops = live
    ops.fullFsync = { url in
        observe("fullFsync")
        try live.fullFsync(url)
    }
    ops.fsyncDirectory = { url in
        observe("fsyncDirectory")
        try live.fsyncDirectory(url)
    }
    ops.renameExclusive = { from, to in
        observe("renameExclusive")
        try live.renameExclusive(from, to)
    }
    ops.renameSwap = { from, to in
        observe("renameSwap")
        if let renameSwap {
            try renameSwap(from, to)
        } else {
            try live.renameSwap(from, to)
        }
    }
    ops.afterMigrationStep = { step in
        observe("step\(step)")
        try hook?(step)
    }
    return ops
}

/// Throws `SeamStop` after `step`.
nonisolated func stopping(after step: Int) -> @Sendable (Int) throws -> Void {
    { if $0 == step { throw SeamStop(step: step) } }
}

/// Relative path → bytes of every regular file, without the empty `Credentials.lock` the operation lock creates.
nonisolated func directoryImage(_ directory: URL) throws -> [String: Data] {
    var image = try VaultStoreFixture.directoryImage(of: directory)
    image["Credentials.lock"] = nil
    return image
}

nonisolated func anchorURL(_ directory: URL, _ name: String) -> URL {
    directory.appendingPathComponent(name, isDirectory: false)
}

/// Flips the first byte of every record's sealed bytes: a store whose records no longer authenticate. Opened and closed by the same
/// no-persist recipe as the pending store (a plain connection would leave `-wal`/`-shm`, which the migration refuses to publish
/// past). Synchronous, so GRDB's blocking overload is chosen.
nonisolated func flipFirstRecord(inStoreAt file: URL) throws {
    let queue = try PendingStore.open(at: file)
    try queue.write { (db: Database) throws in
        for row in try Row.fetchAll(db, sql: "SELECT vaultID, recordID, sealed FROM record") {
            let sealed: Data = row["sealed"]
            try db.execute(
                sql: "UPDATE record SET sealed = ? WHERE vaultID = ? AND recordID = ?",
                arguments: [VaultStoreFixture.flipped(sealed), row["vaultID"] as String, row["recordID"] as String]
            )
        }
    }
    try PendingStore.finish(queue, at: file)
}

nonisolated func newAccess(_ profileID: UUID, epoch: UInt64 = 1) -> VaultAccess {
    VaultAccess(profileID: profileID, epoch: epoch, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
}

/// The active vault rows of a store file, read without creating a sidecar (a read-only `immutable=1` connection, as the anchors do).
nonisolated func activeVaultIDs(inStoreAt file: URL) throws -> [UUID] {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: file.absoluteString + "?immutable=1", configuration: configuration)
    return try queue.read { try StoreTables.vaultRows($0) }.filter { $0.role == .active }.sorted { $0.ordinal < $1.ordinal }.map(\.vaultID)
}
