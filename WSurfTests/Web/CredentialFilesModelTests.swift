// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

/// The editor's Files section through the page model: add, save, preview, Save Copy…, remove, History and Cancel, on a real vault of a
/// fresh profile. Synthetic text files; decrypted copies go to a folder of the test's own.
@MainActor
struct CredentialFilesModelTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        let sources: URL
        let previews: VaultFilePreviewFolder
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Files", symbol: "doc", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager, verifyUser: { _ in })
            sources = FileManager.default.temporaryDirectory.appending(path: "files-model-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            previews = VaultFilePreviewFolder(root: sources.appending(path: "previews", directoryHint: .isDirectory), run: UUID())
            model.previewFolder = previews
            await model.load()
        }

        func source(_ name: String) throws -> URL {
            let url = sources.appending(path: name, directoryHint: .notDirectory)
            try Data("synthetic \(name)".utf8).write(to: url)
            return url
        }

        /// The encrypted files in the vault's folder.
        var blobs: Set<UUID> {
            VaultBlob.contents(of: VaultBlob.folder(in: profile.supportDirectory, vaultID: vault.vaultID)).stored
        }

        @MainActor func stored(_ id: UUID) async throws -> CredentialAccount {
            try #require(try await vault.manager.snapshot().accounts.first { $0.id == id })
        }

        /// A new entry named `name` holding the files `names` (and `note`, when given), saved.
        @MainActor func saveEntry(_ name: String, files names: [String], note: String? = nil) async throws -> UUID {
            try await model.beginEditing(accountID: nil)
            model.draft?.displayName = name
            if let note {
                model.draft?.notes = [CredentialNote(text: note, field: nil)]
            }
            try await model.addFiles(try names.map(source))
            _ = try await model.commitDraft()
            return try #require(model.summaries.first { $0.displayName == name }).id
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: sources)
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    /// End to end: an entry that holds only a name and a file saves, stores the record (schema 3), and reads the file back. Removing
    /// that only file would leave an entry with nothing to keep, which `CredentialAccount.validate()` refuses like any other empty entry:
    /// the save fails before anything is written, the draft stays open, and the stored entry and its file are unchanged.
    @Test func anEntryHoldingOnlyAFileSavesAndKeepsItsLastFile() async throws {
        try await withFixture { f in
            let id = try await f.saveEntry("Synthetic scan", files: ["scan.pdf"])
            let saved = try await f.stored(id)
            let file = try #require(saved.attachments?.first)
            #expect(saved.attachments?.count == 1 && file.name == "scan.pdf" && file.size == Int64("synthetic scan.pdf".utf8.count))
            #expect(saved.username.isEmpty && saved.password == nil && saved.notes == nil && saved.secureItems == nil)
            #expect(f.blobs == [file.id])
            #expect(try Data(contentsOf: try await f.model.temporaryCopy(of: file)) == Data("synthetic scan.pdf".utf8))

            try await f.model.beginEditing(accountID: id)
            f.model.removeFile(file.id)
            await #expect(throws: CredentialVaultError.invalidData) {
                _ = try await f.model.commitDraft()
            }
            #expect(f.model.draft?.attachments.isEmpty == true, "the editor stays open with the change")
            #expect(try await f.stored(id).attachments == [file])
            f.model.cancelEditing()
            await f.model.fileDiscard?.value
            #expect(f.blobs == [file.id], "Cancel removes only files this editor added")
        }
    }

    @Test func aFileIsAddedSavedPreviewedCopiedRemovedAndBroughtBackFromHistory() async throws {
        try await withFixture { f in
            // A note too, so the entry still holds something once its file is removed.
            let id = try await f.saveEntry("Synthetic deed", files: ["deed.pdf"], note: "Synthetic land registry number")
            let saved = try await f.stored(id)
            let file = try #require(saved.attachments?.first)
            #expect(saved.attachments?.count == 1 && file.name == "deed.pdf" && saved.username.isEmpty)
            #expect(f.blobs == [file.id])
            let summary = try #require(f.model.summaries.first { $0.id == id })
            #expect(summary.fileCount == 1 && summary.fileBytes == file.size)
            #expect(CredentialListFilter.visible(f.model.summaries, query: "", filter: .files).map(\.id) == [id])
            #expect(CredentialListFilter.chips(counts: CredentialListFilter.counts(f.model.summaries), selected: .all).contains(.files))
            #expect(f.model.fileUsage.count == 1 && f.model.fileUsage.bytes == file.size)

            // Preview: a decrypted copy in this run's private folder, removed when Quick Look closes.
            let copy = try await f.model.temporaryCopy(of: file)
            #expect(copy.path.hasPrefix(f.previews.runFolder.path))
            #expect(try Data(contentsOf: copy) == Data("synthetic deed.pdf".utf8))
            f.previews.remove(copy)
            #expect(!StoreAnchors.exists(copy))

            // Save Copy…: decrypted where the person chose.
            let chosen = f.sources.appending(path: "Saved deed.pdf")
            try await f.model.saveFileCopy(file, to: chosen)
            #expect(try Data(contentsOf: chosen) == Data("synthetic deed.pdf".utf8))
            #expect(f.model.notice?.text == String(localized: "File Saved"))

            // Removed by an edit: the entry no longer holds it, its earlier version does, and the encrypted file stays.
            try await f.model.beginEditing(accountID: id)
            #expect(f.model.draft?.attachments == [file])
            f.model.removeFile(file.id)
            _ = try await f.model.commitDraft()
            #expect(try await f.stored(id).attachments == nil)
            #expect(f.blobs == [file.id])

            // History shows it and puts it back.
            try await f.model.beginEditing(accountID: id)
            try await f.model.openHistory(accountID: id)
            let earlier = try #require(f.model.history?.versions.first { !$0.isCurrent })
            #expect(earlier.account.attachments == [file] && earlier.changed.contains(.attachment))
            f.model.copyToDraft(.files, from: earlier.id)
            #expect(f.model.draft?.attachments == [file])
            _ = try await f.model.commitDraft()
            #expect(try await f.stored(id).attachments == [file])
            let again = try await f.model.temporaryCopy(of: file)
            #expect(try Data(contentsOf: again) == Data("synthetic deed.pdf".utf8))
        }
    }

    @Test func cancellingRemovesOnlyTheFilesTheEditorAdded() async throws {
        try await withFixture { f in
            let id = try await f.saveEntry("Synthetic folder", files: ["kept.pdf"])
            let kept = try #require(try await f.stored(id).attachments?.first)

            // Added, then Cancel: that file goes, the saved one stays.
            try await f.model.beginEditing(accountID: id)
            try await f.model.addFiles([try f.source("cancelled.pdf")])
            #expect(f.blobs.count == 2)
            f.model.cancelEditing()
            await f.model.fileDiscard?.value
            #expect(f.blobs == [kept.id])

            // Added and removed again before Save: nothing to save, and the file goes.
            try await f.model.beginEditing(accountID: id)
            try await f.model.addFiles([try f.source("dropped.pdf")])
            let dropped = try #require(f.model.draft?.attachments.last)
            f.model.removeFile(dropped.id)
            #expect(f.model.draft?.changesNothing == true)
            _ = try await f.model.commitDraft()
            await f.model.fileDiscard?.value
            #expect(f.blobs == [kept.id])

            // Two added, one removed, saved: the saved one stays, the other goes.
            try await f.model.beginEditing(accountID: id)
            try await f.model.addFiles([try f.source("left-out.pdf"), try f.source("added.pdf")])
            let files = try #require(f.model.draft?.attachments)
            f.model.removeFile(files[1].id)
            _ = try await f.model.commitDraft()
            await f.model.fileDiscard?.value
            #expect(try await f.stored(id).attachments?.map(\.id) == [kept.id, files[2].id])
            #expect(f.blobs == [kept.id, files[2].id])
        }
    }

    /// Owner decision 4: an export to another app carries no file; the sheet counts the files that stay.
    @Test func anExportCarriesNoFile() async throws {
        try await withFixture { f in
            try await f.model.beginEditing(accountID: nil)
            f.model.draft?.username = "ada"
            f.model.draft?.password = "synthetic-password"
            f.model.draft?.displayName = "Synthetic login"
            try await f.model.addFiles([try f.source("secret-scan-name.pdf")])
            _ = try await f.model.commitDraft()
            let snapshot = try await f.vault.manager.snapshot()
            let account = try #require(snapshot.accounts.first)
            #expect(account.attachments?.count == 1)

            let selection = CredentialExportSelection(accountID: account.id, password: true, passkeyIDs: [], totp: false)
            let exported = try CredentialExchangeCodec.export(snapshot, selection: [selection], format: .v1)
            #expect(exported.accounts.flatMap(\.items).flatMap(\.credentials).count == 1, "the login only")
            #expect(!String(describing: exported).contains("secret-scan-name"))
            #expect(CredentialExportSelection.fileCount([account.id: selection], in: f.model.summaries) == 1)
        }
    }
}
