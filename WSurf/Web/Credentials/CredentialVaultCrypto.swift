// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Synchronization

nonisolated enum CredentialVaultLimits {
    /// The v1 file format (`Credentials.vault`): its sealed payload and its plaintext. Also the cap on every single field.
    static let payloadBytes = 4_000_000
    /// The v1 file format only: the whole file.
    static let fileBytes = 8_000_000
    /// The v1 file format only: accounts in one legacy payload, so a migrated vault always fits the live caps below.
    static let legacyAccounts = 1_000
    /// Live accounts in one vault. Also the kept items, and the collections, in one transfer.
    static let accounts = 25_000
    /// Credentials in one transfer, imported or exported.
    static let credentials = 100_000
    /// Plaintext bytes of one account (the store) or of one item (an import). It is the old whole-vault cap, so a history row,
    /// which holds at most one account, stays inside the 8 MB bound of the spec by the same argument as before.
    static let accountBytes = 4_000_000
    /// Plaintext bytes of all live accounts plus the blocked origins (the store), or of one whole transfer (an import).
    static let liveBytes = 128_000_000
    /// The most bytes one account may take once encoded as canonical JSON (with the room `CredentialVaultCrypto.storedBytes(of:)`
    /// keeps for what is set later), which is what the store writes. Escaping makes a string up to six times its size and base64
    /// makes data a third larger, so this is checked on the encoding and not on `accountBytes`. A revision or a removed credential
    /// carries part of an account as base64 text inside its row (4/3 of the encoding), and a removed account carries the encoding
    /// itself: 4/3 of this bound plus `StoreFormat.historyBodyBytes` stays inside the 8 MB history row, so no valid account can
    /// become one that cannot be edited, removed or purged.
    static let encodedAccountBytes = 5_900_000
    // ponytail: cap wrappers at 32 to bound manifest hashing and rewrites; raise only if measured use needs it.
    static let wrappers = 32
}

nonisolated enum CredentialVaultError: Error {
    case privateBrowsing
    case invalidData
    case corruptVault
    case wrongProfile
    case authenticationFailed
    case unauthorized
    case expired
    case staleRevision
    case duplicateIdentifier
    case alreadyExists
    case missingVault
    case noUnlocks
    case oversized
}

nonisolated struct VaultUnlockProof: Sendable {
    let credentialID: Data
    let prfInput: Data
    let prf: SymmetricKey
}
nonisolated final class VaultAccess: Sendable {
    let profileID: UUID
    let epoch: UInt64
    /// The end of the access. It starts as the bound on the unlock itself; `beginLease` sets the lease's own end once the unlock
    /// has completed, and from then on it can only move earlier.
    var deadline: ContinuousClock.Instant {
        limit.withLock { $0.deadline }
    }
    private let revoked = Mutex(false)
    private let limit: Mutex<(deadline: ContinuousClock.Instant, leaseBegun: Bool)>

    init(profileID: UUID, epoch: UInt64, deadline: ContinuousClock.Instant) {
        self.profileID = profileID
        self.epoch = epoch
        limit = Mutex((deadline, false))
    }

    /// Ends the access at `instant`, which may be later than the bound on the unlock. Only the first call counts: it is the moment
    /// the vault opens, and nothing afterwards lengthens the access.
    func beginLease(until instant: ContinuousClock.Instant) {
        limit.withLock { state in
            guard !state.leaseBegun else { return }
            state.leaseBegun = true
            state.deadline = instant
        }
    }

    /// Brings the end forward to `instant`; a later one changes nothing.
    func shorten(to instant: ContinuousClock.Instant) {
        limit.withLock { $0.deadline = min($0.deadline, instant) }
    }

    func revoke() {
        revoked.withLock { $0 = true }
    }

    func isAuthorized(at instant: ContinuousClock.Instant) -> Bool {
        revoked.withLock { !$0 && instant < deadline }
    }

    func checkAuthorization(at instant: ContinuousClock.Instant) throws {
        try revoked.withLock { isRevoked in
            guard !isRevoked else { throw CredentialVaultError.unauthorized }
            guard instant < deadline else { throw CredentialVaultError.expired }
        }
    }

    func withAuthorization<T>(
        now: @Sendable () -> ContinuousClock.Instant,
        operation: () throws -> T
    ) throws -> T {
        try revoked.withLock { isRevoked in
            guard !isRevoked else { throw CredentialVaultError.unauthorized }
            guard now() < deadline else { throw CredentialVaultError.expired }
            try Task.checkCancellation()
            return try operation()
        }
    }
}

