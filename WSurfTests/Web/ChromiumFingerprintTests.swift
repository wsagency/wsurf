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
        let suite = AppDatabase.defaultsSuite("ChromiumFingerprint-\(UUID().uuidString)")
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

    /// A context ID can name another document's context once a navigation commits in a new renderer process. The guard
    /// every evaluation carries refuses to run there: another document's marker or another origin is stale.
    @Test(.boundedWebViews)
    func evaluationsRefuseAnotherDocumentOrOrigin() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Guard</title>")])
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let profile = Profile(id: UUID(), name: "Guard regression", symbol: "globe", color: .gray)
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
            #expect(try await page.evaluateJavaScript("location.pathname", in: nil, contentWorld: .defaultClient) as? String == "/")
            #expect(try await page.evaluateJavaScript("location.pathname", in: nil, contentWorld: .page) as? String == "/")
            let devTools = native.devTools
            let world = devTools.worldName(.defaultClient)
            let isolated = try #require(devTools.contextsByUniqueID.values.first { $0.worldName == world })
            let main = try #require(devTools.contextsByUniqueID.values.first { $0.worldName.isEmpty })

            func run(in target: ChromiumDevTools.ContextState, guardedAs aimed: ChromiumDevTools.ContextState) async throws -> Any {
                let response = try await devTools.command("Runtime.evaluate", params: devTools.address(target).merging([
                    "expression": devTools.documentGuard(aimed) + "'ran'", "returnByValue": true,
                ]) { $1 })
                return try devTools.runtimeValue(response)
            }
            func refused(_ target: ChromiumDevTools.ContextState, as aimed: ChromiumDevTools.ContextState) async -> Bool {
                do {
                    _ = try await run(in: target, guardedAs: aimed)
                    return false
                } catch ChromiumError.staleFrame {
                    return true
                } catch {
                    return false
                }
            }

            #expect(try await run(in: isolated, guardedAs: isolated) as? String == "ran")
            #expect(try await run(in: main, guardedAs: main) as? String == "ran")
            var otherDocument = isolated
            otherDocument.documentID = "another-document"
            #expect(await refused(isolated, as: otherDocument))
            // The page's main world never holds the marker, so a script aimed at an isolated world refuses to run there.
            #expect(await refused(main, as: isolated))
            let port = try #require(url.port)
            #expect(devTools.framesByID[main.frameID]?.serializedOrigin == "http://127.0.0.1:\(port)")
            devTools.framesByID[main.frameID]?.serializedOrigin = "https://another.example"
            #expect(await refused(main, as: main))
            #expect(await refused(isolated, as: isolated))
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }

    /// Records what a page can read about the engine, as evidence (`chromium-signals-*.json` attachments), and holds the
    /// signals a Chrome browser must not show: `navigator.webdriver`, a DevTools client serializing console arguments,
    /// own `navigator` properties, empty languages, a zero-sized window, and a worker user agent unlike the page's.
    @Test(.boundedWebViews)
    func pageVisibleSignalsMatchAChromeBrowser() async throws {
        let serviceWorker = """
            self.addEventListener('install', () => self.skipWaiting());
            self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
            self.addEventListener('message', event => event.source.postMessage(navigator.userAgent));
            """
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Signals</title>"),
            "/worker.js": .bytes(Data("postMessage(navigator.userAgent);".utf8), contentType: "text/javascript"),
            "/sw.js": .bytes(Data(serviceWorker.utf8), contentType: "text/javascript"),
        ])
        let url = try server.url("/")
        try ChromiumRuntime.shared.ensureInitialized()
        let profile = Profile(id: UUID(), name: "Signals", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let suite = AppDatabase.defaultsSuite("ChromiumSignals-\(UUID().uuidString)")
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

        struct Signals: Decodable {
            let webdriver: Bool?
            let consoleSerialized: Bool
            let navigatorOwnKeys: [String]
            let languages: [String]
            let outer: [Double]
            let userAgent: String
            let worker: String
            let serviceWorker: String
        }

        func probe(_ name: String) async throws -> Signals {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            let raw = try #require(try await page.evaluateJavaScript(Self.signalsProbe, in: nil, contentWorld: .page) as? String)
            let head = server.lastRequestHead(for: "/") ?? ""
            Attachment.record("{\"signals\": \(raw), \"requestHead\": \(native.devTools.jsonLiteral(head))}", named: "chromium-signals-\(name).json")
            return try JSONDecoder().decode(Signals.self, from: Data(raw.utf8))
        }

        do {
            _ = try await probe("initial")
            settings.userAgentMode = .safari
            try await native.applySettings(settings)
            let genuine = try await probe("genuine")
            settings.userAgentMode = .wsurf
            try await native.applySettings(settings)
            let overridden = try await probe("wsurf")

            for signals in [genuine, overridden] {
                #expect(signals.webdriver == false)
                #expect(!signals.consoleSerialized)
                #expect(signals.navigatorOwnKeys.isEmpty)
                #expect(!signals.languages.isEmpty)
                #expect(signals.outer.prefix(2).allSatisfy { $0 > 0 })
                #expect(signals.worker == signals.userAgent)
            }
            // An override does not reach service workers (they keep the engine's own string), so only the default holds here.
            #expect(genuine.serviceWorker == genuine.userAgent)
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }

    private static let signalsProbe = """
        (async () => {
          const settle = (promise, fallback) => Promise.race([promise, new Promise(resolve => setTimeout(() => resolve(fallback), 3000))]);
          const query = async name => { try { return (await navigator.permissions.query({name})).state; } catch (error) { return 'error:' + error.name; } };
          const native = value => typeof value === 'function' && Function.prototype.toString.call(value).includes('[native code]');
          let webgl = null;
          try {
            const gl = document.createElement('canvas').getContext('webgl');
            const info = gl?.getExtension('WEBGL_debug_renderer_info');
            webgl = gl ? [gl.getParameter(info ? info.UNMASKED_VENDOR_WEBGL : gl.VENDOR), gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER)] : null;
          } catch (error) { webgl = 'error:' + error.name; }
          // A getter on an error's stack runs only when a DevTools client with the Runtime domain serializes the argument.
          let consoleSerialized = false;
          const bait = new Error('bait');
          Object.defineProperty(bait, 'stack', {get() { consoleSerialized = true; return ''; }});
          console.debug(bait);
          const worker = await settle(new Promise(resolve => {
            const dedicated = new Worker('/worker.js');
            dedicated.onmessage = event => resolve(event.data);
            dedicated.onerror = () => resolve('error');
          }), 'timeout');
          const serviceWorker = await settle((async () => {
            const registration = await navigator.serviceWorker.register('/sw.js');
            await navigator.serviceWorker.ready;
            const active = registration.active;
            return await new Promise(resolve => {
              navigator.serviceWorker.addEventListener('message', event => resolve(event.data), {once: true});
              navigator.serviceWorker.startMessages();
              active.postMessage('ua');
            });
          })().catch(error => 'error:' + error.name), 'timeout');
          const voices = await settle(new Promise(resolve => {
            const now = speechSynthesis.getVoices();
            if (now.length > 0) return resolve(now.length);
            speechSynthesis.addEventListener('voiceschanged', () => resolve(speechSynthesis.getVoices().length), {once: true});
          }), 0);
          const devices = await settle(navigator.mediaDevices?.enumerateDevices?.().then(list => list.map(device => device.kind)) ?? Promise.resolve(null), 'timeout');
          const chrome = globalThis.chrome;
          return JSON.stringify({
            webdriver: navigator.webdriver, consoleSerialized,
            navigatorOwnKeys: Object.getOwnPropertyNames(navigator),
            userAgent: navigator.userAgent, worker, serviceWorker,
            uaDataPlatform: navigator.userAgentData?.platform ?? null, platform: navigator.platform, vendor: navigator.vendor,
            languages: navigator.languages, language: navigator.language,
            plugins: Array.from(navigator.plugins, plugin => plugin.name), mimeTypes: Array.from(navigator.mimeTypes, type => type.type),
            pdfViewerEnabled: navigator.pdfViewerEnabled ?? null,
            chrome: typeof chrome, chromeKeys: chrome ? Object.keys(chrome).sort() : null,
            chromeApp: chrome?.app ? Object.keys(chrome.app).sort() : null, chromeRuntime: typeof chrome?.runtime,
            chromeLoadTimes: native(chrome?.loadTimes), chromeCsi: native(chrome?.csi),
            hardwareConcurrency: navigator.hardwareConcurrency, deviceMemory: navigator.deviceMemory ?? null,
            outer: [outerWidth, outerHeight, innerWidth, innerHeight, screen.width, screen.height, devicePixelRatio],
            notification: typeof Notification === 'function' ? Notification.permission : 'missing',
            notificationQuery: await query('notifications'), geolocationQuery: await query('geolocation'),
            cameraQuery: await query('camera'), microphoneQuery: await query('microphone'),
            permissionsQueryNative: native(navigator.permissions?.query),
            webgl, voices, devices,
            connection: navigator.connection ? {rtt: navigator.connection.rtt, effectiveType: navigator.connection.effectiveType} : null,
            timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            webkitTemporaryStorage: typeof navigator.webkitTemporaryStorage,
            historyLength: history.length,
          });
        })()
        """

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
