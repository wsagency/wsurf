// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CCefAppKit
import CefKit
import Darwin
import Foundation
import os

@MainActor
final class ChromiumRuntime {
    static let shared = ChromiumRuntime()
    private nonisolated static let log = Logger(subsystem: "io.wsagency.wsurf", category: "chromium")

    private final class Context {
        nonisolated(unsafe) let raw: UnsafeMutablePointer<cef_request_context_t>
        let profileID: UUID
        /// Chromium's camera and microphone values were cleared and written from the store (`mirrorCapture`).
        var mirrorsCapture = false
        /// The entries last written to Chromium's autoplay allowlist and pop-up exceptions (`mirrorSiteAnswers`); nil until
        /// the first write.
        var autoplayAllowlist: [String]?
        var popupAllowlist: [String]?
        /// CEF finished loading the profile and its history saving is off (`startContext`).
        var isStarted = false

        init(_ raw: UnsafeMutablePointer<cef_request_context_t>, profileID: UUID) {
            self.raw = raw
            self.profileID = profileID
        }

        deinit {
            ChromiumInterop.release(UnsafeMutableRawPointer(raw))
        }
    }

    /// Every switch WSurf adds to Chromium. None may loosen what a `file:` page can read: left alone, Chromium stops a
    /// local page from fetching other local files, which is what keeps a file opened from Downloads to itself.
    /// `ChromiumFileAccessTests` guards this list and the sources against any such switch or setting.
    nonisolated static let extraCommandLineSwitches: [String: String?] = ["disable-backgrounding-occluded-windows": nil]

    private(set) var rootDirectory: URL
    private var contexts: [UUID: Context] = [:]
    var privateOrigins: [UUID: [String: Date]] = [:]
    private let pages = NSHashTable<ChromiumPage>.weakObjects()
    private var hasShutdown = false

