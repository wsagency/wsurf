// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CCef
import Foundation
import GRDB
import Testing
import WebKit

@testable import WSurf

/// A regular profile's Chromium data lives in a disk profile, so logins survive a quit, and every path that clears or
/// deletes that data reaches the disk. Fixture pages on loopback only; the test runtime's root is a temporary directory and
/// uses Chromium's mock key, never the Keychain.
@MainActor
@Suite(.serialized)
struct ChromiumProfileDataTests {
    private static let write = """
        document.cookie = 'persistToken=kept; Max-Age=3600; Path=/; SameSite=Lax';
        localStorage.setItem('persistToken', 'kept');
        await new Promise((resolve, reject) => {
          const open = indexedDB.open('persist', 1);
          open.onupgradeneeded = () => open.result.createObjectStore('values');
          open.onerror = () => reject(open.error);
          open.onsuccess = () => {
            const transaction = open.result.transaction('values', 'readwrite');
            transaction.objectStore('values').put('kept', 'persistToken');
            transaction.oncomplete = () => { open.result.close(); resolve(); };
            transaction.onerror = () => reject(transaction.error);
          };
        });
        return 'written';
        """

    /// The cookie, the localStorage value and the IndexedDB value, joined by `|`.
    private static let read = """
        const stored = await new Promise(resolve => {
          const open = indexedDB.open('persist', 1);
          open.onupgradeneeded = () => open.result.createObjectStore('values');
          open.onerror = () => resolve('error');
          open.onsuccess = () => {
            const get = open.result.transaction('values').objectStore('values').get('persistToken');
            get.onsuccess = () => { open.result.close(); resolve(get.result || ''); };
            get.onerror = () => { open.result.close(); resolve('error'); };
          };
        });
        return [document.cookie, localStorage.getItem('persistToken') || '', stored].join('|');
        """

    private let runtime = ChromiumRuntime.shared

    private func regularProfile() -> Profile {
        Profile(id: UUID(), name: "Persist", symbol: "person", color: .gray)
    }

