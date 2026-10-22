// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing

@testable import WSurf

// Input History's encrypted store, asserted over temporary directories and in-memory key storage. Every value is synthetic. Nothing
// here touches the real Keychain.

nonisolated enum InputHistoryEmptying: CaseIterable, Sendable {
    case delete, forget, expiry, clear
}

struct InputHistoryStoreTests {
    private let reason = "Test"

    private func values(_ entries: [InputHistoryEntry]) -> [String] {
        entries.map(\.payload.value)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int) & 0o777
    }

    // MARK: - At rest

    @Test func entriesAreEncryptedAtRestAndFilesNeverContainPlaintext() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        let secrets = ["dummy-secret-123", "ada@example.test", "Account sign in", "Password field", "https://example.test/account"]
        let payload = InputHistoryPayload.testSample(
            secrets[0], username: secrets[1], url: secrets[4], title: secrets[2], label: secrets[3]
        )
        _ = try await fixture.store.record(payload, key: "doc#1", retention: .thirtyMinutes)

        let files = fixture.files
        #expect(files.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 1)
        for url in files {
            let body = try Data(contentsOf: url)
            #expect(body.first == 1)
            // One byte of version, a 32-byte encapsulated key and a ciphertext at least as long as the tag.
            #expect(body.count > 33 + 16)
            for secret in secrets + ["example.test", "login"] {
                #expect(body.range(of: Data(secret.utf8)) == nil)
                #expect(!url.lastPathComponent.contains(secret))
            }
            #expect(try permissions(of: url) == 0o600)
        }
        #expect(try permissions(of: fixture.directory) == 0o700)
        // The Keychain holds two raw 32-byte keys and nothing else.
        let context = LAContext()
        #expect(try fixture.privateKeys.read(service: fixture.store.service, context: context)?.count == 32)
        #expect(try fixture.publicKeys.read(service: fixture.store.service, context: context)?.count == 32)
        #expect(fixture.privateKeys.itemCount == 1 && fixture.publicKeys.itemCount == 1)

        let entries = try await fixture.store.unlock(reason: reason)
        #expect(entries.map(\.payload) == [payload])
    }

    @Test func aPayloadDescriptionNeverShowsTheValue() {
        let payload = InputHistoryPayload.testSample("dummy-secret-123", username: "ada@example.test")
        for text in [payload.description, payload.debugDescription, "\(payload)", String(describing: payload), String(reflecting: payload)] {
            #expect(!text.contains("dummy-secret-123"))
            #expect(!text.contains("ada@example.test"))
        }
    }

    @Test func directoryIsExcludedFromBackup() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample(), key: "doc#1", retention: .thirtyMinutes)
        let resource = try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resource.isExcludedFromBackup == true)
    }

    @Test func keysLiveInPerProfileItemsNamedForInputHistoryAndNeverSync() async throws {
        let first = InputHistoryStoreFixture()
        let second = InputHistoryStoreFixture()
        defer {
            first.cleanUp()
            second.cleanUp()
        }
        #expect(first.store.service.contains(".input-history."))
        #expect(first.store.service.hasSuffix(first.profileID.uuidString))
        #expect(first.store.service != second.store.service)
        #expect(first.store.service.hasPrefix(AutofillVaults.serviceNamespace()))

        // The real storages: the private key needs user presence, the public key only an unlocked Mac, and a query names no
        // synchronizable item.
        #expect(InputHistory.privateKeyStorage.access == .userPresence)
        #expect(InputHistory.publicKeyStorage.access == .whenUnlocked)
        let query = AutofillKeychainStorage.query(service: first.store.service)
        #expect(query[kSecAttrSynchronizable as String] == nil)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    // MARK: - Recording and opening

    @Test func recordingNeverReadsThePrivateKey() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        // A read of the private key would fail here, as a canceled prompt does: recording must not notice.
        fixture.privateKeys.failReads(with: errSecAuthFailed)

        _ = try await fixture.store.record(.testSample("first"), key: "a", retention: .thirtyMinutes)
        _ = try await fixture.store.record(.testSample("second"), key: "b", retention: .thirtyMinutes)
        _ = try await fixture.store.record(.testSample("first again"), key: "a", retention: .thirtyMinutes)
        _ = try await fixture.store.forget("b")
        _ = try await fixture.store.applyRetention(.oneDay)
        _ = await fixture.store.purge()
        #expect(await fixture.store.count() == 1)

        #expect(fixture.privateKeys.readCount == 0)
        #expect(fixture.publicKeys.readCount > 0)

        // Opening is the one thing that reads it.
        fixture.privateKeys.failReads(with: nil)
        let entries = try await fixture.store.unlock(reason: reason)
        #expect(values(entries) == ["first again"])
        #expect(fixture.privateKeys.readCount == 1)
    }

    @Test func unlockReturnsNewestFirst() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        let start = fixture.clock.now()
        for (index, value) in ["one", "two", "three"].enumerated() {
            _ = try await fixture.store.record(.testSample(value), key: "field\(index)", retention: .thirtyMinutes)
            fixture.clock.advance(1)
        }

        let entries = try await fixture.store.unlock(reason: reason)
        #expect(values(entries) == ["three", "two", "one"])
        #expect(entries.map(\.createdAt) == [start.addingTimeInterval(2), start.addingTimeInterval(1), start])
        #expect(entries.first?.expiresAt == start.addingTimeInterval(2 + 30 * 60))
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test func aFailedAuthenticationChangesNothing() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("kept"), key: "a", retention: .thirtyMinutes)

        fixture.privateKeys.failReads(with: errSecUserCanceled)
        await #expect(throws: AutofillVaultError.self) { _ = try await fixture.store.unlock(reason: reason) }
        #expect(fixture.files.count == 1)
        #expect(fixture.privateKeys.itemCount == 1 && fixture.publicKeys.itemCount == 1)

        fixture.privateKeys.failReads(with: nil)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["kept"])
    }

    @Test func entryFileRenamedToAnotherIdentityFailsToOpen() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("first"), key: "a", retention: .thirtyMinutes)
        fixture.clock.advance(1)
        _ = try await fixture.store.record(.testSample("second"), key: "b", retention: .thirtyMinutes)
        let original = try #require(fixture.files.first)

        // The body of the first entry under a name that claims another time and identity, as a replay would put it.
        let later = Int64(fixture.clock.now().timeIntervalSince1970 * 1000) + 60_000
        let forged = fixture.directory.appendingPathComponent("\(later + 1_800_000)-\(later)-\(UUID().uuidString).wih")
        try FileManager.default.copyItem(at: original, to: forged)
        // And a file that merely has a valid name.
        let junk = fixture.directory.appendingPathComponent("\(later + 1_800_000)-\(later + 1)-\(UUID().uuidString).wih")
        try Data(repeating: 7, count: 200).write(to: junk)
        #expect(fixture.files.count == 4)

        let entries = try await fixture.store.unlock(reason: reason)
        #expect(values(entries) == ["second", "first"])
        // What cannot be opened can never be shown, so it does not stay behind.
        #expect(fixture.files.count == 2)
        #expect(!FileManager.default.fileExists(atPath: forged.path))
        #expect(!FileManager.default.fileExists(atPath: junk.path))
    }

    @Test func bodiesSwappedBetweenEntriesFailToOpenAndEmptyTheStore() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("first"), key: "a", retention: .thirtyMinutes)
        fixture.clock.advance(1)
        _ = try await fixture.store.record(.testSample("second"), key: "b", retention: .thirtyMinutes)
        let files = fixture.files
        let (one, two) = (try Data(contentsOf: files[0]), try Data(contentsOf: files[1]))
        try two.write(to: files[0])
        try one.write(to: files[1])

        #expect(try await fixture.store.unlock(reason: reason).isEmpty)
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)
    }

    // MARK: - Coalescing and limits

    @Test func sameKeyReplacesTheEntry() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("first"), key: "doc#field", retention: .thirtyMinutes)
        fixture.clock.advance(1)
        let status = try await fixture.store.record(.testSample("second"), key: "doc#field", retention: .thirtyMinutes)
        #expect(status.count == 1)
        #expect(fixture.files.count == 1)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["second"])

        let other = try await fixture.store.record(.testSample("third"), key: "doc#other", retention: .thirtyMinutes)
        #expect(other.count == 2)
    }

    @Test func forgetRemovesTheCoalescedEntry() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("kept"), key: "a", retention: .thirtyMinutes)
        _ = try await fixture.store.record(.testSample("emptied"), key: "b", retention: .thirtyMinutes)

        #expect(try await fixture.store.forget("b").count == 1)
        #expect(try await fixture.store.forget("never-recorded").count == 1)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["kept"])

        // The key is free again: a new commit makes a new entry.
        #expect(try await fixture.store.record(.testSample("again"), key: "b", retention: .thirtyMinutes).count == 2)
    }

    @Test func oldestEntriesAreEvictedBeyondFiveHundred() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        let total = InputHistoryLimits.entries + 3
        for index in 0..<total {
            _ = try await fixture.store.record(.testSample("value-\(index)"), key: "field\(index)", retention: .untilDeleted)
            fixture.clock.advance(1)
        }

        #expect(await fixture.store.count() == InputHistoryLimits.entries)
        #expect(fixture.files.count == InputHistoryLimits.entries)
        let entries = try await fixture.store.unlock(reason: reason)
        #expect(entries.count == InputHistoryLimits.entries)
        #expect(entries.first?.payload.value == "value-\(total - 1)")
        #expect(entries.last?.payload.value == "value-3")

        // An evicted field's key is gone with it: recording it again is a plain new entry.
        _ = try await fixture.store.record(.testSample("value-0 again"), key: "field0", retention: .untilDeleted)
        #expect(await fixture.store.count() == InputHistoryLimits.entries)
    }

    @Test func oversizedValuesAreRejected() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        func record(_ payload: InputHistoryPayload, key: String = "a") async throws {
            _ = try await store.record(payload, key: key, retention: .thirtyMinutes)
        }

        await #expect(throws: InputHistoryError.tooLarge) {
            try await record(.testSample(String(repeating: "x", count: InputHistoryLimits.value + 1), kind: .text))
        }
        await #expect(throws: InputHistoryError.tooLarge) {
            try await record(.testSample(String(repeating: "x", count: InputHistoryLimits.password + 1)))
        }
        await #expect(throws: InputHistoryError.invalid) { try await record(.testSample("")) }
        await #expect(throws: InputHistoryError.invalid) { try await record(.testSample(), key: "") }
        await #expect(throws: InputHistoryError.invalid) {
            try await record(.testSample(), key: String(repeating: "k", count: InputHistoryLimits.key + 1))
        }
        // A refusal makes no keys and no files.
        #expect(fixture.files.isEmpty)
        #expect(fixture.publicKeys.itemCount == 0 && fixture.privateKeys.itemCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))

        // The limits themselves are allowed. A long username is dropped, never cut; long titles and labels are cut.
        try await record(.testSample(
            String(repeating: "p", count: InputHistoryLimits.password),
            username: String(repeating: "u", count: InputHistoryLimits.username + 1),
            title: String(repeating: "t", count: 300),
            label: String(repeating: "l", count: 300)
        ), key: "limits")
        try await record(.testSample(String(repeating: "v", count: InputHistoryLimits.value), kind: .text), key: "text")
        let entries = try await store.unlock(reason: reason)
        let password = try #require(entries.first { $0.payload.kind == .password })
        #expect(password.payload.value.count == InputHistoryLimits.password)
        #expect(password.payload.username == nil)
        #expect(password.payload.title.count == InputHistoryLimits.title)
        #expect(password.payload.label.count == InputHistoryLimits.label)
        #expect(entries.contains { $0.payload.value.count == InputHistoryLimits.value })
    }

    // MARK: - Retention

    @Test func expiredEntriesArePurgedByNameWithoutDecrypting() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("old"), key: "a", retention: .thirtyMinutes)
        fixture.clock.advance(20 * 60)
        _ = try await fixture.store.record(.testSample("new"), key: "b", retention: .thirtyMinutes)
        // A name the store never writes, and a file that is not an entry at all.
        try Data([1, 2, 3]).write(to: fixture.directory.appendingPathComponent("junk.wih"))
        try Data([1]).write(to: fixture.directory.appendingPathComponent("notes.txt"))
        let reads = (fixture.publicKeys.readCount, fixture.privateKeys.readCount)
        let erases = fixture.privateKeys.eraseCount

        fixture.clock.advance(15 * 60)
        let status = await fixture.store.purge()

        #expect(status.count == 1)
        #expect(fixture.files.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("junk.wih").path))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("notes.txt").path))
        let next = try #require(status.nextExpiry)
        #expect(abs(next.timeIntervalSince(fixture.clock.now()) - 15 * 60) < 0.01)
        // Purging read no key at all, and the keys stay while an entry remains.
        #expect(fixture.publicKeys.readCount == reads.0 && fixture.privateKeys.readCount == reads.1)
        #expect(fixture.privateKeys.eraseCount == erases)

        fixture.clock.advance(16 * 60)
        #expect(await fixture.store.purge() == InputHistoryStatus(count: 0, nextExpiry: nil))
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.readCount == 0)
    }

    @Test func shorteningRetentionPurgesImmediately() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("older"), key: "a", retention: .oneDay)
        fixture.clock.advance(2 * 60 * 60)
        _ = try await fixture.store.record(.testSample("newer"), key: "b", retention: .oneDay)

        let status = try await fixture.store.applyRetention(.thirtyMinutes)
        #expect(status.count == 1)
        #expect(fixture.files.count == 1)
        #expect(fixture.privateKeys.readCount == 0)
        let entries = try await fixture.store.unlock(reason: reason)
        #expect(values(entries) == ["newer"])
        #expect(entries.first?.expiresAt == entries.first.map { $0.createdAt.addingTimeInterval(30 * 60) })

        // A longer retention is measured from the entry's creation too.
        _ = try await fixture.store.applyRetention(.oneWeek)
        let longer = try await fixture.store.unlock(reason: reason)
        #expect(longer.first?.expiresAt == longer.first.map { $0.createdAt.addingTimeInterval(7 * 24 * 3600) })
        // And the entry keeps its identity, so the key that made it still replaces it.
        #expect(longer.first?.id == entries.first?.id)
        _ = try await fixture.store.record(.testSample("replacement"), key: "b", retention: .oneWeek)
        #expect(await fixture.store.count() == 1)
    }

    @Test func untilDeletedEntriesNeverExpire() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        let status = try await fixture.store.record(.testSample("forever"), key: "a", retention: .untilDeleted)
        #expect(status.nextExpiry == nil)
        #expect(try #require(fixture.files.first).lastPathComponent.hasPrefix("never-"))

        fixture.clock.advance(400 * 24 * 3600)
        #expect(await fixture.store.purge().count == 1)
        // A clock that moved back since the entry was made does not remove it either.
        fixture.clock.advance(-800 * 24 * 3600)
        #expect(await fixture.store.purge().count == 1)
        fixture.clock.advance(800 * 24 * 3600)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["forever"])
        #expect(try await fixture.store.applyRetention(.untilDeleted).count == 1)
    }

    @Test func clockMovedBackwardsExpiresFutureEntries() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("future"), key: "a", retention: .oneDay)

        // Four minutes ahead is clock noise; six is a clock that moved back, and would stretch the retention.
        fixture.clock.advance(-4 * 60)
        #expect(await fixture.store.purge().count == 1)
        fixture.clock.advance(-2 * 60)
        #expect(await fixture.store.purge().count == 0)
        #expect(fixture.files.isEmpty)
        #expect(fixture.publicKeys.itemCount == 0)
    }

    // MARK: - Deleting and shredding keys

    @Test func clearAllDeletesFilesAndBothKeys() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("one"), key: "a", retention: .untilDeleted)
        _ = try await fixture.store.record(.testSample("two"), key: "b", retention: .untilDeleted)
        let oldKey = try fixture.publicKeys.read(service: fixture.store.service, context: LAContext())

        let status = try await fixture.store.clear()
        #expect(status == InputHistoryStatus(count: 0, nextExpiry: nil))
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)
        #expect(try await fixture.store.unlock(reason: reason).isEmpty)

        // The next entry starts a new pair.
        _ = try await fixture.store.record(.testSample("three"), key: "a", retention: .untilDeleted)
        #expect(try fixture.publicKeys.read(service: fixture.store.service, context: LAContext()) != oldKey)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["three"])
    }

    @Test(arguments: InputHistoryEmptying.allCases)
    func emptyStoreShredsItsKeys(how: InputHistoryEmptying) async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("only"), key: "a", retention: .thirtyMinutes)
        #expect(fixture.privateKeys.itemCount == 1 && fixture.publicKeys.itemCount == 1)

        switch how {
        case .delete:
            let entry = try #require(try await fixture.store.unlock(reason: reason).first)
            // Another entry keeps the keys alive.
            _ = try await fixture.store.record(.testSample("other"), key: "b", retention: .thirtyMinutes)
            _ = try await fixture.store.delete(entry.id)
            #expect(fixture.privateKeys.itemCount == 1 && fixture.publicKeys.itemCount == 1)
            let remaining = try #require(try await fixture.store.unlock(reason: reason).first)
            #expect(try await fixture.store.delete(remaining.id).count == 0)
        case .forget:
            #expect(try await fixture.store.forget("a").count == 0)
        case .expiry:
            fixture.clock.advance(31 * 60)
            #expect(await fixture.store.purge().count == 0)
        case .clear:
            _ = try await fixture.store.clear()
        }

        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.itemCount == 0, "the private key is gone")
        #expect(fixture.publicKeys.itemCount == 0, "the public key is gone")
    }

    @Test func mismatchedKeyPairFailsClosedAndStartsOver() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("sealed to the first key"), key: "a", retention: .untilDeleted)
        // The public key is replaced by one that belongs to no private key here, and the next entry is sealed to it.
        let foreign = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        try fixture.publicKeys.write(foreign, service: fixture.store.service, context: LAContext())
        _ = try await fixture.store.record(.testSample("sealed to the foreign key"), key: "b", retention: .untilDeleted)
        #expect(fixture.files.count == 2)

        await #expect(throws: InputHistoryError.keysUnusable) { _ = try await fixture.store.unlock(reason: reason) }
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)

        // Starting over: the next entry makes a fresh pair and opens.
        _ = try await fixture.store.record(.testSample("fresh"), key: "c", retention: .untilDeleted)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["fresh"])
    }

    @Test func halfAKeyPairStartsOverWithoutKeepingUnreadableEntries() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("lost"), key: "a", retention: .untilDeleted)
        // Someone deleted the private key, as Keychain Access can.
        try fixture.privateKeys.erase(service: fixture.store.service)

        _ = try await fixture.store.record(.testSample("kept"), key: "b", retention: .untilDeleted)
        #expect(fixture.files.count == 1)
        #expect(values(try await fixture.store.unlock(reason: reason)) == ["kept"])
    }

    // MARK: - Who may use it

    @Test func privateProfileIsRefused() async throws {
        let fixture = InputHistoryStoreFixture(profileID: Profile.privateID)
        defer { fixture.cleanUp() }
        let store = fixture.store

        await #expect(throws: InputHistoryError.privateBrowsing) {
            _ = try await store.record(.testSample(), key: "a", retention: .thirtyMinutes)
        }
        await #expect(throws: InputHistoryError.privateBrowsing) { _ = try await store.unlock(reason: "Test") }
        await #expect(throws: InputHistoryError.privateBrowsing) { _ = try await store.clear() }
        await #expect(throws: InputHistoryError.privateBrowsing) { _ = try await store.forget("a") }
        await #expect(throws: InputHistoryError.privateBrowsing) { _ = try await store.applyRetention(.oneDay) }
        #expect(await store.purge() == InputHistoryStatus(count: 0, nextExpiry: nil))
        try await store.erase()

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)
        #expect(fixture.privateKeys.writeCount == 0 && fixture.publicKeys.writeCount == 0)
        #expect(fixture.privateKeys.eraseCount == 0 && fixture.publicKeys.eraseCount == 0)
    }

    @Test func secondInstanceWithoutTheSessionStoresNothing() async throws {
        let fixture = InputHistoryStoreFixture(ownsSession: false)
        defer { fixture.cleanUp() }
        let store = fixture.store
        await #expect(throws: InputHistoryError.unavailable) {
            _ = try await store.record(.testSample(), key: "a", retention: .thirtyMinutes)
        }
        await #expect(throws: InputHistoryError.unavailable) { _ = try await store.forget("a") }
        await #expect(throws: InputHistoryError.unavailable) { _ = try await store.delete("1-2") }
        await #expect(throws: InputHistoryError.unavailable) { _ = try await store.clear() }
        await #expect(throws: InputHistoryError.unavailable) { _ = try await store.applyRetention(.oneDay) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)
        #expect(fixture.publicKeys.writeCount == 0)
    }

    @Test func secondInstanceLeavesTheOwnersFilesAndKeysAlone() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("owned"), key: "a", retention: .thirtyMinutes)
        let other = fixture.sibling(ownsSession: false)

        fixture.clock.advance(31 * 60)
        // The expired entry no longer counts, but only the owner deletes it, and only the owner destroys the keys.
        #expect(await other.purge().count == 0)
        #expect(fixture.files.count == 1)
        #expect(fixture.privateKeys.itemCount == 1 && fixture.publicKeys.itemCount == 1)

        #expect(await fixture.store.purge().count == 0)
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)

        // Erasing a profile is allowed whoever owns the session.
        _ = try await fixture.store.record(.testSample("again"), key: "a", retention: .thirtyMinutes)
        try await other.erase()
        #expect(fixture.files.isEmpty)
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)
    }

    @Test func eraseRemovesTheDirectoryAndBothKeys() async throws {
        let fixture = InputHistoryStoreFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.record(.testSample("one"), key: "a", retention: .untilDeleted)
        try await fixture.store.erase()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(fixture.privateKeys.itemCount == 0 && fixture.publicKeys.itemCount == 0)
        // Erasing what is not there is not an error.
        try await fixture.store.erase()
    }
}