    private init() {
        let directory = AppDatabase.ownsSession
            ? AppDatabase.supportDirectory.appendingPathComponent("Chromium", isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-chromium-\(UUID().uuidString)", isDirectory: true)
        rootDirectory = directory
    }

    var isInitialized: Bool {
        CefRuntime.shared.isInitialized
    }

    var hasLivePages: Bool {
        pages.allObjects.contains { !$0.isClosed }
    }

    /// The Chromium profile of a regular WSurf profile: its cookies, site storage, cache and Chromium's own preferences,
    /// kept across launches. A direct child of the root, which CEF requires of a disk profile: it makes any other path an
    /// in-memory profile that is gone at quit.
    func cacheDirectory(profileID: UUID) -> URL {
        rootDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    /// WSurf's own files about a profile's Chromium data (`origins.json`), where every build before 0.1.16 kept them.
    func catalogDirectory(profileID: UUID) -> URL {
        rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    func ensureInitialized() throws {
        guard !hasShutdown else { throw ChromiumError.closed }
        guard !isInitialized else { return }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // Foundation preserves /tmp aliases; CEF requires canonical filesystem paths.
        guard let canonical = realpath(rootDirectory.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(canonical) }
        rootDirectory = URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
        removeErasedProfiles()
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        // Test and staged profiles are disposable and must not request the user's keychain.
        var disposable = AppDatabase.isRunningTests
        #if DEBUG
        disposable = disposable || StageMode.isActive
        #endif
        configuration.safeStorage = disposable ? .mockKeychain : .keychain
        configuration.rootCachePath = rootDirectory
        configuration.cachePath = rootDirectory.appendingPathComponent("Global", isDirectory: true)
        configuration.persistSessionCookies = true
        configuration.defaultRuntimeStyle = .alloy
        configuration.logSeverity = .error
        // Keep stderr errors visible without persisting private-page details in CEF's log file.
        configuration.logFile = URL(filePath: "/dev/null")
        // Chromium hides the pages of a window that other apps cover: no paint, no resize, throttled timers. An external
        // connection works in such a window, so its screenshots and waits would see a stale or blank page. WebKit tabs get the
        // same per controlled tab (`BrowserPage.ignoresWindowOcclusion`); a minimized window stays hidden in both.
        configuration.extraCommandLineSwitches = Self.extraCommandLineSwitches
        // The main thread waits here for the framework load, CEF's own start and the check of the two against each other. CefKit
        // does the three in one call, so there is one interval for them.
        try Pipeline.signposter.withIntervalSignpost("cef.initialize") {
            try CefRuntime.shared.initialize(configuration: configuration)
        }
        // Our native clients own their browser lifetimes, not CefKit's browser registry.
        CEFApplication.setTerminateHandler(nil)
        // ponytail: CEF stays initialized until quit; a separate engine process is the upgrade if its idle RAM proves material.
    }

    /// Reads the CEF framework into the page cache on a utility thread, so that the first Chromium tab's `dlopen` finds it in
    /// memory and does not wait for the disk on the main thread. Nothing is loaded and no process starts: CEF starts with the
    /// first Chromium tab, as before. It reads only where Chromium has been used, because for a person who never opens a
    /// Chromium tab the framework is 230 MB of reading with no use. Call after launch has drawn. The task ends when the read has
    /// been requested; the app does not wait for it. The pipeline signposts show it as `cef.load`, beside `cef.initialize`, the
    /// main thread's wait in `ensureInitialized`.
    @discardableResult
    func prepareInBackground() -> Task<Void, Never> {
        guard !isInitialized, !hasShutdown, let framework = Self.frameworkBinary else { return Task {} }
        let root = rootDirectory
        return Task.detached(priority: .utility) {
            guard Self.hasUsedChromium(root: root) else { return }
            Pipeline.signposter.withIntervalSignpost("cef.load") {
                Self.readAhead(framework)
            }
        }
    }

    /// The framework binary in the app bundle, where `CefRuntime` looks first.
    private nonisolated static var frameworkBinary: URL? {
        let name = "Chromium Embedded Framework"
        return Bundle.main.privateFrameworksURL?
            .appendingPathComponent("\(name).framework", isDirectory: true).appendingPathComponent(name)
    }

    /// Whether a page of this installation has loaded in Chromium: a profile's catalog of origins (`catalogDirectory`) exists
    /// from its first navigation, and `erase` removes it with the profile.
    nonisolated static func hasUsedChromium(root: URL) -> Bool {
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true).path
        return ((try? FileManager.default.contentsOfDirectory(atPath: profiles)) ?? []).contains { UUID(uuidString: $0) != nil }
    }

    /// Asks the kernel to read `file` into the page cache, in chunks and without copying it to this process.
    nonisolated static func readAhead(_ file: URL) {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        let chunk = Int64(8 << 20)
        var offset: Int64 = 0
        while offset < info.st_size {
            var advice = radvisory(ra_offset: off_t(offset), ra_count: Int32(min(chunk, info.st_size - offset)))
            guard fcntl(descriptor, F_RDADVISE, &advice) != -1 else { return }
            offset += chunk
        }
    }

    func withContext<T>(
        for owner: BrowserProfileContext,
        _ body: (UnsafeMutablePointer<cef_request_context_t>) throws -> T
    ) throws -> T {
        guard !owner.privateSessionEnded else { throw ChromiumError.closed }
        try ensureInitialized()
        let context: Context
        if let existing = contexts[owner.contextID] {
            context = existing
        } else {
            context = try makeContext(
                profileID: owner.profile.id,
                cacheDirectory: owner.profile.isPrivate ? nil : cacheDirectory(profileID: owner.profile.id)
            )
            contexts[owner.contextID] = context
        }
        return try body(context.raw)
    }

    func hasContext(contextID: UUID) -> Bool {
        contexts[contextID] != nil
    }

    /// Creates the profile's context if needed; true once CEF can open a browser on it. A disk profile loads asynchronously,
    /// and until it has, `cef_browser_host_create_browser_sync` returns nil. An in-memory profile is ready at once.
    func startContext(for owner: BrowserProfileContext) throws -> Bool {
        let raw = try withContext(for: owner) { $0 }
        guard let entry = contexts[owner.contextID], !entry.isStarted else { return true }
        let preferences = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: cef_preference_manager_t.self)
        let name = "history.saving_disabled"
        // CEF answers preference calls only for a context that finished loading, the same check browser creation makes.
        guard ChromiumInterop.withString(name, { preferences.pointee.has_preference?(preferences, $0) }) == 1 else { return false }
        if !owner.profile.isPrivate {
            // A disk profile would keep a Chrome history of its own (`History`, `Top Sites`: every address and title). WSurf
            // keeps the history, and its Clear History cannot reach Chromium's, so Chromium saves none.
            guard let value = cef_value_create() else { return false }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(value)) }
            _ = value.pointee.set_bool?(value, 1)
            var error = cef_string_t()
            defer { ccef_string_clear(&error) }
            ChromiumInterop.retain(UnsafeMutableRawPointer(value))
            guard ChromiumInterop.withString(name, { preferences.pointee.set_preference?(preferences, $0, value, &error) }) == 1 else {
                return false
            }
        }
        entry.isStarted = true
        return true
    }

    /// Waits until CEF can open a browser on the profile's context (`startContext`).
    func prepareContext(for owner: BrowserProfileContext) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        // ponytail: polls; `cef_request_context_handler_t.on_request_context_initialized` is the event to use if this shows.
        while try !startContext(for: owner) {
            guard ContinuousClock.now < deadline else {
                throw ChromiumError.unavailable(String(localized: "Chromium could not create this browsing profile."))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Mirrors the store's camera and microphone choices for these origins into Chromium's own permission state, which is
    /// what `navigator.permissions.query` reads: Allow reports `granted`, as Chrome does after an Allow, Deny `denied`, and
    /// Ask `prompt`. Google Meet waits for its own button while it reads `prompt`. Each value covers the exact origin
    /// (Chromium's pattern has no wildcard) in this profile's context only, and only a context that exists:
    /// `ChromiumPage.willNavigate` sets it again before every main-frame navigation. A device is still granted only
    /// through `permissionDecision`, and only a navigated top-level origin or a stored record is ever written, never a
    /// frame's origin.
    func mirrorCapture(_ origins: [String], in owner: BrowserProfileContext) {
        guard let entry = contexts[owner.contextID] else { return }
        let context = entry.raw
        var origins = origins
        if !entry.mirrorsCapture {
            // The first write to a context starts from what the store says, so a change made while no context existed, or
            // to the store's file outside WSurf, leaves nothing behind. A regular profile is a disk profile, which keeps
            // these values across launches (CEF has no layer that does not), and every context on it shares them, so the
            // exception lists are emptied, whatever the origin. A private window's in-memory profile is its own and starts
            // empty. ponytail: a value Chromium wrote itself during a run (its own prompt) waits for that site's next
            // navigation; `add_setting_observer` would catch it. Until the context is ready nothing is written, and each
            // page's first navigation comes after that.
            guard owner.profile.isPrivate || Self.clearPermissionPreferences(context) else { return }
            entry.mirrorsCapture = true
            origins += [WebPermission.camera, .microphone].flatMap(owner.sitePermissions.origins(for:))
        }
        for origin in origins.map({ SitePermissions.webOrigin(for: URL(string: $0)) }) where !origin.isEmpty {
            for (permission, type) in [
                (WebPermission.camera, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA), (.microphone, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC),
            ] {
                let value = switch owner.sitePermissions.policy(for: origin, permission) {
                case .allow:
                    CEF_CONTENT_SETTING_VALUE_ALLOW
                case .deny:
                    CEF_CONTENT_SETTING_VALUE_BLOCK
                case .ask:
                    CEF_CONTENT_SETTING_VALUE_DEFAULT
                }
                ChromiumInterop.withString(origin) { url in
                    context.pointee.set_content_setting?(context, url, url, type, value)
                }
            }
        }
    }

    /// Lets the websites the person allowed do in Chromium, without a click, what they may do in WebKit: start media with
    /// sound (auto-play Allow) and open a pop-up (pop-ups Allow). A user activation WSurf handed out would let any script of
    /// the page do both and more (the colour chooser among them), so Chromium is told per website instead:
    /// - its AutoplayAllowlist preference (`media.autoplay_whitelist`), read for a tab when a main-frame navigation
    ///   finishes, against the tab's own address;
    /// - the Allow exceptions of its pop-ups content setting (`profile.content_settings.exceptions.popups`), which its
    ///   pop-up blocker reads against the opener's address when a page opens a window, before WSurf is asked
    ///   (`blocked_content::ShouldBlockPopup`, then `on_before_popup`). WSurf's own answer still decides after it.
    /// Each list holds the Allow origins of the pages open on Chromium in this profile, `url` (where `page` is about to go)
    /// in place of `page`'s own, each by its tab's answers, so Chromium's profile files keep no more of the history than
    /// the open tabs. Every other website is under Chromium's own rules and the site guard. ponytail: a changed answer
    /// reaches Chromium at the next navigation in the profile, and an auto-play answer reaches a page at its own next
    /// navigation (until a navigation finishes its document runs under the rule of the tab's page before it, so a script
    /// that plays while the page is still being parsed is refused); a per-navigation answer would need CEF support.
    func mirrorSiteAnswers(of page: ChromiumPage, navigatingTo url: URL, in owner: BrowserProfileContext) {
        guard let entry = contexts[owner.contextID], entry.isStarted else { return }
        let tabs = owner.chromiumTabs
        var sites = tabs.map { tab in
            (origin: SitePermissions.webOrigin(for: tab.liveView?.chromium === page ? url : tab.liveView?.url), store: tab.sitePermissions)
        }
        if !tabs.contains(where: { $0.liveView?.chromium === page }) {
            sites.append((origin: SitePermissions.webOrigin(for: url), store: owner.sitePermissions))
        }
        sites.removeAll { $0.origin.isEmpty }
        let autoplay = Self.sitePatterns(sites.filter { ($0.store.autoplay(for: $0.origin) ?? owner.settings.autoplay) == .allow }.map(\.origin))
        if autoplay != entry.autoplayAllowlist, let items = cef_list_value_create() {
            for (index, pattern) in autoplay.enumerated() {
                ChromiumInterop.withString(pattern) { _ = items.pointee.set_string?(items, index, $0) }
            }
            if Self.setPreference("media.autoplay_whitelist", in: entry.raw, { _ = $0.pointee.set_list?($0, items) }) {
                entry.autoplayAllowlist = autoplay
            }
        }
        let popups = Self.sitePatterns(sites.filter {
            TabPopupPolicy.policy(for: $0.origin, store: $0.store, settings: owner.settings) == .allow
        }.map(\.origin))
        if popups != entry.popupAllowlist, let exceptions = cef_dictionary_value_create() {
            for pattern in popups {
                // Primary pattern, secondary pattern (any embedder): the pop-ups setting is keyed by the opener's address alone.
                guard let exception = cef_dictionary_value_create() else { continue }
                _ = ChromiumInterop.withString("setting") { exception.pointee.set_int?(exception, $0, Int32(CEF_CONTENT_SETTING_VALUE_ALLOW.rawValue)) }
                _ = ChromiumInterop.withString(pattern + ",*") { exceptions.pointee.set_dictionary?(exceptions, $0, exception) }
            }
            if Self.setPreference("profile.content_settings.exceptions.popups", in: entry.raw, { _ = $0.pointee.set_dictionary?($0, exceptions) }) {
                entry.popupAllowlist = popups
            }
        }
    }

    /// One exact pattern per origin, sorted; an origin that cannot be one is left out, and only the count is logged.
    private nonisolated static func sitePatterns(_ origins: [String]) -> [String] {
        let patterns = origins.compactMap(sitePattern(for:))
        if patterns.count < origins.count {
            log.notice("site allowlists: dropped \(origins.count - patterns.count) origins that are not one exact host")
        }
        return Set(patterns).sorted()
    }

    /// Sets the preference `name` of `context` to the value `fill` gives a new value; true once Chromium took it.
    private static func setPreference(
        _ name: String, in context: UnsafeMutablePointer<cef_request_context_t>, _ fill: (UnsafeMutablePointer<cef_value_t>) -> Void
    ) -> Bool {
        guard let value = cef_value_create() else { return false }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(value)) }
        fill(value)
        let preferences = UnsafeMutableRawPointer(context).assumingMemoryBound(to: cef_preference_manager_t.self)
        var error = cef_string_t()
        defer { ccef_string_clear(&error) }
        ChromiumInterop.retain(UnsafeMutableRawPointer(value))
        return ChromiumInterop.withString(name) { preferences.pointee.set_preference?(preferences, $0, value, &error) } == 1
    }

    /// The entry that matches `origin` and no other, or nil when it cannot be one. Chromium reads each entry of both lists
    /// as a content-settings pattern (`policy::IsOriginInAllowlist`, `ContentSettingsPattern::FromString`): a host without
    /// `[*.]` is that host alone, `*` and `[*.]` are wildcards, and a pattern without a port matches every port. So the
    /// entry is rebuilt from the scheme (http or https), a host that is plain lowercase DNS labels (punycode for a name
    /// in another script; an IPv4 address is such a name too) or an IPv6 address in brackets, and the port, written out.
    nonisolated static func sitePattern(for origin: String) -> String? {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: true), !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard origin.contains("[") == host.contains(":") else { return nil }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
            }) else { return nil }
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    /// Restores Chromium's exception lists to empty for the permissions WSurf decides; false while the context is not
    /// ready. Besides the camera and microphone values `mirrorCapture` writes, Chromium stores an Allow or a Deny from its
    /// own prompt (location, notifications, camera pan-tilt-zoom), which would otherwise answer for WSurf in later launches.
    static func clearPermissionPreferences(_ context: UnsafeMutablePointer<cef_request_context_t>) -> Bool {
        let preferences = UnsafeMutableRawPointer(context).assumingMemoryBound(to: cef_preference_manager_t.self)
        let names = [
            "media_stream_camera", "media_stream_mic", "camera_pan_tilt_zoom", "geolocation", "geolocation_with_options", "notifications",
        ]
        return names.allSatisfy { name in
            var error = cef_string_t()
            defer { ccef_string_clear(&error) }
            return ChromiumInterop.withString("profile.content_settings.exceptions.\(name)") {
                preferences.pointee.set_preference?(preferences, $0, nil, &error)
            } == 1
        }
    }

    private func makeContext(profileID: UUID, cacheDirectory: URL?) throws -> Context {
        var settings = cef_request_context_settings_t()
        settings.size = MemoryLayout<cef_request_context_settings_t>.stride
        if let cacheDirectory {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            ChromiumInterop.setString(cacheDirectory.path, to: &settings.cache_path)
            settings.persist_session_cookies = 1
        }
        defer { ccef_string_clear(&settings.cache_path) }
        guard let raw = cef_request_context_create_context(&settings, nil) else {
            throw ChromiumError.unavailable(String(localized: "Chromium could not create this browsing profile."))
        }
        return Context(raw, profileID: profileID)
    }

    func register(_ page: ChromiumPage) {
        pages.add(page)
    }

    func unregister(_ page: ChromiumPage) {
        pages.remove(page)
        // Chromium writes its cookie store to disk on a timer, so what a page set in its last seconds can be lost once the
        // profile's last page is gone (a crash, a force quit). Quit flushes every context in `shutdown`.
        let id = page.context.contextID
        if !hasShutdown, !pages.allObjects.contains(where: { $0.context.contextID == id }) {
            flushCookieStore(contextID: id)
        }
    }

    /// Number of cookie-store flushes asked of Chromium (a test reads it).
    private(set) var cookieFlushCount = 0

    /// Asks Chromium to write the cookie store of a context that exists to disk; it finishes in the background.
    private func flushCookieStore(contextID: UUID) {
        guard let entry = contexts[contextID], entry.isStarted,
              let manager = entry.raw.pointee.get_cookie_manager?(entry.raw, nil) else { return }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(manager)) }
        cookieFlushCount += 1
        _ = manager.pointee.flush_store?(manager, nil)
    }

    func releaseContext(contextID: UUID) async {
        for page in pages.allObjects where page.context.contextID == contextID {
            await page.close()
        }
        contexts[contextID] = nil
        privateOrigins[contextID] = nil
    }

    func releaseContexts(profileID: UUID) async {
        let matching = contexts.compactMap { id, context in
            context.profileID == profileID ? id : nil
        }
        for id in matching {
            await releaseContext(contextID: id)
        }
    }

    func command(context: BrowserProfileContext, method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !context.privateSessionEnded else { throw ChromiumError.closed }
        try ensureInitialized()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let page = ChromiumPage(context: context)
        window.contentView = page
        do {
            try await prepareContext(for: context)
            try page.materialize()
            let result = try await page.command(method, params: params)
            await page.close()
            window.close()
            return result
        } catch {
            await page.close()
            window.close()
            throw error
        }
    }

    func shutdown() async {
        guard isInitialized else { return }
        for page in pages.allObjects {
            await page.close()
        }
        privateOrigins.removeAll()
        // Written before CEF shuts down, in case its own shutdown does not.
        contexts.keys.forEach { flushCookieStore(contextID: $0) }
        contexts.removeAll()
        CefRuntime.shared.shutdown()
        hasShutdown = true
        removeErasedProfiles()
        if !AppDatabase.ownsSession {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }
}
