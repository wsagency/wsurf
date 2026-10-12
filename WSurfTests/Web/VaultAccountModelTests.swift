// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct VaultAccountModelTests {
    /// Only the keys a v1 payload carries today: none of the new optional fields appears.
    private static let v1AccountJSON = """
        {
          "id": "00000000-0000-0000-0000-0000000000A1",
          "username": "ada",
          "origins": ["https://example.test"],
          "loginURLs": ["https://example.test/login"],
          "password": "s3cret",
          "passkeys": [
            {
              "id": "00000000-0000-0000-0000-0000000000B1",
              "credentialID": "oKGio6SlpqeoqaqrrK2urw==",
              "rpID": "example.test",
              "userHandle": "AQID",
              "userName": "ada",
              "userDisplayName": "Ada",
              "algorithm": -7,
              "privateKeyPKCS8": "AAEC",
              "backupEligible": true,
              "backupState": false,
              "lastSignedAt": 123.5
            }
          ]
        }
        """

    @Test func v1AccountJSONWithoutNewFieldsDecodesWithNils() throws {
        let account = try JSONDecoder().decode(CredentialAccount.self, from: Data(Self.v1AccountJSON.utf8))

        #expect(account.id == VaultFixtures.fixedAccountID)
        #expect(account.password == "s3cret")
        #expect(account.createdAt == nil)
        #expect(account.modifiedAt == nil)
        #expect(account.migratedAt == nil)
        #expect(account.passwordEvents == nil)
        #expect(account.totpEvents == nil)
        #expect(account.passwordBase == nil)
        #expect(account.totpBase == nil)
        let passkey = try #require(account.passkeys.first)
        #expect(passkey.lastSignedAt == VaultFixtures.reference(123.5))
        #expect(passkey.events == nil)
        #expect(passkey.base == nil)
    }

    @Test func newFieldsRoundTripThroughCodable() throws {
        var account = try VaultFixtures.richAccount()
        let events = CredentialEvents(
            lastImportedAt: VaultFixtures.reference(1),
            lastExportHandoffAt: VaultFixtures.reference(2),
            remoteLastObservedAt: VaultFixtures.reference(3)
        )
        account.createdAt = VaultFixtures.reference(10)
        account.modifiedAt = VaultFixtures.reference(11)
        account.migratedAt = VaultFixtures.reference(12)
        account.passwordEvents = events
        account.totpEvents = CredentialEvents(lastImportedAt: VaultFixtures.reference(4))
        account.passwordBase = ExchangeBase(contentHash: Data(repeating: 0xAB, count: 32), itemID: Data([8]))
        account.totpBase = ExchangeBase(contentHash: Data(repeating: 0xCD, count: 32), itemID: nil)
        account.passkeys[0].events = events
        account.passkeys[0].base = ExchangeBase(contentHash: Data(repeating: 0xEF, count: 32), itemID: Data([7]))

        let decoded = try JSONDecoder().decode(CredentialAccount.self, from: JSONEncoder().encode(account))

        #expect(decoded == account)
        #expect(decoded.totpEvents?.lastExportHandoffAt == nil)
        #expect(decoded.totpBase?.itemID == nil)
    }

    @Test func stampingCreationSetsOnlyCreatedAtAndModifiedAt() throws {
        let account = try VaultFixtures.richAccount()
        let now = VaultFixtures.reference(5_000)

        let stamped = account.stampingCreation(at: now)

        var expected = account
        expected.createdAt = now
        expected.modifiedAt = now
        #expect(stamped == expected)
        #expect(stamped.migratedAt == nil)
        #expect(stamped.passwordEvents == nil)
        #expect(stamped.totpEvents == nil)
        #expect(stamped.passwordBase == nil)
        #expect(stamped.totpBase == nil)
        #expect(account.createdAt == nil)
    }
}
