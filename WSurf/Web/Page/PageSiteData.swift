// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// Clearing one developer origin's website data for an MCP connection. Callers have already established the Developer tier;
/// everything here narrows the effect to that one origin and never returns what it removed.
///
/// What each part reaches:
/// - Storage (localStorage, sessionStorage, IndexedDB, Cache Storage, service workers) is cleared by a script that runs in the
///   page's own document, so it can only touch the origin the page is on. Chromium also clears the origin's other storage
///   through DevTools, keyed by that origin.
/// - Cookies belong to a host, not an origin: every port of the host shares them. Only cookies whose domain is exactly the
///   host are removed; a cookie of a parent domain stays, because other sites may share it.
/// - The HTTP cache is not cleared. Neither engine offers a per-origin removal, and clearing it for a host or for all sites
///   would reach sites the connection has no access to.
nonisolated enum DevelopmentSiteData {
    struct Report: Equatable {
        var localStorage = 0
        var sessionStorage = 0
        var indexedDB = 0
        var cacheStorage = 0
        var serviceWorkers = 0
        var cookies = 0
        /// IndexedDB databases the page kept open; their removal finishes when the page releases them.
        var blockedDatabases = 0
        /// Parts the page or the engine could not clear.
        var failed: [String] = []
    }

    static let storageTypes = "local_storage,session_storage,indexeddb,websql,service_workers,file_systems,storage_buckets,cache_storage"

    /// The host whose cookies belong to `url`, in the form a cookie domain is compared in. Nil when `url` has no host.
    static func cookieHost(of url: URL) -> String? {
        url.host().flatMap { MCPDeveloperAccess.canonicalHost($0) }
    }

    /// Whether a cookie with `domain` is one of `host`'s own: the same name, with or without the leading dot a cookie sets.
    /// A cookie of a parent domain, a subdomain or a sibling host is not.
    static func isHostCookie(domain: String, host: String) -> Bool {
        var name = domain.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        return MCPDeveloperAccess.canonicalHost(name) == host
    }

    /// Body of an async function. The first line refuses to run when the document is no longer on `origin`, so a navigation
    /// between the permission check and the script cannot aim it at another site. Reports counts, never names or values.
    static let script = """
        if (location.origin !== origin) return JSON.stringify({ stale: true });
        const done = { localStorage: 0, sessionStorage: 0, indexedDB: 0, cacheStorage: 0, serviceWorkers: 0, blocked: 0, failed: [] };
        const within = (work) => Promise.race([work(), new Promise((resolve, reject) => setTimeout(() => reject(new Error('timeout')), 4000))]);
        const attempt = async (name, work) => { try { await within(work); } catch (_) { done.failed.push(name); } };
        await attempt('localStorage', async () => { done.localStorage = localStorage.length; localStorage.clear(); });
        await attempt('sessionStorage', async () => { done.sessionStorage = sessionStorage.length; sessionStorage.clear(); });
        await attempt('indexedDB', async () => {
          if (typeof indexedDB === 'undefined' || typeof indexedDB.databases !== 'function') return;
          const databases = await indexedDB.databases();
          await Promise.all(databases.map((database) => new Promise((resolve) => {
            const request = indexedDB.deleteDatabase(database.name);
            const wait = setTimeout(() => { done.blocked += 1; resolve(); }, 1500);
            request.onsuccess = () => { clearTimeout(wait); done.indexedDB += 1; resolve(); };
            request.onerror = () => { clearTimeout(wait); done.failed.push('indexedDB'); resolve(); };
          })));
        });
        await attempt('cacheStorage', async () => {
          if (typeof caches === 'undefined') return;
          const names = await caches.keys();
          await Promise.all(names.map((name) => caches.delete(name)));
          done.cacheStorage = names.length;
        });
        await attempt('serviceWorkers', async () => {
          if (!navigator.serviceWorker) return;
          const registrations = await navigator.serviceWorker.getRegistrations();
          await Promise.all(registrations.map((registration) => registration.unregister()));
          done.serviceWorkers = registrations.length;
        });
        return JSON.stringify(done);
        """
}

enum DevelopmentSiteDataOutcome {
    case cleared(DevelopmentSiteData.Report)
    /// The page left the origin, or `authorize` stopped holding; nothing further was removed.
    case stale
    case unavailable(String)
}

extension BrowserPage {
    /// Clears the website data of `url`'s origin (storage) and host (cookies) in this page's own profile. `authorize` is
    /// checked before each step that removes something and after each wait, so a lost grant or a navigation to another site
    /// stops the work at once.
    func clearDevelopmentSiteData(for url: URL, authorize: @MainActor () -> Bool) async -> DevelopmentSiteDataOutcome {
        let origin = SitePermissions.origin(for: url)
        guard !origin.isEmpty, let host = DevelopmentSiteData.cookieHost(of: url), authorize() else { return .stale }
        var report = DevelopmentSiteData.Report()
        let output: Any
        do {
            output = try await callAsyncJavaScript(
                DevelopmentSiteData.script, arguments: ["origin": origin], in: nil, contentWorld: PageAutomationGuard.world)
        } catch {
            return authorize() ? .unavailable("The page did not respond.") : .stale
        }
        guard authorize() else { return .stale }
        guard let text = output as? String, let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unavailable("The page did not respond.") }
        if object["stale"] as? Bool == true { return .stale }
        func count(_ key: String) -> Int {
            (object[key] as? NSNumber)?.intValue ?? 0
        }
        report.localStorage = count("localStorage")
        report.sessionStorage = count("sessionStorage")
        report.indexedDB = count("indexedDB")
        report.cacheStorage = count("cacheStorage")
        report.serviceWorkers = count("serviceWorkers")
        report.blockedDatabases = count("blocked")
        report.failed = (object["failed"] as? [String]) ?? []
        do {
            report.cookies = try await removeHostCookies(host, authorize: authorize)
            if let chromium, authorize() {
                _ = try await chromium.command("Storage.clearDataForOrigin", params: ["origin": origin, "storageTypes": DevelopmentSiteData.storageTypes])
            }
        } catch {
            report.failed.append(chromium == nil ? "cookies" : "cookies or storage")
        }
        return authorize() ? .cleared(report) : .stale
    }

    /// Removes the cookies whose domain is exactly `host` from this page's own cookie jar and returns how many. Cookie
    /// names and values are not kept or returned.
    private func removeHostCookies(_ host: String, authorize: @MainActor () -> Bool) async throws -> Int {
        var removed = 0
        if let webKit {
            let store = webKit.configuration.websiteDataStore.httpCookieStore
            for cookie in await store.allCookies() where DevelopmentSiteData.isHostCookie(domain: cookie.domain, host: host) {
                guard authorize() else { break }
                await store.deleteCookie(cookie)
                removed += 1
            }
        } else if let chromium {
            let all = try await chromium.command("Network.getAllCookies")
            for cookie in (all["cookies"] as? [[String: Any]]) ?? [] {
                guard let name = cookie["name"] as? String, let domain = cookie["domain"] as? String,
                    DevelopmentSiteData.isHostCookie(domain: domain, host: host)
                else { continue }
                guard authorize() else { break }
                _ = try await chromium.command(
                    "Network.deleteCookies", params: ["name": name, "domain": domain, "path": cookie["path"] as? String ?? "/"])
                removed += 1
            }
        }
        return removed
    }
}
