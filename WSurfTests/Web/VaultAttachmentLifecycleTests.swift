// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// Files kept with vault entries, through the store's own API: the schema raise (owner decision 8), the lifecycle of a file's reference
/// (History, Trash, undo, merge) and of its encrypted file (kept while any row names it, removed by a purge's sweep and by Delete Vault),
/// and the sweep of orphans. Synthetic text files only.
struct VaultAttachmentLifecycleTests {
    // MARK: - Helpers

    private func source(_ f: VaultStoreFixture, _ name: String) throws -> URL {
        let folder = f.directory.appending(path: "sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try Data("synthetic \(name) \(UUID().uuidString)".utf8).write(to: url)
        return url
    }

    private func setFiles(
        _ f: VaultStoreFixture, _ store: ProfileVaultStore, _ access: VaultAccess, owner: UUID, _ files: [CredentialAttachment]?
    ) async throws {
        try await f.edit(store, access) { accounts in
            accounts.map { account in
                var live = account
                if live.id == owner {
                    live.attachments = files
                }
                return live
            }
        }
    }

    /// Encrypts a new file and saves it with `owner`, after the files it already holds.
    @discardableResult
    private func attach(
        _ f: VaultStoreFixture, _ store: ProfileVaultStore, _ access: VaultAccess, _ name: String, to owner: UUID
    ) async throws -> CredentialAttachment {
        let file = try await store.addAttachment(vaultID: f.vaultID, from: try source(f, name), using: access)
        let current = try await live(store, access, f, owner).attachments ?? []
        try await setFiles(f, store, access, owner: owner, current + [file])
        return file
    }

    private func live(_ store: ProfileVaultStore, _ access: VaultAccess, _ f: VaultStoreFixture, _ id: UUID) async throws -> CredentialAccount {
        try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first { $0.id == id })
    }

    private func onDisk(_ f: VaultStoreFixture, vault: UUID? = nil) -> Set<UUID> {
        VaultBlob.contents(of: VaultBlob.folder(in: f.directory, vaultID: vault ?? f.vaultID)).stored
    }

    private func opened(
        _ store: ProfileVaultStore, _ access: VaultAccess, _ f: VaultStoreFixture, _ file: CredentialAttachment
    ) async throws -> String {
        let out = f.directory.appending(path: "out-\(UUID().uuidString)", directoryHint: .notDirectory)
        try await store.readAttachment(vaultID: f.vaultID, file, to: out, using: access)
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }

    /// The registry's schema and `store_meta`'s are both `expected`.
    private func expectSchema(_ f: VaultStoreFixture, _ expected: Int, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let registry = try f.storedRegistry().catalog.schema
        let meta = try f.read { try StoreTables.storeMeta($0) }?.schema
        #expect(registry == expected && meta == expected, comment, sourceLocation: sourceLocation)
    }

    /// Release 0.1.5 (`b2c2af97`, StoreRecords.swift `RegistryCatalog.decode`) refuses a registry whose first field is not 2, and every
    /// unlock and write of the store decodes the registry: it cannot open the store, so it cannot drop a file on its next edit.
    private func release015Accepts(_ catalog: Data) throws -> Bool {
        var reader = StoreReader(catalog)
        return try reader.u64() == 2
    }

    // MARK: - Schema (owner decision 8)

    @Test func theFirstSavedFileRaisesTheStoreSoAnOlderBuildRefusesIt() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try expectSchema(f, 2)
                try await f.edit(store, access) { accounts in
                    accounts.map { account in
                        var renamed = account
                        renamed.displayName = "Renamed"
                        return renamed
                    }
                }
                try expectSchema(f, 2, "an edit without files leaves the format alone")
                let file = try await store.addAttachment(vaultID: f.vaultID, from: try source(f, "scan.pdf"), using: access)
                try expectSchema(f, 2, "an encrypted file nothing refers to yet changes nothing")
                #expect(try release015Accepts(try f.storedRegistry().catalog.encode()))

                try await setFiles(f, store, access, owner: owner.id, [file])
                try expectSchema(f, 3)
                let stored = try #require(try f.read { try StoreTables.registry($0) })
                #expect(try !release015Accepts(stored.catalog))

