// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A local copy of a proof-of-work bot check of the Hetzner kind: the login redirects to a challenge, the challenge
/// fingerprints the page, solves a puzzle in blob workers, and posts the answer with `form.submit()`. The server
/// keeps the challenge in a cookie and answers a flagged or mismatched answer with a new challenge, which a person
/// sees as a check that restarts until it blocks.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ProofOfWorkChallengeTests {
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theFirstAnswerSignsIn(engine: BrowserEngine) async throws {
        let check = Challenge()
        let server = try await HTTPFixtureServer.start(routes: [:], waitsForBody: true) { check.respond(to: $0) }
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/login")
        let (tab, window) = open(url, in: engine)
        defer { window.close() }

        let finished = await waitUntil(timeout: .seconds(40)) {
            tab.page.title == "Signed in" || check.events.last == "pow: blocked"
        }
        #expect(finished && tab.page.title == "Signed in", "\(tab.page.title ?? "untitled"): \(check.events)")
        #expect(check.events == ["login: challenge", "pow: issued", "pow: accepted", "login: signed in"])
        #expect(tab.page.engine == engine)
        tab.detach()
        await tab.waitForRetirement()
    }

    /// Bot checks read a zero or smaller-than-the-page outer size as a headless browser, and wait while a page is hidden.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func pagesSeeAVisibleWindowOfTheirSize(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Size</title>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/")
        let (tab, window) = open(url, in: engine)
        defer { window.close() }
        #expect(await settled(tab, at: url))

        let script = "[outerWidth, outerHeight, innerWidth, innerHeight, document.visibilityState, document.hidden].join(' ')"
        let reply = try await tab.page.evaluateJavaScript(script) as? String ?? ""
        let fields = reply.split(separator: " ").map(String.init)
        try #require(fields.count == 6, "\(reply)")
        #expect(fields[4] == "visible" && fields[5] == "false", "\(reply)")
        let values = fields.prefix(4).compactMap { Int($0) }
        try #require(values.count == 4, "\(reply)")
        #expect(values[0] == Int(window.frame.width) && values[1] == Int(window.frame.height), "\(values)")
        #expect(values[0] >= values[2] && values[1] >= values[3], "\(values)")
        tab.detach()
        await tab.waitForRetirement()
    }

    private func open(_ url: URL, in engine: BrowserEngine) -> (BrowserTab, NSWindow) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let permissions = SitePermissions(storageURL: storage)
        permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let tab = BrowserTab(
            opensBlank: false, privately: true, sitePermissions: permissions,
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        tab.load(url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        return (tab, window)
    }
}