nonisolated struct VaultCommitReceipt: Sendable, Equatable {
    let revision: UInt64
}

nonisolated struct VaultUnlock: Codable, Sendable {
    let credentialID: Data
    let prfInput: Data
}

nonisolated struct VaultDiscovery: Sendable {
    let vaultID: UUID
    let unlocks: [VaultUnlock]
}

nonisolated struct CredentialVaultPayload: Codable, Sendable {
    var revision: UInt64
    var accounts: [CredentialAccount]
    var blockedPasswordOrigins: Set<String>

    private enum CodingKeys: String, CodingKey { case revision, accounts, blockedPasswordOrigins }

    init(revision: UInt64, accounts: [CredentialAccount], blockedPasswordOrigins: Set<String>) {
        self.revision = revision
        self.accounts = accounts
        self.blockedPasswordOrigins = blockedPasswordOrigins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        var accountValues = try container.nestedUnkeyedContainer(forKey: .accounts)
        guard let accountCount = accountValues.count, accountCount <= CredentialVaultLimits.legacyAccounts else {
            throw CredentialVaultError.oversized
        }
        var decodedAccounts: [CredentialAccount] = []
        decodedAccounts.reserveCapacity(accountCount)
        while !accountValues.isAtEnd {
            decodedAccounts.append(try accountValues.decode(CredentialAccount.self))
        }
        accounts = decodedAccounts

        var originValues = try container.nestedUnkeyedContainer(forKey: .blockedPasswordOrigins)
        guard let originCount = originValues.count, originCount <= 4_096 else { throw CredentialVaultError.oversized }
        var decodedOrigins = Set<String>(minimumCapacity: originCount)
        while !originValues.isAtEnd {
            guard decodedOrigins.insert(try originValues.decode(String.self)).inserted else {
                throw CredentialVaultError.invalidData
            }
        }
        blockedPasswordOrigins = decodedOrigins
    }
}

nonisolated struct CredentialKeyWrapper: Codable, Sendable {
    let credentialID: Data
    let prfInput: Data
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    var unlock: VaultUnlock {
        VaultUnlock(credentialID: credentialID, prfInput: prfInput)
    }
}

nonisolated struct CredentialSealedData: Codable, Sendable {
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

// Bounds are enforced while decoding so a hostile plist cannot make us copy every oversized field first.
// Declared in extensions to keep the memberwise initializers.
nonisolated extension CredentialKeyWrapper {
    private enum CodingKeys: String, CodingKey { case credentialID, prfInput, nonce, ciphertext, tag }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys, _ valid: (Int) -> Bool) throws -> Data {
            let data = try container.decode(Data.self, forKey: key)
            guard valid(data.count) else { throw CredentialVaultError.corruptVault }
            return data
        }
        let unlockField: (Int) -> Bool = { (1...CredentialVaultCrypto.maximumUnlockFieldBytes).contains($0) }
        credentialID = try field(.credentialID, unlockField)
        prfInput = try field(.prfInput, unlockField)
        nonce = try field(.nonce) { $0 == 12 }
        ciphertext = try field(.ciphertext) { $0 == 32 }
        tag = try field(.tag) { $0 == 16 }
    }
}

nonisolated extension CredentialSealedData {
    private enum CodingKeys: String, CodingKey { case nonce, ciphertext, tag }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys, _ valid: (Int) -> Bool) throws -> Data {
            let data = try container.decode(Data.self, forKey: key)
            guard valid(data.count) else { throw CredentialVaultError.corruptVault }
            return data
        }
        nonce = try field(.nonce) { $0 == 12 }
        ciphertext = try field(.ciphertext) { $0 <= CredentialVaultLimits.payloadBytes }
        tag = try field(.tag) { $0 == 16 }
    }
}

