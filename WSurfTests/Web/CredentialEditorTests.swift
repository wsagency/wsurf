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

    // MARK: - Leaving the editor

    @Test func cancelAsksOnlyWhenTheDraftChanged() {
        let stored = account(notes: ["kept"])
        var draft = CredentialDraft(editing: stored, revision: 1)
        #expect(!draft.hasUnsavedChanges)

        draft.displayName = "Renamed"
        #expect(draft.hasUnsavedChanges)
        draft.displayName = stored.displayName
        #expect(!draft.hasUnsavedChanges, "putting a value back is no change")

        draft.notes[0].text = "edited"
        #expect(draft.hasUnsavedChanges)
        draft.notes[0].text = "kept"
        draft.websites = "http://insecure.test"
        #expect(draft.hasUnsavedChanges, "an entry that can’t be saved is still unsaved work")
    }

    @Test func aNewDraftAsksOnlyOnceSomethingIsEntered() throws {
        var draft = CredentialDraft(editing: nil, revision: 0)
        #expect(!draft.hasUnsavedChanges)
        draft.addNote()
        draft.websites = " \n "
        #expect(!draft.hasUnsavedChanges, "an empty note and blank lines hold nothing")

        draft.notes[0].text = "typed"
        #expect(draft.hasUnsavedChanges)
        draft.notes[0].text = ""
        draft.password = "typed-password"
        #expect(draft.hasUnsavedChanges)
        draft.password = nil
        try draft.setUpTOTP("JBSWY3DPEHPK3PXP")
        #expect(draft.hasUnsavedChanges)
    }

    @Test func passkeyRemovalTextNamesTheSiteAndAccount() throws {
        let first = PasskeySummary(try VaultFixtures.passkey(rpID: "example.test"))
        let message = first.removalMessage
        #expect(message.contains("example.test") && message.contains("ada") && message.contains("Trash"))
        #expect(!message.contains(first.id.uuidString), "the id is for the system, not for the reader")

        // VoiceOver hears the id only when another passkey of the same site and account would sound identical.
        let other = PasskeySummary(try VaultFixtures.passkey(rpID: "other.test", credentialID: Data(repeating: 2, count: 32)))
        #expect(!first.removeLabel(among: [first, other]).contains(first.id.uuidString))
        let twin = PasskeySummary(try VaultFixtures.passkey(rpID: "example.test", credentialID: Data(repeating: 3, count: 32)))
        #expect(first.removeLabel(among: [first, twin]).contains(first.id.uuidString))
        #expect(twin.removeLabel(among: [first, twin]).contains(twin.id.uuidString))
    }

    // MARK: - Dates

    private func when(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    @Test func theEditorShowsAddedAndUpdatedDates() {
        let first = VaultFixtures.reference(800_000_000)
        let later = VaultFixtures.reference(800_100_000)
        var stored = VaultFixtures.account().stampingCreation(at: first)
        stored.modifiedAt = later

        let expected = [String(localized: "Created \(when(first))"), String(localized: "Updated \(when(later))")]
        #expect(CredentialDraft(editing: stored, revision: 1).dateLines == [expected.joined(separator: " · ")])

        // A new credential has no dates yet, and a date the vault never recorded stays unknown.
        #expect(CredentialDraft(editing: nil, revision: 0).dateLines.isEmpty)
        #expect(CredentialDraft(editing: VaultFixtures.account(), revision: 1).dateLines.isEmpty)
    }

    @Test func anImportedCredentialShowsTheReportedDateLabelled() throws {
        let importedAt = VaultFixtures.reference(800_000_000)
        let reported = VaultFixtures.reference(1_000)
        var stored = VaultFixtures.account()
        stored.exchangeMetadata = try VaultFixtures.sortedJSON(VaultFixtures.exchangeMetadata())
        stored.passwordEvents = CredentialEvents(lastImportedAt: importedAt)

        let draft = CredentialDraft(editing: stored, revision: 1)
        #expect(draft.reportedCreatedAt == reported)
        #expect(draft.dateLines == [
            String(localized: "Imported \(when(importedAt))"),
            String(localized: "Reported by the other app: created \(when(reported))"),
        ])

        // Metadata that does not decode shows no reported date and never blocks the draft.
        stored.exchangeMetadata = Data("not metadata".utf8)
        let undecodable = CredentialDraft(editing: stored, revision: 1)
        #expect(undecodable.reportedCreatedAt == nil)
        #expect(undecodable.dateLines == [String(localized: "Imported \(when(importedAt))")])
    }
}