                try await setFiles(f, store, access, owner: owner.id, nil)
                try expectSchema(f, 3, "the format is only ever raised")
            }
            try f.verify()
            // This build still opens it.
            let (store, access) = try await f.unlocked()
            let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
            #expect(snapshot.accounts.first?.displayName == "Renamed")
        }
    }

    @Test func aStoreFromANewerWSurfIsRefusedWithAClearMessage() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()]) { f in
            try f.mutate { try $0.execute(sql: "UPDATE store_meta SET schema = 4") }
            guard case .failClosed(let closed) = f.evaluate() else {
                Issue.record("a newer store must fail closed")
                return
            }
            #expect(closed.cause == .newerVersion)
            #expect(String(localized: closed.cause.explanation).contains("newer version of WSurf"))
            let store = f.makeStore()
            let access = f.beginAccess()
            await #expect(throws: CredentialStoreError.failClosed(closed)) {
                try await store.unlockInitialized(
                    vaultID: f.vaultID, credentialID: f.proof.credentialID, prf: f.proof.prf, access: access, verifying: nil, scratchWarning: nil
                )
            }

            // A registry that says more than this build knows never decodes, whatever store_meta says.
            var newer = try f.storedRegistry().catalog
            newer.schema = 4
            #expect(throws: CredentialStoreError.malformed) { _ = try RegistryCatalog.decode(newer.encode()) }
            newer.schema = StoreFormat.fileSchema
            #expect(try RegistryCatalog.decode(newer.encode()).schema == 3)
        }
    }

    // MARK: - Reading

    @Test func noFileIsReadUntilOneIsAskedFor() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            var file: CredentialAttachment?
            try await f.withWallStore { store, access in
                let added = try await attach(f, store, access, "passport.jpg", to: owner.id)
                #expect(try await opened(store, access, f, added).hasPrefix("synthetic passport.jpg"))
                file = added
            }
            let added = try #require(file)
            // With the encrypted file gone, unlocking and reading the vault still work: neither opens a file.
            #expect(VaultBlob.remove(added.id, in: VaultBlob.folder(in: f.directory, vaultID: f.vaultID)))
            let (store, access) = try await f.unlocked()
            #expect(try await live(store, access, f, owner.id).attachments == [added])
            #expect(!store.hasBlob(added, vaultID: f.vaultID))
            await #expect(throws: VaultFileError.missing) { _ = try await opened(store, access, f, added) }
        }
    }

    @Test func aLockedVaultDecryptsNothing() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                let file = try await attach(f, store, access, "scan.pdf", to: owner.id)
                await store.lock(vaultID: f.vaultID)
                let out = f.directory.appending(path: "after-lock")
                await #expect(throws: CredentialVaultError.unauthorized) {
                    try await store.readAttachment(vaultID: f.vaultID, file, to: out, using: access)
                }
                #expect(!StoreAnchors.exists(out))
                await #expect(throws: CredentialVaultError.unauthorized) {
                    _ = try await store.addAttachment(vaultID: f.vaultID, from: try source(f, "late.pdf"), using: access)
                }
            }
        }
    }

    // MARK: - History, Trash and undo keep the reference

    @Test func historyKeepsARemovedFileAndRestoresIt() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                let file = try await attach(f, store, access, "deed.pdf", to: owner.id)
                try await setFiles(f, store, access, owner: owner.id, nil)
                #expect(try await live(store, access, f, owner.id).attachments == nil)

                let revision = try #require(try f.sourceRevisions(of: owner.id).first { $0.subject == .attachment })
                #expect(RecordSubject.attachment.restoresFromEarlierVersions)
                #expect(onDisk(f) == [file.id], "the earlier version still names it")
                #expect(try await store.sweepAttachments(vaultID: f.vaultID, using: access) == 0)

                let preview = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: revision.recordID, using: access)
                #expect(preview.attachments == [file])
                _ = try await store.restoreRevision(
                    vaultID: f.vaultID, revisionID: revision.recordID, expectedRevision: try await f.nextRevision(store, access), using: access
                )
                #expect(try await live(store, access, f, owner.id).attachments == [file])
                #expect(try await opened(store, access, f, file).hasPrefix("synthetic deed.pdf"))
            }
            try f.verify()
        }
    }

    @Test func theTrashKeepsTheFilesAndARestoreBringsThemBack() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                let file = try await attach(f, store, access, "x-ray.png", to: owner.id)
                try await f.deleteAccount(store, access, owner.id)
                #expect(try f.trashEntry(of: owner.id).body.snapshot?.attachments == [file])
                #expect(try await store.sweepAttachments(vaultID: f.vaultID, using: access) == 0)
                #expect(onDisk(f) == [file.id])

                try await f.undelete(store, access, try f.trashEntry(of: owner.id).row.recordID)
                #expect(try await live(store, access, f, owner.id).attachments == [file])
                #expect(try await opened(store, access, f, file).hasPrefix("synthetic x-ray.png"))
            }
            try f.verify()
        }
    }

    @Test func undoPutsTheFileBack() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                let file = try await attach(f, store, access, "contract.pdf", to: owner.id)
                let before = try await live(store, access, f, owner.id)
                try await setFiles(f, store, access, owner: owner.id, nil)
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                let stamp = try #require(snapshot.stamps[owner.id])

                _ = try await store.undo(
                    vaultID: f.vaultID, writes: [AccountWrite(accountID: owner.id, expected: .stamp(stamp), replacement: before)], returning: [],
                    removing: [:], using: access
                )
                #expect(try await live(store, access, f, owner.id).attachments == [file])
                #expect(try await opened(store, access, f, file).hasPrefix("synthetic contract.pdf"))
            }
            try f.verify()
        }
    }

    @Test func aMergeCarriesTheFilesToThePrimary() async throws {
        let primary = VaultFixtures.account(username: "ada", password: "one")
        let other = VaultFixtures.account(username: "ada", password: "two", origin: "https://other.example")
        try await VaultStoreFixture.with(accounts: [primary, other]) { f in
            try await f.withWallStore { store, access in
                let first = try await attach(f, store, access, "first.pdf", to: primary.id)
                let second = try await attach(f, store, access, "second.pdf", to: other.id)
                let snapshot = try await store.snapshot(vaultID: f.vaultID, using: access)
                let accounts = snapshot.accounts
                let picks = try #require(CredentialMerge.defaultPicks(for: accounts, survivor: primary.id))
                let merged = try CredentialMerge.merged(accounts, picks: picks)
                _ = try await store.commit(
                    vaultID: f.vaultID, [merged], expectedRevision: snapshot.revision, cause: "merge", changing: [primary.id],
                    merging: [other.id: primary.id], using: access
                )
                #expect(try await live(store, access, f, primary.id).attachments?.map(\.id) == [first.id, second.id])

                // Emptying the Trash removes the merged-away entry; its file stays, because the primary names it.
                _ = try await store.purge(vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access)
                #expect(onDisk(f) == [first.id, second.id])
                #expect(try await opened(store, access, f, second).hasPrefix("synthetic second.pdf"))
            }
            try f.verify()
        }
    }

    // MARK: - Removal

    @Test func aPurgeRemovesExactlyTheFilesNothingElseNames() async throws {
        let gone = VaultFixtures.account(username: "gone")
        let kept = VaultFixtures.account(username: "kept", origin: "https://kept.example")
        try await VaultStoreFixture.with(accounts: [gone, kept]) { f in
            try await f.withWallStore { store, access in
                let purged = try await attach(f, store, access, "purged.pdf", to: gone.id)
                let current = try await attach(f, store, access, "current.pdf", to: kept.id)
                let earlier = try await attach(f, store, access, "earlier.pdf", to: kept.id)
                try await setFiles(f, store, access, owner: kept.id, [current])  // `earlier` is only in History now
                let unsaved = try await store.addAttachment(vaultID: f.vaultID, from: try source(f, "unsaved.pdf"), using: access)

                // What a crash leaves: a half-written file, and a finished one whose commit never happened (another run's).
                let folder = VaultBlob.folder(in: f.directory, vaultID: f.vaultID)
                let crashed = UUID()
                try Data("partial".utf8).write(to: VaultBlob.partial(UUID(), in: folder))
                try Data("orphan".utf8).write(to: VaultBlob.file(crashed, in: folder))

                try await f.deleteAccount(store, access, gone.id)
                #expect(onDisk(f) == [purged.id, current.id, earlier.id, unsaved.id, crashed])
                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [try f.trashEntry(of: gone.id).row.recordID], emptyAll: false,
                    authorization: f.freshAuthorization, using: access
                )
                receipt.expectRemoved(1)
                #expect(onDisk(f) == [current.id, earlier.id, unsaved.id], "the purged entry's file and the orphan go; the unsaved one waits")
                #expect(VaultBlob.contents(of: folder).partial.isEmpty)

                // The editor that added `unsaved` closes without saving: now it goes.
                #expect(try await store.sweepAttachments(vaultID: f.vaultID, only: [unsaved.id, current.id], using: access) == 1)
                #expect(onDisk(f) == [current.id, earlier.id])
                #expect(try await opened(store, access, f, earlier).hasPrefix("synthetic earlier.pdf"))
            }
            try f.verify()
        }
    }

    @Test func deleteVaultRemovesTheVaultsFilesOnly() async throws {
        let owner = VaultFixtures.account()
        try await VaultStoreFixture.with(accounts: [owner], secondVault: true) { f in
            let secondID = try #require(f.secondVaultID)
            let bystander = VaultBlob.file(UUID(), in: VaultBlob.folder(in: f.directory, vaultID: secondID))
            try FileManager.default.createDirectory(at: bystander.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("other vault".utf8).write(to: bystander)
            try await f.withWallStore { store, access in
                let file = try await attach(f, store, access, "scan.pdf", to: owner.id)
                try await f.deleteAccount(store, access, owner.id)  // in the Trash too: the Trash shares the folder
                #expect(onDisk(f) == [file.id])
                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
                #expect(!StoreAnchors.exists(VaultBlob.folder(in: f.directory, vaultID: f.vaultID)))
                #expect(StoreAnchors.exists(bystander))
            }
        }
    }
}
