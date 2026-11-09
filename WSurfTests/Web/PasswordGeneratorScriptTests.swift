// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Generate Password…'s page side in both engines (plan tests S1-S4), from real right-clicks: `generateTarget` tells native what the
/// right-clicked field is without anything sent in, and `generateFill` puts the password into that field and its confirmation only,
/// in that frame only, once. A cross-origin frame is the same fixture server under another host name.
@MainActor
struct PasswordGeneratorScriptTests {
    private static let password = "hq4mzt-wnbcke-paXr9j"

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
        /// Chromium hit-tests an out-of-process frame only once it has been drawn, so only a report from the wrong frame is retried.
        func rightClick(_ id: String, in frame: BrowserFrame? = nil) async throws -> (body: [String: Any], frame: BrowserFrame) {
            for attempt in 1...10 {
                let point = try await PageRightClick.center(of: id, in: page, frame: frame)
                let count = contexts.count
                try await PageRightClick.send(at: point, in: page, window: window)
                try #require(await waitUntil { self.contexts.count > count }, "the right-click on \(id) reached its frame")
                let last = contexts[contexts.count - 1]
                guard let frame, attempt < 10, last.frame.isMainFrame, !frame.isMainFrame else { return last }
                try await Task.sleep(for: .milliseconds(200))
            }
            return contexts[contexts.count - 1]
        }

        func target(_ click: (body: [String: Any], frame: BrowserFrame), in frame: BrowserFrame? = nil) async throws -> [String: Any]? {
            try await page.callAsyncJavaScript(
                "return globalThis.__wsurfPasswords.generateTarget(token, url);",
                arguments: ["token": click.body["token"] as? String ?? "", "url": click.body["url"] as? String ?? ""],
                in: frame ?? click.frame, contentWorld: PasswordAutofill.world
            ) as? [String: Any]
        }

        /// `generateFill` with the right-click's token: how many fields took the password, and the username the form showed.
        func fill(
            _ click: (body: [String: Any], frame: BrowserFrame), in frame: BrowserFrame? = nil, _ password: String = PasswordGeneratorScriptTests.password
        ) async throws -> (count: Int, username: String?) {
            let answer = try await page.callAsyncJavaScript(
                "return globalThis.__wsurfPasswords.generateFill(token, url, password);",
                arguments: ["token": click.body["token"] as? String ?? "", "url": click.body["url"] as? String ?? "", "password": password],
                in: frame ?? click.frame, contentWorld: PasswordAutofill.world
            ) as? [String: Any]
            return ((answer?["count"] as? NSNumber)?.intValue ?? 0, answer?["username"] as? String)
        }

        func values(_ ids: [String], in frame: BrowserFrame? = nil) async throws -> [String] {
            var result: [String] = []
            for id in ids {
                let value = try await page.callAsyncJavaScript(
                    "return document.getElementById(id).value;", arguments: ["id": id], in: frame, contentWorld: PasswordAutofill.world
                ) as? String
                result.append(value ?? "?")
            }
            return result
        }

