// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation
import WSurfVault

private struct ChromiumOriginCatalog: Codable {
    var origins: [String: Date] = [:]
    /// The top-level sites each origin was loaded under as a cross-site frame. Chromium keeps such a frame's storage under
    /// that site, where clearing the origin does not reach. Absent in files from before 0.1.16.
    var frames: [String: Set<String>]?
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
    private func originCatalog(for context: BrowserProfileContext) -> ChromiumOriginCatalog {
        if context.profile.isPrivate {
            return ChromiumOriginCatalog(origins: privateOrigins[context.contextID] ?? [:])
        }
        let url = catalogDirectory(profileID: context.profile.id).appendingPathComponent("origins.json")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ChromiumOriginCatalog.self, from: data) else {
            return ChromiumOriginCatalog()
        }
        return catalog
    }

    private func saveOriginCatalog(_ catalog: ChromiumOriginCatalog, for context: BrowserProfileContext) {
        guard !context.privateSessionEnded else { return }
        if context.profile.isPrivate {
            privateOrigins[context.contextID] = catalog.origins
            return
        }
        let directory = catalogDirectory(profileID: context.profile.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: directory.appendingPathComponent("origins.json"), options: .atomic)
    }

    /// Whether this profile has a site that Chromium recorded data for. Chromium's own files in a regular profile's
    /// directory are not site data and do not count.
    private func hasStoredData(for context: BrowserProfileContext) -> Bool {
        if context.profile.isPrivate {
            return hasContext(contextID: context.contextID) || privateOrigins[context.contextID]?.isEmpty == false
        }
        return !originCatalog(for: context).origins.isEmpty
    }

    func preflightClearData(
        context: BrowserProfileContext,
        kinds: Set<BrowsingData.Kind>,
        since: Date
    ) throws {
        guard hasStoredData(for: context) else { return }
        guard (kinds.contains(.cookies) || kinds.contains(.cache))
                && since > Date(timeIntervalSince1970: 0) else { return }
        throw ChromiumError.unavailable(
            String(localized: "Chromium can clear website data only for all time.")
        )
    }

    /// Records only navigated HTTP(S) origins, and for a frame the top-level site its storage is kept under (`topLevel` is
    /// the page's address). Private contexts stay in memory and are discarded with the private session.
    func recordOrigin(_ url: URL, under topLevel: URL? = nil, context: BrowserProfileContext) {
        guard !context.privateSessionEnded, ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        var catalog = originCatalog(for: context)
        catalog.origins[url.originString] = Date()
        if let site = topLevel.flatMap(Self.partitionSite), site != Self.partitionSite(of: url) {
            var frames = catalog.frames ?? [:]
            frames[url.originString, default: []].insert(site)
            catalog.frames = frames
        }
        saveOriginCatalog(catalog, for: context)
    }

    /// The site Chromium partitions a cross-site frame's storage by: scheme and registrable domain (else host), no port.
    private static func partitionSite(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        return "\(scheme)://\(RelyingPartyPolicy.registrableDomain(of: host) ?? host)"
    }

    /// Chromium's storage keys (`<origin>/^0<top-level site>`) of the recorded cross-site frames that `include` picks by
    /// frame origin and top-level site.
    private func frameStorageKeys(in catalog: ChromiumOriginCatalog, where include: (String, String) -> Bool) -> [String] {
        (catalog.frames ?? [:]).sorted { $0.key < $1.key }.flatMap { origin, sites in
            sites.sorted().filter { include(origin, $0) }.map { "\(origin)/^0\($0)" }
        }
    }

    func erase(profile: Profile) async throws {
        guard !profile.isOriginal, !profile.isPrivate else { return }
        await releaseContexts(profileID: profile.id)
        // Chromium writes some of a profile's files (TransportSecurity, Network Persistent State) back while it lets the
        // profile go, after its last context is gone, so the profile stays marked and `removeErasedProfiles` takes what is
        // left once CEF has stopped: at quit, or at the next launch after a crash.
        try FileManager.default.createDirectory(at: erasedDirectory, withIntermediateDirectories: true)
        try Data().write(to: erasedDirectory.appendingPathComponent(profile.id.uuidString))
        for directory in [cacheDirectory(profileID: profile.id), catalogDirectory(profileID: profile.id)] {
            try? FileManager.default.removeItem(at: directory)
        }
        if !isInitialized {
            removeErasedProfiles()
        }
    }

    private var erasedDirectory: URL {
        rootDirectory.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent("Erased", isDirectory: true)
    }

    /// Removes what is left of the profiles `erase` marked; only while CEF is not running, so Chromium writes nothing back.
    func removeErasedProfiles() {
        let markers = (try? FileManager.default.contentsOfDirectory(at: erasedDirectory, includingPropertiesForKeys: nil)) ?? []
        for marker in markers {
            guard let id = UUID(uuidString: marker.lastPathComponent) else { continue }
            let directories = [cacheDirectory(profileID: id), catalogDirectory(profileID: id)]
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
            if !directories.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                try? FileManager.default.removeItem(at: marker)
            }
        }
    }

    func clearData(context: BrowserProfileContext, kinds: Set<BrowsingData.Kind>, since: Date) async throws {
        try preflightClearData(context: context, kinds: kinds, since: since)
        // A regular profile's disk profile can hold data no recorded site names (a cookie a page set for another domain,
        // kept after the page's own site was removed), so clearing for all time reaches it whenever it exists.
        let isAllTime = since <= Date(timeIntervalSince1970: 0)
        let hasDiskProfile = !context.profile.isPrivate
            && FileManager.default.fileExists(atPath: cacheDirectory(profileID: context.profile.id).path)
        guard hasStoredData(for: context) || isAllTime && hasDiskProfile else { return }
        guard kinds.contains(.cache) || kinds.contains(.cookies) else { return }

        if kinds.contains(.cookies) {
            try await clearCookies(context: context)
        }
        let originalCatalog = originCatalog(for: context)
        let origins = originalCatalog.origins.keys.sorted()
        if kinds.contains(.cache) {
            _ = try await command(context: context, method: "Network.clearBrowserCache")
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
                context: context,
                method: "Storage.clearDataForOrigin",
                params: ["origin": origin, "storageTypes": storageTypes]
            )
        }
        for key in frameStorageKeys(in: originalCatalog, where: { _, _ in true }) {
            _ = try await command(
                context: context,
                method: "Storage.clearDataForStorageKey",
                params: ["storageKey": key, "storageTypes": storageTypes]
            )
        }
        if kinds.contains(.cookies), kinds.contains(.cache) {
            var catalog = originCatalog(for: context)
            for origin in origins where catalog.origins[origin] == originalCatalog.origins[origin] {
                catalog.origins[origin] = nil
                catalog.frames?[origin] = nil
            }
            saveOriginCatalog(catalog, for: context)
        }

    }

    func websiteDataEntries(context: BrowserProfileContext) async throws -> [WebsiteData.Entry] {
        guard hasStoredData(for: context) else { return [] }
        let catalog = originCatalog(for: context)
        var entries: [WebsiteData.Entry] = []
        for origin in catalog.origins.keys.sorted() {
            _ = try await command(
                context: context,
                method: "Storage.getUsageAndQuota",
                params: ["origin": origin]
            )
            entries.append(.init(displayName: origin, types: WebsiteData.allTypes, engine: .chromium))
        }
        return entries
    }

    func removeWebsiteData(names: Set<String>, context: BrowserProfileContext) async throws {
        guard !names.isEmpty, hasStoredData(for: context) else { return }
        let storageTypes = "cookies,local_storage,session_storage,indexeddb,websql,service_workers,file_systems,storage_buckets,cache_storage,shader_cache"
        for origin in names {
            guard let scheme = URL(string: origin)?.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { continue }
            _ = try await command(
                context: context,
                method: "Storage.clearDataForOrigin",
                params: ["origin": origin, "storageTypes": storageTypes]
            )
        }
        // The site's own frames elsewhere, and the cross-site frames its pages held.
        let sites = Set(names.compactMap { URL(string: $0).flatMap(Self.partitionSite) })
        var catalog = originCatalog(for: context)
        for key in frameStorageKeys(in: catalog, where: { names.contains($0) || sites.contains($1) }) {
            _ = try await command(
                context: context,
                method: "Storage.clearDataForStorageKey",
                params: ["storageKey": key, "storageTypes": storageTypes]
            )
        }
        catalog = originCatalog(for: context)
        for name in names {
            catalog.origins[name] = nil
            catalog.frames?[name] = nil
        }
        catalog.frames = catalog.frames?.compactMapValues { framed in
            let kept = framed.subtracting(sites)
            return kept.isEmpty ? nil : kept
        }
        saveOriginCatalog(catalog, for: context)
    }

    private func clearCookies(context: BrowserProfileContext) async throws {
        let manager = try withContext(for: context) { context -> UnsafeMutablePointer<cef_cookie_manager_t> in
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
