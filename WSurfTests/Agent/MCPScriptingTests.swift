// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing

@testable import WSurf

/// `evaluateScript`: who may run a script, what comes back, how long it may take, and what the user is told. Each case that
/// depends on the engine runs on WebKit and on the embedded Chromium.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPScriptingTests {
    static let password = "Hunter2-user-pw"
    static let card = "4111 1111 1111 1111"

    static let page = """
        <!doctype html><title>Scripting</title>
        <h1 id=title class="hero big">Hello</h1>
        <p id=note>Some text</p>
        <form id=login>
          <input id=user name=username value=alice>
          <input id=pw name=pw type=password aria-label="Password">
          <input id=card name=card autocomplete=cc-number aria-label="Card number">
        </form>
        <input type=hidden id=token value="tok-abc-123">
        <script>
          window.marker = 'page-global';
          const pw = document.getElementById('pw');
          pw.addEventListener('input', () => { document.title = 'Signed in with ' + pw.value; });
        </script>
        """

    private func fillSensitiveFields(_ rig: ScriptingRig) async throws {
        _ = try await rig.page("document.getElementById('pw').value = '\(Self.password)'; document.getElementById('card').value = '\(Self.card)'; 1")
    }

    // MARK: Who may run a script

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func scriptsRunOnlyInTheDeveloperTierOnDeveloperSites(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            let title = try await rig.run("document.title")
            #expect(title.status == "ok", "\(title.allText)")
            #expect(title.fields["value"]?.stringValue == "Scripting")
            #expect(title.fields["type"]?.stringValue == "string")
            #expect(title.fields["world"]?.stringValue == "page")

            // Development is not the Developer tier: the script is refused before anything runs.
            try rig.trust.setStanding(.development, for: rig.client.id)
            let refused = try await rig.run("document.title = 'ran'")
            #expect(refused.isError == true)
            #expect(refused.allText.contains("Developer access"), "\(refused.allText)")
            #expect(try await rig.page("document.title") as? String == "Scripting", "a refused script does not run")

            // Back at Developer it runs again.
            try rig.trust.setStanding(.developer, for: rig.client.id)
            #expect(try await rig.run("1 + 1").fields["value"]?.intValue == 2)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func anUnpairedConnectionNeverGetsScripts() async throws {
        try await ScriptingRig.with(html: Self.page, paired: false, sheet: .developer) { rig in
            // The sheet is not even offered Allow Developer to an unpaired connection, and an answer of it anyway is capped.
            #expect(rig.session.grants[rig.tab.id]?.access == .development)
            let refused = try await rig.run("document.title = 'ran'")
            #expect(refused.isError == true)
            #expect(try await rig.page("document.title") as? String == "Scripting")
            #expect(try await rig.edit("setText", ["selector": "#title", "value": "x"]).isError == true)
            #expect(try await rig.page("document.getElementById('title').textContent") as? String == "Hello")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func scriptsNeedTheDeveloperProfile() async throws {
        try await ScriptingRig.with(html: Self.page, profile: nil, sheet: .developer) { rig in
            #expect(rig.session.grants[rig.tab.id]?.access == .development)
            let refused = try await rig.run("document.title = 'ran'")
            #expect(refused.isError == true)
            #expect(try await rig.page("document.title") as? String == "Scripting")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func scriptsStopWhenThePageLeavesTheDeveloperSitesOrTheSiteIsReadOnly() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            #expect(try await rig.run("1").status == "ok")

            rig.tab.assistantAccess.set(.readOnly)
            #expect(try await rig.run("document.title = 'ran'").isError == true, "a Read Only site record caps the Developer tier")
            rig.tab.assistantAccess.set(.control)
            #expect(try await rig.run("1").status == "ok")

            // Taking This Mac off the developer sites ends the grant: the tab is no longer shared at all.
            try rig.trust.setIncludesThisMac(false)
            let gone = try await rig.run("document.title = 'ran'")
            #expect(gone.isError == true)
            #expect(gone.allText.contains("not shared"), "\(gone.allText)")
            #expect(try await rig.page("document.title") as? String == "Scripting")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aPrivateWindowIsNeverScripted() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let privateTab = BrowserTab(privately: true)
            privateTab.urlString = "http://localhost:5173/"
            rig.browser.tabs.append(privateTab)
            let refused = try await rig.call("evaluateScript", ["source": "1"], tab: privateTab)
            #expect(refused.isError == true)
            #expect(refused.allText.contains("not shared"), "\(refused.allText)")
            rig.browser.tabs.removeAll { $0 === privateTab }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aTabThatIsNotOnScreenIsNotScripted() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let other = rig.browser.newTab(url: try rig.server.url())
            #expect(rig.browser.activeTabID == other.id)
            let refused = try await rig.run("document.title = 'ran'")
            #expect(refused.status == "denied", "\(refused.allText)")
            #expect(refused.allText.contains("switchTab"))
            #expect(try await rig.page("document.title") as? String == "Scripting")
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func aFrameOfAnotherOriginIsOutOfReach(engine: BrowserEngine) async throws {
        let other = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Other</title><p id=inner>Inner</p>")])
        let html = "<!doctype html><title>Outer</title><iframe id=f src=\"\(try other.url().absoluteString)\"></iframe>"
        try await ScriptingRig.with(engine: engine, html: html) { rig in
            // The browser's same-origin rule applies: the main-frame script cannot read the frame's document.
            let document = try await rig.run("document.getElementById('f').contentDocument")
            #expect(document.status == "ok", "\(document.allText)")
            #expect(document.fields["type"]?.stringValue == "null")
            let reach = try await rig.run("() => frames[0].document.title")
            #expect(reach.status == "scriptError", "\(reach.allText)")
            #expect(reach.fields["error"]?.objectValue?["name"]?.stringValue == "SecurityError", "\(reach.allText)")
            // An edit does not find the frame's content either.
            #expect(try await rig.edit("remove", ["selector": "#inner"]).status == "invalidInput")
        }
        withExtendedLifetime(other) {}
    }

    // MARK: What comes back

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func resultsAreBoundedSerializedAndScrubbed(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            // Text and lists are cut, and the reply says so.
            let text = try await rig.run("'x'.repeat(100000)")
            #expect(text.status == "ok", "\(text.allText)")
            #expect(text.fields["truncated"]?.boolValue == true)
            #expect((text.fields["value"]?.stringValue?.count ?? .max) <= 4_100)

            let list = try await rig.run("Array.from({ length: 5000 }, (_, i) => i)")
            #expect(list.fields["truncated"]?.boolValue == true)
            #expect(list.fields["type"]?.stringValue == "array")
            #expect((list.fields["value"]?.arrayValue?.count ?? .max) <= 101)

            // However it is built, a value is serialized in at most 16 KiB.
            let wide = try await rig.run("Array.from({ length: 100 }, (_, i) => 'item-' + i + '-'.repeat(0) + 'y'.repeat(3000))")
            #expect(wide.status == "ok", "\(wide.allText)")
            let bytes = try #require(wide.fields["value"]).jsonBytes
            #expect(bytes <= PageScripting.maximumValueBytes, "\(bytes)")
            #expect(wide.fields["truncated"]?.boolValue == true)

            // Depth is limited and a cycle is marked, not followed.
            let deep = try await rig.run("(() => { let v = 'leaf'; for (let i = 0; i < 12; i++) v = { v }; return v })()")
            #expect(deep.fields["truncated"]?.boolValue == true)
            let cycle = try await rig.run("(() => { const a = { name: 'a' }; a.self = a; return a })()")
            #expect(cycle.fields["value"]?.objectValue?["self"]?.stringValue == "[Circular]", "\(cycle.allText)")

            // Values JSON cannot carry are named, and a node is described, not serialized.
            let odd = try await rig.run(
                "({ u: undefined, f() {}, s: Symbol('s'), b: 12n, n: NaN, d: new Date(0), r: /x/g, m: new Map([[1, 2]]), set: new Set([3]), el: document.getElementById('title') })")
            let value = try #require(odd.fields["value"]?.objectValue, "\(odd.allText)")
            #expect(value["u"]?.stringValue == "[undefined]")
            #expect(value["f"]?.stringValue == "[Function f]")
            #expect(value["s"]?.stringValue == "[Symbol(s)]")
            #expect(value["b"]?.stringValue == "[BigInt 12]")
            #expect(value["n"]?.stringValue == "[NaN]")
            #expect(value["d"]?.stringValue == "1970-01-01T00:00:00.000Z")
            #expect(value["r"]?.stringValue == "/x/g")
            #expect(value["m"]?.objectValue?["[Map]"]?.arrayValue?.count == 1)
            #expect(value["set"]?.objectValue?["[Set]"]?.arrayValue?.count == 1)
            #expect(value["el"]?.stringValue == "<h1#title.hero.big>")
            #expect(try await rig.run("undefined").fields["type"]?.stringValue == "undefined")

            // A function is called and a promise awaited.
            #expect(try await rig.run("() => 40 + 2").fields["value"]?.intValue == 42)
            #expect(try await rig.run("(async () => { await new Promise(done => setTimeout(done, 20)); return 'late' })()").fields["value"]?.stringValue == "late")
            #expect(try await rig.run("document.title;").fields["value"]?.stringValue == "Scripting", "a trailing semicolon is dropped")

            // A secret this connection registered is hidden, wherever the script puts it.
            #expect(rig.session.secrets.register("zebra-quartz-77") == .registered)
            let echoed = try await rig.run("({ a: 'x zebra-quartz-77 y', b: ['ZEBRA-QUARTZ-77'], c: encodeURIComponent('zebra quartz 77') })")
            #expect(!echoed.allText.contains("zebra-quartz-77"))
            #expect(!echoed.allText.lowercased().contains("zebra-quartz-77"))
            #expect(echoed.allText.contains(MCPSecretScrubber.replacement))
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func aScriptCannotLeaveTheExpressionItRunsIn(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            try await fillSensitiveFields(rig)
            // Closing the parenthesis to carry on only ends the expression: what follows `return` is never run.
            let breakout = try await rig.run("0); document.title = 'pwned'; window.__stolen = document.getElementById('pw').value; (0")
            #expect(breakout.status == "ok", "\(breakout.allText)")
            #expect(breakout.fields["value"]?.intValue == 0)
            #expect(try await rig.page("document.title") as? String == "Scripting", "no side effect outside the expression")
            #expect(try await rig.page("window.__stolen === undefined") as? Bool == true)

            // The harness is out of reach: the script runs in a function of its own with the page's global scope only, so it can
            // neither answer for itself nor reach the time limit, the checks or its own text.
            for name in ["resolve", "finish", "describe", "source", "outcome", "failure", "later", "make"] {
                let reach = try await rig.run("0), \(name), (0")
                #expect(reach.status == "scriptError", "\(name): \(reach.allText)")
                #expect(reach.fields["error"]?.objectValue?["name"]?.stringValue == "ReferenceError", "\(name): \(reach.allText)")
            }
            let forged = try await rig.run("0), resolve({ ok: true, type: 'string', value: 'forged', truncated: false }), (0")
            #expect(forged.status == "scriptError", "\(forged.allText)")
            #expect(!forged.allText.contains("forged"))

            // What a script like that does return is checked like any other result.
            let value = try await rig.run("[document.getElementById('pw').value, document.getElementById('card').value][0]")
            #expect(value.fields["value"]?.stringValue == "‹hidden›")
            #expect(!value.allText.contains(Self.password))
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func aFailureOfTheHarnessIsHiddenToo(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            try await fillSensitiveFields(rig)
            // A page that makes the harness itself fail with a field's value: what the engine says is a reply like any other.
            _ = try await rig.page("window.setTimeout = () => { throw new Error('boom ' + document.getElementById('pw').value) }; 1")
            let failed = try await rig.run("1")
            #expect(failed.status == "scriptError", "\(failed.allText)")
            #expect(!failed.allText.contains(Self.password), "\(failed.allText)")
            #expect(failed.allText.contains("boom ‹hidden›"), "\(failed.allText)")
            // The isolated world has its own timers, so it still answers.
            #expect(try await rig.run("1 + 1", world: "isolated").fields["value"]?.intValue == 2)
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func aPageThatForgesTheReplyIsHeldToTheBound(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            // A page that replaced JSON.stringify can hand back any text; what WSurf returns does not rest on the page's word.
            _ = try await rig.page(#"JSON.stringify = () => '{"ok":true,"type":"string","value":"' + 'x'.repeat(40000) + '"}'; 1"#)
            let oversized = try await rig.run("1")
            #expect(oversized.status == "ok", "\(oversized.allText)")
            #expect(oversized.fields["value"]?.stringValue == "[larger than 16 KiB]")
            #expect(oversized.fields["truncated"]?.boolValue == true)
            _ = try await rig.page(#"JSON.stringify = () => '{"ok":true,"type":"string","value":"' + 'x'.repeat(60000) + '"}'; 1"#)
            let huge = try await rig.run("1")
            #expect(huge.status == "scriptError", "\(huge.allText)")
            #expect(huge.allText.contains("more than the 48 KiB"), "\(huge.allText)")
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func aStrictContentSecurityPolicyIsToldAndTheIsolatedWorldStillWorks(engine: BrowserEngine) async throws {
        let strict = HTTPFixtureServer.Response.html(Self.page, headers: ["Content-Security-Policy": "script-src 'unsafe-inline'"])
        try await ScriptingRig.with(engine: engine, html: Self.page, routes: ["/": strict]) { rig in
            let page = try await rig.run("document.title")
            if engine == .webKit {
                // WebKit holds the compiled text to the page's policy in the page's world, and says how to go on.
                #expect(page.status == "scriptError", "\(page.allText)")
                #expect(page.fields["error"]?.objectValue?["compile"]?.boolValue == true, "\(page.allText)")
                #expect(page.allText.contains("Use world isolated"), "\(page.allText)")
            } else {
                // Chromium compiles through DevTools, which the page's policy does not bind.
                #expect(page.fields["value"]?.stringValue == "Scripting", "\(page.allText)")
            }
            let isolated = try await rig.run("document.title", world: "isolated")
            #expect(isolated.fields["value"]?.stringValue == "Scripting", "\(isolated.allText)")
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func errorsComeBackWithAMessageAndABoundedStack(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            let thrown = try await rig.run("() => { throw new TypeError('boom ' + 'z'.repeat(5000)) }")
            #expect(thrown.status == "scriptError", "\(thrown.allText)")
            #expect(thrown.isError == true)
            let error = try #require(thrown.fields["error"]?.objectValue)
            #expect(error["name"]?.stringValue == "TypeError")
            #expect(error["message"]?.stringValue?.hasPrefix("boom z") == true)
            #expect((error["message"]?.stringValue?.count ?? .max) <= 1_001)
            #expect((error["stack"]?.stringValue?.count ?? .max) <= 2_001)

            let rejected = try await rig.run("Promise.reject(new Error('nope'))")
            #expect(rejected.status == "scriptError")
            #expect(rejected.fields["error"]?.objectValue?["message"]?.stringValue == "nope")
            let plain = try await rig.run("(() => { throw 'just text' })()")
            #expect(plain.fields["error"]?.objectValue?["message"]?.stringValue == "just text")

            // Statements are not an expression; the reply says how to fix that, and nothing ran.
            let statements = try await rig.run("document.title = 'ran'; const a = 1; a")
            #expect(statements.status == "scriptError", "\(statements.allText)")
            #expect(statements.allText.contains("wrap statements in a function"), "\(statements.allText)")
            #expect(try await rig.page("document.title") as? String == "Scripting")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func inputIsBoundedBeforeAnythingRuns() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let long = "'" + String(repeating: "x", count: PageScripting.maximumSourceBytes) + "'"
            let refused = try await rig.run(long)
            #expect(refused.status == "invalidInput", "\(refused.allText)")
            #expect(try await rig.run("   ;  ").status == "invalidInput")
            let entry = try #require(MCPToolCatalog.entries.first { $0.name == "evaluateScript" })
            #expect(throws: (any Error).self) { try entry.validate(["tabID": "t", "source": "1", "timeoutMs": 49]) }
            #expect(throws: (any Error).self) { try entry.validate(["tabID": "t", "source": "1", "timeoutMs": 5_001]) }
            #expect(throws: (any Error).self) { try entry.validate(["tabID": "t", "source": "1", "world": "main"]) }
            try entry.validate(["tabID": "t", "source": "1", "timeoutMs": 5_000, "world": "isolated"])
        }
    }

    // MARK: Sensitive values

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func passwordAndCardValuesNeverComeBack(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            try await fillSensitiveFields(rig)
            let hidden = "‹hidden›"

            let direct = try await rig.run("document.querySelector('input[type=password]').value")
            #expect(direct.status == "ok", "\(direct.allText)")
            #expect(direct.fields["value"]?.stringValue == hidden)
            #expect((direct.fields["redacted"]?.intValue ?? 0) >= 1)
            #expect(!direct.allText.contains(Self.password))
            #expect(try await rig.run("document.getElementById('card').value").fields["value"]?.stringValue == hidden)

            // Wherever it goes in the result, in whatever form a script or a page writes it.
            let forms = try await rig.run(
                """
                (() => { const v = document.getElementById('pw').value; return {
                  plain: v, line: 'login=' + v + '&x=1', list: [v, 'a'], upper: v.toUpperCase(), url: encodeURIComponent(v),
                  json: JSON.stringify({ p: v }), html: '<b>' + v + '</b>', form: new FormData(document.getElementById('login')).get('pw'),
                  title: document.title, nested: { deeper: { v } }, [v]: 'as a key' } })()
                """)
            #expect(forms.status == "ok", "\(forms.allText)")
            #expect(!forms.allText.contains(Self.password))
            #expect(!forms.allText.lowercased().contains(Self.password.lowercased()))
            let object = try #require(forms.fields["value"]?.objectValue)
            #expect(object["plain"]?.stringValue == hidden)
            #expect(object["line"]?.stringValue == "login=\(hidden)&x=1")
            #expect(object["upper"]?.stringValue == hidden)
            #expect(object["form"]?.stringValue == hidden)
            #expect(object["nested"]?.objectValue?["deeper"]?.objectValue?["v"]?.stringValue == hidden)
            #expect(object[hidden]?.stringValue == "as a key")

            // A value read before the script clears the field, or removes it, is still caught.
            let erased = try await rig.run("(() => { const e = document.getElementById('pw'); const v = e.value; e.value = ''; e.remove(); return v })()")
            #expect(erased.fields["value"]?.stringValue == hidden, "\(erased.allText)")
            #expect(!erased.allText.contains(Self.password))

            // An error that carries the value is checked too.
            let thrown = try await rig.run("() => { throw new Error('bad card ' + document.getElementById('card').value) }")
            #expect(thrown.status == "scriptError")
            #expect(!thrown.allText.contains(Self.card))
            #expect(thrown.allText.contains(hidden))

            // A cookie that looks like a session id is hidden; a setting is not.
            _ = try await rig.page("document.cookie = 'session=abcdef0123456789abcdef; path=/'; document.cookie = 'theme=dark; path=/'; 1")
            let cookies = try await rig.run("document.cookie")
            #expect(cookies.fields["value"]?.stringValue?.contains("session=‹hidden›") == true, "\(cookies.allText)")
            #expect(cookies.fields["value"]?.stringValue?.contains("theme=dark") == true)
            #expect(!cookies.allText.contains("abcdef0123456789abcdef"))
            _ = try await rig.page("document.cookie = 'session=; Max-Age=0; path=/'; document.cookie = 'theme=; Max-Age=0; path=/'; 1")

            // Ordinary fields come back as they are, and so does the isolated world's view of a sensitive one.
            #expect(try await rig.run("document.getElementById('user').value").fields["value"]?.stringValue == "alice")
            let isolated = try await rig.run("document.getElementById('card').value", world: "isolated")
            #expect(isolated.fields["value"]?.stringValue == hidden)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aShortSensitiveValueIsHiddenWhenItIsTheWholeString() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            _ = try await rig.page("document.getElementById('pw').value = 'abc'; 1")
            let whole = try await rig.run("document.getElementById('pw').value")
            #expect(whole.fields["value"]?.stringValue == "‹hidden›")
            // Inside longer text a value under 4 characters is not recognized: it would destroy ordinary output.
            let inside = try await rig.run("'about the abc'")
            #expect(inside.fields["value"]?.stringValue == "about the abc")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func aTypedSecretIsHiddenInTheResultAndTheScriptThatNamesItIsAudited() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let read = try await rig.call("readPage")
            let content = try #require(read.fields["content"]?.stringValue)
            let line = try #require(content.split(separator: "\n").first { $0.contains("field \"Password\"") })
            let ref = try #require(Int(line.dropFirst().prefix { $0.isNumber }))
            let typed = try await rig.call("typeOnPage", ["ref": .int(ref), "text": .string(Self.password), "secret": true])
            #expect(typed.isError == false, "\(typed.allText)")

            let echo = try await rig.run("document.title")
            #expect(echo.status == "ok", "\(echo.allText)")
            #expect(!echo.allText.contains(Self.password))
            #expect(echo.allText.contains("‹"), "the page echoed the secret into its title and the reader hid it")

            // The script itself names the secret: the user's record hides it.
            _ = try await rig.run("'\(Self.password)'.length")
            let entries = rig.session.activity.entries.filter { $0.event == .tool("evaluateScript") }
            #expect(entries.count == 2)
            let details = entries.compactMap(\.detail).joined(separator: "\n")
            #expect(!details.contains(Self.password), "\(details)")
            #expect(details.contains(MCPSecretScrubber.auditReplacement), "\(details)")
        }
    }

    // MARK: Time

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func timeoutsStopLongScripts(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            let stuck = try await rig.run("new Promise(() => {})", timeoutMs: 100)
            #expect(stuck.status == "timedOut", "\(stuck.allText)")
            #expect(stuck.isError == true)
            #expect(stuck.allText.contains("100 ms"))
            // The tab answers the next call.
            #expect(try await rig.run("1 + 1").fields["value"]?.intValue == 2)

            // A script that is still waiting when its time is up does not return what it finds later.
            let slow = try await rig.run("(async () => { await new Promise(done => setTimeout(done, 1500)); return 'late' })()", timeoutMs: 100)
            #expect(slow.status == "timedOut")
            #expect(!slow.allText.contains("late'"))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func theBadgeShowsWhileAScriptRunsAndACancelledScriptStopsWaiting() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            #expect(!rig.session.isWorking)
            let running = Task { try await rig.run("new Promise(() => {})", timeoutMs: 5_000) }
            #expect(await waitUntil { rig.session.isWorking }, "the connection badge shows the page being scripted")
            // Stop cancels the running call; it does not wait out the script's time.
            running.cancel()
            let result = try await running.value
            #expect(result.isError == true)
            #expect(await waitUntil { !rig.session.isWorking })
            #expect(try await rig.run("1 + 1").fields["value"]?.intValue == 2, "the tab answers the next call")
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func aDialogTheScriptOpensIsReturnedAndAnsweredByTheConnection(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            if engine == .webKit {
                await rig.host()
            }
            // The alert blocks the page, so the call returns the dialog instead of waiting for a script that cannot finish.
            let opened = try await rig.run("(() => { alert('Saved'); document.title = 'after'; return 1 })()")
            #expect(opened.status == "dialogOpened", "\(opened.allText)")
            let dialog = try #require(opened.fields["dialogs"]?.arrayValue?.first?.objectValue)
            #expect(dialog["type"]?.stringValue == "alert")
            let done = try await rig.call("handleDialog", ["dialogID": dialog["dialogID"] ?? .null, "action": "accept"])
            #expect(done.status == "ok", "\(done.allText)")
            #expect(await waitUntil { (try? await rig.page("document.title")) as? String == "after" }, "the script went on once the alert was answered")
        }
    }

    // MARK: Worlds

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func pageAndIsolatedWorldsBehaveAsDocumented(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            // The page's world sees the page's variables; the isolated world shares the DOM and none of them.
            #expect(try await rig.run("window.marker").fields["value"]?.stringValue == "page-global")
            #expect(try await rig.run("window.marker", world: "isolated").fields["type"]?.stringValue == "undefined")
            let isolated = try await rig.run("document.getElementById('title').textContent", world: "isolated")
            #expect(isolated.fields["value"]?.stringValue == "Hello")
            #expect(isolated.fields["world"]?.stringValue == "isolated")

            // What an isolated script sets stays in its world, between calls.
            let set = try await rig.run("(globalThis.kept = 7)", world: "isolated")
            #expect(set.fields["value"]?.intValue == 7, "\(set.allText)")
            let kept = try await rig.run("globalThis.kept", world: "isolated")
            #expect(kept.fields["value"]?.intValue == 7, "\(kept.allText)")
            let page = try await rig.run("typeof globalThis.kept")
            #expect(page.fields["value"]?.stringValue == "undefined", "\(page.allText)")

            // The DOM is the same one.
            _ = try await rig.run("(document.getElementById('note').textContent = 'changed')", world: "isolated")
            #expect(try await rig.run("document.getElementById('note').textContent").fields["value"]?.stringValue == "changed")
            #expect(try await rig.run("(window.fromPage = 1, document.getElementById('note').textContent)").fields["value"]?.stringValue == "changed")
            #expect(try await rig.run("typeof window.fromPage", world: "isolated").fields["value"]?.stringValue == "undefined")
        }
    }

    // MARK: Audit

    @Test(.timeLimit(.minutes(3)))
    func everyScriptCallIsAudited() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let middle = String(repeating: "m", count: 400)
            _ = try await rig.run("document.title")
            _ = try await rig.run("(() => { /* START */ const s = '\(middle)'; return s.length /* END */ })()", world: "isolated")
            _ = try await rig.run("() => { throw new Error('x') }")
            try rig.trust.setStanding(.development, for: rig.client.id)
            _ = try await rig.run("document.title = 'refused'")

            let entries = rig.session.activity.entries.filter { $0.event == .tool("evaluateScript") }
            #expect(entries.count == 4, "a refused call is recorded too")
            #expect(entries.map(\.outcome) == [.succeeded, .succeeded, .failed, .failed])
            let details = entries.compactMap(\.detail)
            #expect(details.count == 4)
            #expect(details[0].hasPrefix("page: document.title · sha256 "), "\(details[0])")
            #expect(details[1].hasPrefix("isolated: ") && details[1].contains("START") && details[1].contains("END") && details[1].contains("…"), "\(details[1])")
            #expect(!details[1].contains(middle), "the middle of a long script is cut")
            #expect(details.allSatisfy { $0.count <= ExternalActivityLog.detailLimit + 1 })
            let digest = try #require(details[0].components(separatedBy: "sha256 ").last)
            #expect(digest.count == 8 && digest.allSatisfy(\.isHexDigit))
            #expect(entries.allSatisfy { $0.tabID == rig.tab.id })
        }
    }

    @Test func theCatalogDeclaresTheDeveloperScope() throws {
        for name in ["evaluateScript", "editDOM"] {
            let entry = try #require(MCPToolCatalog.entries.first { $0.name == name })
            #expect(entry.scope == .developer, "\(name)")
            #expect(!entry.readOnly)
            #expect(MCPBrowserSession.actionTitle(forTool: name)?.isEmpty == false)
        }
        #expect(MCPBrowserSession.scriptingCalls == ["evaluateScript", "editDOM"])
    }
}

nonisolated extension Value {
    /// The size of this value as JSON.
    var jsonBytes: Int {
        (try? JSONEncoder().encode(self).count) ?? .max
    }
}

/// A script that never yields blocks its page until the engine stops it, so it has a suite of its own.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPScriptingLoopTests {
    @Test(.timeLimit(.minutes(3)))
    func chromiumStopsAScriptThatNeverYields() async throws {
        try await ScriptingRig.with(engine: .chromium, html: MCPScriptingTests.page) { rig in
            let loop = try await rig.run("(() => { while (true) {} })()", timeoutMs: 100)
            #expect(loop.status == "timedOut", "\(loop.allText)")
            #expect(loop.fields["interrupted"]?.boolValue == true, "\(loop.allText)")
            #expect(await waitUntil { (try? await rig.run("1 + 1").fields["value"]?.intValue) == 2 }, "the page answers again")
        }
    }
}
