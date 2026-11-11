// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A real right-click on a page: a trusted contextmenu event in the frame under the point. The page cancels the event, as every
/// fixture here does, so no menu opens. WebKit gets the mouse events through its window, Chromium through DevTools input.
@MainActor
enum PageRightClick {
    private static let inputSeen = "wsurfInputSeen"

    /// Chromium takes no input into a page it has not drawn yet: the first page of a fresh process can drop a single click, and
    /// nothing re-sends it. Installed before the first load, this records in the page that a mouse event reached it, so a test
    /// can wait for that positive signal before it clicks (`awaitInputDelivery`). WebKit takes events through its window and
    /// needs neither.
    static func watchInput(on page: BrowserPage) {
        guard page.chromium != nil else { return }
        page.installScript(
            "document.addEventListener('mousemove', () => { document.documentElement.dataset.\(inputSeen) = '1'; }, true);",
            in: PasswordAutofill.world, injectionTime: .atDocumentStart, forMainFrameOnly: true
        )
    }

    /// Moves the mouse over the page (changes no state: no click, no key) until the page reports it saw the move. A page that
    /// never takes input fails here, naming the cause, instead of as a click that "never reached its frame".
    static func awaitInputDelivery(in page: BrowserPage) async throws {
        guard let chromium = page.chromium else { return }
        try #require(await waitUntil {
            _ = try await chromium.command("Input.dispatchMouseEvent", params: ["type": "mouseMoved", "x": 2.0, "y": 2.0, "buttons": 0])
            return try await page.callAsyncJavaScript(
                "return document.documentElement.dataset.\(inputSeen) === '1';", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
            ) as? Bool == true
        }, "the Chromium page took mouse input")
    }

    /// `left`: an ordinary click instead, which focuses a field the way a person does.
    static func send(at point: CGPoint, in page: BrowserPage, window: NSWindow, left: Bool = false) async throws {
        if let chromium = page.chromium {
            for (type, buttons) in [("mousePressed", left ? 1 : 2), ("mouseReleased", 0)] {
                _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                    "type": type, "x": Double(point.x), "y": Double(point.y), "button": left ? "left" : "right", "buttons": buttons,
                    "clickCount": 1,
                ])
            }
            return
        }
        let native = try #require(page.webKit)
        let location = native.convert(point, to: nil)
        for type in left ? [NSEvent.EventType.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: [.rightMouseDown, .leftMouseDown].contains(type) ? 1 : 0
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
        private(set) var selections: [[String: Any]] = []

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
            case "select":
                selections.append(body)
            default:
                break
            }
        }

        var subframe: BrowserFrame? {
            readyFrames.last { !$0.isMainFrame }
        }

        /// Right-clicks element `id` (in `frame`, the iframe's document, when given) and returns what that frame's script reported.
        /// Chromium hit-tests an out-of-process frame only once it has been drawn: until then the click lands on the page, which
        /// reports a right-click on no field. Only that is tried again; any other report is returned as it is.
        func rightClick(_ id: String, in frame: BrowserFrame? = nil) async throws -> (body: [String: Any], frame: BrowserFrame) {
            try await PageRightClick.awaitInputDelivery(in: page)
            for attempt in 1...10 {
                let point = try await PageRightClick.center(of: id, in: page, frame: frame)
                let count = contexts.count
                try await PageRightClick.send(at: point, in: page, window: window)
                try #require(await waitUntil { self.contexts.count > count }, "the right-click on \(id) reached its frame")
                let last = contexts[contexts.count - 1]
                guard let frame, attempt < 10, last.frame.isMainFrame, !frame.isMainFrame, last.body["token"] is NSNull || last.body["token"] == nil else {
                    return last
                }
                try await Task.sleep(for: .milliseconds(200))
            }
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
        <form id="aw"><input id="vu" name="vu"><input id="vp" type="password" name="vp">
        <input type="hidden" id="hu" name="UserName"><input type="hidden" id="hp" name="Password"><button>Login</button></form>
        <output id="log"></output>
        <form id="mv"><input id="mu" autocomplete="username"><input id="mp" type="password"></form>
        <form id="ma"><input id="mau" autocomplete="username"><input id="mpw" type="password"></form>
        <form id="evil" action="https://elsewhere.example/steal"></form>
        <script>
        // Pages that, while the username fills, move the password into a form that sends it to another site.
        mu.addEventListener('blur', () => evil.append(mp));
        mau.addEventListener('input', () => mpw.setAttribute('form', 'evil'));
        </script>
        <script>
        // AribaWeb-style: the form that is sent carries hidden copies, made by the page's own key and blur listeners.
        vu.addEventListener('keyup', () => { hu.value = vu.value; });
        vp.addEventListener('blur', () => { hp.value = vp.value; });
        for (const type of ['focus','keydown','beforeinput','input','keyup','change','blur']) {
          vp.addEventListener(type, event => { log.value += `${type}${event.isTrusted ? '!' : ''}=${vp.value.length} `; });
        }
        aw.addEventListener('submit', event => {
          event.preventDefault();
          const sent = new FormData(aw);
          aw.dataset.sent = `${sent.get('UserName')}|${sent.get('Password')}`;
        });
        </script>
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
        PageRightClick.watchInput(on: page)
        page.installScript(PasswordAutofillScript.source, in: PasswordAutofill.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { harness.receive($0) }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { page.url == url && !page.isLoading })
            try #require(await waitUntil { harness.readyFrames.contains(where: \.isMainFrame) })
            try #require(await waitUntil { harness.subframe != nil }, "the iframe's script is ready")
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

    /// Edit ▸ Pick Credential…: with no right-click, the frame reports its focused field as a right-click would, and the fill that
    /// follows is the right-click's own. Nothing in focus, no pickable field in focus, a frame that is not focused and a frame whose
    /// autofill is off all report nothing.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theFocusedFieldIsReportedAsARightClickWouldAndNothingElseIs(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let main = try #require(harness.readyFrames.first(where: \.isMainFrame))
            let sub = try #require(harness.subframe)
            func focused(in frame: BrowserFrame) async throws -> [String: Any]? {
                try await harness.page.callAsyncJavaScript(
                    "return globalThis.__wsurfPasswords.focusedContext();", arguments: [:], in: frame, contentWorld: PasswordAutofill.world
                ) as? [String: Any]
            }
            try await PageRightClick.awaitInputDelivery(in: harness.page)
            #expect(try await focused(in: main) == nil, "nothing is focused")
            #expect(try await focused(in: sub) == nil)

            try await PageRightClick.send(
                at: try await PageRightClick.center(of: "bu", in: harness.page), in: harness.page, window: harness.window, left: true
            )
            var report: [String: Any]?
            try #require(await waitUntil { report = try? await focused(in: main); return report != nil }, "the focused field is reported")
            let body = try #require(report)
            #expect(body["action"] as? String == "context" && body["field"] as? String == "text")
            #expect(UUID(uuidString: body["token"] as? String ?? "") != nil && body["documentID"] is String && body["url"] is String)
            #expect(try await focused(in: sub) == nil, "another frame has nothing focused")

            // The token is the right-click's: the fill reaches the focused field's form and no other.
            report = try await focused(in: main)
            let fresh = try #require(report)
            #expect(try await harness.fill((fresh, main), ["username": "ada", "password": "dummy-secret"]) == 2)
            #expect(try await harness.values(["bu", "bp", "au", "ap", "xu", "xp"]) == ["ada", "dummy-secret", "", "", "", ""])

            // A focus in something that cannot be picked reports nothing; so does a frame whose autofill is off.
            _ = try await harness.page.callAsyncJavaScript(
                "document.getElementById('bu').blur();", arguments: [:], in: main, contentWorld: PasswordAutofill.world
            )
            #expect(try await focused(in: main) == nil, "the body is in focus")
            _ = try await harness.page.callAsyncJavaScript(
                "document.getElementById('bu').focus(); globalThis.__wsurfPasswords.setEnabled(false);", arguments: [:], in: main,
                contentWorld: PasswordAutofill.world
            )
            #expect(try await focused(in: main) == nil, "autofill is off")
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
    func aCodeSplitOverBoxesGoesBoxByBoxFromTheFirstWhicheverWasRightClicked(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let short = try await harness.rightClick("d1")
            #expect(try await harness.fill(short, ["code": "1234"]) == 0, "six boxes are not a four-digit code's")

            let click = try await harness.rightClick("d3")
            #expect(click.body["field"] as? String == "code")

            #expect(try await harness.fill(click, ["code": "246813"]) == 6)

            #expect(try await harness.values(["d1", "d2", "d3", "d4", "d5", "d6", "pin"]) == ["2", "4", "6", "8", "1", "3", ""])
        }
    }

    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aPasswordOrCodeIsNeverFilledIntoAFormThatSendsItToAnotherSite(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("xu")
            #expect(try await harness.fill(click, ["username": "ada", "password": "dummy-secret"]) == -1)

            let again = try await harness.rightClick("xu")
            #expect(try await harness.fill(again, ["code": "123456"]) == -1)

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

    /// WebKit runs the page scripts in a cross-origin iframe too. Under site isolation Chromium runs such a frame in another process,
    /// which gets the autofill scripts through its own DevTools session (`ChromiumDevTools+CrossSiteFrames`): the right-click lands on
    /// that frame and the fill goes into that frame and field only.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aRightClickInAnotherSitesFrameBelongsToThatFrameAlone(engine: BrowserEngine) async throws {
        try await withHarness(engine, crossOriginFrame: true) { harness in
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

    /// What the AribaWeb-style form sends, and what the password field's own listeners saw: `type`, `!` when trusted, `=` and the
    /// field's length at that moment.
    private func ariba(_ harness: Harness) async throws -> (sent: String?, log: [String]) {
        let sent = try await harness.page.callAsyncJavaScript(
            "aw.requestSubmit(); return aw.dataset.sent ?? null;", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
        ) as? String
        let log = try await harness.page.callAsyncJavaScript(
            "return document.getElementById('log').value;", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
        ) as? String
        return (sent, (log ?? "").split(separator: " ").map(String.init))
    }

    private func clearLog(_ harness: Harness) async throws {
        _ = try await harness.page.callAsyncJavaScript(
            "document.getElementById('log').value = '';", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
        )
    }

    /// From its keydown on, the password field heard the whole sequence once, with the value in place from `input` on, and every
    /// event the fill made itself untrusted. A focus or blur may be the engine's own (trusted) or, on a page without focus, the
    /// script's. The fill ends by focusing the chosen field again; a trusted blur and focus after that are the view's focus state
    /// catching up (as on a hosted runner, run 41792997943), not the fill, so the check ends at that focus.
    private func expectTyped(_ log: [String], length: Int) {
        let heard = Array(log.drop { !$0.hasPrefix("keydown") })
        let refocus = heard.firstIndex { $0.hasPrefix("blur") }.flatMap { blur in heard[blur...].firstIndex { $0.hasPrefix("focus") } }
        let typing = heard[..<(refocus ?? heard.endIndex)].filter { !$0.hasPrefix("focus") }
        #expect(typing.map { String($0.prefix { $0 != "!" && $0 != "=" }) } == ["keydown", "beforeinput", "input", "keyup", "change", "blur"],
                "\(log)")
        #expect(typing.prefix(5) == ["keydown=0", "beforeinput=0", "input=\(length)", "keyup=\(length)", "change=\(length)"],
                "the fill's own events are untrusted: \(log)")
        #expect(typing.last?.hasSuffix("=\(length)") == true, "blur comes after the value: \(log)")
    }

    /// AribaWeb copies the visible fields into the hidden ones it sends, on keyup and on blur. A pick fills so that those copies
    /// happen, in both engines.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aPickReachesAFormThatCopiesItsFieldsOnKeyAndBlur(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("vp")
            try await clearLog(harness)
            #expect(try await harness.fill(click, ["username": "ada", "password": "dummy-secret"]) == 2)

            let (sent, log) = try await ariba(harness)
            #expect(sent == "ada|dummy-secret")
            expectTyped(log, length: 12)
            #expect(try await harness.values(["vu", "vp", "au", "ap", "bu", "bp"]) == ["ada", "dummy-secret", "", "", "", ""])
        }
    }

    /// The page's own listeners run while the username fills. A password field they move into a form that sends to another site,
    /// by moving it or by its `form` attribute, takes nothing.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aPasswordMovedToAnotherSitesFormDuringTheFillTakesNothing(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            for (username, password) in [("mu", "mp"), ("mau", "mpw")] {
                let click = try await harness.rightClick(username)
                #expect(try await harness.fill(click, ["username": "ada", "password": "dummy-secret"]) == 1, "\(username)")
                #expect(try await harness.values([username, password]) == ["ada", ""], "\(password) took nothing")
            }
        }
    }

    /// The same while the page has no focus, as a Chromium page has none while the picker's sheet holds the window: Blink then
    /// sends no focus or blur of its own, so the fill sends them.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aPickReachesTheFormWhileThePageHasNoFocus(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("vp")
            harness.window.makeFirstResponder(nil)
            let unfocused = await waitUntil(timeout: .seconds(3)) {
                (try? await harness.page.callAsyncJavaScript(
                    "return document.hasFocus();", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
                )) as? Bool == false
            }
            try await clearLog(harness)
            #expect(try await harness.fill(click, ["username": "ada", "password": "dummy-secret"]) == 2)

            let (sent, log) = try await ariba(harness)
            #expect(sent == "ada|dummy-secret")
            expectTyped(log, length: 12)
            if engine == .chromium {
                #expect(unfocused, "Chromium's page lost focus with its view")
                #expect(log.contains("blur=12"), "Blink sent no blur, so the fill did: \(log)")
            }
        }
    }

    /// The same for a suggestion picked under a focused field; moving focus through the fields does not offer suggestions again,
    /// and focus ends in the field the person was in.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aSuggestionReachesAFormThatCopiesItsFieldsOnKeyAndBlur(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            try await PageRightClick.awaitInputDelivery(in: harness.page)
            try await PageRightClick.send(
                at: try await PageRightClick.center(of: "vp", in: harness.page), in: harness.page, window: harness.window, left: true
            )
            try #require(await waitUntil { harness.selections.last?["token"] is String }, "the click selects the password field")
            let selection = try #require(harness.selections.last)
            let token = try #require(selection["token"] as? String), url = try #require(selection["url"] as? String)
            try await clearLog(harness)
            let count = try await harness.page.callAsyncJavaScript(
                "return globalThis.__wsurfPasswords.fill(token, url, login);",
                arguments: ["token": token, "url": url, "login": ["username": "ada", "password": "dummy-secret"]],
                in: nil, contentWorld: PasswordAutofill.world
            )
            #expect((count as? NSNumber)?.intValue == 2)
            let selections = harness.selections.count

            let (sent, log) = try await ariba(harness)
            #expect(sent == "ada|dummy-secret")
            expectTyped(log, length: 12)
            #expect(try await harness.page.callAsyncJavaScript(
                "return document.activeElement?.id ?? null;", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
            ) as? String == "vp")
            try await Task.sleep(for: .milliseconds(400))
            #expect(harness.selections.count == selections, "the fill's own focus moves offer nothing")
        }
    }
}
