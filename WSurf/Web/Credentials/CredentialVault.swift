// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Synchronization

// ponytail: serializes writers in this process only; use an OS file lock if multiple processes can mutate a vault.
nonisolated enum CredentialVaultMutation {
    static let lock = Mutex(())
}
actor CredentialVault {
    private let profileID: UUID
    private let directory: URL
    private let fileURL: URL
    private let now: @Sendable () -> ContinuousClock.Instant
    private var dataKey: SymmetricKey?
    private var activeAccess: VaultAccess?

    init(
        profileID: UUID,
        directory: URL,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) throws {
        guard profileID != Profile.privateID else { throw CredentialVaultError.privateBrowsing }
        self.profileID = profileID
        self.directory = directory
        fileURL = directory.appendingPathComponent("Credentials.vault", isDirectory: false)
        self.now = now
    }

    func discovery() throws -> VaultDiscovery {
        let envelope = try loadEnvelope()
        return VaultDiscovery(
            vaultID: envelope.vaultID,
            unlocks: envelope.wrappers.map(\.unlock).sorted { $0.credentialID.lexicographicallyPrecedes($1.credentialID) }
        )
    }

    func create(unlock proof: VaultUnlockProof, access: VaultAccess) throws {
        try withMutation {
            guard access.profileID == profileID else { throw CredentialVaultError.unauthorized }
            try CredentialVaultCrypto.validateProof(proof)
            try access.withAuthorization(now: now) {
                guard !FileManager.default.fileExists(atPath: fileURL.path) else { throw CredentialVaultError.alreadyExists }
                let vaultID = UUID()
                let key = SymmetricKey(size: .bits256)
                let wrapper = try CredentialVaultCrypto.wrap(key, with: proof, profileID: profileID, vaultID: vaultID)
                let empty = CredentialVaultPayload(revision: 0, accounts: [], blockedPasswordOrigins: [])
                let sealed = try CredentialVaultCrypto.sealPayload(empty, key: key, profileID: profileID, vaultID: vaultID, wrappers: [wrapper])
                let envelope = CredentialVaultEnvelope(format: CredentialVaultCrypto.format, profileID: profileID, vaultID: vaultID, wrappers: [wrapper], payload: sealed)
                try write(envelope, deadline: access.deadline)
                if activeAccess !== access {
                    activeAccess?.revoke()
                }
                activeAccess = access
                dataKey = key
            }
        }
    }

    func unlock(credentialID: Data, prf: SymmetricKey, access: VaultAccess) throws {
        guard access.profileID == profileID else { throw CredentialVaultError.unauthorized }
        try access.withAuthorization(now: now) {
            let envelope = try loadEnvelope()
            guard let wrapper = envelope.wrappers.first(where: { $0.credentialID == credentialID }) else {
                throw CredentialVaultError.authenticationFailed
            }
            let keyData = try CredentialVaultCrypto.unwrap(wrapper, prf: prf, profileID: profileID, vaultID: envelope.vaultID)
            let key = SymmetricKey(data: keyData)
            _ = try CredentialVaultCrypto.openPayload(
                envelope.payload,
                key: key,
                profileID: profileID,
                vaultID: envelope.vaultID,
                wrappers: envelope.wrappers
            )
            if activeAccess !== access {
                activeAccess?.revoke()
            }
            activeAccess = access
            dataKey = key
        }
    }

    func snapshot(using access: VaultAccess) throws -> VaultSnapshot {
        try withKey(using: access) { key in
            let envelope = try loadEnvelope()
            let payload = try CredentialVaultCrypto.openPayload(
                envelope.payload,
                key: key,
                profileID: profileID,
                vaultID: envelope.vaultID,
                wrappers: envelope.wrappers
            )
            return VaultSnapshot(revision: payload.revision, accounts: payload.accounts, blockedPasswordOrigins: payload.blockedPasswordOrigins)
        }
    }

    func commit(_ accounts: [CredentialAccount], expectedRevision: UInt64, using access: VaultAccess) throws -> VaultCommitReceipt {
        try withMutation {
            try withKey(using: access) { key in
                let envelope = try loadEnvelope()
                let current = try CredentialVaultCrypto.openPayload(
                    envelope.payload,
                    key: key,
                    profileID: profileID,
                    vaultID: envelope.vaultID,
                    wrappers: envelope.wrappers
                )
                guard current.revision == expectedRevision else { throw CredentialVaultError.staleRevision }
                let nextRevision = try increment(expectedRevision)
                let updated = CredentialVaultPayload(
                    revision: nextRevision,
                    accounts: accounts,
                    blockedPasswordOrigins: current.blockedPasswordOrigins
                )
                let replacement = try reseal(updated, envelope: envelope, key: key)
                try write(replacement, deadline: access.deadline)
                return VaultCommitReceipt(revision: nextRevision)
            }
        }
    }

    func updatePasswordSavePolicy(_ blockedOrigins: Set<String>, expectedRevision: UInt64, using access: VaultAccess) throws -> VaultCommitReceipt {
        try withMutation {
            try withKey(using: access) { key in
                let envelope = try loadEnvelope()
                let current = try CredentialVaultCrypto.openPayload(
                    envelope.payload,
                    key: key,
                    profileID: profileID,
                    vaultID: envelope.vaultID,
                    wrappers: envelope.wrappers
                )
                guard current.revision == expectedRevision else { throw CredentialVaultError.staleRevision }
                let nextRevision = try increment(expectedRevision)
                let updated = CredentialVaultPayload(revision: nextRevision, accounts: current.accounts, blockedPasswordOrigins: blockedOrigins)
                let replacement = try reseal(updated, envelope: envelope, key: key)
                try write(replacement, deadline: access.deadline)
                return VaultCommitReceipt(revision: nextRevision)
            }
        }
    }

    func addUnlock(_ proof: VaultUnlockProof, using access: VaultAccess) throws -> VaultCommitReceipt {
        try withMutation {
            try CredentialVaultCrypto.validateProof(proof)
            return try withKey(using: access) { key in
                let envelope = try loadEnvelope()
                guard !envelope.wrappers.contains(where: { $0.credentialID == proof.credentialID }) else {
                    throw CredentialVaultError.duplicateIdentifier
                }
                guard envelope.wrappers.count < CredentialVaultLimits.wrappers else { throw CredentialVaultError.oversized }
                let current = try CredentialVaultCrypto.openPayload(
                    envelope.payload,
                    key: key,
                    profileID: profileID,
                    vaultID: envelope.vaultID,
                    wrappers: envelope.wrappers
                )
                let newWrapper = try CredentialVaultCrypto.wrap(key, with: proof, profileID: profileID, vaultID: envelope.vaultID)
                var wrappers = envelope.wrappers
                wrappers.append(newWrapper)
                let nextRevision = try increment(current.revision)
                let updated = CredentialVaultPayload(revision: nextRevision, accounts: current.accounts, blockedPasswordOrigins: current.blockedPasswordOrigins)
                let sealed = try CredentialVaultCrypto.sealPayload(updated, key: key, profileID: profileID, vaultID: envelope.vaultID, wrappers: wrappers)
                let replacement = CredentialVaultEnvelope(format: envelope.format, profileID: profileID, vaultID: envelope.vaultID, wrappers: wrappers, payload: sealed)
                try write(replacement, deadline: access.deadline)
                return VaultCommitReceipt(revision: nextRevision)
            }
        }
    }

    func removeUnlock(credentialID: Data, verifiedRemaining: VaultUnlockProof, using access: VaultAccess) throws -> VaultCommitReceipt {
        try withMutation {
            try CredentialVaultCrypto.validateProof(verifiedRemaining)
            return try withKey(using: access) { key in
                guard credentialID != verifiedRemaining.credentialID else { throw CredentialVaultError.noUnlocks }
                let envelope = try loadEnvelope()
                guard envelope.wrappers.count > 1 else { throw CredentialVaultError.noUnlocks }
                guard let verifiedWrapper = envelope.wrappers.first(where: { $0.credentialID == verifiedRemaining.credentialID }) else {
                    throw CredentialVaultError.authenticationFailed
                }
                let verifiedKey = try CredentialVaultCrypto.unwrap(
                    verifiedWrapper,
                    prf: verifiedRemaining.prf,
                    profileID: profileID,
                    vaultID: envelope.vaultID
                )
                guard key.withUnsafeBytes({ Data($0) }) == verifiedKey else { throw CredentialVaultError.authenticationFailed }
                guard envelope.wrappers.contains(where: { $0.credentialID == credentialID }) else { throw CredentialVaultError.invalidData }
                let current = try CredentialVaultCrypto.openPayload(
                    envelope.payload,
                    key: key,
                    profileID: profileID,
                    vaultID: envelope.vaultID,
                    wrappers: envelope.wrappers
                )
                let wrappers = envelope.wrappers.filter { $0.credentialID != credentialID }
                guard !wrappers.isEmpty else { throw CredentialVaultError.noUnlocks }
                let nextRevision = try increment(current.revision)
                let updated = CredentialVaultPayload(revision: nextRevision, accounts: current.accounts, blockedPasswordOrigins: current.blockedPasswordOrigins)
                let sealed = try CredentialVaultCrypto.sealPayload(updated, key: key, profileID: profileID, vaultID: envelope.vaultID, wrappers: wrappers)
                let replacement = CredentialVaultEnvelope(format: envelope.format, profileID: profileID, vaultID: envelope.vaultID, wrappers: wrappers, payload: sealed)
                try write(replacement, deadline: access.deadline)
                return VaultCommitReceipt(revision: nextRevision)
            }
        }
    }

    func lock() {
        activeAccess?.revoke()
        activeAccess = nil
        dataKey = nil
    }

    func lock(ifUsing access: VaultAccess) {
        guard activeAccess === access else { return }
        lock()
    }

    private func withMutation<T>(_ operation: () throws -> T) throws -> T {
        try CredentialVaultMutation.lock.withLock { _ in try operation() }
    }

    private func withKey<T>(
        using access: VaultAccess,
        operation: (SymmetricKey) throws -> T
    ) throws -> T {
        guard access.profileID == profileID, activeAccess === access, let key = dataKey else {
            throw CredentialVaultError.unauthorized
        }
        return try access.withAuthorization(now: now) {
            guard self.activeAccess === access, self.dataKey != nil else { throw CredentialVaultError.unauthorized }
            return try operation(key)
        }
    }

    private func loadEnvelope() throws -> CredentialVaultEnvelope {
        try CredentialVaultCrypto.decodeEnvelope(readFile(), profileID: profileID)
    }

    private func readFile() throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw CredentialVaultError.missingVault }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CredentialVaultError.corruptVault }
        if let fileSize = attributes[.size] as? NSNumber, fileSize.uint64Value > UInt64(CredentialVaultLimits.fileBytes) {
            throw CredentialVaultError.oversized
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(min(CredentialVaultLimits.fileBytes, (attributes[.size] as? NSNumber)?.intValue ?? 0))
        while result.count <= CredentialVaultLimits.fileBytes {
            let remaining = CredentialVaultLimits.fileBytes + 1 - result.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= CredentialVaultLimits.fileBytes else { throw CredentialVaultError.oversized }
        return result
    }

    private func write(_ envelope: CredentialVaultEnvelope, deadline: ContinuousClock.Instant) throws {
        try CredentialVaultCrypto.validateEnvelope(envelope, profileID: profileID)
        let bytes = try CredentialVaultCrypto.encodeEnvelope(envelope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CredentialVaultError.corruptVault }
        }
        // ponytail: rewrite one bounded 8 MB envelope; split files only if measured I/O needs it.
        guard now() < deadline else { throw CredentialVaultError.expired }
        try Task.checkCancellation()
        try bytes.write(to: fileURL, options: .atomic)
    }

    private func reseal(_ payload: CredentialVaultPayload, envelope: CredentialVaultEnvelope, key: SymmetricKey) throws -> CredentialVaultEnvelope {
        let sealed = try CredentialVaultCrypto.sealPayload(
            payload,
            key: key,
            profileID: profileID,
            vaultID: envelope.vaultID,
            wrappers: envelope.wrappers
        )
        return CredentialVaultEnvelope(
            format: envelope.format,
            profileID: profileID,
            vaultID: envelope.vaultID,
            wrappers: envelope.wrappers,
            payload: sealed
        )
    }

    private func increment(_ revision: UInt64) throws -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { throw CredentialVaultError.invalidData }
        return next
    }
}
