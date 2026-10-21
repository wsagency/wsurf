// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// Cards and other items in the import review: they are reviewed before Import, follow their login, and are written only by Import.
// Synthetic values only.
@MainActor
extension CredentialExchangeCoordinatorTests {
    private func cardCredential() -> ASImportableCredential {
        .creditCard(.init(
            number: .init(id: nil, fieldType: .string, value: SecureItemFixtures.cardNumber, label: nil),
            fullName: .init(id: nil, fieldType: .string, value: "Ada Lovelace", label: nil),
            cardType: nil,
            verificationNumber: .init(id: nil, fieldType: .concealedString, value: SecureItemFixtures.cardCode, label: nil),
            pin: nil, expiryDate: nil, validFrom: nil
        ))
    }

    private func itemRecords(_ f: Fixture) throws -> [CredentialImportReview.Record] {
        try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)).candidates.flatMap(\.records)
    }

    /// A card is one record of the review, nothing is written until Import, and Import stores the card.
    @Test func aCardOnlyItemIsReviewedAsItemsAndStoredOnImport() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            let before = try f.diskBytes()
            try await f.stage(handBuilt([item(id: 1, scoped: true, [cardCredential()])]))

            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.candidates.count == 1 && review.omitted.isEmpty)
            #expect(try itemRecords(f).map(\.kind) == [.secureItems])
            let key = try #require(review.candidates.first).searchKey
            #expect(!key.contains(SecureItemFixtures.cardNumber) && !key.contains(SecureItemFixtures.cardCode) && key.contains("item 1"))
            #expect(counts(planned(f)) == [1, 0])
            #expect(try f.diskBytes() == before)

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored().accounts
            #expect(stored.count == 2)
            let imported = try #require(stored.first { $0.secureItems != nil })
            #expect(imported.username.isEmpty && imported.password == nil)
            let card = try #require(imported.secureItems?.first)
            #expect(imported.secureItems?.count == 1 && card.kind == .creditCard)
            #expect(card.value("number") == SecureItemFixtures.cardNumber && card.value("verificationNumber") == SecureItemFixtures.cardCode)
        }
    }

    /// A card nobody decided goes where its login goes, in the review as well as in the import itself.
    @Test func anUndecidedCardFollowsItsLogin() async throws {
        try await withFixture { f in
            let bare = account(username: "", password: nil, totp: generator())
            try await f.seed([bare])
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), cardCredential()])]))
            let initial = try itemRecords(f)
            #expect(initial.map(\.kind) == [.password, .secureItems])
            #expect(initial.allSatisfy { $0.destination == .newAccount(origins: [Self.origin]) && !$0.needsChoice })

            // Skip the login: the card is skipped with it, and the outcome says so.
            try f.coordinator.choose(.skip, for: initial[0].incoming, owner: f.owner)
            #expect(try itemRecords(f).map(\.destination) == [.skipped, .skipped])
            let skipped = try #require(planned(f))
            #expect(counts(skipped) == [0, 0] && skipped.results.map(\.action) == [.skipped, .skipped])

            // Merge the login into a stored account: the card goes there too.
            try f.coordinator.choose(.merge(into: bare.id), for: initial[0].incoming, owner: f.owner)
            for record in try itemRecords(f) {
                guard case let .existing(accountID, _, _, _) = record.destination else {
                    Issue.record("\(record.kind) was not placed in the stored account")
                    continue
                }
                #expect(accountID == bare.id)
            }
            #expect(counts(planned(f)) == [0, 1])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try #require(try await f.stored().accounts.first)
            #expect(stored.password == "pw1" && stored.secureItems?.first?.kind == .creditCard && stored.totp != nil)
        }
    }
}
