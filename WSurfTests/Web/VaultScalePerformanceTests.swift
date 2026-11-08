// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import AuthenticationServices
import Foundation
import XCTest

@testable import WSurf
@testable import WSurfVault

// A vault of 20,000 synthetic credentials (every tenth with a passkey) behind the real manager and store: one saved edit, through
// the per-account write, the whole-vault commit and each caller of it, plus one undo and one restore from the Trash. Nothing here is
// real data. The vault limit is 25,000; the owner's report
// was 5.1 s for one edit at 20,000. `Tools/check-performance.sh` holds the measured steps to budgets set from the Pro's samples.
nonisolated final class VaultScalePerformanceTests: XCTestCase, @unchecked Sendable {
    static let count = 20_000

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
        var nextSave: (login: SavedPassword, accountID: UUID, snapshot: StoreSnapshot)?
        var nextEntry: (id: UUID, revision: UInt64)?
        var model: CredentialSettingsModel?

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

        /// Drops what the pass prepared (its vault read, payload and write), so the next pass starts without it in memory.
        func dropPrepared() {
            nextWrite = nil
            nextPayload = nil
            nextSave = nil
            nextEntry = nil
        }

        func cleanup() async {
            model = nil
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
        let options = XCTMeasureOptions.budgeted
        if manual {
            options.invocationOptions = [.manuallyStart, .manuallyStop]
        }
        return options
    }

    /// Hands the allocator's free pages back to the system, so the footprint holds what is live and not what was freed but kept.
    private static func returnFreePages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// Measures `step` alone against a fresh 20,000-credential vault, as the memory it retains. `prepare` (the caller's own reads,
    /// given the pass number) runs before each measured step, outside the measurement; `check` runs once on the vault after the last
    /// pass.
    ///
    /// A step reads the vault into new containers of 20,000 accounts, builds two more maps for its transaction and swaps the store's
    /// cache for the new one, so it allocates and drops about 100 MB, much of it in large blocks. So every pass starts from a released
    /// state and ends in one: what an earlier pass prepared is dropped (`dropPrepared`), and the free pages are returned just before
    /// the measurement starts and just before it stops. What stays in the footprint is what the step retained, and a leak still
    /// shows, because only free pages go back. That holds only with the allocator's large-block cache off, as the test plan has it
    /// (`testFreedLargeBlocksLeaveTheFootprint`).
    @MainActor
    func measureWrite(
        prepare: @escaping @MainActor (Fixture, CredentialManager, Int) async throws -> Void,
        step: @escaping @MainActor (Fixture, CredentialManager) async throws -> Void,
        check: @escaping @MainActor (StoreSnapshot, Int) throws -> Void
    ) {
        let fixture = Fixture()
        finish { try await fixture.makeVault() }
        guard let manager = fixture.vault?.manager else { return XCTFail("The 20,000-credential vault was not made.") }
        var passes = 0
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions(manual: true)) {
            passes += 1
            let pass = passes
            autoreleasepool {
                finish { try await prepare(fixture, manager, pass) }
                Self.returnFreePages()
                startMeasuring()
                finish { try await step(fixture, manager) }
                Self.returnFreePages()
                stopMeasuring()
                fixture.dropPrepared()
            }
        }
        let last = passes
        finish {
            let snapshot = try await manager.snapshot()
            try check(snapshot, last)
        }
        finish { await fixture.cleanup() }
    }

    /// The host's physical footprint, the figure whose change `XCTMemoryMetric` reports.
    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// What every memory budget relies on: a freed large block leaves the footprint once the free pages are returned. By default the
    /// allocator keeps freed blocks of up to tens of MB in a cache that stays in the footprint, which `malloc_zone_pressure_relief`
    /// does not empty and the kernel takes back only under memory pressure, at moments of its own. On a Mac under pressure that moved
    /// single samples by 10 to 50 MB either way while the step kept nothing (0.1.17 gate 4, autofilled password among 20,000:
    /// 33718, -17744, 18924, 30097, -18711 kB). The test plan turns the cache off (`MallocLargeCache=0` in WSurf.xctestplan).
    func testFreedLargeBlocksLeaveTheFootprint() {
        let size = 4 << 20
        var blocks = (0..<8).map { _ in [UInt8](repeating: 1, count: size) }
        let held = Self.footprint()
        blocks.removeAll()
        Self.returnFreePages()
        let given = held - Self.footprint()
        XCTAssertGreaterThan(given, Int64(7 * size), "freed 32 MB, the footprint gave back \(given / 1024) kB")
    }

    // MARK: Autofill reads (D5)

    /// Measures `read` of a fresh 20,000-credential vault through its store, under the manager's current access, as the memory it
    /// retains; the free pages are returned just before the measurement starts and just before it stops, as in `measureWrite`.
    @MainActor
    func measureRead(_ read: @escaping @MainActor (ProfileVaultStore, UUID, VaultAccess) async throws -> Void) {
        let fixture = Fixture()
        finish { try await fixture.makeVault() }
        guard let manager = fixture.vault?.manager else { return XCTFail("The 20,000-credential vault was not made.") }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions(manual: true)) {
            autoreleasepool {
                Self.returnFreePages()
                startMeasuring()
                finish { try await read(manager.store, manager.vaultID, try manager.currentAccess()) }
                Self.returnFreePages()
                stopMeasuring()
            }
        }
        finish { await fixture.cleanup() }
    }

    /// The verified read of all 20,000 credentials (`snapshot`), which every autofill list made before D5(a): the baseline of the case
    /// below.
    func testReadingTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            measureRead { store, vaultID, access in
                let snapshot = try await store.snapshot(vaultID: vaultID, using: access)
                XCTAssertEqual(snapshot.accounts.count, Self.count)
            }
        }
    }

    /// What a password field's focus reads since D5(a): the same verified read, projected to candidates on the vault actor, so no
    /// account leaves it. The projection adds little to the read: plan D5 §2.9's P1 asks for at most 1.1 times the case above, which
    /// was measured by hand when the budgets were set. The budgets themselves are absolute and gate gross regressions only.
    func testListingAutofillCandidatesAmongTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            measureRead { store, vaultID, access in
                let candidates = try await store.autofillCandidates(vaultID: vaultID, using: access)
                XCTAssertEqual(candidates.candidates.count, Self.count)
            }
        }
    }

    /// The calendar date the projection case dates its cards by: mid-June 2030, before `SecureItemFixtures.card` ends (2031-07).
    static let projectionDate = Date(timeIntervalSince1970: 1_907_755_200)

    /// `storedAccounts()` with items: every tenth credential (from the fifth) also holds a card and a Wi-Fi network, and one card in
    /// ten has ended; every tenth credential (from the third) holds a contact, a name and an address.
    static func accountsWithItems() throws -> [CredentialAccount] {
        try storedAccounts().enumerated().map { index, stored in
            var account = stored
            switch index % 10 {
            case 5:
                var card = SecureItemFixtures.card()
                if index % 100 == 5 {
                    card.fields[3].value = "2020-01"
                }
                account.secureItems = [card, SecureItemFixtures.wifi()]
            case 3:
                account.secureItems = [SecureItemFixtures.name(), SecureItemFixtures.address()]
            default:
                break
            }
            return account
        }
    }

    /// The projection alone, without the read and with no I/O: what the vault actor makes of 20,000 decoded credentials for a
    /// password field (`autofillCandidates`: each credential and its items' facts, a digit filter and a card check per card), a card
    /// field (the card rows of `autofillItems`, through the store's own `cardRows`) and an address field (its contact rows,
    /// `contactRow`). The read cases above hold it only inside a read of about 0.6 s; here a slower projection shows on its own.
    func testProjectingTwentyThousandCredentialsForAutofill() throws {
        let accounts = try Self.accountsWithItems()
        let date = Self.projectionDate
        MainActor.assumeIsolated {
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: measuredOptions()) {
                let candidates = accounts.map(AutofillCandidate.init)
                let cards = accounts.flatMap { ProfileVaultStore.cardRows(of: $0, now: date).map(\.row) }
                let contacts = accounts.compactMap { ProfileVaultStore.contactRow(of: $0)?.row }
                XCTAssertEqual(candidates.count, Self.count)
                XCTAssertEqual(cards.count, 1_800)
                XCTAssertEqual(contacts.count, 2_000)
            }
        }
    }

    // MARK: Edits

    /// One changed password, written with the per-account write the import and the bulk actions use. The read that finds the
    /// account's stamp is the caller's and stays outside the measurement.
    func testEditingOneOfTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            measureWrite { fixture, manager, pass in
                let snapshot = try await manager.snapshot()
                var edited = try XCTUnwrap(snapshot.accounts.first)
                edited.password = "edited-\(pass)"
                let stamp = try XCTUnwrap(snapshot.stamps[edited.id])
                fixture.nextWrite = AccountWrite(accountID: edited.id, expected: .stamp(stamp), replacement: edited)
            } step: { fixture, manager in
                let write = try XCTUnwrap(fixture.nextWrite)
                _ = try await manager.commitAccounts([write], authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch))
            } check: { snapshot, last in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, "edited-\(last)")
            }
        }
    }

    /// The same edit through the whole-vault commit with no account named, the store's fallback: it compares each account with its
    /// stored row once. Every caller in the app names the accounts it edited (the tests below).
    func testSavingOneEditOfTwentyThousandCredentialsAsAWholeVault() {
        MainActor.assumeIsolated {
            measureWrite { fixture, manager, pass in
                let snapshot = try await manager.snapshot()
                var accounts = snapshot.accounts
                accounts[0].password = "edited-\(pass)"
                fixture.nextPayload = (accounts, snapshot.revision)
            } step: { fixture, manager in
                let payload = try XCTUnwrap(fixture.nextPayload)
                _ = try await manager.commit(
                    payload.accounts, expectedRevision: payload.revision, authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch)
                )
            } check: { snapshot, last in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, "edited-\(last)")
            }
        }
    }

    /// The credential editor's save (`CredentialSettingsModel.save`): it reads the vault, puts the edited account in and commits the
    /// whole vault naming that account, so one account is compared on its bytes and the other 19,999 by `==`.
    func testSavingOneEditInTheCredentialEditorAmongTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            measureWrite { fixture, manager, pass in
                if fixture.model == nil {
                    let profile = try XCTUnwrap(fixture.profile)
                    fixture.model = CredentialSettingsModel(profile: profile, exchange: fixture.coordinator, manager: manager)
                }
                let snapshot = try await manager.snapshot()
                var edited = try XCTUnwrap(snapshot.accounts.first)
                edited.password = "edited-\(pass)"
                fixture.nextPayload = ([edited], snapshot.revision)
            } step: { fixture, _ in
                let payload = try XCTUnwrap(fixture.nextPayload)
                let model = try XCTUnwrap(fixture.model)
                _ = try await model.save(try XCTUnwrap(payload.accounts.first), expectedRevision: payload.revision)
            } check: { snapshot, last in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, "edited-\(last)")
            }
        }
    }

    /// The autofill save of a new password for the credential it offered (`CredentialAccountSelection.commitSave`), naming it.
    func testSavingAnAutofilledPasswordAmongTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            measureWrite { fixture, manager, pass in
                let snapshot = try await manager.snapshot()
                let account = try XCTUnwrap(snapshot.accounts.first)
                let origin = try XCTUnwrap(account.origins.first)
                let login = try SavedPassword(website: origin, username: account.username, password: "autofilled-\(pass)")
                fixture.nextSave = (login, account.id, snapshot)
            } step: { fixture, manager in
                let save = try XCTUnwrap(fixture.nextSave)
                let outcome = try await CredentialAccountSelection.commitSave(
                    save.login, origin: save.login.origin, offered: .update(save.accountID), loginURL: nil, snapshot: save.snapshot,
                    manager: manager, epoch: try XCTUnwrap(manager.authorizationEpoch)
                )
                XCTAssertEqual(outcome, .saved)
            } check: { snapshot, last in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, "autofilled-\(last)")
            }
        }
    }

    /// A passkey sign-in's write (`WebsiteAuthenticatorCeremony` without the prompts around it): the signed passkey's
    /// `lastSignedAt` advances and the whole vault is committed naming its account.
    func testSigningInWithAPasskeyAmongTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            measureWrite { fixture, manager, pass in
                let snapshot = try await manager.snapshot()
                var accounts = snapshot.accounts
                let index = try XCTUnwrap(accounts.firstIndex { !$0.passkeys.isEmpty })
                accounts[index].passkeys[0].lastSignedAt = start.addingTimeInterval(Double(pass))
                fixture.nextPayload = (accounts, snapshot.revision)
            } step: { fixture, manager in
                let payload = try XCTUnwrap(fixture.nextPayload)
                let signed = try XCTUnwrap(payload.accounts.first { !$0.passkeys.isEmpty }).id
                _ = try await manager.commit(
                    payload.accounts, expectedRevision: payload.revision, authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch),
                    changing: [signed]
                )
            } check: { snapshot, last in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first { !$0.passkeys.isEmpty }?.passkeys.first?.lastSignedAt, start.addingTimeInterval(Double(last)))
            }
        }
    }

    // MARK: Undo and the Trash

    /// Undo of one edit (`CredentialManager.undo`): the account gets its earlier password back, bound to the stamp read after the edit.
    func testUndoingOneEditAmongTwentyThousandCredentials() {
        MainActor.assumeIsolated {
            measureWrite { fixture, manager, pass in
                let snapshot = try await manager.snapshot()
                var account = try XCTUnwrap(snapshot.accounts.first)
                account.password = "undone-\(pass)"
                let stamp = try XCTUnwrap(snapshot.stamps[account.id])
                fixture.nextWrite = AccountWrite(accountID: account.id, expected: .stamp(stamp), replacement: account)
            } step: { fixture, manager in
                let write = try XCTUnwrap(fixture.nextWrite)
                _ = try await manager.undo(
                    writes: [write], returning: [], removing: [:], authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch)
                )
            } check: { snapshot, last in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
                XCTAssertEqual(snapshot.accounts.first?.password, "undone-\(last)")
            }
        }
    }

    /// One deleted credential restored from the Trash (`CredentialManager.undelete`). The delete and the read of its Trash entry
    /// are the caller's and stay outside the measurement.
    func testRestoringOneOfTwentyThousandCredentialsFromTheTrash() {
        MainActor.assumeIsolated {
            measureWrite { fixture, manager, pass in
                let epoch = try XCTUnwrap(manager.authorizationEpoch)
                let snapshot = try await manager.snapshot()
                let id = fixture.accounts[pass].id
                let deleted = try await manager.delete(.account(id), expectedRevision: snapshot.revision, authorizedEpoch: epoch)
                let page = try await manager.trashPage(after: nil)
                let entry = try XCTUnwrap(page.items.first { $0.ownerID == id })
                fixture.nextEntry = (entry.id, deleted.revision)
            } step: { fixture, manager in
                let entry = try XCTUnwrap(fixture.nextEntry)
                _ = try await manager.undelete(
                    entryID: entry.id, expectedRevision: entry.revision, authorizedEpoch: try XCTUnwrap(manager.authorizationEpoch)
                )
            } check: { snapshot, _ in
                XCTAssertEqual(snapshot.accounts.count, Self.count)
            }
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
