// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import WSurf

struct CredentialVaultTests {
    private nonisolated final class TestClock: Sendable {
        private let instant: Mutex<ContinuousClock.Instant>

        init() {
            instant = Mutex(ContinuousClock().now)
        }

        var now: ContinuousClock.Instant {
            instant.withLock { $0 }
        }

        func advance(_ duration: Duration) {
            instant.withLock { $0 = $0.advanced(by: duration) }
        }
    }

    private func access(profileID: UUID, clock: TestClock, lifetime: Duration = .seconds(300)) -> VaultAccess {
        VaultAccess(profileID: profileID, epoch: 1, deadline: clock.now.advanced(by: lifetime))
    }

    private func proof(_ id: UInt8 = 1) -> VaultUnlockProof {
        VaultUnlockProof(
            credentialID: Data(repeating: id, count: 32),
            prfInput: Data(repeating: id &+ 1, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
    }

    private func makeVault(
        at directory: URL,
        profileID: UUID,
        clock: TestClock
    ) throws -> CredentialVault {
        try CredentialVault(profileID: profileID, directory: directory, now: { clock.now })
    }

    private func account(
        id: UUID = UUID(),
        username: String = "ada",
        password: String? = "secret",
        passkeys: [WebsitePasskey] = []
    ) -> CredentialAccount {
        CredentialAccount(
            id: id,
            username: username,
            displayName: nil,
            origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!],
            password: password,
            passkeys: passkeys,
            totp: nil,
            exchangeAccountID: nil,
            exchangeItemID: nil
        )
    }

    private func validTestPasskey(rpID: String) throws -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(),
            credentialID: Data(repeating: 1, count: 32),
            rpID: rpID,
            userHandle: Data([1]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private struct PayloadFixture: Codable {
        let revision: UInt64
        let accounts: [CredentialAccount]
        let blockedPasswordOrigins: Set<String>
    }

    private func exactPayloadAccountSize() throws -> CredentialAccount {
        let encoder = JSONEncoder()
        let base = try encoder.encode(PayloadFixture(revision: 1, accounts: [account(username: "")], blockedPasswordOrigins: [])).count
        let target = 4_000_000
        let record = account(username: String(repeating: "a", count: target - base))
        #expect(try encoder.encode(PayloadFixture(revision: 1, accounts: [record], blockedPasswordOrigins: [])).count == target)
        return record
    }

    private func replacingLargestData(_ value: Any, replacement: (Data) -> Data) -> (Any, Int)? {
        if let data = value as? Data {
            return (replacement(data), data.count)
        }
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            var largest = 0
            for key in dictionary.keys {
                guard let child = dictionary[key], let (updated, size) = replacingLargestData(child, replacement: replacement), size > largest else { continue }
                result[key] = updated
                largest = size
            }
            return largest == 0 ? nil : (result, largest)
        }
        if let values = value as? [Any] {
            var result = values
            var largest = 0
            for index in values.indices {
                guard let (updated, size) = replacingLargestData(values[index], replacement: replacement), size > largest else { continue }
                result[index] = updated
                largest = size
            }
            return largest == 0 ? nil : (result, largest)
        }
        return nil
    }

    private func replacingData(_ value: Any, equalTo target: Data, replacement: (Data) -> Data) -> Any? {
        if let data = value as? Data {
            return data == target ? replacement(data) : nil
        }
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            var changed = false
            for (key, child) in dictionary {
                if let updated = replacingData(child, equalTo: target, replacement: replacement) {
                    result[key] = updated
                    changed = true
                }
            }
            return changed ? result : nil
        }
        if let values = value as? [Any] {
            var result = values
            var changed = false
            for index in values.indices {
                if let updated = replacingData(values[index], equalTo: target, replacement: replacement) {
                    result[index] = updated
                    changed = true
                }
            }
            return changed ? result : nil
        }
        return nil
    }

