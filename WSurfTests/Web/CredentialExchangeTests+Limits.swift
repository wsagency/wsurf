// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// A real Passwords library is thousands of items, many with a note or a passkey beside the login. The transfer is sized for that.
// All data is synthetic (`ExchangeScale`): `example.test` hosts and generated keys.
extension CredentialExchangeTests {
    /// The owner's transfer was refused at `account[0]/item[542]`: every credential counted toward one cap of 1,000, so an item
    /// with a login and a note used up two of them. 600 such items hold 1,200 credentials and must import.
    @Test func transferWithMoreThan1000CredentialsImports() throws {
        let transfer = try ExchangeScale.transfer(items: 600, noteBytes: 40, passkeyEvery: nil, totpEvery: nil)
        #expect(transfer.accounts[0].items.reduce(0) { $0 + $1.credentials.count } == 1_200)

        let preview = try CredentialExchangeCodec.preview(transfer, against: snapshot([]))

        #expect(preview.candidates.count == 600)
        #expect(preview.omitted.isEmpty)
        #expect(preview.candidates.allSatisfy { $0.password != nil && $0.notes?.count == 1 })
    }

    @Test func transferOf5000ItemsWithNotesAndPasskeysImports() throws {
        let transfer = try ExchangeScale.transfer(items: 5_000)

        let preview = try CredentialExchangeCodec.preview(transfer, against: snapshot([]))

        #expect(preview.candidates.count == 5_000)
        #expect(preview.omitted.isEmpty)
        #expect(preview.candidates.filter { !$0.passkeys.isEmpty }.count == 500)
        #expect(preview.candidates.filter { $0.totp != nil }.count == 250)
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(accounts.count == 5_000)
    }

    // MARK: A refusal names the limit

    /// The refusal of `transfer`, or `nil` (with an issue) when it was not refused that way.
    private func refusal(
        of transfer: ASExportedCredentialData, sourceLocation: SourceLocation = #_sourceLocation
    ) -> CredentialExchangeError? {
        do {
            _ = try CredentialExchangeCodec.preview(transfer, against: snapshot([]))
            Issue.record("Expected the transfer to be refused", sourceLocation: sourceLocation)
        } catch let error as CredentialExchangeError {
            return error
        } catch {
            Issue.record("Expected a positioned refusal, got \(error)", sourceLocation: sourceLocation)
        }
        return nil
    }

    /// 101 items of one login and 990 codes each. Every code after the first is skipped later, but all of them count toward the
    /// transfer, so after 100 items the total is 99,100 and the next item cannot fit its 991.
    private func transferOverTheCredentialCap(titles: Bool = false) -> ASExportedCredentialData {
        let codes = Array(repeating: ExchangeScale.totp(0), count: 990)
        return ExchangeScale.transfer((0...100).map { index in
            var item = ExchangeScale.item(index, credentials: [ExchangeScale.login(index)] + codes)
            if titles {
                item.title = "Zebra Savings \(index)"
            }
            return item
        })
    }

    @Test func transferOverTheCredentialCapIsRefusedNamingTheLimit() throws {
        let error = try #require(refusal(of: transferOverTheCredentialCap()))

        #expect(error.reason == .oversized && error.limit == .credentials)
        #expect(error.record == .item(account: 0, item: 100))
        #expect(error.description == "oversized(credentials) at account[0]/item[100]")
    }

    @Test func transferOverTheItemCapIsRefusedNamingTheLimit() throws {
        let items = (0...CredentialVaultLimits.accounts).map { ExchangeScale.item($0, credentials: [ExchangeScale.login($0)]) }

        let error = try #require(refusal(of: ExchangeScale.transfer(items)))

        #expect(error.reason == .oversized && error.limit == .items)
        #expect(error.record == .item(account: 0, item: CredentialVaultLimits.accounts))
    }

    @Test func transferOverTheCollectionCapIsRefusedNamingTheLimit() throws {
        let collections = (0...CredentialVaultLimits.accounts).map {
            ASImportableCollection(
                id: ExchangeScale.itemID($0), created: nil, lastModified: nil, title: "c", subtitle: nil, items: [], subcollections: []
            )
        }
        let transfer = ExchangeScale.transfer([ExchangeScale.item(0, credentials: [ExchangeScale.login(0)])])
        let account = ASImportableAccount(
            id: ExchangeScale.accountID, userName: "ada", email: "", collections: collections, items: transfer.accounts[0].items
        )
        let withCollections = ASExportedCredentialData(
            accounts: [account],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture", timestamp: transfer.timestamp
        )

        let error = try #require(refusal(of: withCollections))

        #expect(error.reason == .oversized && error.limit == .collections)
        #expect(error.record == .collection(account: 0, path: [CredentialVaultLimits.accounts]))
    }

    @Test func aPasskeyKeyOverItsBoundIsRefusedNamingTheLimit() throws {
        let key = Data(count: PasskeyKeyEncoding.maximumDERBytes + 1)
        let credentials = [ExchangeScale.login(0), passkey(key: key)]
        let transfer = ExchangeScale.transfer([ExchangeScale.item(0, credentials: credentials)])

        let error = try #require(refusal(of: transfer))

        #expect(error.reason == .oversized && error.limit == .keyBytes)
        #expect(error.record == .credential(account: 0, item: 0, credential: 1))
        #expect(error.credentialKind == .passkey)
    }