/// The server half of the check. Requests arrive on the fixture's queue, so state sits behind a lock.
private nonisolated final class Challenge: @unchecked Sendable {
    private let lock = NSLock()
    private var session: String?
    private var clearance: String?
    private var rejections = 0
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func respond(to request: HTTPFixtureServer.Request) -> HTTPFixtureServer.Response? {
        lock.withLock { () -> HTTPFixtureServer.Response? in
            let cookies = Self.fields(request.headers["cookie"] ?? "", separator: ";")
            switch (request.method, request.path) {
            case ("GET", "/login"):
                if let clearance, cookies["clearance"] == clearance {
                    recorded.append("login: signed in")
                    return .html("<!doctype html><title>Signed in</title><p>Welcome</p>")
                }
                recorded.append("login: challenge")
                return Self.redirect("302 Found", to: "/pow", cookie: "strict=1; Path=/; SameSite=Strict; HttpOnly")
            case ("GET", "/pow"):
                guard rejections < 3 else {
                    recorded.append("pow: blocked")
                    return HTTPFixtureServer.Response(status: "429 Too Many Requests", headers: [:], body: Data("Blocked".utf8))
                }
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                session = token
                recorded.append("pow: issued")
                return .html(Self.page(token), headers: ["Set-Cookie": "session=\(token); Path=/; SameSite=Lax; HttpOnly"])
            case ("POST", "/pow"):
                if let reason = rejection(of: request, cookies: cookies) {
                    rejections += 1
                    recorded.append("pow: rejected, \(reason)")
                    return Self.redirect("303 See Other", to: "/pow")
                }
                let token = UUID().uuidString
                clearance = token
                recorded.append("pow: accepted")
                return Self.redirect("303 See Other", to: "/login", cookie: "clearance=\(token); Path=/; SameSite=Strict; HttpOnly")
            case ("GET", "/module.wasm"):
                return .bytes(Self.module, contentType: "application/wasm")
            default:
                return nil
            }
        }
    }

    private func rejection(of request: HTTPFixtureServer.Request, cookies: [String: String]) -> String? {
        guard request.headers["content-type"]?.hasPrefix("application/x-www-form-urlencoded") == true else {
            return "content type \(request.headers["content-type"] ?? "none")"
        }
        guard let session, cookies["session"] == session else {
            return "session cookie \(cookies["session"] ?? "missing")"
        }
        guard cookies["strict"] == "1" else { return "no SameSite=Strict cookie" }
        let form = Self.fields(String(decoding: request.body, as: UTF8.self), separator: "&")
        let hsum = form["hsum"] ?? ""
        guard hsum == "clean" else { return "fingerprint \(hsum)" }
        let answer = (form["challenge"] ?? "").split(separator: ".", maxSplits: 1).map(String.init)
        guard answer.count == 2, Self.solves("\(session)|\(hsum)|\(answer[0])|\(answer[1])") else {
            return "answer \(form["challenge"] ?? "missing")"
        }
        return nil
    }

    /// FNV-1a over ASCII, so the page and the server hash the same bytes.
    private static func solves(_ text: String) -> Bool {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash % 64 == 0
    }

    private static func fields(_ text: String, separator: Character) -> [String: String] {
        text.split(separator: separator).reduce(into: [:]) { fields, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: " ")
            }
            guard parts.count == 2 else { return }
            fields[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
    }

    private static func redirect(_ status: String, to path: String, cookie: String? = nil) -> HTTPFixtureServer.Response {
        var headers = ["Location": path]
        headers["Set-Cookie"] = cookie
        return HTTPFixtureServer.Response(status: status, headers: headers, body: Data())
    }

    /// `(module (func (export "f") (result i32) i32.const 42))`
    private static let module = Data([
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B,
    ])

    /// The same order of work as the real check: fingerprint, then workers, then wait until visible, then post.
    private static func page(_ token: String) -> String {
        #"""
        <!doctype html><title>Security Check</title>
        <input type="hidden" id="mainbytes" value="\#(token)">
        <form method="POST" action="/pow" id="form">
          <input type="hidden" name="challenge" id="challenge"><input type="hidden" name="hsum" id="hsum">
        </form>
        <script id="worker1" type="javascript/worker">
        function fnv(s) { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h >>> 0; }
        onmessage = e => { let n = 0; while (fnv(e.data + '|' + n) % 64 !== 0) n++; postMessage(n); };
        </script>
        <script>
        addEventListener('gotcha', () => {
          const source = document.querySelector('#worker1');
          const blob = new Blob([source.textContent], { type: 'text/javascript' });
          source.remove();
          const started = Date.now();
          const cores = navigator.hardwareConcurrency || 1;
          const count = cores >= 2 ? Math.min(Math.floor(cores / 2), 8) : 1;
          const workers = [];
          let answered = false;
          for (let i = 0; i < count; i++) {
            const worker = new Worker(URL.createObjectURL(blob));
            worker.onmessage = event => {
              const poll = setInterval(() => {
                if (document.hidden) { document.title = 'Waiting while hidden'; return; }
                clearInterval(poll);
                if (answered) return;
                answered = true;
                workers.forEach(w => w.terminate());
                setTimeout(() => {
                  document.getElementById('challenge').value = i + '.' + event.data;
                  document.getElementById('form').submit();
                }, Math.max(50, 650 - (Date.now() - started)));
              }, 55);
            };
            worker.postMessage(document.getElementById('mainbytes').value + '|' + document.getElementById('hsum').value + '|' + i);
            workers.push(worker);
          }
        });
        (async () => {
          let flags = '';
          try {
            const loaded = await WebAssembly.instantiateStreaming(fetch('/module.wasm'));
            if (loaded.instance.exports.f() !== 42) flags += 'a';
          } catch (e) { flags += 'a'; }
          const draw = () => {
            const canvas = document.createElement('canvas');
            canvas.width = 220; canvas.height = 60;
            const c = canvas.getContext('2d');
            c.shadowBlur = 4; c.shadowColor = 'red'; c.rotate(0.05);
            c.fillStyle = '#f60'; c.font = '16px sans-serif'; c.fillText('Cwm fjordbank glyphs', 4, 30);
            c.globalCompositeOperation = 'multiply'; c.fillStyle = 'rgb(0,128,255)';
            c.beginPath(); c.arc(50, 25, 20, 0, 7); c.fill();
            return canvas.toDataURL();
          };
          if (draw() !== draw()) flags += 'c';
          // The real check reads this one through eval of a constant string.
          if (eval('!!navigator.webdriver')) flags += 'w';
          if (!outerWidth || !outerHeight) flags += 'o';
          document.getElementById('hsum').value = flags || 'clean';
          dispatchEvent(new Event('gotcha'));
        })();
        </script>
        """#
    }
}