nonisolated struct CredentialVaultEnvelope: Codable, Sendable {
    let format: Int
    let profileID: UUID
    let vaultID: UUID
    var wrappers: [CredentialKeyWrapper]
    var payload: CredentialSealedData

    private enum CodingKeys: String, CodingKey { case format, profileID, vaultID, wrappers, payload }

    init(format: Int, profileID: UUID, vaultID: UUID, wrappers: [CredentialKeyWrapper], payload: CredentialSealedData) {
        self.format = format
        self.profileID = profileID
        self.vaultID = vaultID
        self.wrappers = wrappers
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        vaultID = try container.decode(UUID.self, forKey: .vaultID)
        var wrapperValues = try container.nestedUnkeyedContainer(forKey: .wrappers)
        guard let wrapperCount = wrapperValues.count, wrapperCount <= CredentialVaultLimits.wrappers else {
            throw CredentialVaultError.oversized
        }
        var decodedWrappers: [CredentialKeyWrapper] = []
        decodedWrappers.reserveCapacity(wrapperCount)
        while !wrapperValues.isAtEnd {
            decodedWrappers.append(try wrapperValues.decode(CredentialKeyWrapper.self))
        }
        wrappers = decodedWrappers
        payload = try container.decode(CredentialSealedData.self, forKey: .payload)
    }
}

