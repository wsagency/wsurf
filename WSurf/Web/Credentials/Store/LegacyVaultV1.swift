// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Read-only access to the v1 vault file, used only by migration (spec §10 step 1). Nothing here writes.
nonisolated enum LegacyVaultV1 {
    nonisolated struct Opened {
        let vaultID: UUID
        let dek: SymmetricKey
        let payload: CredentialVaultPayload
        let wrappers: [CredentialKeyWrapper]
    }

    /// The v1 file's bytes (B0), read once and capped one byte past the format limit so an oversized file is detected, not loaded.
    static func readEnvelope(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: CredentialVaultLimits.fileBytes + 1) ?? Data()
        guard bytes.count <= CredentialVaultLimits.fileBytes else { throw CredentialVaultError.oversized }
        return bytes
    }

    /// Decodes `bytes` for `profileID` and opens its DEK and payload with the proof's credential and PRF output, so the key and the
    /// accounts always correspond to these exact bytes. A credential that is not enrolled or a wrong PRF is `authenticationFailed`.
    static func open(
        _ bytes: Data, profileID: UUID, proof: VaultUnlockProof
    ) throws -> Opened {
        try open(bytes, profileID: profileID, credentialID: proof.credentialID, prf: proof.prf)
    }

    static func open(
        _ bytes: Data, profileID: UUID, credentialID: Data, prf: SymmetricKey
    ) throws -> Opened {
        let envelope = try CredentialVaultCrypto.decodeEnvelope(bytes, profileID: profileID)
        guard let wrapper = envelope.wrappers.first(where: { $0.credentialID == credentialID }) else {
            throw CredentialVaultError.authenticationFailed
        }
        let dek = SymmetricKey(data: try CredentialVaultCrypto.unwrap(wrapper, prf: prf, profileID: profileID, vaultID: envelope.vaultID))
        let payload = try CredentialVaultCrypto.openPayload(
            envelope.payload, key: dek, profileID: profileID, vaultID: envelope.vaultID, wrappers: envelope.wrappers
        )
        return Opened(vaultID: envelope.vaultID, dek: dek, payload: payload, wrappers: envelope.wrappers)
    }
}
