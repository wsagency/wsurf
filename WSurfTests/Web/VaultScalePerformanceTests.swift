// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import XCTest

@testable import WSurf

// A vault of 20,000 synthetic credentials (every tenth with a passkey) behind the real manager and store: one saved edit, through
// the per-account write and through the whole-vault commit. Nothing here is real data. The vault limit is 25,000; the owner's report
// was 5.1 s for one edit at 20,000. `Tools/check-performance.sh` holds the measured steps to budgets set from the Pro's samples.
nonisolated final class VaultScalePerformanceTests: XCTestCase, @unchecked Sendable {
    static let count = 20_000
    private static let iterations = 5

    /// The stored credentials: usernames and passwords no import item of `ExchangeScale` repeats, so an import against them is new.
    static func storedAccounts() throws -> [CredentialAccount] {
        try (0..<count).map { index in
            let host = "site\(index).example.test"
            let passkeys = try index % 10 == 0
                ? [VaultFixtures.passkey(rpID: host, credentialID: Data("stored-credential-\(index)".utf8))]
                : []
            return VaultFixtures.account(
                username: "stored\(index)", password: "stored-password-\(index)", origin: "https://\(host)", passkeys: passkeys
            )
        }
    }

    /// What a test keeps between its synchronous steps.
    @MainActor
    final class Fixture {
        var profile: Profile?
        var vault: FixtureVault?
        var accounts: [CredentialAccount] = []
        let coordinator = CredentialExchangeCoordinator()
        let owner = UUID()
        /// The write the next measured step makes, prepared outside the measurement.
        var nextWrite: AccountWrite?
        var nextPayload: (accounts: [CredentialAccount], revision: UInt64)?

        /// An unlocked vault holding `storedAccounts()`.
        func makeVault() async throws {
            let profile = Profile(id: UUID(), name: "Scale", symbol: "key", color: .blue)
            self.profile = profile
            let made = try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked])
            let vault = try XCTUnwrap(made.vaults.first)
            self.vault = vault
            accounts = try VaultScalePerformanceTests.storedAccounts()
            try await VaultManagerFixture.save(accounts, in: vault)
        }

        /// Stages `transfer` for review against the vault, as the system hand-off does.
        func stage(_ transfer: ASExportedCredentialData) async throws {
            let manager = try XCTUnwrap(vault?.manager)
            let token = UUID()
            XCTAssertEqual(coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)), .accepted)
            try coordinator.claimImport(token: token, for: manager, owner: owner)
            try await coordinator.stage(transfer, into: manager, owner: owner)
        }

        var review: CredentialImportReview? {
            vault.flatMap { coordinator.importReview(for: $0.manager, owner: owner) }
        }

        func cleanup() async {
            if let manager = vault?.manager {
                coordinator.cancelImport(for: manager, owner: owner)
            }
            if let profile {
                await VaultManagerFixture.cleanup(profile)
            }
        }
    }

    /// Runs `work` to its end from this synchronous test (`ReaderPerformanceTests.finish`): the test is not an actor job itself, so
    /// the wait spins the run loop that the manager's main-actor steps need.
    @MainActor
    func finish(_ work: @escaping @MainActor () async throws -> Void) {
        let done = XCTestExpectation(description: "async step")
        Task {
            do {
                try await work()
            } catch {
                XCTFail("\(error)")
            }
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 600), .completed)
    }

    @MainActor
    func measuredOptions(manual: Bool = false) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        if manual {
            options.invocationOptions = [.manuallyStart, .manuallyStop]
        }
        return options
    }

    // MARK: Edits

    /// One changed password, written with the per-account write the import and the bulk actions use. The read that finds the
    /// account's stamp is the caller's and stays outside the measurement.
    func testEditingOneOfTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            let fixture = Fixture()
            finish { try await fixture.makeVault() }
            guard let manager = fixture.vault?.manager else { return XCTFail("The 20,000-credential vault was not made.") }
            var edits = 0
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions(manual: true)) {
                edits += 1
                let password = "edited-\(edits)"
                finish {
                    let snapshot = try await manager.snapshot()
                    var edited = try XCTUnwrap(snapshot.accounts.first)
                    edited.password = password
                    let stamp = try XCTUnwrap(snapshot.stamps[edited.id])
                    fixture.nextWrite = AccountWrite(accountID: edited.id, expected: .stamp(stamp), replacement: edited)
                }
                startMeasuring()
                finish {
                    let write = try XCTUnwrap(fixture.nextWrite)
                    _ = try await manager.commitAccounts([write], authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch))
                }
                stopMeasuring()
            }
            let last = "edited-\(edits)"
            finish {
                let snapshot = try await manager.snapshot()
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, last)
            }
            finish { await fixture.cleanup() }
        }
    }

    /// The same edit through the whole-vault commit the credential editor, the autofill save and the passkey sign-in use: the
    /// caller hands back every account, so the store compares each with its stored row once.
    func testSavingOneEditOfTwentyThousandCredentialsAsAWholeVault() {
        MainActor.assumeIsolated {
            let fixture = Fixture()
            finish { try await fixture.makeVault() }
            guard let manager = fixture.vault?.manager else { return XCTFail("The 20,000-credential vault was not made.") }
            var edits = 0
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions(manual: true)) {
                edits += 1
                let password = "edited-\(edits)"
                finish {
                    let snapshot = try await manager.snapshot()
                    var accounts = snapshot.accounts
                    accounts[0].password = password
                    fixture.nextPayload = (accounts, snapshot.revision)
                }
                startMeasuring()
                finish {
                    let payload = try XCTUnwrap(fixture.nextPayload)
                    _ = try await manager.commit(
                        payload.accounts, expectedRevision: payload.revision, authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch)
                    )
                }
                stopMeasuring()
            }
            let last = "edited-\(edits)"
            finish {
                let snapshot = try await manager.snapshot()
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, last)
            }
            finish { await fixture.cleanup() }
        }
    }

    // MARK: Import review

    /// The merge sheet of 20 imported passkeys, each listing the 20,000 saved credentials it can join (none holds its credential
    /// ID). Each list is one pass over the vault; the item, the stored credential IDs and the titles are looked up.
    func testListingMergeTargetsForPasskeysAmongTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            let fixture = Fixture()
            finish {
                try await fixture.makeVault()
                try await fixture.stage(try ExchangeScale.transfer(items: 2_000, passkeyEvery: 1, totpEvery: nil))
            }
            guard let review = fixture.review else { return XCTFail("The 2,000-item transfer was not staged.") }
            let passkeys = Array(review.candidates.flatMap(\.records).filter { $0.kind == .passkey }.prefix(20))
            XCTAssertEqual(passkeys.count, 20)
            XCTAssertEqual(passkeys.first.map { fixture.coordinator.mergeTargets(for: $0.incoming, owner: fixture.owner).count }, Self.count)
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions()) {
                for record in passkeys {
                    _ = fixture.coordinator.mergeTargets(for: record.incoming, owner: fixture.owner)
                }
            }
            finish { await fixture.cleanup() }
        }
    }

    /// One merge per pass in a review with nothing left to decide that fills the vault: 5,000 new items beside 20,000 saved
    /// credentials make the 25,000 the vault holds at most. A merge is proven by the import's plan before it is kept, so it costs one
    /// plan of the import (which still checks the 5,000 accounts it would add), never the review rebuilt and never the vault and the
    /// transfer validated again.
    func testChoosingAMergeInAReviewThatFillsTheVault() {
        MainActor.assumeIsolated {
            let fixture = Fixture()
            let items = CredentialVaultLimits.accounts - Self.count
            finish {
                try await fixture.makeVault()
                try await fixture.stage(try ExchangeScale.transfer(items: items, passkeyEvery: nil, totpEvery: nil))
            }
            guard let review = fixture.review else { return XCTFail("The 5,000-item transfer was not staged.") }
            XCTAssertTrue(review.isResolved)
            let notes = review.candidates.compactMap { $0.records.first { $0.kind == .note } }
            XCTAssertEqual(notes.count, items)
            var merged = 0
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions()) {
                // The note of one item joins one saved credential that holds no note and no other app's item.
                let note = notes[merged], target = fixture.accounts[merged].id
                merged += 1
                do {
                    try fixture.coordinator.choose(.merge(into: target), for: note.incoming, owner: fixture.owner)
                } catch {
                    XCTFail("merge \(merged) was refused: \(error)")
                }
            }
            let decided = fixture.review?.candidates.filter { $0.records.contains { $0.choice == .merge(into: fixture.accounts[0].id) } }
            XCTAssertEqual(decided?.count, 1)
            finish { await fixture.cleanup() }
        }
    }
}
