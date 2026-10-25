// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A real right-click on a page: a trusted contextmenu event in the frame under the point. The page cancels the event, as every
/// fixture here does, so no menu opens. WebKit gets the mouse events through its window, Chromium through DevTools input.
@MainActor
enum PageRightClick {
    static func send(at point: CGPoint, in page: BrowserPage, window: NSWindow) async throws {
        if let chromium = page.chromium {
            for (type, buttons) in [("mousePressed", 2), ("mouseReleased", 0)] {
                _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                    "type": type, "x": Double(point.x), "y": Double(point.y), "button": "right", "buttons": buttons, "clickCount": 1,
                ])
            }
            return
        }
        let native = try #require(page.webKit)
        let location = native.convert(point, to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0
            )))
        }
    }

    /// The middle of element `id` in the page's viewport points; `frame` is the document it is in, inside the page's one iframe.
    static func center(of id: String, in page: BrowserPage, frame: BrowserFrame? = nil) async throws -> CGPoint {
        func numbers(_ value: Any?) -> [Double] {
            (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        }
        let inner = numbers(try await page.callAsyncJavaScript(
            "const r = document.getElementById(id).getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2];",
            arguments: ["id": id], in: frame, contentWorld: PasswordAutofill.world
        ))
        try #require(inner.count == 2, "\(id) is on the page")
        guard let frame, !frame.isMainFrame else { return CGPoint(x: inner[0], y: inner[1]) }
        let outer = numbers(try await page.callAsyncJavaScript(
            "const f = document.querySelector('iframe'); const r = f.getBoundingClientRect(); return [r.x + f.clientLeft, r.y + f.clientTop];",
            arguments: [:], in: nil, contentWorld: PasswordAutofill.world
        ))
        try #require(outer.count == 2, "the iframe is on the page")
        return CGPoint(x: outer[0] + inner[0], y: outer[1] + inner[1])
    }
}

/// Pick Credential…'s page side in both engines, from real right-clicks: the frame the click landed in records the field, and a fill
/// reaches that field and its partner only, in that frame only, once. An iframe is its own frame with its own record; a cross-origin
/// one is the same fixture server under another host name.
@MainActor
struct CredentialPickerScriptTests {
    private final class Harness {
        let page: BrowserPage
        let window: NSWindow
        private(set) var contexts: [(body: [String: Any], frame: BrowserFrame)] = []
        private(set) var readyFrames: [BrowserFrame] = []

        init(page: BrowserPage, window: NSWindow) {
            self.page = page
            self.window = window
        }

        func receive(_ message: BrowserScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["action"] as? String {
            case "context":
                contexts.append((body, message.frameInfo))
            case "ready":
                readyFrames.append(message.frameInfo)
            default:
                break
            }
        }

        var subframe: BrowserFrame? {
            readyFrames.last { !$0.isMainFrame }
        }

        /// Right-clicks element `id` (in `frame`, the iframe's document, when given) and returns what that frame's script reported.
        func rightClick(_ id: String, in frame: BrowserFrame? = nil) async throws -> (body: [String: Any], frame: BrowserFrame) {
            let point = try await PageRightClick.center(of: id, in: page, frame: frame)
            let count = contexts.count
            try await PageRightClick.send(at: point, in: page, window: window)
            try #require(await waitUntil { self.contexts.count > count }, "the right-click on \(id) reached its frame")
            return contexts[contexts.count - 1]
        }

        /// `__wsurfPasswords.pickFill` with a right-click's token, in `frame` (the frame that reported it, unless another is named).
        func fill(
            _ context: (body: [String: Any], frame: BrowserFrame), in frame: BrowserFrame? = nil, _ fields: [String: Any]
        ) async throws -> Int {
            let answer = try await page.callAsyncJavaScript(
                "return globalThis.__wsurfPasswords.pickFill(token, url, fields);",
                arguments: ["token": context.body["token"] as? String ?? "", "url": context.body["url"] as? String ?? "", "fields": fields],
                in: frame ?? context.frame, contentWorld: PasswordAutofill.world
            )
            return (answer as? NSNumber)?.intValue ?? 0
        }

        func value(_ id: String, in frame: BrowserFrame? = nil) async throws -> String? {
            try await page.callAsyncJavaScript(
                "return document.getElementById(id).value;", arguments: ["id": id], in: frame, contentWorld: PasswordAutofill.world
            ) as? String
        }

