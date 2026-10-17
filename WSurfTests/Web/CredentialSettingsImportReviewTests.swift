// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// The page's side of the import review: the decisions the sheet makes through the model, what a refusal says, and what Import
// reports afterwards. The coordinator and the vault are real. Synthetic data only.
@MainActor
struct CredentialSettingsImportReviewTests {
    private let base = CredentialExchangeCoordinatorTests()

    private func withPage(
        _ body: (CredentialExchangeCoordinatorTests.Fixture, CredentialSettingsModel) async throws -> Void
    ) async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let model = CredentialSettingsModel(profile: f.profile, pasteboard: pasteboard, exchange: f.coordinator, manager: f.manager)
            await model.load()
            try await body(f, model)
            model.cancelImport()
        }
    }

    /// A decision that is kept clears an earlier refusal; one that doesn't apply says so and changes nothing.
    @Test func aRefusedDecisionIsShownAndAKeptOneClearsIt() async throws {
        try await withPage { f, model in
            try await f.stage(base.threeItems(), owner: model.owner)
            let item = try #require(model.importReview?.candidates.first)
            let tally = try #require(model.importReview?.tally)

            model.chooseImportItem(.keepSaved, for: item.id)
            #expect(model.error != nil && model.importReview?.tally == tally)

            model.chooseImportItem(.skip, for: item.id)
            #expect(model.error == nil)
            #expect(model.importCandidate(withID: item.id)?.effect == .skipped && model.importReview?.tally.skipped == 1)
        }
    }

    /// The sheet asks for the saved credentials a part can join only when the user opens the list.
    @Test func mergeTargetsAreAskedForOnlyOnDemand() async throws {
        try await withPage { f, model in
            var bare = base.account(username: "", password: nil, totp: base.generator("bare-seed"))
            bare.origins = ["https://other.test"]
            let snapshot = try await f.stored()
            _ = try await f.manager.commit(
                snapshot.accounts + [bare], expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch)
            )
            try await f.stage(base.threeItems(), owner: model.owner)
            let record = try #require(model.importReview?.candidates.first?.records.first)

            let targets = model.mergeTargets(for: record.incoming)
            #expect(targets.map(\.accountID) == [bare.id] && targets.first?.allowedOrigins == ["https://other.test"])
        }
    }

    /// Import reports what the plan made of the choices, and the page lists it.
    @Test func importReportsWhatBecameOfEveryItem() async throws {
        try await withPage { f, model in
            try await f.stage(base.threeItems(), owner: model.owner)
            let third = try #require(model.importReview?.candidates.last)
            model.chooseImportItem(.skip, for: third.id)
            let planned = try #require(model.plannedImportOutcome())
            #expect(planned.added == 2 && planned.updated == 0)

            await model.commitImport()
            #expect(model.importReview == nil && model.transferMessage?.kind == .succeeded)
            let results = try #require(model.lastImport?.results)
            // Five credentials in three items: the login and note of the first, the login and code of the second, the skipped login.
            #expect(results.count == 5 && results.filter { $0.action == .added }.count == 4 && results.filter { $0.action == .skipped }.count == 1)
            #expect(try await f.stored().accounts.count == 3)
        }
    }
}
