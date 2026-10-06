// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation

private struct ChromiumOriginCatalog: Codable {
    var origins: [String: Date] = [:]
}

private nonisolated final class ChromiumCompletion {
    let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func pointer() -> UnsafeMutablePointer<cef_completion_callback_t> {
        let callback = ChromiumInterop.allocate(cef_completion_callback_t.self, owner: self)
        callback.pointee.on_complete = { callbackSelf in
            guard let callbackSelf,
                  let owner = ChromiumInterop.owner(
                    ChromiumCompletion.self,
                    of: UnsafeMutableRawPointer(callbackSelf)
                  ) else { return }
            owner.continuation.resume()
        }
        return callback
    }
}

private nonisolated final class ChromiumDeleteCookiesCompletion {
    let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func pointer() -> UnsafeMutablePointer<cef_delete_cookies_callback_t> {
        let callback = ChromiumInterop.allocate(cef_delete_cookies_callback_t.self, owner: self)
        callback.pointee.on_complete = { callbackSelf, _ in
            guard let callbackSelf,
                  let owner = ChromiumInterop.owner(
                    ChromiumDeleteCookiesCompletion.self,
                    of: UnsafeMutableRawPointer(callbackSelf)
                  ) else { return }
            owner.continuation.resume()
        }
        return callback
    }
}