    @Test func itemOverTheByteBoundIsRefusedButTheSameBytesSplitImport() throws {
        let text = String(repeating: "x", count: 2_000_001)
        let together = ExchangeScale.transfer([ExchangeScale.item(0, credentials: [ExchangeScale.login(0), note(text), note(text)])])

        let error = try #require(refusal(of: together))

        #expect(error.reason == .oversized && error.limit == .itemBytes)
        #expect(error.record == .credential(account: 0, item: 0, credential: 2))
        #expect(error.credentialKind == .note)

        // The same two notes in two items are 2 MB each: both import.
        let split = ExchangeScale.transfer([
            ExchangeScale.item(0, credentials: [ExchangeScale.login(0), note(text)]),
            ExchangeScale.item(1, credentials: [ExchangeScale.login(1), note(text)]),
        ])
        let preview = try CredentialExchangeCodec.preview(split, against: snapshot([]))
        #expect(preview.candidates.count == 2 && preview.omitted.isEmpty)
    }

    /// Control characters are six bytes each once escaped, so a note a quarter the size of the item cap can still be too big to
    /// save: a history row, which carries the account encoded, would not hold it.
    @Test func anItemThatGrowsWhenEncodedIsRefusedNamingTheLimit() throws {
        let text = String(repeating: "\u{01}", count: 1_200_000)
        let transfer = ExchangeScale.transfer([ExchangeScale.item(0, credentials: [ExchangeScale.login(0), note(text)])])

        let error = try #require(refusal(of: transfer))

        #expect(error.reason == .oversized && error.limit == .itemEncodedBytes)
        #expect(error.record == .item(account: 0, item: 0))
        let bound = (Double(CredentialVaultLimits.encodedAccountBytes) / 1_000_000).formatted()
        #expect(CredentialTransferMessage.malformed(error).text.contains("larger than \(bound) MB once saved"))

        // 900,000 of the same characters are 5.4 MB once saved: the item imports, and the store keeps what the import kept.
        let smallerNote = note(String(repeating: "\u{01}", count: 900_000))
        let smaller = ExchangeScale.transfer([ExchangeScale.item(0, credentials: [ExchangeScale.login(0), smallerNote])])
        let preview = try CredentialExchangeCodec.preview(smaller, against: snapshot([]))
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(accounts.count == 1)
        try ProfileVaultStore.validate(accounts, blockedOrigins: [])
    }

    @Test func transferOverTheTotalByteBudgetIsRefusedNamingTheLimit() throws {
        // One 3.9 MB string shared by every note: 32 items are 124.8 MB, the 33rd takes the transfer over 128 MB.
        let text = String(repeating: "x", count: 3_900_000)
        let transfer = ExchangeScale.transfer((0..<33).map {
            ExchangeScale.item($0, credentials: [ExchangeScale.login($0), note(text)])
        })

        let error = try #require(refusal(of: transfer))

        #expect(error.reason == .oversized && error.limit == .transferBytes)
        #expect(error.record == .credential(account: 0, item: 32, credential: 1))
    }

    @Test func previewCountsEachItemTheWayTheStoreDoes() throws {
        // The exporter's account id (1 MB here) is read once, but every kept item stores it, and the store counts it per account.
        // The preview measures with the store's own function, so it refuses at the item the store would refuse.
        let accountID = Data(repeating: 0xA1, count: 1_000_000)
        let items = (0..<200).map { ExchangeScale.item($0, credentials: [ExchangeScale.login($0)]) }
        let transfer = ASExportedCredentialData(
            accounts: [ASImportableAccount(id: accountID, userName: "ada", email: "", collections: [], items: items)],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let error = try #require(refusal(of: transfer))

        #expect(error.reason == .oversized && error.limit == .transferBytes)
        #expect(error.record == .item(account: 0, item: 127), "127 items of 1,000,0xx B fit in 128 MB, the 128th does not")
    }

    @Test func limitRefusalMessageNamesTheLimitAndNoValue() throws {
        let error = try #require(refusal(of: transferOverTheCredentialCap(titles: true)))

        let message = CredentialTransferMessage.malformed(error)

        #expect(message.text.contains("more than \(CredentialVaultLimits.credentials.formatted()) credentials"))
        #expect(message.text.contains("account[0]/item[100]"))
        for text in [message.text, error.description, String(describing: error)] {
            #expect(!text.contains("Zebra") && !text.contains("password-"), "no title or value in the refusal")
        }
    }

    @Test func everyLimitHasItsOwnText() {
        let texts = CredentialExchangeError.Limit.allCases.map(\.text)

        #expect(texts.count == CredentialExchangeError.Limit.allCases.count && Set(texts).count == texts.count)
        #expect(texts.allSatisfy { !$0.isEmpty && !$0.contains("import limits") })
    }
}