nonisolated enum CredentialVaultCrypto {
    static let format = 1
    private static let wrappingLabel = Data("WSurf vault wrapping v1".utf8)
    static let maximumUnlockFieldBytes = 1_024

    static func validateProof(_ proof: VaultUnlockProof) throws {
        guard !proof.credentialID.isEmpty, proof.credentialID.count <= maximumUnlockFieldBytes,
              !proof.prfInput.isEmpty, proof.prfInput.count <= maximumUnlockFieldBytes,
              proof.prf.withUnsafeBytes({ $0.count == 32 }) else { throw CredentialVaultError.invalidData }
    }

    static func sealPayload(_ payload: CredentialVaultPayload, key: SymmetricKey, profileID: UUID, vaultID: UUID, wrappers: [CredentialKeyWrapper]) throws -> CredentialSealedData {
        let encoded = try encodePayload(payload)
        let aad = payloadAAD(profileID: profileID, vaultID: vaultID, wrappers: wrappers)
        return try seal(encoded, key: key, authenticating: aad)
    }

    static func openPayload(_ sealed: CredentialSealedData, key: SymmetricKey, profileID: UUID, vaultID: UUID, wrappers: [CredentialKeyWrapper]) throws -> CredentialVaultPayload {
        guard sealed.ciphertext.count <= CredentialVaultLimits.payloadBytes,
              sealed.nonce.count == 12, sealed.tag.count == 16 else { throw CredentialVaultError.corruptVault }
        let plaintext = try open(sealed, key: key, authenticating: payloadAAD(profileID: profileID, vaultID: vaultID, wrappers: wrappers))
        guard plaintext.count <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.oversized }
        let payload: CredentialVaultPayload
        do {
            payload = try JSONDecoder().decode(CredentialVaultPayload.self, from: plaintext)
        } catch {
            throw CredentialVaultError.corruptVault
        }
        try validate(payload)
        return payload
    }

    static func wrap(_ dataKey: SymmetricKey, with proof: VaultUnlockProof, profileID: UUID, vaultID: UUID) throws -> CredentialKeyWrapper {
        try validateProof(proof)
        let wrappingKey = deriveWrappingKey(proof.prf, profileID: profileID, vaultID: vaultID)
        let data = dataKey.withUnsafeBytes { Data($0) }
        let sealed = try seal(data, key: wrappingKey, authenticating: wrapperAAD(proof, profileID: profileID, vaultID: vaultID))
        let wrapper = CredentialKeyWrapper(credentialID: proof.credentialID, prfInput: proof.prfInput, nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
        guard try unwrap(wrapper, prf: proof.prf, profileID: profileID, vaultID: vaultID) == data else {
            throw CredentialVaultError.authenticationFailed
        }
        return wrapper
    }

    static func unwrap(_ wrapper: CredentialKeyWrapper, prf: SymmetricKey, profileID: UUID, vaultID: UUID) throws -> Data {
        guard !wrapper.credentialID.isEmpty, wrapper.credentialID.count <= maximumUnlockFieldBytes,
              !wrapper.prfInput.isEmpty, wrapper.prfInput.count <= maximumUnlockFieldBytes,
              wrapper.nonce.count == 12, wrapper.ciphertext.count == 32, wrapper.tag.count == 16,
              prf.withUnsafeBytes({ $0.count == 32 }) else { throw CredentialVaultError.corruptVault }
        let proof = VaultUnlockProof(credentialID: wrapper.credentialID, prfInput: wrapper.prfInput, prf: prf)
        let sealed = CredentialSealedData(nonce: wrapper.nonce, ciphertext: wrapper.ciphertext, tag: wrapper.tag)
        let key = deriveWrappingKey(prf, profileID: profileID, vaultID: vaultID)
        let result = try open(sealed, key: key, authenticating: wrapperAAD(proof, profileID: profileID, vaultID: vaultID))
        guard result.count == 32 else { throw CredentialVaultError.corruptVault }
        return result
    }

    static func validateEnvelope(_ envelope: CredentialVaultEnvelope, profileID: UUID) throws {
        guard envelope.format == format else { throw CredentialVaultError.corruptVault }
        guard envelope.profileID == profileID else { throw CredentialVaultError.wrongProfile }
        guard !envelope.wrappers.isEmpty, envelope.wrappers.count <= CredentialVaultLimits.wrappers,
              envelope.payload.nonce.count == 12, envelope.payload.tag.count == 16,
              envelope.payload.ciphertext.count <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.corruptVault }
        guard Set(envelope.wrappers.map(\.credentialID)).count == envelope.wrappers.count else {
            throw CredentialVaultError.duplicateIdentifier
        }
        for wrapper in envelope.wrappers {
            guard !wrapper.credentialID.isEmpty, wrapper.credentialID.count <= maximumUnlockFieldBytes,
                  !wrapper.prfInput.isEmpty, wrapper.prfInput.count <= maximumUnlockFieldBytes,
                  wrapper.nonce.count == 12, wrapper.ciphertext.count == 32, wrapper.tag.count == 16 else {
                throw CredentialVaultError.corruptVault
            }
        }
    }

    static func encodeEnvelope(_ envelope: CredentialVaultEnvelope) throws -> Data {
        var encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw CredentialVaultError.invalidData
        }
        guard data.count <= CredentialVaultLimits.fileBytes else { throw CredentialVaultError.oversized }
        return data
    }

    static func decodeEnvelope(_ data: Data, profileID: UUID) throws -> CredentialVaultEnvelope {
        guard data.count <= CredentialVaultLimits.fileBytes else { throw CredentialVaultError.oversized }
        guard data.starts(with: Data("bplist00".utf8)) else { throw CredentialVaultError.corruptVault }
        let envelope: CredentialVaultEnvelope
        do {
            envelope = try PropertyListDecoder().decode(CredentialVaultEnvelope.self, from: data)
        } catch {
            throw CredentialVaultError.corruptVault
        }
        try validateEnvelope(envelope, profileID: profileID)
        return envelope
    }

    /// The plaintext bytes the store counts for one account: the size of each variable field, not of its encoding. The store and
    /// the import codec both measure an account with this one function, so what the codec accepts the store keeps.
    static func liveBytes(of account: CredentialAccount) throws -> Int {
        var total = 0
        func add(_ count: Int) throws {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw CredentialVaultError.oversized }
            total = sum
        }
        try add(account.username.utf8.count)
        try add(account.displayName?.utf8.count ?? 0)
        try add(account.password?.utf8.count ?? 0)
        for origin in account.origins {
            try add(origin.utf8.count)
        }
        for url in account.loginURLs {
            try add(url.absoluteString.utf8.count)
        }
        for value in [account.exchangeAccountID, account.exchangeItemID].compactMap({ $0 }) {
            try add(value.count)
        }
        try add(account.exchangeMetadata?.count ?? 0)
        if let metadata = account.basicAuthenticationMetadata {
            for field in [metadata.username, metadata.password].compactMap({ $0 }) {
                try add(field.id?.count ?? 0)
                try add(field.label?.utf8.count ?? 0)
            }
        }
        if let generator = account.totp {
            try add(generator.secret.count)
            try add(generator.issuer?.utf8.count ?? 0)
            try add(generator.userName?.utf8.count ?? 0)
        }
        for link in account.mergedFrom ?? [] {
            try add(link.exchangeAccountID.count)
            try add(link.exchangeItemID.count)
            try add(link.passwordBase?.itemID?.count ?? 0)
            try add(link.totpBase?.itemID?.count ?? 0)
        }
        for note in account.notes ?? [] {
            try add(note.text.utf8.count)
            try add(note.field?.id?.count ?? 0)
            try add(note.field?.label?.utf8.count ?? 0)
        }
        for passkey in account.passkeys {
            try add(passkey.credentialID.count)
            try add(passkey.rpID.utf8.count)
            try add(passkey.userHandle.count)
            try add(passkey.userName.utf8.count)
            try add(passkey.userDisplayName.utf8.count)
            try add(passkey.privateKeyPKCS8.count)
            try add(passkey.exchangeFIDO2Metadata?.count ?? 0)
        }
        return total
    }

    /// The bytes the store may have to write for one account, which `encodedAccountBytes` bounds: the canonical JSON (the encoder
    /// every live row and history row uses) of the account with everything that is set after it was checked filled in at its
    /// largest. The store stamps three dates when it saves, the export hand-off marks the login, the code and each passkey with
    /// dates and a hash, and an observed-base record holds a hash and a copy of the exporter's item id. Measuring the account with
    /// those present means one at the bound can still be saved, edited and marked, and does not grow past the bound afterwards.
    static func storedBytes(of account: CredentialAccount) throws -> Int {
        var full = account
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_79)
        let events = CredentialEvents(
            lastImportedAt: date, lastExportHandoffAt: date, remoteLastObservedAt: date, lastExportHandoffHash: Data(count: 32)
        )
        let base = ExchangeBase(contentHash: Data(count: 32), itemID: account.exchangeItemID)
        full.createdAt = date
        full.modifiedAt = date
        full.migratedAt = date
        full.passwordEvents = events
        full.totpEvents = events
        full.passwordBase = base
        full.totpBase = base
        full.mergedFrom = full.mergedFrom?.map { link in
            var filled = link
            filled.passwordBase = ExchangeBase(contentHash: Data(count: 32), itemID: link.exchangeItemID)
            filled.totpBase = filled.passwordBase
            return filled
        }
        for index in full.passkeys.indices {
            full.passkeys[index].createdAt = date
            full.passkeys[index].lastSignedAt = date
            full.passkeys[index].events = events
            full.passkeys[index].base = base
        }
        // A thousand bytes more for a date that prints longer than this one.
        let (total, overflow) = try CredentialContent.canonicalJSON(full).count.addingReportingOverflow(1_024)
        guard !overflow else { throw CredentialVaultError.oversized }
        return total
    }

    /// `unchanged` names accounts the store holds byte for byte (checked when they were written): they still count towards the
    /// totals and every uniqueness rule, but their own encoded size and `validate()` are not checked again.
    static func validate(_ payload: CredentialVaultPayload, unchanged: Set<UUID> = []) throws {
        guard payload.accounts.count <= CredentialVaultLimits.accounts,
              payload.blockedPasswordOrigins.count <= 4_096 else { throw CredentialVaultError.oversized }
        var variableBytes = 0
        func add(_ count: Int) throws {
            let (total, overflow) = variableBytes.addingReportingOverflow(count)
            guard !overflow, total <= CredentialVaultLimits.liveBytes else { throw CredentialVaultError.oversized }
            variableBytes = total
        }

        var accountIDs = Set<UUID>()
        var credentialIDs = Set<Data>()
        var passkeyIDs = Set<UUID>()
        for account in payload.accounts {
            guard accountIDs.insert(account.id).inserted else { throw CredentialVaultError.duplicateIdentifier }
            let bytes = try liveBytes(of: account)
            let checked = unchanged.contains(account.id)
            guard bytes <= CredentialVaultLimits.accountBytes,
                  try checked || storedBytes(of: account) <= CredentialVaultLimits.encodedAccountBytes else { throw CredentialVaultError.oversized }
            try add(bytes)
            for passkey in account.passkeys {
                guard credentialIDs.insert(passkey.credentialID).inserted,
                      passkeyIDs.insert(passkey.id).inserted else { throw CredentialVaultError.duplicateIdentifier }
            }
            if !checked {
                try account.validate()
            }
        }
        for origin in payload.blockedPasswordOrigins {
            try add(origin.utf8.count)
            guard let url = URL(string: origin), CredentialAccount.origin(for: url) == origin else {
                throw CredentialVaultError.invalidData
            }
        }
    }

    static func encodePayload(_ payload: CredentialVaultPayload) throws -> Data {
        try validate(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw CredentialVaultError.invalidData
        }
        guard data.count <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.oversized }
        return data
    }

    static func manifestDigest(_ wrappers: [CredentialKeyWrapper]) -> Data {
        var input = Data()
        appendLength(wrappers.count, to: &input)
        for wrapper in wrappers.sorted(by: { $0.credentialID.lexicographicallyPrecedes($1.credentialID) }) {
            appendField(wrapper.credentialID, to: &input)
            appendField(wrapper.prfInput, to: &input)
            appendField(wrapper.nonce, to: &input)
            appendField(wrapper.ciphertext, to: &input)
            appendField(wrapper.tag, to: &input)
        }
        return Data(SHA256.hash(data: input))
    }

    private static func seal(_ plaintext: Data, key: SymmetricKey, authenticating aad: Data) throws -> CredentialSealedData {
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        } catch {
            throw CredentialVaultError.authenticationFailed
        }
        return CredentialSealedData(nonce: Data(sealed.nonce), ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    private static func open(_ sealed: CredentialSealedData, key: SymmetricKey, authenticating aad: Data) throws -> Data {
        do {
            let nonce = try AES.GCM.Nonce(data: sealed.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch { throw CredentialVaultError.authenticationFailed }
    }

    private static func deriveWrappingKey(_ prf: SymmetricKey, profileID: UUID, vaultID: UUID) -> SymmetricKey {
        var info = wrappingLabel
        appendField(uuidData(profileID), to: &info)
        appendField(uuidData(vaultID), to: &info)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: prf, salt: Data(), info: info, outputByteCount: 32)
    }

    private static func wrapperAAD(_ proof: VaultUnlockProof, profileID: UUID, vaultID: UUID) -> Data {
        var aad = Data()
        appendLength(StoreFormat.wrapperFormat, to: &aad)
        appendField(uuidData(profileID), to: &aad)
        appendField(uuidData(vaultID), to: &aad)
        appendField(proof.credentialID, to: &aad)
        appendField(proof.prfInput, to: &aad)
        return aad
    }

    private static func payloadAAD(profileID: UUID, vaultID: UUID, wrappers: [CredentialKeyWrapper]) -> Data {
        var aad = Data()
        appendLength(format, to: &aad)
        appendField(uuidData(profileID), to: &aad)
        appendField(uuidData(vaultID), to: &aad)
        appendField(manifestDigest(wrappers), to: &aad)
        return aad
    }

    private static func uuidData(_ uuid: UUID) -> Data {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func appendField(_ data: Data, to output: inout Data) {
        appendLength(data.count, to: &output)
        output.append(data)
    }

    private static func appendLength(_ value: Int, to output: inout Data) {
        var length = UInt64(value).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    }
}