        /// What the sign-up password field's own listeners saw: `type`, `!` when trusted, `=` and the field's length then.
        func log() async throws -> [String] {
            let log = try await page.callAsyncJavaScript(
                "return document.getElementById('log').value;", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
            ) as? String
            return (log ?? "").split(separator: " ").map(String.init)
        }
    }

    private static let cancel = "<script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"

    /// One form for each row of the plan's table (2.6), and a form that sends to another website.
    private static func page(crossOriginFrame: Bool) -> String {
        let host = crossOriginFrame ? "'localhost:' + location.port" : "location.host"
        return cancel + #"""
        <form id="signup"><input id="se" type="email" value="ada@example.test">
        <input id="sp" type="password" autocomplete="new-password" maxlength="24" passwordrules="required: upper; required: digit; minlength: 12;">
        <input id="sc" type="password" name="confirm_password" minlength="14"></form>
        <form id="single"><input id="oe" type="email" value="grace@example.test"><input id="op" type="password" autocomplete="new-password"></form>
        <form id="change3"><input id="cu" autocomplete="username" value="bob"><input id="cc" type="password" autocomplete="current-password">
        <input id="cn" type="password" autocomplete="new-password"><input id="cf" type="password" autocomplete="new-password"></form>
        <form id="change2"><input id="dc" type="password" placeholder="Current password"><input id="dn" type="password" placeholder="New password"></form>
        <form id="plain3"><input id="u1" type="password"><input id="u2" type="password"><input id="u3" type="password"></form>
        <form id="new3"><input id="n1" type="password" autocomplete="new-password"><input id="n2" type="password" autocomplete="new-password">
        <input id="n3" type="password" autocomplete="new-password"></form>
        <form id="login"><input id="lu" autocomplete="username" value="eve"><input id="lp" type="password" autocomplete="current-password"></form>
        <form id="first"><input id="t1" type="password"></form><form id="second"><input id="t2" type="password"></form>
        <form action="https://elsewhere.example/collect"><input id="xu" value="mallory"><input id="xp" type="password"></form>
        <p id="text">Some text</p>
        <output id="log"></output>
        <script>
        for (const type of ['focus','keydown','beforeinput','input','keyup','change','blur']) {
          sp.addEventListener(type, event => { log.value += `${type}${event.isTrusted ? '!' : ''}=${sp.value.length} `; });
        }
        </script>
        <script>
        const frame = document.createElement('iframe');
        frame.src = location.protocol + '//' + \#(host) + '/frame';
        frame.width = 400; frame.height = 120;
        document.body.append(frame);
        </script>
        """#
    }

    private static let frame = cancel + #"""
        <form><input id="fu" autocomplete="username" value="frame-user"><input id="fp" type="password" autocomplete="new-password">
        <input id="fc" type="password" autocomplete="new-password"></form>
        """#

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
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), configuration: configuration), context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            page = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
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
            try #require(await waitUntil { harness.subframe != nil }, "the iframe's script is ready")
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

    // MARK: - S1: the field's facts and the fields a new password goes into

    /// For each form of the plan's table: what `generateTarget` says, and which fields the password then goes into.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func eachFormTellsWhatTheFieldIsAndFillsOnlyTheFieldAndItsConfirmation(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            // (right-clicked, filled, the form's other password fields, which stay empty)
            let rows: [(String, [String], [String])] = [
                ("sc", ["sp", "sc"], []),
                ("op", ["op"], []),
                ("cn", ["cn", "cf"], ["cc"]),
                ("cf", ["cn", "cf"], ["cc"]),
                ("dn", ["dn"], ["dc"]),
                ("u3", ["u2", "u3"], ["u1"]),
                ("n2", ["n2"], ["n1", "n3"]),
                ("lp", ["lp"], []),
                ("t1", ["t1"], ["t2"]),
            ]
            for (clicked, filled, untouched) in rows {
                let click = try await harness.rightClick(clicked)
                let facts = try #require(try await harness.target(click), "\(clicked)")
                #expect(facts["password"] as? Bool == true && facts["current"] as? Bool == false, "\(clicked)")
                #expect(facts["safe"] as? Bool == true, "\(clicked)")
                #expect((facts["partner"] is [String: Any]) == (filled.count == 2), "\(clicked)")
                let result = try await harness.fill(click)
                #expect(result.count == filled.count, "\(clicked)")
                #expect(try await harness.values(filled) == filled.map { _ in Self.password }, "\(clicked)")
                #expect(try await harness.values(untouched) == untouched.map { _ in "" }, "\(clicked) touched no other field")
            }
        }
    }

    /// The facts native gets: the field's rules and its and its confirmation's limits, the username the form shows, and refusals for
    /// a field that is not a password field and for the current password of a change form. Nothing is filled by asking.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theFactsAreTheRulesTheLimitsAndTheUsernameAndAskingFillsNothing(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let signUp = try #require(try await harness.target(try await harness.rightClick("sp")))
            #expect(signUp["rules"] as? String == "required: upper; required: digit; minlength: 12;")
            #expect((signUp["field"] as? [String: Any])?["maxLength"] as? NSNumber == 24)
            #expect((signUp["field"] as? [String: Any])?["minLength"] as? NSNumber == -1, "the DOM's none")
            #expect((signUp["partner"] as? [String: Any])?["minLength"] as? NSNumber == 14)
            #expect(signUp["username"] as? String == "ada@example.test")
            let parsed = try #require(PasswordGeneratorFlow.Field(signUp))
            #expect(parsed.kind == .new && parsed.hasConfirmation && parsed.username == "ada@example.test")
            #expect(parsed.limits == PasswordFieldLimits(minLength: 14, maxLength: 24), "the field's and its confirmation's limits")
            #expect(parsed.rules == PasswordRules(parsing: "required: upper; required: digit; minlength: 12;"))
            #expect(try await harness.values(["sp", "sc"]) == ["", ""])

            #expect(try await harness.target(try await harness.rightClick("cn"))?["username"] as? String == "bob")
            #expect(try await harness.target(try await harness.rightClick("xp"))?["safe"] as? Bool == false)

            let email = try #require(try await harness.target(try await harness.rightClick("se")))
            #expect(email["password"] as? Bool == false)
            #expect(PasswordGeneratorFlow.Field(email)?.kind == .notPassword)
            for current in ["cc", "dc", "u1"] {
                let facts = try #require(try await harness.target(try await harness.rightClick(current)), "\(current)")
                #expect(facts["current"] as? Bool == true, "\(current)")
                #expect(PasswordGeneratorFlow.Field(facts)?.kind == .currentPassword, "\(current)")
            }
            let text = try await harness.rightClick("text")
            #expect(try await harness.target(text) == nil, "no field was right-clicked")
        }
    }

    // MARK: - S2: the fill

    /// The fill types the password into the field and its confirmation as a person would (the field's own listeners hear the same
    /// sequence as a pick's, every event untrusted), returns the count and the username the form shows, and works once per
    /// right-click. A form that sends elsewhere and a current-password field take nothing.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theFillTypesIntoTheFieldAndItsConfirmationOnceAndRefusesWhatItMustNot(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("sp")
            let result = try await harness.fill(click)
            #expect(result.count == 2 && result.username == "ada@example.test")
            #expect(try await harness.values(["sp", "sc"]) == [Self.password, Self.password])
            let length = Self.password.count
            // From keydown on, every event the fill made itself is untrusted; the blur may be the engine's own.
            let heard = Array(try await harness.log().drop { !$0.hasPrefix("keydown") }).filter { !$0.hasPrefix("focus") }
            #expect(heard.prefix(5) == ["keydown=0", "beforeinput=0", "input=\(length)", "keyup=\(length)", "change=\(length)"], "\(heard)")
            #expect(heard.dropFirst(5).first.map { $0.hasPrefix("blur") && $0.hasSuffix("=\(length)") } == true, "\(heard)")
            #expect(try await harness.fill(click, "again-again-again").count == 0, "a right-click fills once")
            #expect(try await harness.target(click) == nil, "and is spent")
            #expect(try await harness.values(["sp", "sc"]) == [Self.password, Self.password])

            let unsafe = try await harness.rightClick("xp")
            #expect(try await harness.fill(unsafe).count == -1)
            #expect(try await harness.values(["xp"]) == [""])
            let current = try await harness.rightClick("cc")
            #expect(try await harness.fill(current).count == 0)
            #expect(try await harness.values(["cc", "cn", "cf"]) == ["", "", ""])
            let empty = try await harness.rightClick("op")
            #expect(try await harness.fill(empty, "").count == 0, "no password, no fill")
            #expect(try await harness.values(["op"]) == [""])
        }
    }

    // MARK: - S3: a field in a cross-origin frame

    /// The right-click in a cross-origin frame belongs to that frame: its facts and fill work there, and its token means nothing in
    /// the page's own frame, whose fields stay empty.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func aFieldInACrossOriginFrameTakesThePasswordInThatFrameOnly(engine: BrowserEngine) async throws {
        try await withHarness(engine, crossOriginFrame: true) { harness in
            let frame = try #require(harness.subframe)
            let click = try await harness.rightClick("fp", in: frame)
            try #require(!click.frame.isMainFrame, "the frame reported the right-click")
            #expect(try await harness.target(click, in: try #require(harness.readyFrames.first(where: \.isMainFrame))) == nil)
            #expect(try await harness.fill(click, in: try #require(harness.readyFrames.first(where: \.isMainFrame))).count == 0)
            let facts = try #require(try await harness.target(click))
            #expect(facts["username"] as? String == "frame-user" && facts["partner"] is [String: Any])
            #expect(try await harness.fill(click).count == 2)
            #expect(try await harness.values(["fp", "fc"], in: click.frame) == [Self.password, Self.password])
            #expect(try await harness.values(["sp", "sc", "op", "lp"]) == ["", "", "", ""])
        }
    }

    // MARK: - S4: an unfocused page

    /// The same fill while the page has no focus, as a Chromium page has none while a native sheet holds the window: Blink then
    /// sends no focus or blur of its own, so the fill sends them.
    @Test(.boundedWebViews, arguments: BrowserEngine.allCases)
    func theFillReachesTheFieldWhileThePageHasNoFocus(engine: BrowserEngine) async throws {
        try await withHarness(engine) { harness in
            let click = try await harness.rightClick("sp")
            harness.window.makeFirstResponder(nil)
            let unfocused = await waitUntil(timeout: .seconds(3)) {
                (try? await harness.page.callAsyncJavaScript(
                    "return document.hasFocus();", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
                )) as? Bool == false
            }
            _ = try await harness.page.callAsyncJavaScript(
                "document.getElementById('log').value = '';", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
            )
            #expect(try await harness.fill(click).count == 2)
            let log = try await harness.log()
            #expect(log.contains("input=\(Self.password.count)") && log.contains("change=\(Self.password.count)"), "\(log)")
            if engine == .chromium {
                #expect(unfocused, "Chromium's page lost focus with its view")
                #expect(log.contains("blur=\(Self.password.count)"), "Blink sent no blur, so the fill did: \(log)")
            }
        }
    }
}