    /// Loads `url` in a new page of `context`, runs `script` there and closes the page.
    private func run(_ script: String, at url: URL, in context: BrowserProfileContext) async throws -> String? {
        let page = BrowserPage(chromium: ChromiumPage(context: context))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.close() }
        page.load(URLRequest(url: url))
        try #require(await waitUntil { page.url == url && !page.isLoading })
        let result = try await page.callAsyncJavaScript(script, in: nil, contentWorld: .page) as? String
        await page.close()
        return result
    }

    private nonisolated final class Flush: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, Never>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }
    }

    /// Writes the context's cookies to its store now, rather than at Chromium's next periodic commit.
    private func flushCookies(_ context: BrowserProfileContext) async throws {
        let manager = try runtime.withContext(for: context) { raw in
            try #require(raw.pointee.get_cookie_manager?(raw, nil))
        }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(manager)) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let callback = ChromiumInterop.allocate(cef_completion_callback_t.self, owner: Flush(continuation))
            callback.pointee.on_complete = { me in
                ChromiumInterop.owner(Flush.self, of: me.map(UnsafeMutableRawPointer.init))?.continuation.resume()
            }
            if manager.pointee.flush_store?(manager, callback) != 1 {
                continuation.resume()
            }
        }
    }

    /// The names of the cookies in the profile's cookie database on disk, read from a copy so Chromium's lock is no matter.
    private func storedCookieNames(_ profile: Profile) throws -> Set<String> {
        let directory = runtime.cacheDirectory(profileID: profile.id)
        let stores = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "Cookies" } ?? []
        var names: Set<String> = []
        for store in stores {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cookies-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            for suffix in ["", "-journal", "-wal"] where FileManager.default.fileExists(atPath: store.path + suffix) {
                try FileManager.default.copyItem(atPath: store.path + suffix, toPath: copy.appendingPathComponent("Cookies" + suffix).path)
            }
            let database = try DatabaseQueue(path: copy.appendingPathComponent("Cookies").path)
            names.formUnion(try database.read { try String.fetchAll($0, sql: "SELECT name FROM cookies") })
        }
        return names
    }

    /// Whether any file under the runtime's root holds `token`.
    private func rootHolds(_ token: String) -> Bool {
        let needle = Data(token.utf8)
        let files = FileManager.default.enumerator(at: runtime.rootDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files.contains { (try? Data(contentsOf: $0))?.range(of: needle) != nil }
    }

    /// The origins in the profile's `origins.json` on disk: what WSurf lists as sites with Chromium data, as a later launch reads it.
    private func storedOrigins(_ profile: Profile) throws -> Set<String> {
        struct Stored: Decodable {
            var origins: [String: Date]
        }
        let file = runtime.catalogDirectory(profileID: profile.id).appendingPathComponent("origins.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return Set(try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file)).origins.keys)
    }

    @Test(.boundedWebViews)
    func aRegularProfileKeepsItsSiteDataOnDisk() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Persist</title>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/")
        let profile = regularProfile()
        let first = BrowserProfileContext(profile: profile)
        let privateContext = BrowserProfileContext(profile: .privateBrowsing())
        try runtime.ensureInitialized()

        #expect(try await run(Self.write, at: url, in: first) == "written")
        try await flushCookies(first)
        // On disk, in this profile's own Chromium profile.
        #expect(try storedCookieNames(profile).contains("persistToken"))
        #expect(runtime.cacheDirectory(profileID: profile.id).deletingLastPathComponent() == runtime.rootDirectory)
        // Chromium saves no history of its own there: WSurf keeps the history, and Clear History cannot reach Chromium's.
        try runtime.withContext(for: first) { raw in
            let preferences = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: cef_preference_manager_t.self)
            let value = ChromiumInterop.withString("history.saving_disabled") { preferences.pointee.get_preference?(preferences, $0) }
            defer { ChromiumInterop.release(value.map(UnsafeMutableRawPointer.init)) }
            #expect(value.flatMap { $0.pointee.get_bool?($0) } == 1)
        }

        // A private window keeps its own data in memory only.
        let privateToken = "private\(UUID().uuidString.prefix(8))"
        _ = try await run(
            "document.cookie = '\(privateToken)=1; Max-Age=3600; Path=/'; localStorage.setItem('\(privateToken)', '1'); return 'ok'",
            at: url, in: privateContext
        )
        try await flushCookies(privateContext)
        #expect(try await run(Self.read, at: url, in: privateContext) == "\(privateToken)=1||")

        // The first context is gone; the next one on the same profile still reads all three.
        await runtime.releaseContext(contextID: first.contextID)
        let next = BrowserProfileContext(profile: profile)
        #expect(try await run(Self.read, at: url, in: next) == "persistToken=kept|kept|kept")
        // Nothing the private window stored reached any file, after the regular profile's writes had time to land.
        #expect(!rootHolds(privateToken))

        await runtime.releaseContext(contextID: next.contextID)
        await privateContext.endPrivateSession()
        try await runtime.erase(profile: profile)
    }

    /// Closing a profile's last Chromium page asks Chromium to write its cookie store, so nothing waits for the periodic commit.
    @Test(.boundedWebViews)
    func closingTheLastChromiumPageFlushesTheCookieStore() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Persist</title>")])
        defer { withExtendedLifetime(server) {} }
        let profile = regularProfile()
        let context = BrowserProfileContext(profile: profile)
        try runtime.ensureInitialized()
        let before = runtime.cookieFlushCount

        #expect(try await run(Self.write, at: try server.url("/"), in: context) == "written")

        #expect(runtime.cookieFlushCount == before + 1, "the last page of the profile closed: one flush")
        #expect(await waitUntil { (try? storedCookieNames(profile).contains("persistToken")) == true }, "the cookie reached the disk")

        await runtime.releaseContext(contextID: context.contextID)
        try await runtime.erase(profile: profile)
    }

    @Test(.boundedWebViews)
    func clearingOneSiteThenEverythingRemovesTheDataFromDisk() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Persist</title>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/")
        let origin = try #require(url.scheme.map { "\($0)://\(url.host() ?? ""):\(url.port ?? 0)" })
        let profile = regularProfile()
        let context = BrowserProfileContext(profile: profile)
        try runtime.ensureInitialized()

        #expect(try await run(Self.write, at: url, in: context) == "written")
        // A cookie for a site WSurf never recorded, as a page of another site can leave behind.
        _ = try await runtime.command(context: context, method: "Network.setCookie", params: [
            "name": "unrecorded", "value": "1", "url": "http://unrecorded.test/", "expires": Date().timeIntervalSince1970 + 3600,
        ])
        try await flushCookies(context)
        try #require(try storedCookieNames(profile).isSuperset(of: ["persistToken", "unrecorded"]))

        // Website Data, one site.
        let snapshot = try await WebsiteData.snapshot(context: context)
        let entry = try #require(snapshot.entries.first { $0.engine == .chromium && $0.displayName == origin })
        // The catalog is written a moment after a navigation, and the removal writes it at once.
        runtime.flushOriginCatalogs()
        #expect(try storedOrigins(profile).contains(origin))
        try await WebsiteData.remove([entry], of: snapshot, context: context)
        try await flushCookies(context)
        #expect(try storedCookieNames(profile) == ["unrecorded"])
        #expect(try !storedOrigins(profile).contains(origin))

        // Clear Browsing Data, everything, with no recorded site left.
        try await BrowsingData.clear([.cookies, .cache], range: .everything, history: context.history, context: context)
        try await flushCookies(context)
        #expect(try storedCookieNames(profile).isEmpty)

        await runtime.releaseContext(contextID: context.contextID)
        let next = BrowserProfileContext(profile: profile)
        #expect(try await run(Self.read, at: url, in: next) == "||")
        await runtime.releaseContext(contextID: next.contextID)
        try await runtime.erase(profile: profile)
    }

    /// Clearing everything (Clear Browsing Data, Clear on Quit) reaches a disk profile that no tab opened in this run, which
    /// Chromium first has to load: CEF opens no page on it until then.
    @Test(.boundedWebViews)
    func clearingEverythingReachesADiskProfileNoTabOpened() async throws {
        let profile = regularProfile()
        let context = BrowserProfileContext(profile: profile)
        try runtime.ensureInitialized()
        try FileManager.default.createDirectory(at: runtime.cacheDirectory(profileID: profile.id), withIntermediateDirectories: true)
        #expect(!runtime.hasContext(contextID: context.contextID))
        try await BrowsingData.clear([.cookies, .cache], range: .everything, history: context.history, context: context)
        #expect(runtime.hasContext(contextID: context.contextID))
        await runtime.releaseContext(contextID: context.contextID)
        try await runtime.erase(profile: profile)
    }

    /// A cross-site frame's storage is kept under the page's site, where clearing the frame's own origin does not reach.
    @Test(.boundedWebViews)
    func clearingReachesTheStorageOfACrossSiteFrame() async throws {
        let frame = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("""
                <!doctype html><script>
                const before = localStorage.getItem('framed');
                localStorage.setItem('framed', 'kept');
                parent.postMessage(before || 'empty', '*');
                </script>
                """),
        ])
        let top = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Top</title><body></body>")])
        defer { withExtendedLifetime((frame, top)) {} }
        // localhost and 127.0.0.1 are different sites.
        let frameURL = try frame.url("/frame").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        let url = try top.url("/")
        let topOrigin = try #require(url.scheme.map { "\($0)://\(url.host() ?? ""):\(url.port ?? 0)" })
        let embed = """
            return await new Promise(resolve => {
              addEventListener('message', event => resolve(String(event.data)), { once: true });
              const frame = document.createElement('iframe');
              frame.src = '\(frameURL)';
              document.body.appendChild(frame);
              setTimeout(() => resolve('timeout'), 10000);
            });
            """
        let profile = regularProfile()
        let context = BrowserProfileContext(profile: profile)
        try runtime.ensureInitialized()

        #expect(try await run(embed, at: url, in: context) == "empty")
        #expect(try await run(embed, at: url, in: context) == "kept")
        // Website Data, the page's site.
        let snapshot = try await WebsiteData.snapshot(context: context)
        let entry = try #require(snapshot.entries.first { $0.engine == .chromium && $0.displayName == topOrigin })
        try await WebsiteData.remove([entry], of: snapshot, context: context)
        #expect(try await run(embed, at: url, in: context) == "empty")
        // Clear Browsing Data, everything.
        try await BrowsingData.clear([.cookies, .cache], range: .everything, history: context.history, context: context)
        #expect(try await run(embed, at: url, in: context) == "empty")

        await runtime.releaseContext(contextID: context.contextID)
        try await runtime.erase(profile: profile)
    }

    @Test(.boundedWebViews)
    func deletingAProfileRemovesItsChromiumData() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Persist</title>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/")
        let profile = regularProfile()
        let context = BrowserProfileContext(profile: profile)
        try runtime.ensureInitialized()
        #expect(try await run(Self.write, at: url, in: context) == "written")
        try await flushCookies(context)
        try #require(try storedCookieNames(profile).contains("persistToken"))
        // The Chromium profile and WSurf's `origins.json` beside it.
        let catalog = runtime.rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        let directories = [runtime.cacheDirectory(profileID: profile.id), catalog]
        // The catalog is written a moment after a navigation.
        runtime.flushOriginCatalogs()
        try #require(directories.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        try await runtime.erase(profile: profile)
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        // Chromium writes a few files back while it lets the profile go; the mark taken at the erase removes them once CEF
        // has stopped (at quit or the next launch), which the call below stands in for after that write.
        let marker = catalog.deletingLastPathComponent().appendingPathComponent("Erased", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        _ = await waitUntil(timeout: .seconds(10)) { FileManager.default.fileExists(atPath: directories[0].path) }
        try await Task.sleep(for: .seconds(1))
        runtime.removeErasedProfiles()
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
