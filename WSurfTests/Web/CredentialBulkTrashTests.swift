// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// Move to Trash from the list, for one credential or several: one write, no dialog, bound to what the page showed. Test-only
// in-memory unlock keys, a private pasteboard and synthetic credentials.

@MainActor
struct CredentialBulkTrashTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Bulk", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        @MainActor func seed(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
        }

        @MainActor func snapshot() async throws -> StoreSnapshot {
            try await vault.manager.snapshot()
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func account(_ username: String, on host: String) -> CredentialAccount {
        VaultFixtures.account(username: username, password: "pw-\(username)", origin: "https://\(host).example.test")
    }

    @Test func movingSeveralToTrashIsOneCommit() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b"), account("linus", on: "c")]
            try await f.seed(accounts)
            let before = try await f.snapshot().revision

            try await f.model.moveToTrash(ids: [accounts[0].id, accounts[2].id])

            let after = try await f.snapshot()
            #expect(after.revision == before + 1, "one commit for both")
            #expect(after.accounts.map(\.id) == [accounts[1].id])
            let trash = try await f.vault.manager.trashPage(after: nil).items
            #expect(Set(trash.map(\.ownerID)) == [accounts[0].id, accounts[2].id])
            #expect(trash.allSatisfy { $0.scope == .account })
            #expect(f.model.summaries.map(\.id) == [accounts[1].id], "the page shows the vault as it is now")
            #expect(f.model.notice?.text == String(localized: "Moved 2 credentials to Trash."))
        }
    }

    @Test func movingOneNamesTheCredentialCountInTheNotice() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            try await f.seed(accounts)

            try await f.model.moveToTrash(ids: [accounts[1].id])

            #expect(f.model.notice?.text == String(localized: "Moved 1 credential to Trash."))
            #expect(f.model.notice?.text.contains("grace") == false, "a notice never names what it moved")
        }
    }

    @Test func aChangedRowRefusesTheWholeMoveAndWritesNothing() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            try await f.seed(accounts)
            // Another window changes the second credential after this page showed it.
            var changed = try #require(try await f.snapshot().accounts.first { $0.id == accounts[1].id })
            changed.password = "changed-elsewhere"
            try await VaultManagerFixture.save([accounts[0], changed], in: f.vault)
            let revision = try await f.snapshot().revision

            await #expect(throws: CredentialVaultError.staleRevision) {
                try await f.model.moveToTrash(ids: [accounts[0].id, accounts[1].id])
            }

            let after = try await f.snapshot()
            #expect(after.revision == revision, "nothing was written, not even the credential that had not changed")
            #expect(Set(after.accounts.map(\.id)) == Set(accounts.map(\.id)))
            #expect(try await f.vault.manager.trashPage(after: nil).items.isEmpty)
            #expect(f.model.notice == nil)
        }
    }

    @Test func aMoveAfterALockIsRefused() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a")]
            try await f.seed(accounts)
            f.vault.manager.lock(reason: .manual)

            await #expect(throws: CredentialVaultError.unauthorized) {
                try await f.model.moveToTrash(ids: [accounts[0].id])
            }

            try await VaultManagerFixture.unlock(f.vault)
            #expect(try await f.snapshot().accounts.map(\.id) == [accounts[0].id])
            #expect(try await f.vault.manager.trashPage(after: nil).items.isEmpty)
        }
    }

    @Test func aCredentialTheListDoesNotHoldWritesNothing() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            try await f.seed(accounts)
            let revision = try await f.snapshot().revision

            await #expect(throws: CredentialVaultError.invalidData) {
                try await f.model.moveToTrash(ids: [accounts[0].id, UUID()])
            }

            #expect(try await f.snapshot().revision == revision)
            #expect(try await f.vault.manager.trashPage(after: nil).items.isEmpty)
        }
    }
}
