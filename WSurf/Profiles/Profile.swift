// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import os
import WebKit
import WSurfCore

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
        if isPrivate {
            return URL(filePath: NSTemporaryDirectory())
                .appending(path: "WSurf-private", directoryHint: .isDirectory)
        }
        guard !isOriginal else { return AppDatabase.supportDirectory }
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
        supportDirectory.appendingPathComponent("SitePermissions.json")
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

    @MainActor
    static func erase(_ profile: Profile) async {
        guard !profile.isOriginal else { return }
        if !profile.isPrivate {
            // Revokes issued access and drains vault work before anything is deleted; never wipes the vault itself (the
            // support directory removal below does). First in this branch so no caller of `erase` can bypass it.
            CloudSync.shared?.vaults?.profileErased(profile.id)
            await CredentialManager.retire(profileID: profile.id)
            CloudTabs.shared?.forget(profileID: profile.id)
            try? await WKWebsiteDataStore.remove(forIdentifier: profile.id)
            try? await AutofillVaults.cards(for: profile.id).erase()
            try? await AutofillVaults.contacts(for: profile.id).erase()
            try? await AutofillVaults.legacyPasswords(for: profile.id).erase()
            await InputHistory.shared.erase(profile)
            _ = await Task.detached { try? AutofillSaveIndex.erase(profileID: profile.id) }.value
            do {
                try await ChromiumRuntime.shared.erase(profile: profile)
            } catch {
                Pipeline.log.error("profile: Chromium data erase failed")
            }
        }
        await ExtensionManager.eraseData(for: profile)
        try? FileManager.default.removeItem(at: profile.supportDirectory)
        try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        ProfileSettingsStore.forget(profile.id)
    }
}
