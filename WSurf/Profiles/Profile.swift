// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import os
import WebKit
import WSurfCore
import WSurfVault

nonisolated struct Profile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var symbol: String
    var color: TabFolderColor

    static let originalID = UUID(uuidString: "0E000000-0000-4000-A000-000000000001")!
    static let privateID = UUID(uuidString: "0E000000-0000-4000-A000-000000000002")!

    var isOriginal: Bool {
        id == Self.originalID
    }

    var isPrivate: Bool {
        id == Self.privateID
    }

    static func original() -> Profile {
        Profile(
            id: originalID,
            name: String(localized: "Personal"),
            symbol: "person",
            color: .gray
        )
    }

    static func privateBrowsing() -> Profile {
        Profile(
            id: privateID,
            name: String(localized: "Private Browsing"),
            symbol: "plus.square.fill",
            color: .gray
        )
    }
}

// MARK: - Where a profile's things live

extension Profile {
    var supportDirectory: URL {
        Self.supportDirectory(for: id)
    }

    private static func supportDirectory(for id: UUID) -> URL {
        if id == privateID {
            return URL(filePath: NSTemporaryDirectory())
                .appending(path: "WSurf-private", directoryHint: .isDirectory)
        }
        guard id != originalID else { return AppDatabase.supportDirectory }
        return AppDatabase.supportDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var databaseURL: URL? {
        if isPrivate {
            return nil
        }
        return isOriginal ? AppDatabase.defaultURL : AppDatabase.url(forProfile: id)
    }

    @MainActor
    func makeDatabase() -> AppDatabase {
        if isPrivate {
            return .temporary()
        }
        guard let databaseURL, !isOriginal else { return .shared }
        guard AppDatabase.ownsSession else { return .temporary() }
        return AppDatabase(at: databaseURL)
    }

    var downloadsFile: URL {
        supportDirectory.appendingPathComponent("Downloads.json")
    }

    var zoomFile: URL {
        supportDirectory.appendingPathComponent("page-zoom.json")
    }

    var permissionsFile: URL {
        Self.permissionsFile(for: id)
    }

    static func permissionsFile(for id: UUID) -> URL {
        supportDirectory(for: id).appendingPathComponent("SitePermissions.json")
    }

    var autofillLastUsedFile: URL {
        supportDirectory.appendingPathComponent("AutofillLastUsed.json")
    }

    var spacesFile: URL {
        supportDirectory.appendingPathComponent("Spaces.json")
    }

    #if DEBUG
    /// Test hosts only: the WebKit store a throwaway profile uses instead of a persistent store of its own. WebKit's Networking
    /// process takes sandbox extensions for each persistent store it ever serves and never gives them back, and after about 180
    /// stores it can open no store's databases ("Unable to open database file on disk") until it restarts, which it does not
    /// while any store is alive. A helper that makes a profile per case shares one store through this.
    @MainActor static var dataStoreForTesting: [UUID: WKWebsiteDataStore] = [:]
    #endif

    @MainActor
    func makeDataStore() -> WKWebsiteDataStore {
        if isPrivate {
            return .nonPersistent()
        }
        #if DEBUG
        if StageMode.isActive, isOriginal {
            return StageMode.websiteDataStore()
        }
        if let store = Self.dataStoreForTesting[id] {
            return store
        }
        #endif
        return isOriginal ? .default() : WKWebsiteDataStore(forIdentifier: id)
    }

    struct VaultListUnavailable: LocalizedError {
        var errorDescription: String? {
            String(localized: "WSurf couldn’t read this profile’s vault list. Try deleting the profile again.")
        }
    }

    @MainActor
    func vaultRemovals(rechecking consent: Set<VaultProfileRemoval>? = nil) async throws -> Set<VaultProfileRemoval> {
        guard !isOriginal, !isPrivate, consent?.isEmpty != true else { return [] }
        do {
            let listing = try await CredentialManager.store(for: self).listing()
            let live = Set(listing.map(\.vaultID))
            let candidates = consent.map { live.intersection($0.map(\.vaultID)) } ?? live
            guard !candidates.isEmpty else { return [] }
            let approved = try VaultProfileRemoval.approved(in: supportDirectory, profileID: id, localVaults: candidates, requireEnrollmentFile: consent != nil)
            return consent?.intersection(approved) ?? approved
        } catch {
            throw VaultListUnavailable()
        }
    }

    @MainActor
    static func erase(_ profile: Profile) async {
        if !profile.isOriginal, !profile.isPrivate {
            CloudSync.shared?.vaults?.profileErased(profile.id)
        }
        do {
            try await eraseLocalData(profile)
        } catch {
            Pipeline.log.error("profile: local data erase failed")
        }
    }

    struct PendingWebsiteData: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            underlying.localizedDescription
        }
    }

    @MainActor
    static func eraseLocalData(_ profile: Profile) async throws {
        guard !profile.isOriginal else { return }
        var failure: Error?
        var websiteFailure: PendingWebsiteData?
        func attempt(_ erase: () async throws -> Void) async {
            do {
                try await erase()
            } catch {
                failure = failure ?? error
            }
        }
        if !profile.isPrivate {
            // Revokes issued access and drains vault work before anything is deleted; never wipes the vault itself (the
            // support directory removal below does). First in this branch so no caller of `erase` can bypass it.
            CloudSync.shared?.vaults?.forgetErasedProfile(profile.id)
            await CredentialManager.retire(profileID: profile.id)
            CloudTabs.shared?.forget(profileID: profile.id)
            // A launch replay can reach WebKit before the first browser window initializes its main run loop.
            _ = WKWebsiteDataStore.nonPersistent()
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: profile.id)
            } catch {
                if await WKWebsiteDataStore.allDataStoreIdentifiers.contains(profile.id) {
                    websiteFailure = PendingWebsiteData(underlying: error)
                }
            }
            await attempt { try await AutofillVaults.cards(for: profile.id).erase() }
            await attempt { try await AutofillVaults.contacts(for: profile.id).erase() }
            await attempt { try await AutofillVaults.legacyPasswords(for: profile.id).erase() }
            await attempt { try await InputHistory.shared.erase(profile) }
            await attempt { try await AutofillSaveIndex.erase(profileID: profile.id) }
            await attempt { try await ChromiumRuntime.shared.erase(profile: profile) }
        }
        await ExtensionManager.eraseData(for: profile)
        for directory in [profile.supportDirectory, FaviconLoader.cacheDirectory(for: profile)] {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch CocoaError.fileNoSuchFile {
                // A previous attempt may already have removed this directory.
            } catch {
                failure = failure ?? error
            }
        }
        ProfileSettingsStore.forget(profile.id)
        if let failure = failure ?? websiteFailure {
            throw failure
        }
    }
}