extension ChromiumRuntime {
    private func originCatalog(for profile: Profile) -> ChromiumOriginCatalog {
        if profile.isPrivate {
            return ChromiumOriginCatalog(origins: privateOrigins)
        }
        let url = cacheDirectory(profileID: profile.id).appendingPathComponent("origins.json")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ChromiumOriginCatalog.self, from: data) else {
            return ChromiumOriginCatalog()
        }
        return catalog
    }

    private func saveOriginCatalog(_ catalog: ChromiumOriginCatalog, for profile: Profile) {
        if profile.isPrivate {
            privateOrigins = catalog.origins
            return
        }
        let directory = cacheDirectory(profileID: profile.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: directory.appendingPathComponent("origins.json"), options: .atomic)
    }

    private func hasStoredData(for profile: Profile) -> Bool {
        if profile.isPrivate {
            return hasPrivateContext || !privateOrigins.isEmpty
        }
        let directory = cacheDirectory(profileID: profile.id)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return !originCatalog(for: profile).origins.isEmpty
            || files.contains { $0.lastPathComponent != "origins.json" }
    }

    func preflightClearData(
        profile: Profile,
        kinds: Set<BrowsingData.Kind>,
        since: Date
    ) throws {
        guard hasStoredData(for: profile) else { return }
        guard (kinds.contains(.cookies) || kinds.contains(.cache))
                && since > Date(timeIntervalSince1970: 0) else { return }
        throw ChromiumError.unavailable(
            String(localized: "Chromium can clear website data only for all time.")
        )
    }

    /// Records only navigated HTTP(S) origins. Private contexts stay in memory
    /// and are discarded with the private session.
    func recordOrigin(_ url: URL, profileID: UUID, isPrivate: Bool) {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        let profile = Profile(
            id: profileID,
            name: profileID.uuidString,
            symbol: "person",
            color: .gray
        )
        var catalog = originCatalog(for: profile)
        catalog.origins[url.originString] = Date()
        saveOriginCatalog(catalog, for: profile)
    }

    func erase(profile: Profile) async throws {
        guard !profile.isOriginal else { return }
        await releaseContext(profileID: profile.id)
        try FileManager.default.removeItem(at: cacheDirectory(profileID: profile.id))
    }

    func clearData(profile: Profile, kinds: Set<BrowsingData.Kind>, since: Date) async throws {
        try preflightClearData(profile: profile, kinds: kinds, since: since)
        guard hasStoredData(for: profile) else { return }
        guard kinds.contains(.cache) || kinds.contains(.cookies) else { return }

        if kinds.contains(.cookies) {
            try await clearCookies(profile: profile)
        }
        let originalCatalog = originCatalog(for: profile)
        let origins = originalCatalog.origins.keys.sorted()
        if kinds.contains(.cache) {
            _ = try await command(profile: profile, method: "Network.clearBrowserCache")
        }
        let storageTypes: String = {
            switch (kinds.contains(.cookies), kinds.contains(.cache)) {
            case (true, true):
                return "cookies,local_storage,session_storage,indexeddb,websql,service_workers,file_systems,storage_buckets,cache_storage,shader_cache"
            case (true, false):
                return "cookies,local_storage,session_storage,indexeddb,websql,service_workers,file_systems,storage_buckets"
            default:
                return "cache_storage,shader_cache"
            }
        }()
        for origin in origins {
            _ = try await command(
                profile: profile,
                method: "Storage.clearDataForOrigin",
                params: ["origin": origin, "storageTypes": storageTypes]
            )
        }
        if kinds.contains(.cookies), kinds.contains(.cache) {
            var catalog = originCatalog(for: profile)
            for origin in origins where catalog.origins[origin] == originalCatalog.origins[origin] {
                catalog.origins[origin] = nil
            }
            saveOriginCatalog(catalog, for: profile)
        }

    }

    func websiteDataEntries(profile: Profile) async throws -> [WebsiteData.Entry] {
        guard hasStoredData(for: profile) else { return [] }
        let catalog = originCatalog(for: profile)
        var entries: [WebsiteData.Entry] = []
        for origin in catalog.origins.keys.sorted() {
            _ = try await command(
                profile: profile,
                method: "Storage.getUsageAndQuota",
                params: ["origin": origin]
            )
            entries.append(.init(displayName: origin, types: WebsiteData.allTypes, engine: .chromium))
        }
        return entries
    }

    func removeWebsiteData(names: Set<String>, profile: Profile) async throws {
        guard !names.isEmpty, hasStoredData(for: profile) else { return }
        for origin in names {
            guard let scheme = URL(string: origin)?.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { continue }
            _ = try await command(
                profile: profile,
                method: "Storage.clearDataForOrigin",
                params: [
                    "origin": origin,
                    "storageTypes": "cookies,local_storage,session_storage,indexeddb,websql,service_workers,file_systems,storage_buckets,cache_storage,shader_cache",
                ]
            )
        }
        var catalog = originCatalog(for: profile)
        for name in names {
            catalog.origins[name] = nil
        }
        saveOriginCatalog(catalog, for: profile)
    }

    private func clearCookies(profile: Profile) async throws {
        let manager = try withContext(for: profile) { context -> UnsafeMutablePointer<cef_cookie_manager_t> in
            guard let manager = context.pointee.get_cookie_manager?(context, nil) else {
                throw ChromiumError.unavailable(String(localized: "Chromium cookies are unavailable."))
            }
            return manager
        }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(manager)) }
        guard let deleteCookies = manager.pointee.delete_cookies,
              let flushStore = manager.pointee.flush_store else {
            throw ChromiumError.unavailable(String(localized: "Chromium cookies are unavailable."))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let callbackOwner = ChromiumDeleteCookiesCompletion(continuation)
            let callback = callbackOwner.pointer()
            let accepted = deleteCookies(manager, nil, nil, callback)
            if accepted == 0 {
                continuation.resume(throwing: ChromiumError.unavailable(String(localized: "Chromium cookies could not be cleared.")))
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let callbackOwner = ChromiumCompletion(continuation)
            let callback = callbackOwner.pointer()
            let accepted = flushStore(manager, callback)
            if accepted == 0 {
                continuation.resume(throwing: ChromiumError.unavailable(String(localized: "Chromium cookies could not be saved.")))
            }
        }
    }
}

private extension URL {
    var originString: String {
        guard let scheme, let host else { return absoluteString }
        let port = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
