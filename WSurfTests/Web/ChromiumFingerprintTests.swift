// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What a page can read about the Chromium engine: no DevTools Runtime domain, no WSurf globals in its main world, and
/// client hints that match the user agent with and without an override.
@MainActor
@Suite(.serialized)
struct ChromiumFingerprintTests {
    private static let probe = """
        (async () => {
          const data = navigator.userAgentData;
          const high = await data.getHighEntropyValues(['architecture', 'bitness', 'model', 'platformVersion', 'fullVersionList']);
          const worker = await new Promise((resolve, reject) => {
            const worker = new Worker('/worker.js');
            worker.onmessage = event => resolve(event.data);
            worker.onerror = () => reject(new Error('worker failed'));
          });
          return JSON.stringify({
            userAgent: navigator.userAgent, worker,
            brands: data.brands, mobile: data.mobile, platform: data.platform,
            architecture: high.architecture, bitness: high.bitness, model: high.model,
            platformVersion: high.platformVersion, fullVersionList: high.fullVersionList,
            wsurfKeys: Object.getOwnPropertyNames(globalThis).filter(key => key.startsWith('__wsurf')),
          });
        })()
        """

    private struct Probe: Decodable, Equatable {
        struct Brand: Decodable, Equatable {
            let brand: String
            let version: String
        }

        let userAgent: String
        let worker: String
        let brands: [Brand]
        let mobile: Bool
        let platform: String
        let architecture: String
        let bitness: String
        let model: String
        let platformVersion: String
        let fullVersionList: [Brand]
        let wsurfKeys: [String]

        /// Everything but the user agent strings, which the override changes on purpose.
        var hints: [String] {
            [
                brands.map { "\($0.brand)/\($0.version)" }.joined(separator: ","), "\(mobile)", platform, architecture, bitness,
                model, platformVersion, fullVersionList.map { "\($0.brand)/\($0.version)" }.joined(separator: ","),
            ]
        }
    }

    @Test(.boundedWebViews)
    func pagesSeeNoDevToolsRuntimeAndConsistentClientHints() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Fingerprint</title>"),
            "/worker.js": .bytes(Data("postMessage(navigator.userAgent);".utf8), contentType: "text/javascript"),
        ])
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let profile = Profile(id: UUID(), name: "Fingerprint regression", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        var commands: [(method: String, params: [String: Any])] = []
        native.devTools.commandObserver = { commands.append(($0, $1)) }
        let page = BrowserPage(chromium: native)
        let world = WKContentWorld.world(name: "WSurfFingerprint")
        var messages: [BrowserScriptMessage] = []
        page.addScriptMessageHandler(name: "fingerprintProbe", in: world) { messages.append($0) }
        // Sent at document start, before native can bind the world: it must be queued, not lost.
        page.installScript("globalThis.__wsurfSend('fingerprintProbe', location.pathname);", in: world,
                           injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let suite = "ChromiumFingerprint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = BrowserSettings(defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }

        func load() async throws -> Probe {
            messages.removeAll()
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            let raw = try #require(try await page.evaluateJavaScript(Self.probe, in: nil, contentWorld: .page) as? String)
            return try JSONDecoder().decode(Probe.self, from: Data(raw.utf8))
        }

        func requestHeaders() throws -> [String: String] {
            let head = try #require(server.lastRequestHead(for: "/"))
            return head.split(separator: "\r\n").dropFirst().reduce(into: [:]) { fields, line in
                guard let colon = line.firstIndex(of: ":") else { return }
                fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        do {
            // The first load applies the application's settings; the probes below use this test's own.
            _ = try await load()
            settings.userAgentMode = .safari
            try await native.applySettings(settings)
            let genuine = try await load()
            let genuineHeaders = try requestHeaders()
            let mainFrame = try #require(try await native.frames().first(where: \.isMainFrame))
            try #require(await waitUntil { messages.contains { $0.body as? String == "/" } })
            #expect(messages.first?.frameInfo.documentID == mainFrame.documentID)

            settings.userAgentMode = .wsurf
            try await native.applySettings(settings)
            let overridden = try await load()
            let overriddenHeaders = try requestHeaders()
            try #require(await waitUntil { messages.contains { $0.body as? String == "/" } })

            #expect(!genuine.brands.isEmpty)
            #expect(genuine.wsurfKeys.isEmpty)
            #expect(genuine.worker == genuine.userAgent)
            #expect(genuineHeaders["sec-ch-ua"]?.isEmpty == false)
            #expect(genuineHeaders["user-agent"] == genuine.userAgent)

            #expect(overridden.userAgent == "\(genuine.userAgent) WSurf/\(UpdateFeed.currentVersion)")
            #expect(overridden.worker == overridden.userAgent)
            #expect(overridden.hints == genuine.hints)
            #expect(overridden.wsurfKeys.isEmpty)
            #expect(overriddenHeaders["user-agent"] == overridden.userAgent)
            #expect(overriddenHeaders["sec-ch-ua"] == genuineHeaders["sec-ch-ua"])
            #expect(overriddenHeaders["sec-ch-ua-platform"] == genuineHeaders["sec-ch-ua-platform"])

            let mainWorld = try await page.evaluateJavaScript(
                "[typeof __wsurfSend, typeof __wsurfNative, typeof window.webkit].join()", in: nil, contentWorld: .page
            ) as? String
            #expect(mainWorld == "undefined,undefined,undefined")

            let methods = commands.map(\.method)
            #expect(!methods.contains("Runtime.enable"))
            #expect(methods.contains("Runtime.addBinding"))
            // Every binding names one recorded isolated-world context; none is global or reaches the main world.
            for command in commands where command.method == "Runtime.addBinding" {
                #expect(command.params["executionContextId"] is Int)
                #expect(command.params["executionContextName"] == nil)
            }

            settings.userAgentMode = .safari
            try await native.applySettings(settings)
            #expect(try await load().userAgent == genuine.userAgent)
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }

    /// The page world's relay reaches page-world handlers through the bridge world, and the main world never gets the
    /// native binding.
    @Test(.boundedWebViews)
    func pageWorldMessagesArriveWithoutAMainWorldBinding() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Relay</title><iframe src='/child'></iframe>"),
            "/child": .html("<!doctype html><title>Child</title>"),
        ])
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let profile = Profile(id: UUID(), name: "Relay regression", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        var messages: [BrowserScriptMessage] = []
        page.addScriptMessageHandler(name: "pageProbe", in: .page) { messages.append($0) }
        page.installScript("__wsurfSend('pageProbe', [location.pathname, typeof __wsurfNative]);", in: .page,
                           injectionTime: .atDocumentEnd, forMainFrameOnly: false)
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
            try #require(await waitUntil { messages.count == 2 })
            let frames = try await native.frames()
            let bodies = Set(messages.compactMap { ($0.body as? [Any])?.compactMap { $0 as? String }.joined(separator: ",") })
            #expect(bodies == ["/,undefined", "/child,undefined"])
            for message in messages {
                #expect(frames.contains { $0.documentID == message.frameInfo.documentID })
            }
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }
}
