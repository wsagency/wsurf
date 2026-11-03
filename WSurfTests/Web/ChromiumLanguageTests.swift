// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The languages a Chromium page and its requests see, and what Chromium draws in them.
///
/// Chromium picks its UI locale through the main bundle's localizations, and WSurf declares only `en`, so it loads the en-US
/// strings whatever the system languages are. CEF's `accept_language_list` is not set, so `navigator.languages` and
/// `Accept-Language` are CEF's `en-US,en`. Measured on 154.0.32 with all 55 locale paks and with the three kept ones
/// (`en en_GB hr`), under `-AppleLanguages (de)`, `(hr)` and `(zh-Hans-CN)`: identical in every run. So pruning the paks
/// (`Tools/embed-chromium.sh`, `WSURF_CEF_LOCALES`) changes nothing a page or a request can see. This test fails if that stops
/// being true, for example when a locale or an accept-language list is set.
@MainActor
@Suite(.serialized)
struct ChromiumLanguageTests {
    private static let probe = """
        (() => {
          const input = document.getElementById('required');
          input.checkValidity();
          return JSON.stringify({
            language: navigator.language, languages: navigator.languages,
            intlLocale: Intl.DateTimeFormat().resolvedOptions().locale,
            validationMessage: input.validationMessage,
          });
        })()
        """

    private struct Probe: Decodable {
        let language: String
        let languages: [String]
        let intlLocale: String
        let validationMessage: String
    }

    private func observe() async throws -> (probe: Probe, acceptLanguage: String?) {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Languages</title><input id=required required>"),
        ])
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let profile = Profile(id: UUID(), name: "Language report", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.close() }

        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            let raw = try #require(try await page.evaluateJavaScript(Self.probe, in: nil, contentWorld: .page) as? String)
            let head = try #require(server.lastRequestHead(for: "/"))
            let acceptLanguage = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("accept-language:") }
                .map { $0.dropFirst("accept-language:".count).trimmingCharacters(in: .whitespaces) }
            let evidence = """
                {"preferredLanguages": \(try Self.json(Locale.preferredLanguages)), "probe": \(raw),
                 "acceptLanguage": \(try Self.json(acceptLanguage ?? ""))}
                """
            Attachment.record(evidence, named: "chromium-languages.json")
            let probe = try JSONDecoder().decode(Probe.self, from: Data(raw.utf8))
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            return (probe, acceptLanguage)
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    @Test(.boundedWebViews)
    func chromiumReportsEnglishWhicheverLocalesAreBundled() async throws {
        // The fallback language the pruning must never remove, and every kept language has its pak.
        let resources = try #require(Bundle.main.privateFrameworksURL)
            .appending(path: "Chromium Embedded Framework.framework/Versions/A/Resources")
        let bundled = try FileManager.default.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".lproj") }
        #expect(bundled.contains("en.lproj"))
        for name in bundled {
            #expect(FileManager.default.fileExists(atPath: resources.appending(path: "\(name)/locale.pak").path), "\(name)")
        }

        let seen = try await observe()
        #expect(seen.probe.language == "en-US")
        #expect(seen.probe.languages == ["en-US", "en"])
        #expect(seen.probe.intlLocale == "en-US")
        #expect(seen.probe.validationMessage == "Please fill out this field.")
        #expect(seen.acceptLanguage == "en-US,en;q=0.9")
    }
}

/// `Tools/prune-chromium-locales.sh`, which `Tools/embed-chromium.sh` runs on the copied Chromium framework before signing it.
struct ChromiumLocalePruningTests {
    private static let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Tools/prune-chromium-locales.sh")

    /// A stand-in for the framework's Resources: lproj directories (languages and gender stubs) with a pak each, plus files.
    private func makeResources() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "WSurf-prune-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in ["en", "en_GB", "en_FEMININE", "hr", "hr_NEUTER", "de", "de_MASCULINE", "zh_CN", "es_419"] {
            let directory = root.appending(path: "\(name).lproj", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("pak".utf8).write(to: directory.appending(path: "locale.pak"))
        }
        try Data("pak".utf8).write(to: root.appending(path: "resources.pak"))
        try Data("plist".utf8).write(to: root.appending(path: "Info.plist"))
        return root
    }

    private func prune(_ resources: URL, keeping locales: String) throws -> (status: Int32, remaining: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [Self.script.path, resources.path, locales]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted()
        return (process.terminationStatus, remaining)
    }

    @Test func keepsOnlyTheNamedLanguagesAndDropsTheirGenderStubs() throws {
        let resources = try makeResources()
        defer { try? FileManager.default.removeItem(at: resources) }
        let result = try prune(resources, keeping: "en en_GB hr")
        #expect(result.status == 0)
        #expect(result.remaining == ["Info.plist", "en.lproj", "en_GB.lproj", "hr.lproj", "resources.pak"])
        #expect(FileManager.default.fileExists(atPath: resources.appending(path: "hr.lproj/locale.pak").path))
    }

    @Test func aBlankListKeepsEveryLanguage() throws {
        let resources = try makeResources()
        defer { try? FileManager.default.removeItem(at: resources) }
        let before = try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted()
        for blank in ["", "  "] {
            let result = try prune(resources, keeping: blank)
            #expect(result.status == 0)
            #expect(result.remaining == before)
        }
    }

    @Test func aListWithoutTheFallbackLanguageIsRefusedAndRemovesNothing() throws {
        let resources = try makeResources()
        defer { try? FileManager.default.removeItem(at: resources) }
        let before = try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted()
        let result = try prune(resources, keeping: "hr en_GB")
        #expect(result.status != 0)
        #expect(result.remaining == before)
    }
}