        func values(_ ids: [String], in frame: BrowserFrame? = nil) async throws -> [String] {
            var result: [String] = []
            for id in ids {
                result.append(try await value(id, in: frame) ?? "?")
            }
            return result
        }

        func classification(_ id: String) async throws -> String? {
            try await page.callAsyncJavaScript(
                "return globalThis.__wsurfAutofillForms.field(document.getElementById(id))?.kind ?? null;",
                arguments: ["id": id], in: nil, contentWorld: PasswordAutofill.world
            ) as? String
        }
    }

    private static let cancel = "<script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"

    private static func page(crossOriginFrame: Bool) -> String {
        let host = crossOriginFrame ? "'localhost:' + location.port" : "location.host"
        return cancel + #"""
        <form id="a"><input id="au" autocomplete="username"><input id="ap" type="password"></form>
        <form id="b"><input id="bu" name="email" type="email"><input id="bp" type="password"></form>
        <p id="text">Some text</p>
        <div><input id="pin" name="pin" inputmode="numeric" maxlength="6"></div>
        <div><input id="d1" maxlength="1"><input id="d2" maxlength="1"><input id="d3" maxlength="1">
        <input id="d4" maxlength="1"><input id="d5" maxlength="1"><input id="d6" maxlength="1"><button>Verify</button></div>
        <form action="https://elsewhere.example/collect"><input id="xu"><input id="xp" type="password"></form>
        <script>
        const frame = document.createElement('iframe');
        frame.src = location.protocol + '//' + \#(host) + '/frame';
        frame.width = 400; frame.height = 120;
        document.body.append(frame);
        </script>
        """#
    }

    private static let frame = cancel + #"<form><input id="fu" autocomplete="username"><input id="fp" type="password"></form>"#

    private func withHarness(
        _ engine: BrowserEngine, crossOriginFrame: Bool = false, body: (Harness) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><html><body>\(Self.page(crossOriginFrame: crossOriginFrame))</body></html>"),
            "/frame": .html("<!doctype html><html><body>\(Self.frame)</body></html>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration), context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        let harness = Harness(page: page, window: window)
        page.installScript(PasswordAutofillScript.source, in: PasswordAutofill.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { harness.receive($0) }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(await waitUntil { harness.readyFrames.contains(where: \.isMainFrame) })
            if !(engine == .chromium && crossOriginFrame) {
                try #require(await waitUntil { harness.subframe != nil }, "the iframe's script is ready")
            }
            // What the policy sends a profile with password autofill on; the private test profile would get false.
            for frame in harness.readyFrames {
                _ = try await page.callAsyncJavaScript(
                    "globalThis.__wsurfPasswords.setEnabled(true);", arguments: [:], in: frame, contentWorld: PasswordAutofill.world
                )
            }
            try await body(harness)
        } catch {
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        await page.close()
        await context.endPrivateSession()
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theRightClickedFieldAndItsPartnerTakeTheLoginAndNothingElseDoes(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("bu")
            #expect(click.frame.isMainFrame && click.body["field"] as? String == "text")
            #expect(UUID(uuidString: click.body["token"] as? String ?? "") != nil)

            #expect(try await harness.fill(click, ["username": "ada@example.test", "password": "dummy-secret"]) == 2)

            #expect(try await harness.values(["bu", "bp"]) == ["ada@example.test", "dummy-secret"])
            #expect(try await harness.values(["au", "ap", "pin", "xu", "xp"]) == ["", "", "", "", ""])
            let frame = try #require(harness.subframe)
            #expect(try await harness.values(["fu", "fp"], in: frame) == ["", ""])
            #expect(try await harness.fill(click, ["username": "again", "password": "again"]) == 0, "a right-click fills once")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aRightClickedPasswordFieldTakesThePasswordAndItsUsernameFieldTheUsername(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("ap")
            #expect(click.body["field"] as? String == "password")

            #expect(try await harness.fill(click, ["username": "ada", "password": "dummy-secret"]) == 2)

            #expect(try await harness.values(["au", "ap", "bu", "bp"]) == ["ada", "dummy-secret", "", ""])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aCodeGoesIntoTheRightClickedFieldThatNothingCallsACode(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            #expect(try await harness.classification("pin") == nil, "the automatic offer does not know this field")
            let click = try await harness.rightClick("pin")
            #expect(click.body["field"] as? String == "code")

            #expect(try await harness.fill(click, ["code": "123456"]) == 1)

            #expect(try await harness.values(["pin", "au", "ap", "d1"]) == ["123456", "", "", ""])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aCodeSplitOverBoxesGoesBoxByBox(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("d1")
            #expect(click.body["field"] as? String == "code")

            #expect(try await harness.fill(click, ["code": "246813"]) == 6)

            #expect(try await harness.values(["d1", "d2", "d3", "d4", "d5", "d6", "pin"]) == ["2", "4", "6", "8", "1", "3", ""])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aPasswordIsNeverFilledIntoAFormThatSendsItToAnotherSite(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("xu")

            #expect(try await harness.fill(click, ["username": "ada", "password": "dummy-secret"]) == -1)

            #expect(try await harness.values(["xu", "xp"]) == ["", ""], "nothing at all is filled")
        }
    }

    /// The frame's own record and fill, asserted by `frameTakesItsOwnRightClickAlone`.
    private func checkFrameIsolation(_ harness: Harness, frameHost: String) async throws {
        let frame = try #require(harness.subframe)
        let inFrame = try await harness.rightClick("fu", in: frame)
        #expect(!inFrame.frame.isMainFrame && inFrame.frame.securityOrigin.host == frameHost)

        let main = try #require(harness.readyFrames.first { $0.isMainFrame })
        #expect(try await harness.fill(inFrame, in: main, ["username": "ada", "password": "dummy-secret"]) == 0,
                "the main frame does not know the frame's right-click")
        #expect(try await harness.fill(inFrame, ["username": "ada", "password": "dummy-secret"]) == 2)
        #expect(try await harness.values(["fu", "fp"], in: frame) == ["ada", "dummy-secret"])
        #expect(try await harness.values(["au", "ap", "bu", "bp"]) == ["", "", "", ""])

        let inMain = try await harness.rightClick("au")
        #expect(try await harness.fill(inMain, in: frame, ["username": "x", "password": "y"]) == 0,
                "a frame the person did not right-click in takes nothing")
        #expect(try await harness.values(["fu", "fp"], in: frame) == ["ada", "dummy-secret"])
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aRightClickInAnIframeBelongsToThatFrameAlone(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            try await checkFrameIsolation(harness, frameHost: "127.0.0.1")
        }
    }

    /// WebKit runs the page scripts in a cross-origin iframe too. Chromium runs them only in frames of the page's own process (its
    /// DevTools session attaches to no other target), so under site isolation a cross-origin iframe gets none: neither the dropdown
    /// nor Pick Credential… works there yet (Phase A).
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aRightClickInAnotherSitesFrameBelongsToThatFrameAlone(engine: BrowserEngine) async throws {
        try await withHarness(engine, crossOriginFrame: true) { harness in
            if engine == .chromium {
                await withKnownIssue("Chromium: no WSurf page script in a cross-origin (out-of-process) iframe") {
                    #expect(await waitUntil(timeout: .seconds(8)) { harness.subframe != nil })
                }
                return
            }
            try await checkFrameIsolation(harness, frameHost: "localhost")
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aRightClickOnSomethingElseForgetsTheEarlierField(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let field = try await harness.rightClick("au")
            let text = try await harness.rightClick("text")
            #expect(text.body["token"] is NSNull || text.body["token"] == nil, "no field, no token")

            #expect(try await harness.fill(field, ["username": "ada", "password": "dummy-secret"]) == 0)
            #expect(try await harness.values(["au", "ap"]) == ["", ""])
        }
    }

    /// Phase A: second-factor fields whose names say so are codes for the automatic offer too; a card's security code is not.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func secondFactorFieldsAreCodes(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            _ = try await harness.page.callAsyncJavaScript("""
                document.body.insertAdjacentHTML('beforeend', `
                  <form><input id="totp" name="totp"></form><form><input id="mfa" name="mfaCode"></form>
                  <form><input id="two" name="twoFactorToken"></form><form><input id="fa" name="2fa_code"></form>
                  <form><input id="otp" placeholder="Enter OTP"></form><form><input id="sec" placeholder="Security code"></form>
                  <form><input id="mfaon" name="mfaEnabled"></form>`);
                """, arguments: [:], in: nil, contentWorld: PasswordAutofill.world)
            for id in ["totp", "mfa", "two", "fa", "otp"] {
                #expect(try await harness.classification(id) == "one-time-code", "\(id)")
            }
            #expect(try await harness.classification("sec") == nil, "a security code may be a card's")
            #expect(try await harness.classification("mfaon") != "one-time-code", "a setting about a second factor is no code")
        }
    }
}
