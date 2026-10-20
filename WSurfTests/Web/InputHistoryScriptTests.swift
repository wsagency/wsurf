// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The page script in a real document. A test cannot type into a page, so it calls the script's own handlers through the test
/// hooks with events that look trusted. Events the page itself dispatches are real, and are never trusted.
@MainActor
struct InputHistoryScriptTests {
    private static let form = """
        <form onsubmit="return false">
        <label for="username">Email</label><input id="username" autocomplete="username">
        <label for="password">Password</label><input id="password" type="password" autocomplete="current-password">
        </form>
        <textarea id="note" aria-label="Notes"></textarea>
        <div id="rich" contenteditable></div>
        """

    private final class Sink: NSObject, WKScriptMessageHandler {
        var bodies: [[String: Any]] = []
        var commits: [[String: Any]] {
            bodies.filter { $0["action"] as? String == "commit" }
        }

        var pings: Int {
            bodies.filter { $0["action"] as? String == "ping" }.count
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] {
                bodies.append(body)
            }
        }
    }

    private func load(_ html: String = form, enabled: Bool = true) async throws -> (BrowserPage, Sink) {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let sink = Sink()
        let world = AutofillPage.world
        configuration.userContentController.add(sink, contentWorld: world, name: InputHistoryCapture.handlerName)
        BrowserPage.installBridge(in: configuration.userContentController, world: world)
        for source in [AutofillFormScript.source, InputHistoryScript.client(testHooks: true)] {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world
            ))
        }
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view = BrowserPage(
            webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration), context: context
        )
        view.loadHTMLString("<!doctype html>" + html, baseURL: URL(string: "https://login.example/"))
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        if enabled {
            _ = try await run("globalThis.__wsurfInputHistory.setPolicy({enabled:true});", in: view)
        }
        return (view, sink)
    }

    @discardableResult
    private func run(_ script: String, in view: BrowserPage) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: AutofillPage.world)
    }

    /// `call` runs on the script's test handle: `edit(field('password'), 'value')`.
    @discardableResult
    private func hook(_ call: String, in view: BrowserPage) async throws -> Any? {
        try await run("const field = id => document.getElementById(id); return globalThis.__wsurfInputHistory.__test.\(call);", in: view)
    }

    /// Messages of one page arrive in the order they were sent, so once the ping is here every earlier message is too.
    private func settle(_ sink: Sink, in view: BrowserPage) async throws {
        let before = sink.pings
        try await hook("ping()", in: view)
        #expect(await waitUntil { sink.pings > before })
    }

    private func values(_ sink: Sink) -> [String] {
        sink.commits.compactMap { $0["value"] as? String }
    }

    // MARK: - What counts as typing

    @Test(.boundedWebViews) func nothingIsPostedWhilePolicyIsOff() async throws {
        let (view, sink) = try await load(enabled: false)
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        try await hook("blur(field('password'))", in: view)
        try await hook("enter()", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)
        #expect(try await hook("pending()", in: view) as? Int == 0)

        // Switching it on and off again forgets what was waiting.
        _ = try await run("globalThis.__wsurfInputHistory.setPolicy({enabled:true});", in: view)
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        _ = try await run("globalThis.__wsurfInputHistory.setPolicy({enabled:false});", in: view)
        #expect(try await hook("pending()", in: view) as? Int == 0)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)
    }

    @Test(.boundedWebViews) func untrustedInputIsNeverCaptured() async throws {
        let (view, sink) = try await load()
        try await hook("scripted(field('password'), 'dummy-secret-123')", in: view)
        try await hook("blur(field('password'))", in: view)
        // The page's own events are real events, and none of them is trusted.
        _ = try await view.evaluateJavaScript("""
            const password = document.getElementById('password');
            password.focus();
            password.value = 'dummy-secret-123';
            password.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true, inputType: 'insertText', data: 'x'}));
            password.dispatchEvent(new Event('change', {bubbles: true}));
            password.dispatchEvent(new FocusEvent('focusout', {bubbles: true, composed: true}));
            document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
            document.querySelector('form').dispatchEvent(new SubmitEvent('submit', {bubbles: true, cancelable: true}));
            password.blur();
            1
            """)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)
        #expect(try await hook("pending()", in: view) as? Int == 0)
    }

    @Test(.boundedWebViews) func autofilledValuesStayOutEvenWhenTheUserEditsThem() async throws {
        let (view, sink) = try await load()
        try await hook("scripted(field('password'), 'dummy-autofill-1')", in: view)
        try await hook("edit(field('password'), 'dummy-autofill-1x')", in: view)
        try await hook("blur(field('password'))", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)

        // Emptying the field is the person's own act. What they type after it is theirs.
        try await hook("edit(field('password'), '')", in: view)
        try await hook("edit(field('password'), 'dummy-fresh-2')", in: view)
        try await hook("blur(field('password'))", in: view)
        try await settle(sink, in: view)
        #expect(values(sink) == ["dummy-fresh-2"])
    }

    @Test(.boundedWebViews) func anAutofilledUsernameIsNotPairedWithATypedPassword() async throws {
        let (view, sink) = try await load()
        try await hook("scripted(field('username'), 'ada@example.test')", in: view)
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        try await hook("blur(field('password'))", in: view)
        #expect(await waitUntil { sink.commits.count == 1 })
        #expect(sink.commits.first?["username"] as? String == "")
    }

    // MARK: - What is sent, and when

    @Test(.boundedWebViews) func committedPasswordIsPostedOnceOnBlurWithItsUsername() async throws {
        let (view, sink) = try await load()
        try await hook("edit(field('username'), 'ada@example.test')", in: view)
        try await hook("blur(field('username'))", in: view)
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        try await hook("blur(field('password'))", in: view)
        // Later events find nothing waiting.
        try await hook("blur(field('password'))", in: view)
        try await hook("enter()", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)

        #expect(sink.commits.count == 2)
        let password = try #require(sink.commits.first { $0["kind"] as? String == "password" })
        #expect(password["value"] as? String == "dummy-secret-123")
        #expect(password["username"] as? String == "ada@example.test")
        #expect(password["label"] as? String == "Password")
        #expect(password["cleared"] as? Bool == false)
        #expect(password["url"] as? String == "https://login.example/")
        #expect(UUID(uuidString: password["documentID"] as? String ?? "") != nil)
        #expect(Int(password["field"] as? String ?? "") != nil)
        let username = try #require(sink.commits.first { $0["kind"] as? String == "username" })
        #expect(username["value"] as? String == "ada@example.test")
        #expect(username["field"] as? String != password["field"] as? String)
    }

    @Test(.boundedWebViews) func programmaticClearKeepsTheLastTypedValue() async throws {
        let (view, sink) = try await load()
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        // The page empties the field before the person leaves it, as a login that failed would.
        _ = try await view.evaluateJavaScript("document.getElementById('password').value = ''; 1")
        try await hook("blur(field('password'))", in: view)
        try await settle(sink, in: view)
        #expect(values(sink) == ["dummy-secret-123"])
        #expect(sink.commits.first?["cleared"] as? Bool == false)
    }

    @Test(.boundedWebViews) func userClearingTheFieldSendsCleared() async throws {
        let (view, sink) = try await load()
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        try await hook("blur(field('password'))", in: view)
        try await hook("edit(field('password'), '')", in: view)
        try await hook("blur(field('password'))", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.map { $0["cleared"] as? Bool } == [false, true])
        #expect(values(sink) == ["dummy-secret-123", ""])
        #expect(sink.commits.last?["username"] as? String == "")
    }

    @Test(.boundedWebViews) func idleCommitFiresAfterTypingStops() async throws {
        let (view, sink) = try await load()
        try await hook("idle(100)", in: view)
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        #expect(await waitUntil { sink.commits.count == 1 })
        #expect(values(sink) == ["dummy-secret-123"])
        #expect(try await hook("pending()", in: view) as? Int == 0)
    }

    @Test func theIdleDelayIsOneAndAHalfSeconds() {
        #expect(InputHistoryScript.client(testHooks: false).contains("idleMilliseconds = 1500"))
    }

    @Test(.boundedWebViews) func enterSubmitAndHidingAlsoCommit() async throws {
        let (view, sink) = try await load()
        try await hook("edit(field('password'), 'dummy-one')", in: view)
        try await hook("enter()", in: view)
        try await hook("edit(field('note'), 'dummy-two')", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(values(sink) == ["dummy-one", "dummy-two"])
        #expect(sink.commits.last?["kind"] as? String == "multiline")
    }

    @Test(.boundedWebViews) func aBurstOfKeystrokesIsOneCommitAndCheap() async throws {
        let (view, sink) = try await load()
        try await hook("idle(600000)", in: view)
        let milliseconds = try #require(try await run("""
            const field = document.getElementById('note'), hooks = globalThis.__wsurfInputHistory.__test;
            const start = performance.now();
            for (let index = 0; index < 5000; index++) hooks.edit(field, 'x' + index);
            return performance.now() - start;
            """, in: view) as? Double)
        // 100 microseconds a keystroke, in a debug build, is far above what one costs: a map write and a clock read.
        #expect(milliseconds < 500, "5000 keystrokes took \(milliseconds) ms")
        #expect(try await hook("pending()", in: view) as? Int == 1)
        #expect(sink.commits.isEmpty)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(values(sink) == ["x4999"])
    }

    @Test(.boundedWebViews) func trackedFieldsAreBounded() async throws {
        let (view, sink) = try await load()
        try await hook("idle(600000)", in: view)
        _ = try await view.evaluateJavaScript("for (let i = 0; i < 60; i++) { const e = document.createElement('input'); e.id = 'f' + i; document.body.append(e); } 1")
        _ = try await run("""
            for (let i = 0; i < 60; i++) globalThis.__wsurfInputHistory.__test.edit(document.getElementById('f' + i), 'v' + i);
            """, in: view)
        try await settle(sink, in: view)
        // The 51st field made room by sending the first 50.
        #expect(sink.commits.count == 50)
        #expect(try await hook("pending()", in: view) as? Int == 10)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(Set(values(sink)).count == 60)
    }

    @Test(.boundedWebViews) func oversizedValuesAreNotTracked() async throws {
        let (view, sink) = try await load()
        try await hook("edit(field('note'), 'n'.repeat(10001))", in: view)
        try await hook("edit(field('password'), 'p'.repeat(4097))", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)
        try await hook("edit(field('password'), 'p'.repeat(4096))", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(values(sink).map(\.count) == [4096])
    }

    // MARK: - What is never captured

    @Test(.boundedWebViews) func cardNumbersSecurityCodesAndOneTimeCodesAreNeverCaptured() async throws {
        let (view, sink) = try await load("""
            <input id="card" autocomplete="cc-number"><input id="cvv" autocomplete="cc-csc"><input id="holder" autocomplete="cc-name">
            <input id="code" autocomplete="one-time-code"><input id="otp" aria-label="Verification code">
            <input id="short" maxlength="6" placeholder="Enter code"><input id="cvc" name="cardCvc">
            <input id="plain" aria-label="Notes"><input id="number" aria-label="Reference" type="number">
            """)
        for id in ["card", "cvv", "holder", "code", "otp", "short", "cvc"] {
            try await hook("edit(field('\(id)'), '123456')", in: view)
        }
        // Whatever the field is called, a number that passes the card check is not kept.
        try await hook("edit(field('plain'), '4111 1111 1111 1111')", in: view)
        try await hook("edit(field('number'), '4111111111111111')", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)

        try await hook("edit(field('plain'), 'A 16 digit reference 1234567890123456')", in: view)
        try await hook("edit(field('number'), '1234567890123456')", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(Set(values(sink)) == ["A 16 digit reference 1234567890123456", "1234567890123456"])
    }

    @Test(.boundedWebViews) func aCardNumberTypedAsAPasswordOrUsernameIsDropped() async throws {
        let (view, sink) = try await load()
        try await hook("edit(field('username'), '4111111111111111')", in: view)
        try await hook("edit(field('password'), '4111111111111111')", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)
    }

    @Test(.boundedWebViews) func editorsAndOtherElementsAreNotCaptured() async throws {
        let (view, sink) = try await load("""
            <div id="rich" contenteditable>text</div><input id="box" type="checkbox">
            <input id="range" type="range"><input id="date" type="date"><input id="hidden" type="hidden"><select id="menu"></select>
            """)
        for id in ["rich", "box", "range", "date", "hidden", "menu"] {
            try await hook("edit(field('\(id)'), 'dummy-text')", in: view)
        }
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.isEmpty)
        #expect(try await hook("pending()", in: view) as? Int == 0)
    }

    @Test(.boundedWebViews) func aFieldInsideAShadowTreeIsCaptured() async throws {
        let (view, sink) = try await load("""
            <div id="host"></div>
            <script>
              const root = document.getElementById('host').attachShadow({mode: 'open'});
              root.innerHTML = '<input id="inner" aria-label="Inner">';
            </script>
            """)
        try await hook("edit(field('host').shadowRoot.getElementById('inner'), 'dummy-text')", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(values(sink) == ["dummy-text"])
    }

    // MARK: - The page cannot see it

    @Test(.boundedWebViews) func pageWorldCannotSeeTheCaptureGlobals() async throws {
        let (view, _) = try await load()
        for name in ["__wsurfInputHistory", "__wsurfAutofillForms", "__wsurfSend"] {
            #expect(try await view.evaluateJavaScript("typeof globalThis.\(name)") as? String == "undefined")
        }
        // Nor can it reach the handler by its name.
        #expect(try await view.evaluateJavaScript("typeof window.webkit?.messageHandlers?.wsurfInputHistory") as? String == "undefined")
    }

    @Test(.boundedWebViews) func captureLeavesNoDOMAttributes() async throws {
        let (view, sink) = try await load()
        let before = try #require(try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String)
        let count = try #require(try await view.evaluateJavaScript("document.getElementsByTagName('*').length") as? Int)
        let globals = try #require(try await view.evaluateJavaScript("Object.getOwnPropertyNames(window).length") as? Int)
        try await hook("edit(field('username'), 'ada@example.test')", in: view)
        try await hook("edit(field('password'), 'dummy-secret-123')", in: view)
        try await hook("blur(field('password'))", in: view)
        try await hook("leave()", in: view)
        try await settle(sink, in: view)
        #expect(sink.commits.count == 2)
        #expect(try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String == before)
        #expect(try await view.evaluateJavaScript("document.getElementsByTagName('*').length") as? Int == count)
        #expect(try await view.evaluateJavaScript("Object.getOwnPropertyNames(window).length") as? Int == globals)
    }

    @Test func testHooksAreAbsentOutsideTests() {
        #expect(!InputHistoryScript.client(testHooks: false).contains("__test"))
        #expect(!InputHistoryScript.client(testHooks: false).contains("/*hooks*/"))
        #expect(InputHistoryScript.client(testHooks: true).contains("__test"))
        #expect(InputHistoryScript.clientSource == InputHistoryScript.client(testHooks: AppDatabase.isRunningTests))
    }

    /// The script only listens: it never changes the page, stops an event, stores, fetches or logs.
    @Test func theScriptNeverTouchesThePageOrTheOutside() {
        let source = InputHistoryScript.client(testHooks: false)
        let forbidden = [
            "stopPropagation", "stopImmediatePropagation", "preventDefault", "setAttribute", "removeAttribute", "dataset",
            "classList", ".style", "innerHTML", "appendChild", "insertAdjacent", "localStorage", "sessionStorage", "indexedDB",
            "document.cookie", "fetch(", "XMLHttpRequest", "sendBeacon", "console.", "eval(", "new Function",
        ]
        for word in forbidden {
            #expect(!source.contains(word), "\(word)")
        }
    }
}

/// The page script, the capture and the store together, through a real document.
@MainActor
struct InputHistoryPipelineTests {
    private func withRig(
        recording: Bool, capture shared: InputHistoryCapture? = nil, control: @escaping @MainActor () -> Bool = { false },
        _ body: (InputHistoryCaptureRig) async throws -> Void
    ) async throws {
        let rig = InputHistoryCaptureRig(recording: recording, formModel: true, capture: shared, control: control)
        do {
            try await body(rig)
        } catch {
            await rig.tearDown()
            throw error
        }
        await rig.tearDown()
    }

    private func enabled(_ rig: InputHistoryCaptureRig) async throws -> Bool? {
        try await rig.page.callAsyncJavaScript(
            "return globalThis.__wsurfInputHistory?.__test.enabled();", arguments: [:], in: nil, contentWorld: AutofillPage.world
        ) as? Bool
    }

    @discardableResult
    private func type(_ rig: InputHistoryCaptureRig, _ call: String) async throws -> Any? {
        try await rig.page.callAsyncJavaScript(
            "const field = id => document.getElementById(id); return globalThis.__wsurfInputHistory.__test.\(call);",
            arguments: [:], in: nil, contentWorld: AutofillPage.world
        )
    }

    private func open(_ rig: InputHistoryCaptureRig) async throws {
        rig.page.loadHTMLString(
            "<!doctype html><title>Sign in</title><form onsubmit='return false'><label for='username'>Email</label>"
                + "<input id='username' autocomplete='username'><label for='password'>Password</label>"
                + "<input id='password' type='password' autocomplete='current-password'></form>",
            baseURL: URL(string: "https://login.example/")
        )
        #expect(await PageSettle.untilIdle(rig.page, timeout: .seconds(20)))
        #expect(await waitUntil { rig.capture.documentCount(in: rig.page) >= 1 })
    }

    private func becomes(_ value: Bool, in rig: InputHistoryCaptureRig) async throws -> Bool {
        try await waitUntil { try await enabled(rig) == value }
    }

    @Test(.boundedWebViews) func aTypedPasswordReachesTheEncryptedStore() async throws {
        try await withRig(recording: true) { rig in
            try await open(rig)
            #expect(try await becomes(true, in: rig))

            try await type(rig, "edit(field('username'), 'ada@example.test')")
            try await type(rig, "edit(field('password'), 'dummy-secret-123')")
            try await type(rig, "blur(field('password'))")
            #expect(try await waitUntil { try await rig.entries().count == 2 })
            let entries = try await rig.entries()
            let password = try #require(entries.first { $0.payload.kind == .password })
            #expect(password.payload.value == "dummy-secret-123")
            #expect(password.payload.username == "ada@example.test")
            #expect(password.payload.url == "https://login.example/")
            #expect(password.payload.title == "Sign in")
            #expect(password.payload.label == "Password")
            // The files hold ciphertext only.
            let directory = InputHistory.directory(for: rig.profile)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let body = try Data(contentsOf: directory.appendingPathComponent(name))
                #expect(body.range(of: Data("dummy-secret-123".utf8)) == nil)
            }
        }
    }

    /// The one test with real keystrokes: the page is in a window, and the text goes in through the engine, as the person's typing does.
    @Test(.boundedWebViews) func realTypingIsRecordedAndScriptedFillingIsNot() async throws {
        try await withRig(recording: true) { rig in
            let window = NSWindow(
                contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = rig.page
            window.orderBack(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await open(rig)
            #expect(try await becomes(true, in: rig))
            try await type(rig, "idle(200)")

            // A script fills the username and sends the events a real edit would. None of them is trusted.
            _ = try await rig.page.evaluateJavaScript("""
                const username = document.getElementById('username');
                username.focus();
                username.value = 'ada@example.test';
                username.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true, inputType: 'insertText', data: 'a'}));
                username.dispatchEvent(new Event('change', {bubbles: true}));
                1
                """)
            _ = try await rig.page.evaluateJavaScript("document.getElementById('password').focus(); 1")
            let webView = try #require(rig.page.webKit)
            #expect(window.makeFirstResponder(webView))
            try await rig.page.insertText("dummy-secret-123")
            #expect(try await waitUntil { try await rig.entries().count == 1 })
            let entries = try await rig.entries()
            let password = try #require(entries.first)
            #expect(password.payload.kind == .password)
            #expect(password.payload.value == "dummy-secret-123")
            // The username came from a script, so it is not kept with the password either.
            #expect(password.payload.username == nil)
        }
    }

    @Test(.boundedWebViews) func switchingRecordingAndExclusionsReachOpenPages() async throws {
        try await withRig(recording: false) { rig in
            try await open(rig)
            // Off by default: the script was never told to start.
            #expect(try await enabled(rig) == false)

            rig.context.settings.recordsInputHistory = true
            rig.capture.refreshPolicy()
            #expect(try await becomes(true, in: rig))

            rig.context.settings.inputHistoryExcludedSites = ["login.example"]
            rig.capture.refreshPolicy()
            #expect(try await becomes(false, in: rig))
            rig.context.settings.inputHistoryExcludedSites = []
            rig.capture.refreshPolicy()
            #expect(try await becomes(true, in: rig))

            rig.context.settings.recordsInputHistory = false
            rig.capture.refreshPolicy()
            #expect(try await becomes(false, in: rig))
        }
    }

    @Test(.boundedWebViews, arguments: ["assistant", "connected app"])
    func controlOfTheTabSwitchesTheScriptOffAndDropsWhatWasWaiting(controller: String) async throws {
        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))
        func control(_ on: Bool) {
            if controller == "assistant" {
                tab.setAgentWorking(on)
            } else {
                tab.setExternalAutomationWorking(on)
            }
        }
        try await withRig(recording: true, control: { tab.isUnderAssistantControl }) { rig in
            try await open(rig)
            #expect(try await becomes(true, in: rig))
            try await type(rig, "idle(600000)")

            // Typed before the control began and not yet sent: it is dropped, not sent when the call is over.
            try await type(rig, "edit(field('password'), 'dummy-before-control')")
            control(true)
            #expect(try await becomes(false, in: rig))
            #expect(try await type(rig, "pending()") as? Int == 0)
            try await type(rig, "edit(field('password'), 'dummy-agent-typed')")
            try await type(rig, "blur(field('password'))")
            control(false)
            #expect(try await becomes(true, in: rig))
            let during = try await rig.entries()
            #expect(during.isEmpty)

            // The person's own typing is recorded again once the control has ended.
            try await type(rig, "edit(field('password'), 'dummy-own-typing')")
            try await type(rig, "blur(field('password'))")
            #expect(try await waitUntil { try await rig.entries().count == 1 })
            let entries = try await rig.entries()
            #expect(entries.map(\.payload.value) == ["dummy-own-typing"])
        }
    }

    @Test(.boundedWebViews) func settingsChangesReachTheSharedCapture() async throws {
        let shared = InputHistoryCapture.shared
        let owned = shared.ownsSession
        shared.ownsSession = true
        defer { shared.ownsSession = owned }
        try await withRig(recording: false, capture: shared) { rig in
            try await open(rig)
            #expect(try await enabled(rig) == false)
            // The setting calls the shared capture itself. The test never refreshes it by hand.
            rig.context.settings.recordsInputHistory = true
            #expect(try await becomes(true, in: rig))
            rig.context.settings.recordsInputHistory = false
            #expect(try await becomes(false, in: rig))
        }
    }
}
