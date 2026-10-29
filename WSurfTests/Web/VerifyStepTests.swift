// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What the "Verify" step of a sign-in or payment flow meets in a tab of each engine: a passkey request (Google's "Verify it's
/// you"), and cross-site storage and payment APIs in a frame of another site (a challenge frame). Every page is a real `BrowserTab`
/// of a fresh profile with no vault, on a loopback server: the top page on `localhost` (a relying party no app is associated with)
/// or on 127.0.0.1 with a frame of `localhost`. A click is real input:
/// AppKit events through the window for WebKit, DevTools input for Chromium. Each case prints one `VERIFY` line with what it saw.
@MainActor
@Suite(.serialized)
struct VerifyStepTests {
    // MARK: - Fixture

    /// One button covering the top-left corner; a click runs whatever `plan` names. Results go to `__out` and, in a frame, to the
    /// parent too.
    private static let probe = #"""
        <!doctype html><title>Probe</title>
        <style>body { margin: 0 } #go { position: absolute; left: 0; top: 0; width: 300px; height: 80px }</style>
        <button id="go">Verify</button>
        <script>
          window.__out = [];
          window.__plan = null;
          const report = value => { __out.push(value); if (parent !== window) parent.postMessage({ probe: value }, '*'); };
          const elapsed = started => Math.round(performance.now() - started);
          async function passkey(op) {
            const started = performance.now();
            const challenge = crypto.getRandomValues(new Uint8Array(32));
            const publicKey = op === 'get'
              ? { challenge, rpId: location.hostname, timeout: 4000, userVerification: 'preferred',
                  allowCredentials: [{ type: 'public-key', id: crypto.getRandomValues(new Uint8Array(16)) }] }
              : { challenge, rp: { id: location.hostname, name: 'Probe' }, timeout: 4000,
                  user: { id: new Uint8Array([1]), name: 'ada', displayName: 'Ada' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }] };
            try {
              await navigator.credentials[op]({ publicKey });
              report({ op, outcome: 'resolved', ms: elapsed(started) });
            } catch (error) {
              report({ op, outcome: error.name, message: String(error.message).slice(0, 160), ms: elapsed(started) });
            }
          }
          async function capabilities() {
            const P = window.PublicKeyCredential, value = { present: !!P };
            const ask = async (name, call) => { try { value[name] = await call(); } catch (error) { value[name] = error.name; } };
            await ask('uvpaa', () => P ? P.isUserVerifyingPlatformAuthenticatorAvailable() : null);
            await ask('conditional', () => P && P.isConditionalMediationAvailable ? P.isConditionalMediationAvailable() : null);
            await ask('client', () => P && P.getClientCapabilities ? P.getClientCapabilities() : null);
            report({ op: 'capabilities', value });
          }
          async function storage() {
            const value = {};
            document.cookie = 'probe=1; SameSite=None; Secure';
            value.cookie = document.cookie;
            try { localStorage.setItem('probe', '1'); value.localStorage = localStorage.getItem('probe'); } catch (error) { value.localStorage = error.name; }
            try { value.hasStorageAccess = document.hasStorageAccess ? await document.hasStorageAccess() : 'absent'; } catch (error) { value.hasStorageAccess = error.name; }
            value.paymentRequest = typeof PaymentRequest;
            value.applePaySession = typeof ApplePaySession;
            if (window.PaymentRequest) {
              try {
                const request = new PaymentRequest([{ supportedMethods: 'https://apple.com/apple-pay', data: { version: 3,
                  merchantIdentifier: 'merchant.test', merchantCapabilities: ['supports3DS'], supportedNetworks: ['visa'], countryCode: 'US' } }],
                  { total: { label: 'Probe', amount: { currency: 'USD', value: '1.00' } } });
                value.canMakePayment = await request.canMakePayment();
              } catch (error) { value.canMakePayment = error.name + ': ' + String(error.message).slice(0, 120); }
            }
            report({ op: 'storage', value });
          }
          async function requestStorage() {
            const started = performance.now();
            try { await document.requestStorageAccess(); report({ op: 'requestStorageAccess', outcome: 'granted', ms: elapsed(started) }); }
            catch (error) { report({ op: 'requestStorageAccess', outcome: error.name, message: String(error.message).slice(0, 160), ms: elapsed(started) }); }
          }
          // Apple's sign-in widget: it asks what the browser offers, then starts a conditional request; its "Sign in with Passkey"
          // button ends that request and asks again, with a signal of its own.
          let conditional = null;
          async function conditionalRequest() {
            const P = window.PublicKeyCredential;
            if (P && P.getClientCapabilities) await P.getClientCapabilities();
            const value = P && P.isConditionalMediationAvailable ? await P.isConditionalMediationAvailable() : false;
            report({ op: 'conditional-available', value });
            if (!value) return;
            conditional = new AbortController();
            const started = performance.now();
            navigator.credentials.get({ mediation: 'conditional', signal: conditional.signal,
              publicKey: { challenge: crypto.getRandomValues(new Uint8Array(32)), rpId: location.hostname, timeout: 120000 } })
              .then(() => report({ op: 'conditional', outcome: 'resolved', ms: elapsed(started) }),
                    error => report({ op: 'conditional', outcome: error.name, ms: elapsed(started) }));
          }
          async function passkeySignIn() {
            conditional?.abort();
            const started = performance.now();
            try {
              await navigator.credentials.get({ mediation: 'optional', signal: new AbortController().signal, publicKey: {
                challenge: crypto.getRandomValues(new Uint8Array(32)), rpId: location.hostname, timeout: 120000,
                allowCredentials: [{ type: 'public-key', id: crypto.getRandomValues(new Uint8Array(16)), transports: ['internal', 'hybrid'] }],
                extensions: { largeBlob: { read: true } } } });
              report({ op: 'get', outcome: 'resolved', ms: elapsed(started) });
            } catch (error) {
              report({ op: 'get', outcome: error.name, message: String(error.message).slice(0, 160), ms: elapsed(started) });
            }
          }
          const plans = { get: () => passkey('get'), create: () => passkey('create'), requestStorage, passkeySignIn };
          document.getElementById('go').addEventListener('click', () => plans[window.__plan]?.());
          window.addEventListener('message', event => {
            if (event.data?.plan) window.__plan = event.data.plan;
            if (event.data?.ask === 'capabilities') capabilities();
            if (event.data?.ask === 'storage') storage();
            if (event.data?.ask === 'conditional') conditionalRequest();
          });
          if (parent !== window) parent.postMessage('probe-ready', '*'); else window.__ready = true;
        </script>
        """#

    /// A page of 127.0.0.1 holding the probe of `localhost` in a frame over the same corner, allowed to ask for passkeys and
    /// payments, as a sign-in or payment frame is.
    private static let host = """
        <!doctype html><title>Host</title><style>body { margin: 0 }</style>
        <body>
        <script>
          window.__out = [];
          window.addEventListener('message', event => {
            if (event.data?.probe) __out.push(event.data.probe);
            if (event.data === 'probe-ready') window.__ready = true;
          });
          const frame = document.createElement('iframe');
          frame.allow = 'publickey-credentials-get *; publickey-credentials-create *; payment *';
          frame.src = 'http://localhost:' + location.port + '/probe';
          frame.style = 'position: absolute; left: 0; top: 0; width: 320px; height: 100px; border: 0';
          document.body.append(frame);
        </script>
        """

    /// A page of `localhost` that makes the probe its sign-in frame by script, allowed to ask for passkeys in Apple's words, and
    /// keeps the frame's window at once: Apple's sign-in (idmsa.apple.com, `authService.js`) makes its widget so, a frame of its own
    /// origin. Touching the window makes Chromium set up the frame's first, empty document, which then hands that window on.
    private static let signIn = """
        <!doctype html><title>Sign In</title><style>body { margin: 0 }</style>
        <body>
        <script>
          window.__out = [];
          window.addEventListener('message', event => {
            if (event.data?.probe) __out.push(event.data.probe);
            if (event.data === 'probe-ready') window.__ready = true;
          });
          const frame = document.createElement('iframe');
          frame.allow = 'publickey-credentials-get ' + location.origin + ';bluetooth ' + location.origin;
          frame.src = location.origin + '/probe';
          frame.name = 'aid-auth-widget';
          frame.style = 'position: absolute; left: 0; top: 0; width: 320px; height: 100px; border: 0';
          document.body.append(frame);
          window.__widget = window.frames[frame.name];
        </script>
        """

    enum Placement: String, Sendable, CustomStringConvertible {
        /// The probe is the top page, on `localhost`.
        case top
        /// The probe is a frame of `localhost` in a page of 127.0.0.1.
        case frame
        /// The probe is the sign-in frame a page of its own origin (`localhost`) made.
        case signInFrame

        var description: String {
            rawValue
        }
    }

    // MARK: - Rig

    @MainActor
    private final class Rig {
        let engine: BrowserEngine
        let placement: Placement
        let server: HTTPFixtureServer
        let profile: Profile
        let tab: BrowserTab
        let window: NSWindow
        /// The texts of every sheet the window showed, in order.
        private(set) var sheets: [String] = []

        init(engine: BrowserEngine, placement: Placement, server: HTTPFixtureServer, profile: Profile, tab: BrowserTab, window: NSWindow) {
            self.engine = engine
            self.placement = placement
            self.server = server
            self.profile = profile
            self.tab = tab
            self.window = window
        }

        var page: BrowserPage {
            tab.page
        }

        /// Sends `message` to the probe: itself on top, its frame otherwise.
        func tell(_ message: String) async throws {
            let target = placement == .top ? "window" : "frames[0]"
            _ = try await page.evaluateJavaScript("\(target).postMessage(\(message), '*'); true")
        }

        /// A person's click on the probe's button.
        func click() async throws {
            let point = CGPoint(x: 150, y: 40)
            if let chromium = page.chromium {
                for (type, buttons) in [("mousePressed", 1), ("mouseReleased", 0)] {
                    _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                        "type": type, "x": Double(point.x), "y": Double(point.y), "button": "left", "buttons": buttons, "clickCount": 1,
                    ])
                }
                return
            }
            let native = try #require(page.webKit)
            let location = native.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                )))
            }
        }

        func results() async throws -> [[String: Any]] {
            let json = try await page.evaluateJavaScript("JSON.stringify(window.__out)") as? String ?? "[]"
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        }

        /// Waits for the probe's next result. A sheet that opens meanwhile is read and then closed with its Cancel button, as a
        /// person who reads it and declines would.
        func nextResult(after count: Int, timeout: Duration = .seconds(15)) async throws -> [String: Any]? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let sheet = window.attachedSheet {
                    try await Task.sleep(for: .milliseconds(200))
                    let buttons = Self.buttons(in: sheet.contentView)
                    sheets.append((Self.texts(in: sheet.contentView) + ["buttons: " + buttons.joined(separator: ", ")]).joined(separator: " | "))
                    // NSAlert answers with the first button's code plus the index of the button in the order it was added.
                    let index = buttons.firstIndex(of: String(localized: "Cancel")) ?? max(0, buttons.count - 1)
                    window.endSheet(sheet, returnCode: NSApplication.ModalResponse(
                        rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
                }
                let all = try await results()
                if all.count > count {
                    return all[count]
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }

        private static func texts(in view: NSView?) -> [String] {
            guard let view else { return [] }
            var found: [String] = []
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                found.append(field.stringValue.replacingOccurrences(of: "\n", with: " / "))
            }
            for subview in view.subviews {
                found += texts(in: subview)
            }
            return found
        }

        /// The alert's buttons in the order they were added (NSAlert lays them out right to left).
        private static func buttons(in view: NSView?) -> [String] {
            guard let view else { return [] }
            var found: [(String, CGFloat)] = []
            func walk(_ view: NSView) {
                if let button = view as? NSButton, button.bezelStyle == .push || button.bezelStyle == .rounded {
                    found.append((button.title, button.convert(button.bounds, to: nil).maxX))
                }
                view.subviews.forEach(walk)
            }
            walk(view)
            return found.sorted { $0.1 > $1.1 }.map(\.0)
        }
    }

    private func withRig(
        _ engine: BrowserEngine, _ placement: Placement, privately: Bool = false, body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/probe": .html(Self.probe), "/host": .html(Self.host), "/signin": .html(Self.signIn)])
        let port = try #require(server.url("/").port)
        let top = switch placement {
        case .top:
            "http://localhost:\(port)/probe"
        case .frame:
            "http://127.0.0.1:\(port)/host"
        case .signInFrame:
            "http://localhost:\(port)/signin"
        }
        let topURL = try #require(URL(string: top))
        let profile = try await privately ? Profile.privateBrowsing() : VaultManagerFixture.newProfile("Verify")
        let context = BrowserProfileContext(profile: profile)
        for origin in ["http://localhost:\(port)", "http://127.0.0.1:\(port)"] {
            context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: URL(string: origin)))
        }
        let tab = BrowserTab(opensBlank: false, privately: privately, context: context)
        switch engine {
        case .webKit:
            tab.adopt(BrowserPage(webKit: context.webViewPool.acquire(), context: context))
        case .chromium:
            try ChromiumRuntime.shared.ensureInitialized()
            tab.adopt(BrowserPage(chromium: ChromiumPage(context: context)))
        }
        // Borderless, as in `OpenInNewTabTests`: a window that could become key would take the first click to activate itself.
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        let rig = Rig(engine: engine, placement: placement, server: server, profile: profile, tab: tab, window: window)
        do {
            tab.page.load(URLRequest(url: topURL))
            try #require(await waitUntil { tab.page.url == topURL && !tab.page.isLoading }, "the page loaded")
            try #require(await waitUntil { try await tab.page.evaluateJavaScript("window.__ready === true") as? Bool == true }, "the probe is ready")
            try await Task.sleep(for: .milliseconds(300))
            try await body(rig)
        } catch {
            await close(rig)
            throw error
        }
        await close(rig)
    }

    private static func line(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return "nil"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Passkeys

    /// What a page asks before it offers a passkey. In the top page WSurf's own script answers on both engines and says a passkey
    /// can be offered; in a frame of another site the engine answers, and without Apple's browser entitlement (WebKit) or the
    /// Chromium Touch ID keychain group (Chromium) it has no platform authenticator.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, [Placement.top, .frame])
    func whatAPageLearnsAboutPasskeys(engine: BrowserEngine, placement: Placement) async throws {
        try await withRig(engine, placement) { rig in
            try await rig.tell("{ ask: 'capabilities' }")
            let result = try #require(await rig.nextResult(after: 0), "the probe answered")
            let value = try #require(result["value"] as? [String: Any])
            print("VERIFY capabilities engine=\(engine) placement=\(placement) \(Self.line(value))")
            if placement == .top {
                #expect(value["conditional"] as? Bool == true, "WSurf's script offers conditional sign-in")
                #expect((value["client"] as? [String: Any])?["hybridTransport"] as? Bool == false, "WSurf offers no phone")
            } else {
                #expect(value["uvpaa"] as? Bool == false, "the engine has no platform authenticator here")
            }
        }
    }

    /// A passkey request after a click, on a site WSurf holds no passkey for, in a profile without a vault. The top page gets WSurf's
    /// sheet, which names the site, says WSurf has nothing for it, and sends the person to the site's other way to sign in, with
    /// one button that ends the request as the site's "cancelled". It offers no way out that cannot work: neither engine reaches Apple
    /// Passwords, a phone or a security key. A frame of another site gets the engine's WebAuthn: WebKit's refuses at once in a document
    /// without focus (a test window never has it), and Chromium's ends at once too (`WebAuthnScript.engineRefusal`) where it used to
    /// show nothing and not end (still pending after 100 s, for a request that asked for 4).
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases, [Placement.top, .frame])
    func aPasskeyRequestAfterAClick(engine: BrowserEngine, placement: Placement) async throws {
        for operation in ["get", "create"] {
            try await withRig(engine, placement) { rig in
                try await rig.tell("{ plan: '\(operation)' }")
                try await Task.sleep(for: .milliseconds(100))
                let clicked = ContinuousClock.now
                try await rig.click()
                let result = try #require(await rig.nextResult(after: 0), "the request ended")
                let seconds = clicked.duration(to: .now)
                print("VERIFY passkey engine=\(engine) placement=\(placement) op=\(operation) \(Self.line(result)) wall=\(seconds) sheets=\(rig.sheets)")
                #expect(result["outcome"] as? String == "NotAllowedError")
                if placement == .frame {
                    #expect(rig.sheets.isEmpty && seconds < .seconds(2), "the engine refused at once, showing nothing")
                } else {
                    let advice = operation == "get"
                        ? String(localized: "Choose another way to sign in on the website.")
                        : String(localized: "Choose another way to continue on the website.")
                    #expect(rig.sheets.count == 1, "one sheet")
                    let sheet = rig.sheets.first ?? ""
                    #expect(sheet.contains("localhost") && sheet.contains(advice), "\(sheet)")
                    #expect(sheet.hasSuffix("buttons: " + String(localized: "OK")), "one button: \(sheet)")
                    #expect(!sheet.contains("Chromium"), "no promise of another engine: \(sheet)")
                }
            }
        }
    }

    /// Apple's sign-in, as the Apple Developer account page shows it: a frame of the page's own origin asks what the browser offers,
    /// starts a conditional request, and its "Sign in with Passkey" button ends that request and asks again. WSurf answers the frame as
    /// it answers a top page: conditional sign-in is offered, the conditional request shows nothing by itself and ends when the page
    /// ends it, and the button's request gets WSurf's sheet, then the site's "not allowed". It used to reach no one. WebKit kept its
    /// own WebAuthn in every frame, which without Apple's browser entitlement refuses at once (and Apple's widget then shows nothing).
    /// In Chromium the frame's first, empty document handed its window to the widget's, so WSurf's relay stayed with the empty one:
    /// the widget's questions went unanswered and its request never ended.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aSignInFrameOfThePagesOwnOriginGetsWSurfsSheet(engine: BrowserEngine) async throws {
        try await withRig(engine, .signInFrame) { rig in
            try await rig.tell("{ ask: 'conditional' }")
            let available = try #require(await rig.nextResult(after: 0), "the frame learned whether conditional sign-in is offered")
            #expect(available["value"] as? Bool == true, "WSurf offers conditional sign-in in the frame: \(Self.line(available))")
            try await Task.sleep(for: .seconds(1))
            let quiet = try await rig.results().count == 1
            #expect(rig.window.attachedSheet == nil && quiet, "the conditional request shows nothing by itself")
            try await rig.tell("{ plan: 'passkeySignIn' }")
            try await Task.sleep(for: .milliseconds(100))
            let clicked = ContinuousClock.now
            try await rig.click()
            var outcomes: [String: String] = [:]
            while outcomes["get"] == nil, let result = try await rig.nextResult(after: 1 + outcomes.count) {
                outcomes[result["op"] as? String ?? "?"] = result["outcome"] as? String ?? "?"
            }
            print("VERIFY sign-in frame engine=\(engine) \(outcomes) wall=\(clicked.duration(to: .now)) sheets=\(rig.sheets)")
            #expect(outcomes["get"] == "NotAllowedError", "the button's request ended as the site's \"not allowed\"")
            #expect(outcomes["conditional"] == "AbortError", "the page ended its conditional request")
            #expect(rig.sheets.count == 1, "one sheet")
            let sheet = rig.sheets.first ?? ""
            #expect(sheet.contains("localhost") && sheet.contains(String(localized: "Choose another way to sign in on the website.")), "\(sheet)")
            #expect(sheet.hasSuffix("buttons: " + String(localized: "OK")), "one button: \(sheet)")
        }
    }

    /// A private Chromium page has no vault: WSurf's passkey script hands its request to CEF's own WebAuthn, which used to show
    /// nothing and not end. It now ends at once as not allowed.
    @Test(.boundedWebViews)
    func aPrivateChromiumPagesPasskeyRequestEndsAtOnce() async throws {
        try await withRig(.chromium, .top, privately: true) { rig in
            try await rig.tell("{ plan: 'get' }")
            try await Task.sleep(for: .milliseconds(100))
            let clicked = ContinuousClock.now
            try await rig.click()
            let result = try #require(await rig.nextResult(after: 0), "the request ended")
            let seconds = clicked.duration(to: .now)
            print("VERIFY private engine=chromium \(Self.line(result)) wall=\(seconds) sheets=\(rig.sheets)")
            #expect(result["outcome"] as? String == "NotAllowedError" && seconds < .seconds(2) && rig.sheets.isEmpty)
        }
    }

    // MARK: - A frame of another site

    /// What a frame of another site (a sign-in or challenge frame) can keep and ask for. WebKit blocks its cookies and refuses Storage
    /// Access at once, with no prompt, to a site the person never used as a page of its own; it has no Payment Request API, because
    /// Apple Pay is off (`NativeApplePay`). Chromium keeps its cookies and grants Storage Access without a prompt.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func whatAFrameOfAnotherSiteCanStore(engine: BrowserEngine) async throws {
        try await withRig(engine, .frame) { rig in
            try await rig.tell("{ ask: 'storage' }")
            let stored = try #require(await rig.nextResult(after: 0)?["value"] as? [String: Any], "the probe answered")
            try await rig.tell("{ plan: 'requestStorage' }")
            try await Task.sleep(for: .milliseconds(100))
            try await rig.click()
            let asked = try #require(await rig.nextResult(after: 1), "the request ended")
            print("VERIFY storage engine=\(engine) \(Self.line(stored)) request=\(Self.line(asked)) sheets=\(rig.sheets)")
            #expect(rig.sheets.isEmpty, "no prompt")
            #expect(stored["localStorage"] as? String == "1")
            if engine == .webKit {
                #expect(stored["cookie"] as? String == "" && stored["hasStorageAccess"] as? Bool == false)
                #expect(asked["outcome"] as? String == "NotAllowedError")
                #expect(stored["paymentRequest"] as? String == "undefined" && stored["applePaySession"] as? String == "undefined")
            } else {
                #expect(stored["cookie"] as? String == "probe=1" && asked["outcome"] as? String == "granted")
            }
        }
    }

    private func close(_ rig: Rig) async {
        rig.tab.detach()
        await rig.tab.waitForRetirement()
        rig.window.contentView = nil
        rig.window.close()
        if rig.profile.isPrivate {
            await rig.tab.context.endPrivateSession()
        } else {
            await VaultManagerFixture.erase(rig.profile)
        }
    }
}
