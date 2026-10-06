// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CCefAppKit
import CefKit
import Darwin
import Foundation

@MainActor
final class ChromiumRuntime {
    static let shared = ChromiumRuntime()

    private final class Context {
        nonisolated(unsafe) let raw: UnsafeMutablePointer<cef_request_context_t>

        init(_ raw: UnsafeMutablePointer<cef_request_context_t>) {
            self.raw = raw
        }

        deinit {
            ChromiumInterop.release(UnsafeMutableRawPointer(raw))
        }
    }

    private(set) var rootDirectory: URL
    private(set) var currentProfile = Profile.original()
    private var contexts: [UUID: Context] = [:]
    private var privateContext: Context?
    var hasPrivateContext: Bool {
        privateContext != nil
    }
    var privateOrigins: [String: Date] = [:]
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

    func use(profile: Profile) {
        currentProfile = profile
    }

    func cacheDirectory(profileID: UUID) -> URL {
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
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        configuration.safeStorage = .keychain
        configuration.rootCachePath = rootDirectory
        configuration.cachePath = rootDirectory.appendingPathComponent("Global", isDirectory: true)
        configuration.persistSessionCookies = true
        configuration.defaultRuntimeStyle = .alloy
        configuration.logSeverity = .error
        // Keep stderr errors visible without persisting private-page details in CEF's log file.
        configuration.logFile = URL(filePath: "/dev/null")
        try CefRuntime.shared.initialize(configuration: configuration)
        // Our native clients own their browser lifetimes, not CefKit's browser registry.
        CEFApplication.setTerminateHandler(nil)
        // ponytail: CEF stays initialized until quit; a separate engine process is the upgrade if its idle RAM proves material.
    }

    func withContext<T>(for profile: Profile, _ body: (UnsafeMutablePointer<cef_request_context_t>) throws -> T) throws -> T {
        try ensureInitialized()
        let context: Context
        if profile.isPrivate {
            if let privateContext {
                context = privateContext
            } else {
                context = try makeContext(cacheDirectory: nil)
                privateContext = context
            }
        } else if let existing = contexts[profile.id] {
            context = existing
        } else {
            context = try makeContext(cacheDirectory: cacheDirectory(profileID: profile.id))
            contexts[profile.id] = context
        }
        return try body(context.raw)
    }

    private func makeContext(cacheDirectory: URL?) throws -> Context {
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
        return Context(raw)
    }

    func register(_ page: ChromiumPage) {
        pages.add(page)
    }

    func unregister(_ page: ChromiumPage) {
        pages.remove(page)
    }

    func endPrivateSession() {
        precondition(!pages.allObjects.contains { $0.isPrivate && !$0.isClosed })
        privateContext = nil
        privateOrigins.removeAll()
    }

    func releaseContext(profileID: UUID) async {
        for page in pages.allObjects where page.profileID == profileID {
            await page.close()
        }
        contexts[profileID] = nil
        if profileID == Profile.privateID {
            privateContext = nil
            privateOrigins.removeAll()
        }
    }

    func command(profile: Profile, method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try ensureInitialized()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let page = ChromiumPage(profile: profile)
        window.contentView = page
        try page.materialize()
        do {
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
        privateContext = nil
        privateOrigins.removeAll()
        contexts.removeAll()
        CefRuntime.shared.shutdown()
        hasShutdown = true
        if !AppDatabase.ownsSession {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }
}
