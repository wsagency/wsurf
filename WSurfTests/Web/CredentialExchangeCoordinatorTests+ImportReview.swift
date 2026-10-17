// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// The import review as the user meets it: which credentials need a decision, what is decided for them, and what a decision costs.
// Synthetic data only (`example.test` hosts, hand-built transfers).
@MainActor
extension CredentialExchangeCoordinatorTests {
    func plainNote(_ text: String) -> ASImportableCredential {
        .note(.init(content: .init(id: nil, fieldType: .string, value: text, label: nil)))
    }

    /// Three items that have everything the review distinguishes: a login with a note, a login with a code, a bare login.
    func threeItems() -> ASExportedCredentialData {
        handBuilt([
            item(id: 1, scoped: true, [password("pw1"), plainNote("memo")]),
            item(id: 2, scoped: true, [password("pw2"), totpCredential()]),
            item(id: 3, scoped: true, [password("pw3")]),
        ])
    }

    // MARK: - Re-imports

    /// The same transfer, imported twice. The first import recorded what it brought in, so nothing in the second is a question.
    @Test func reimportOfAnUnchangedTransferNeedsNoDecision() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.count == 4)

            try await f.stage(threeItems())
            let again = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(again.candidates.count == 3)
            #expect(again.isResolved, "every item is the one that was imported before")
        }
    }

    /// Spec §13.3: no silent re-import from Trash. Removing an imported item and importing it again leaves it out until the user says so.
    @Test func previouslyRemovedItemIsSkippedByDefault() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let stored = try await f.stored()
            let victim = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 1]) })
            let epoch = try #require(f.manager.authorizationEpoch)
            _ = try await f.manager.delete(.account(victim.id), expectedRevision: stored.revision, authorizedEpoch: epoch)

            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("memo")])]))
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.candidates.flatMap(\.records).allSatisfy { $0.destination == .skipped })
            #expect(counts(review.outcome) == [0, 0])
        }
    }
}
