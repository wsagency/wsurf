// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// The credential editor's draft and what saving it leaves behind, through the settings model. Test-only in-memory unlock keys;
// no native ceremony and nothing here is evidence of Apple provider behavior.

@MainActor
struct CredentialEditorTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Editor", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.locked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        /// Unlocks the vault, stores `accounts` and loads them into the model.
        @MainActor func seed(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.unlock(vault)
            _ = try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
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

    private func account(notes: [String] = []) -> CredentialAccount {
        var result = VaultFixtures.account()
        result.notes = notes.isEmpty ? nil : notes.map { CredentialNote(text: $0, field: nil) }
        return result
    }

    // MARK: - Removing a note

    @Test func removingTheOnlyNoteSavesItAsAnEarlierVersion() async throws {
        let stored = account(notes: ["only note"])
        try await withFixture { f in
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            f.model.draft?.removeNote(at: 0)
            _ = try await f.model.commitDraft()

            let saved = try #require(try await f.vault.manager.snapshot().accounts.first)
            #expect(saved.notes == nil && saved.password == stored.password)
            let page = try await f.vault.manager.revisionPage(accountID: stored.id, after: nil)
            #expect(page.items.map(\.subject) == [.note])
            let counts = try await f.vault.manager.historyCounts()
            #expect(counts.live.revision == 1 && counts.trash.trashEntry == 0)
        }
    }

    @Test func removingOneOfSeveralNotesSavesTheOldListAsAVersion() async throws {
        let stored = account(notes: ["first", "second"])
        try await withFixture { f in
            try await f.seed([stored])
            try await f.model.beginEditing(accountID: stored.id)
            f.model.draft?.removeNote(at: 0)
            _ = try await f.model.commitDraft()

            let saved = try #require(try await f.vault.manager.snapshot().accounts.first)
            #expect(saved.notes?.map(\.text) == ["second"])
            let page = try await f.vault.manager.revisionPage(accountID: stored.id, after: nil)
            #expect(page.items.map(\.subject) == [.note])
            let counts = try await f.vault.manager.historyCounts()
            #expect(counts.live.revision == 1 && counts.trash.trashEntry == 0)
        }
    }
}