    private func replacingFormatVersion(_ value: Any) -> Any? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var result = dictionary
        var changed = false
        for (key, child) in dictionary {
            if key.lowercased().contains("format"), child is NSNumber {
                result[key] = 99
                changed = true
            } else if let nested = replacingFormatVersion(child) {
                result[key] = nested
                changed = true
            }
        }
        return changed ? result : nil
    }

    private func corruptedPropertyList(_ bytes: Data, mutate: (Any) -> Any?) throws -> Data {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let value = try PropertyListSerialization.propertyList(from: bytes, options: [], format: &format)
        guard let changed = mutate(value) else { throw TestFailure.noMatchingValue }
        return try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
    }

    private func paddedEnvelope(_ bytes: Data, to targetSize: Int) throws -> Data {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var envelope = try PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) as? [String: Any] else {
            throw TestFailure.noMatchingValue
        }
        var paddingCount = max(0, targetSize - bytes.count)
        for _ in 0..<8 {
            envelope["ignoredPadding"] = Data(repeating: 0, count: paddingCount)
            let padded = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            let difference = targetSize - padded.count
            if difference == 0 {
                return padded
            }
            paddingCount += difference
            guard paddingCount >= 0 else { throw TestFailure.noMatchingValue }
        }
        throw TestFailure.noMatchingValue
    }

    private func assertRejectedCorruption(
        _ corrupted: Data,
        originalDirectory: URL,
        unlock: VaultUnlockProof,
        profileID: UUID,
        clock: TestClock
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try corrupted.write(to: directory.appendingPathComponent("Credentials.vault"))
        let corruptedBefore = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        await #expect(throws: (any Error).self) {
            try await vault.unlock(credentialID: unlock.credentialID, prf: unlock.prf, access: access(profileID: profileID, clock: clock))
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == corruptedBefore)

        let untouched = try makeVault(at: originalDirectory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await untouched.unlock(credentialID: unlock.credentialID, prf: unlock.prf, access: permit)
        #expect(try await untouched.snapshot(using: permit).accounts.count == 1)
    }

    private enum TestFailure: Error { case noMatchingValue }

    @Test func privateProfilesCannotCreatePersistentCredentialVaults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try CredentialVault(profileID: Profile.privateID, directory: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func constructingAnAccessPermitAloneDoesNotUnlockTheVault() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        await #expect(throws: (any Error).self) {
            try await vault.snapshot(using: access(profileID: profileID, clock: clock))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func accountValidationKeepsOriginsCanonicalAndLoginURLsPathOnly() throws {
        var record = account()
        record.origins = ["https://EXAMPLE.test:443"]
        #expect(throws: (any Error).self) { try record.validate() }

        let sanitized = try CredentialAccount.sanitizedLoginURL(URL(string: "https://ada:secret@example.test:443/login?token=private#section")!)
        #expect(sanitized.absoluteString == "https://example.test/login")
        #expect(CredentialAccount.origin(for: URL(string: "http://example.test/login")!) == nil)
        #expect(CredentialAccount.origin(for: URL(string: "https://user@example.test/login")!) == nil)
    }

    @Test func invalidTOTPAndPKCS8InputsAreRejected() throws {
        for (period, digits) in [(UInt16(0), UInt16(6)), (UInt16(30), UInt16(5)), (UInt16(30), UInt16(11))] {
            let generator = TOTPGenerator(secret: Data([1, 2, 3]), algorithm: .sha1, period: period, digits: digits, issuer: nil, userName: nil)
            #expect(throws: (any Error).self) { try generator.validate() }
        }

        let oversized = Data(repeating: 0, count: 4_000_001)
        let key = P256.Signing.PrivateKey()
        let valid = try PasskeyKeyEncoding.exportPKCS8(key)
        let imported = try PasskeyKeyEncoding.importPKCS8(valid)
        #expect(imported.rawRepresentation == key.rawRepresentation)
        let message = Data("key-use fixture".utf8)
        let signature = try imported.signature(for: message)
        #expect(key.publicKey.isValidSignature(signature, for: message))
        var wrongCurve = valid
        let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        if let oidRange = wrongCurve.range(of: p256OID) {
            wrongCurve[oidRange.upperBound - 1] = 0x22
        } else {
            Issue.record("PKCS#8 fixture did not contain the P-256 curve OID")
        }
        var contradictoryPublicKey = valid
        if let publicKeyRange = contradictoryPublicKey.range(of: key.publicKey.x963Representation) {
            contradictoryPublicKey[publicKeyRange.upperBound - 1] ^= 1
        } else {
            Issue.record("PKCS#8 fixture did not contain its public key")
        }
        var nonminimalLength = valid
        let lengthByte = nonminimalLength[1]
        if lengthByte & 0x80 == 0 {
            nonminimalLength[1] = 0x81
            nonminimalLength.insert(lengthByte, at: 2)
        } else {
            nonminimalLength[1] += 1
            nonminimalLength.insert(0, at: 2)
        }
        for der in [Data(), Data([0x30, 0x82, 0x01]), wrongCurve, contradictoryPublicKey, nonminimalLength, oversized] {
            #expect(throws: (any Error).self) { try PasskeyKeyEncoding.importPKCS8(der) }
        }
    }

    @Test func pkcs8ImportAcceptsNonzeroStartIndexDataSlice() throws {
        let key = P256.Signing.PrivateKey()
        let encoded = try PasskeyKeyEncoding.exportPKCS8(key)
        let padded = Data([0xFF]) + encoded + Data([0xFF])
        let start = padded.index(after: padded.startIndex)
        let end = padded.index(before: padded.endIndex)
        let slice = padded[start..<end]

        #expect(slice.startIndex == start)
        #expect(try PasskeyKeyEncoding.importPKCS8(slice).rawRepresentation == key.rawRepresentation)
    }

    @Test func wrongKeyAndWrongProfileCannotUnlockOrChangeExistingVault() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let unlock = proof()
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: unlock, access: permit)
        let before = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        let initial = try await vault.snapshot(using: permit)

        let wrongProfileID = UUID()
        let wrongVault = try makeVault(at: directory, profileID: wrongProfileID, clock: clock)
        await #expect(throws: (any Error).self) {
            try await wrongVault.unlock(
                credentialID: unlock.credentialID,
                prf: unlock.prf,
                access: access(profileID: wrongProfileID, clock: clock)
            )
        }

        let restarted = try makeVault(at: directory, profileID: profileID, clock: clock)
        await #expect(throws: (any Error).self) {
            try await restarted.unlock(credentialID: unlock.credentialID, prf: SymmetricKey(size: .bits256), access: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == before)
        let unchanged = try await vault.snapshot(using: permit)
        #expect(unchanged.revision == initial.revision)
        #expect(unchanged.accounts.map(\.id) == initial.accounts.map(\.id))
    }

    @Test func validAndRejectedMutationsPreserveRevisionAndDiskBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)

        let saved = account()
        let receipt = try await vault.commit([saved], expectedRevision: 0, using: permit)
        let committedBytes = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        #expect(committedBytes.range(of: Data("ada".utf8)) == nil)
        #expect(committedBytes.range(of: Data("secret".utf8)) == nil)
        #expect(receipt.revision == 1)

        await #expect(throws: (any Error).self) {
            try await vault.commit([saved, saved], expectedRevision: receipt.revision, using: permit)
        }
        await #expect(throws: (any Error).self) {
            try await vault.commit([saved], expectedRevision: 0, using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == committedBytes)
        #expect(try await vault.snapshot(using: permit).accounts.map(\.id) == [saved.id])
    }

    @Test func revokeAndExpiryAreCheckedAtActorAccessBoundaries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let unlock = proof()
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: unlock, access: permit)
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        clock.advance(.seconds(299))
        #expect(try await vault.snapshot(using: permit).revision == 0)
        clock.advance(.seconds(1))
        await #expect(throws: (any Error).self) { try await vault.snapshot(using: permit) }
        await #expect(throws: (any Error).self) {
            try await vault.commit([account()], expectedRevision: 0, using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == originalBytes)

        let freshPermit = access(profileID: profileID, clock: clock)
        try await vault.unlock(credentialID: unlock.credentialID, prf: unlock.prf, access: freshPermit)
        freshPermit.revoke()
        await #expect(throws: (any Error).self) { try await vault.snapshot(using: freshPermit) }
        await #expect(throws: (any Error).self) {
            try await vault.commit([account()], expectedRevision: 0, using: freshPermit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == originalBytes)
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) != Data())
    }

    @Test func twoUnlockWrappersAreIndependentAndOnlyVerifiedRemainingPathCanReplaceOne() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        let first = proof(1)
        let second = proof(3)
        try await vault.create(unlock: first, access: permit)
        _ = try await vault.addUnlock(second, using: permit)

        let restarted = try makeVault(at: directory, profileID: profileID, clock: clock)
        try await restarted.unlock(credentialID: first.credentialID, prf: first.prf, access: permit)
        let firstSnapshot = try await restarted.snapshot(using: permit)
        let independentlyUnlocked = try makeVault(at: directory, profileID: profileID, clock: clock)
        try await independentlyUnlocked.unlock(credentialID: second.credentialID, prf: second.prf, access: permit)
        let secondSnapshot = try await independentlyUnlocked.snapshot(using: permit)
        #expect(secondSnapshot.revision == firstSnapshot.revision)
        #expect(secondSnapshot.accounts.map(\.id) == firstSnapshot.accounts.map(\.id))

        let beforeRejectedWrappers = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        await #expect(throws: (any Error).self) {
            try await vault.addUnlock(proof(1), using: permit)
        }
        await #expect(throws: (any Error).self) {
            try await vault.removeUnlock(credentialID: first.credentialID, verifiedRemaining: proof(3), using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == beforeRejectedWrappers)
        _ = try await vault.removeUnlock(credentialID: first.credentialID, verifiedRemaining: second, using: permit)
        await #expect(throws: (any Error).self) {
            try await vault.removeUnlock(credentialID: second.credentialID, verifiedRemaining: second, using: permit)
        }
    }

    @Test func passwordSavePolicySurvivesUnrelatedAccountCommit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)
        let policy = Set(["https://blocked.test"])
        let policyReceipt = try await vault.updatePasswordSavePolicy(policy, expectedRevision: 0, using: permit)
        let accountReceipt = try await vault.commit([account()], expectedRevision: policyReceipt.revision, using: permit)
        let snapshot = try await vault.snapshot(using: permit)
        #expect(snapshot.revision == accountReceipt.revision)
        #expect(snapshot.blockedPasswordOrigins == policy)

    }
    @Test func accountCountLimitAndDuplicateAccountIDsAreAtomic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)
        let allowed = (0..<1_000).map { _ in account() }
        let receipt = try await vault.commit(allowed, expectedRevision: 0, using: permit)
        let bytesAtLimit = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        #expect(try await vault.snapshot(using: permit).accounts.count == 1_000)

        await #expect(throws: (any Error).self) {
            try await vault.commit(allowed + [account()], expectedRevision: receipt.revision, using: permit)
        }
        let duplicateID = UUID()
        await #expect(throws: (any Error).self) {
            try await vault.commit([account(id: duplicateID), account(id: duplicateID)], expectedRevision: receipt.revision, using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == bytesAtLimit)
    }

    @Test func unlockWrapperLimitRejectsTheThirtyThirdWrapperWithoutMutation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(1), access: permit)
        for id in UInt8(2)...UInt8(32) {
            _ = try await vault.addUnlock(proof(id), using: permit)
        }
        let before = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        await #expect(throws: (any Error).self) {
            try await vault.addUnlock(proof(33), using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == before)
        #expect(try await vault.discovery().unlocks.count == 32)
    }

    @Test func exactPayloadLimitIsAcceptedAndOneByteOverIsRejectedWithoutReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)
        let exact = try exactPayloadAccountSize()
        let receipt = try await vault.commit([exact], expectedRevision: 0, using: permit)
        let before = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        #expect(receipt.revision == 1)
        await #expect(throws: (any Error).self) {
            try await vault.commit([account(username: exact.username + "a")], expectedRevision: receipt.revision, using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == before)
    }

    @Test func canonicalRelyingPartyIDsAreUsableByStoredPasskeys() throws {
        let idna = try RelyingPartyPolicy.validate(
            rpID: "bücher.de",
            origin: URL(string: "https://login.bücher.de")!
        )
        #expect(idna == "xn--bcher-kva.de")
        try validTestPasskey(rpID: idna).validate()

        let trailingDot = try RelyingPartyPolicy.validate(
            rpID: "example.com.",
            origin: URL(string: "https://login.example.com.")!
        )
        #expect(trailingDot == "example.com.")
        try validTestPasskey(rpID: trailingDot).validate()
    }

    @Test func publicSuffixAndIPAddressRelyingPartiesRemainRejectedForCeremonies() throws {
        for rpID in ["com", "127.0.0.1"] {
            #expect(throws: (any Error).self) {
                try RelyingPartyPolicy.validate(rpID: rpID, origin: URL(string: "https://\(rpID)")!)
            }
        }
        #expect(throws: (any Error).self) { try validTestPasskey(rpID: "127.0.0.1").validate() }
    }

    @Test func pslDeniedStoredPasskeyRemainsReadableAndEditable() async throws {
        let rpID = "com"
        let origin = URL(string: "https://\(rpID)")!
        #expect(throws: (any Error).self) { try RelyingPartyPolicy.validate(rpID: rpID, origin: origin) }
        let passkey = try validTestPasskey(rpID: rpID)
        try passkey.validate()

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let proof = proof()
        let permit = access(profileID: profileID, clock: clock)
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        try await vault.create(unlock: proof, access: permit)
        _ = try await vault.commit([account(passkeys: [passkey])], expectedRevision: 0, using: permit)

        let reopened = try makeVault(at: directory, profileID: profileID, clock: clock)
        let reopenedAccess = access(profileID: profileID, clock: clock)
        try await reopened.unlock(credentialID: proof.credentialID, prf: proof.prf, access: reopenedAccess)
        let snapshot = try await reopened.snapshot(using: reopenedAccess)
        #expect(snapshot.accounts.first?.passkeys.map(\.rpID) == [rpID])

        var edited = snapshot.accounts[0]
        edited.password = "updated"
        _ = try await reopened.commit([edited], expectedRevision: snapshot.revision, using: reopenedAccess)
        let updated = try await reopened.snapshot(using: reopenedAccess)
        #expect(updated.accounts[0].password == "updated")
        #expect(updated.accounts[0].passkeys.map(\.rpID) == [rpID])
    }

    @Test func fileInputLimitAcceptsExactlyEightMegabytesAndRejectsOneByteMore() async throws {
        let sourceDirectory = try temporaryDirectory()
        let exactDirectory = try temporaryDirectory()
        let oversizedDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: exactDirectory)
            try? FileManager.default.removeItem(at: oversizedDirectory)
        }
        let profileID = UUID()
        let clock = TestClock()
        let source = try makeVault(at: sourceDirectory, profileID: profileID, clock: clock)
        try await source.create(unlock: proof(), access: access(profileID: profileID, clock: clock))
        let original = try Data(contentsOf: sourceDirectory.appendingPathComponent("Credentials.vault"))
        let exact = try paddedEnvelope(original, to: 8_000_000)
        let oversized = try paddedEnvelope(original, to: 8_000_001)
        #expect(exact.count == 8_000_000)
        #expect(oversized.count == 8_000_001)

        try exact.write(to: exactDirectory.appendingPathComponent("Credentials.vault"))
        let exactVault = try makeVault(at: exactDirectory, profileID: profileID, clock: clock)
        #expect(try await exactVault.discovery().unlocks.count == 1)

        try oversized.write(to: oversizedDirectory.appendingPathComponent("Credentials.vault"))
        let oversizedVault = try makeVault(at: oversizedDirectory, profileID: profileID, clock: clock)
        await #expect(throws: (any Error).self) { try await oversizedVault.discovery() }
    }

    @Test func passwordWithoutApprovedOriginRemainsValidForManualAssociation() throws {
        var unscoped = account()
        unscoped.origins = []
        unscoped.loginURLs = []
        try unscoped.validate()
        #expect(unscoped.origins.isEmpty && unscoped.loginURLs.isEmpty)
    }

    @Test func backupStateRequiresBackupEligibility() throws {
        var passkey = try validTestPasskey(rpID: "example.test")
        passkey.backupEligible = false
        try passkey.validate()

        passkey.backupState = true
        #expect(throws: (any Error).self) { try passkey.validate() }
    }

    @Test func duplicatePasskeyCredentialIDsAreRejectedBeforeReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)
        let pkcs8 = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        func passkey() -> WebsitePasskey {
            WebsitePasskey(
                id: UUID(), credentialID: Data(repeating: 7, count: 32), rpID: "example.test",
                userHandle: Data([1]), userName: "ada", userDisplayName: "Ada", algorithm: -7,
                privateKeyPKCS8: pkcs8, backupEligible: true, backupState: false, exchangeFIDO2Metadata: nil
            )
        }
        let duplicate = account(password: nil, passkeys: [passkey(), passkey()])
        let before = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        var invalidRecord = account()
        invalidRecord.totp = TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 0, digits: 6, issuer: nil, userName: nil)
        await #expect(throws: (any Error).self) {
            try await vault.commit([invalidRecord], expectedRevision: 0, using: permit)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == before)
        await #expect(throws: (any Error).self) { try await vault.commit([duplicate], expectedRevision: 0, using: permit) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == before)
    }

    @Test func headerCiphertextAndUnselectedWrapperCorruptionFailAuthentication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        let first = proof(1)
        let second = proof(3)
        try await vault.create(unlock: first, access: permit)
        let wrapperReceipt = try await vault.addUnlock(second, using: permit)
        _ = try await vault.commit([account()], expectedRevision: wrapperReceipt.revision, using: permit)
        let original = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        let header = try corruptedPropertyList(original, mutate: replacingFormatVersion)
        let ciphertext = try corruptedPropertyList(original) { value in
            replacingLargestData(value) { data in
                var changed = data
                if !changed.isEmpty {
                    changed[changed.startIndex] ^= 1
                }
                return changed
            }?.0
        }
        let unselectedWrapper = try corruptedPropertyList(original) { value in
            replacingData(value, equalTo: second.prfInput) { data in
                var changed = data
                changed[changed.startIndex] ^= 1
                return changed
            }
        }
        try await assertRejectedCorruption(header, originalDirectory: directory, unlock: first, profileID: profileID, clock: clock)
        try await assertRejectedCorruption(ciphertext, originalDirectory: directory, unlock: first, profileID: profileID, clock: clock)
        try await assertRejectedCorruption(unselectedWrapper, originalDirectory: directory, unlock: first, profileID: profileID, clock: clock)
    }

    @Test func envelopeFieldDecodersRejectOutOfBoundsDataWhileDecoding() throws {
        func wrapper(
            id: Int = 32, prf: Int = 32, nonce: Int = 12, ciphertext: Int = 32, tag: Int = 16
        ) -> CredentialKeyWrapper {
            CredentialKeyWrapper(
                credentialID: Data(repeating: 1, count: id), prfInput: Data(repeating: 2, count: prf),
                nonce: Data(repeating: 3, count: nonce), ciphertext: Data(repeating: 4, count: ciphertext),
                tag: Data(repeating: 5, count: tag)
            )
        }
        func sealed(nonce: Int = 12, ciphertext: Int = 32, tag: Int = 16) -> CredentialSealedData {
            CredentialSealedData(
                nonce: Data(repeating: 3, count: nonce), ciphertext: Data(repeating: 4, count: ciphertext),
                tag: Data(repeating: 5, count: tag)
            )
        }
        func decode<T: Codable>(_ value: T) throws -> T {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try PropertyListDecoder().decode(T.self, from: encoder.encode(value))
        }
        let limit = CredentialVaultCrypto.maximumUnlockFieldBytes

        // Valid boundary values keep their wire shape.
        #expect(try decode(wrapper(id: limit, prf: 1)).credentialID.count == limit)
        #expect(try decode(sealed(ciphertext: CredentialVaultLimits.payloadBytes)).ciphertext.count == CredentialVaultLimits.payloadBytes)

        for invalid in [
            wrapper(id: 0), wrapper(id: limit + 1), wrapper(prf: 0), wrapper(prf: limit + 1),
            wrapper(nonce: 11), wrapper(nonce: 13), wrapper(ciphertext: 31), wrapper(ciphertext: 33),
            wrapper(tag: 15), wrapper(tag: 17),
        ] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
        for invalid in [
            sealed(nonce: 11), sealed(nonce: 13), sealed(ciphertext: CredentialVaultLimits.payloadBytes + 1),
            sealed(tag: 15), sealed(tag: 17),
        ] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
    }

    @Test func deadlineCrossingDuringCommitPreservesPriorVaultBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let start = ContinuousClock().now
        let deadline = start.advanced(by: .seconds(300))
        let commitClockPhase = Mutex(0)
        let vault = try CredentialVault(profileID: profileID, directory: directory, now: {
            commitClockPhase.withLock { phase -> ContinuousClock.Instant in
                if phase == 0 {
                    return start
                }
                if phase == 1 {
                    phase = 2
                    return start
                }
                phase += 1
                return deadline
            }
        })
        let permit = VaultAccess(profileID: profileID, epoch: 1, deadline: deadline)
        try await vault.create(unlock: proof(), access: permit)
        let original = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        commitClockPhase.withLock { $0 = 1 }

        await #expect(throws: (any Error).self) {
            try await vault.commit([account()], expectedRevision: 0, using: permit)
        }
        #expect(commitClockPhase.withLock { $0 } >= 3)
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == original)
    }

    @Test func cancellationBeforeCommitPreservesVaultBytesAndRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let cancellation = Mutex((armed: false, issued: false))
        let vault = try CredentialVault(profileID: profileID, directory: directory, now: {
            let shouldCancel = cancellation.withLock { state in
                guard state.armed else { return false }
                state.armed = false
                return true
            }
            if shouldCancel {
                let foundTask = withUnsafeCurrentTask { task in
                    task?.cancel()
                    return task != nil
                }
                cancellation.withLock { $0.issued = foundTask }
            }
            return clock.now
        })
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)
        let original = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        cancellation.withLock { $0.armed = true }
        let commit = Task { try await vault.commit([account()], expectedRevision: 0, using: permit) }

        await #expect(throws: CancellationError.self) { _ = try await commit.value }
        #expect(cancellation.withLock { $0.issued })
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == original)
        #expect(try await vault.snapshot(using: permit).revision == 0)
    }

    @Test func committedReceiptRemainsSuccessfulWhenCallerCancelsAfterCommit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: proof(), access: permit)

        let commit = Task {
            let receipt = try await vault.commit([account()], expectedRevision: 0, using: permit)
            withUnsafeCurrentTask { $0?.cancel() }
            return receipt
        }
        let receipt = try await commit.value

        #expect(receipt.revision == 1)
        #expect(try await vault.snapshot(using: permit).revision == receipt.revision)
    }

    @Test func failedAtomicReplacementLeavesPriorVaultBytesUsable() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let unlock = proof()
        let permit = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: unlock, access: permit)
        let original = try Data(contentsOf: directory.appendingPathComponent("Credentials.vault"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) {
            try await vault.commit([account()], expectedRevision: 0, using: permit)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == original)
        let restarted = try makeVault(at: directory, profileID: profileID, clock: clock)
        try await restarted.unlock(credentialID: unlock.credentialID, prf: unlock.prf, access: permit)
        #expect(try await restarted.snapshot(using: permit).revision == 0)
    }

    @Test func staleAccessCleanupCannotLockNewerAccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let clock = TestClock()
        let vault = try makeVault(at: directory, profileID: profileID, clock: clock)
        let unlockProof = proof()
        let oldAccess = access(profileID: profileID, clock: clock)
        try await vault.create(unlock: unlockProof, access: oldAccess)

        let newAccess = access(profileID: profileID, clock: clock)
        try await vault.unlock(credentialID: unlockProof.credentialID, prf: unlockProof.prf, access: newAccess)
        await vault.lock(ifUsing: oldAccess)
        #expect(try await vault.snapshot(using: newAccess).revision == 0)

        await vault.lock(ifUsing: newAccess)
        await #expect(throws: (any Error).self) { try await vault.snapshot(using: newAccess) }
    }

    @Test func basicAuthenticationMetadataPreservesEmptyAndAbsentPasswords() throws {
        let usernameField = CredentialEditableFieldMetadata(id: Data([1]), label: "Login", fieldType: .string)
        let passwordField = CredentialEditableFieldMetadata(id: Data([2]), label: "Password", fieldType: .concealedString)
        var presentEmpty = account(password: "")
        presentEmpty.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: usernameField, password: passwordField)
        try presentEmpty.validate()
        #expect(presentEmpty.password == "")

        var absent = account(password: nil)
        absent.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: usernameField, password: nil)
        try absent.validate()
        #expect(absent.password == nil)

        absent.password = ""
        #expect(throws: (any Error).self) { try absent.validate() }
        presentEmpty.basicAuthenticationMetadata?.password = nil
        #expect(throws: (any Error).self) { try presentEmpty.validate() }
        presentEmpty.basicAuthenticationMetadata?.password = CredentialEditableFieldMetadata(id: Data([1]), label: "Password", fieldType: .email)
        #expect(throws: (any Error).self) { try presentEmpty.validate() }
    }

    @Test func basicAuthenticationMetadataContributesToPayloadBudget() throws {
        let id = Data(repeating: 7, count: 1_024)
        let label = String(repeating: "x", count: 2_048)
        var record = account(username: String(repeating: "a", count: 3_994_000), password: "")
        record.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: id, label: label, fieldType: .string),
            password: CredentialEditableFieldMetadata(id: Data(repeating: 8, count: 1_024), label: label, fieldType: .concealedString)
        )
        record.basicAuthenticationMetadata?.username?.id = Data(repeating: 7, count: 1_025)
        #expect(throws: (any Error).self) { try record.validate() }
        record.basicAuthenticationMetadata?.username?.id = id
        record.basicAuthenticationMetadata?.username?.label = String(repeating: "x", count: 2_049)
        #expect(throws: (any Error).self) { try record.validate() }
        record.basicAuthenticationMetadata?.username?.label = label
        let payload = CredentialVaultPayload(revision: 0, accounts: [record], blockedPasswordOrigins: [])
        #expect(throws: (any Error).self) { try CredentialVaultCrypto.validate(payload) }

        record.username = "ada"
        record.basicAuthenticationMetadata?.password?.id = id
        #expect(throws: (any Error).self) { try record.validate() }
    }

}
