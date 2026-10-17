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
}
