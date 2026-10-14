// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// Runs the real `PageRuntime.script` in an off-screen WKWebView, in the same content world the driver uses.
@MainActor
final class RuntimeHarness: NSObject, WKNavigationDelegate {
    struct Output {
        let raw: String
        let object: [String: Any]
        subscript(key: String) -> Any? { object[key] }
    }

    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?

    init(html: String, size: CGSize = CGSize(width: 800, height: 600)) async {
        webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        super.init()
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish() }

    /// A failed load resumes too, so a fixture that cannot load fails its test instead of hanging it.
    private func finish() {
        loaded?.resume()
        loaded = nil
    }

    /// Evaluates `body` (which must `return JSON.stringify(...)`) after the runtime, like `PageDriver.scripted`.
    func run(_ body: String) async throws -> Output {
        let script = "(() => {\n" + PageRuntime.script + "\n" + body + "\n})()"
        let value = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        let raw = try #require(value as? String)
        let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return Output(raw: raw, object: object)
    }

    func state(_ selector: String) async throws -> Output {
        try await run("return JSON.stringify(R.elementState(\(try Self.literal(selector))));")
    }

    func find(_ selector: String, offset: Int = 0, limit: Int = 50) async throws -> Output {
        try await run("return JSON.stringify(R.findAll(\(try Self.literal(selector)), \(offset), \(limit)));")
    }

    func inspect(_ ref: Int) async throws -> Output {
        try await run("return JSON.stringify(R.inspect(\(ref)));")
    }

    static func literal(_ string: String) throws -> String {
        String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
    }
}

@MainActor
struct DevelopmentElementStateTests {
    @Test func reportsVisibleEnabledSingleMatch() async throws {
        let page = await RuntimeHarness(html: "<button id=go>Go</button>")
        let state = try await page.state("#go")
        #expect(state["count"] as? Int == 1)
        #expect(state["visible"] as? Bool == true)
        #expect(state["enabled"] as? Bool == true)
    }

    @Test func zeroAndMultipleMatchesAreCountedNotGuessed() async throws {
        let page = await RuntimeHarness(html: "<p class=a>1</p><p class=a>2</p><p class=a>3</p>")
        let none = try await page.state(".missing")
        #expect(none["count"] as? Int == 0)
        #expect(none["visible"] is NSNull)  // no state to report: `!visible` must not read as "hidden"
        let many = try await page.state(".a")
        #expect((many["count"] as? Int ?? 0) > 1)
        #expect(many["visible"] is NSNull)
        #expect(many["enabled"] is NSNull)
    }

    @Test(arguments: [
        "<div id=t style='display:none'>x</div>",
        "<div id=t style='visibility:hidden'>x</div>",
        "<div id=t style='width:0;height:0'></div>",
        "<div style='display:none'><div id=t>x</div></div>",
        "<div id=t hidden>x</div>",
    ])
    func hiddenElementsAreNotVisible(html: String) async throws {
        let page = await RuntimeHarness(html: html)
        #expect(try await page.state("#t")["visible"] as? Bool == false)
    }

    @Test func transparentElementsRemainVisible() async throws {
        let page = await RuntimeHarness(html: "<div id=t style='opacity:0'>x</div>")
        #expect(try await page.state("#t")["visible"] as? Bool == true)
    }

    @Test(arguments: [
        "<button id=t disabled>x</button>",
        "<fieldset disabled><button id=t>x</button></fieldset>",
        "<button id=t aria-disabled='true'>x</button>",
        "<div aria-disabled='true'><button id=t>x</button></div>",
        "<div inert><button id=t>x</button></div>",
    ])
    func disabledElementsAreNotEnabled(html: String) async throws {
        let page = await RuntimeHarness(html: html)
        #expect(try await page.state("#t")["enabled"] as? Bool == false)
    }

    @Test func invalidSelectorIsAnErrorNotAnEmptyMatchSet() async throws {
        let page = await RuntimeHarness(html: "<p>x</p>")
        for selector in ["div[", "::::", "a b >", "#"] {
            let state = try await page.state(selector)
            #expect(state["problem"] as? String == "invalid", "\(selector)")
            #expect(state["count"] == nil)
        }
    }

    @Test func matchesInsideOpenShadowRootsAndSameOriginFrames() async throws {
        let page = await RuntimeHarness(html: """
            <div id=host></div>
            <iframe srcdoc="<button id=inner>In frame</button>"></iframe>
            <script>document.getElementById('host').attachShadow({mode:'open'}).innerHTML = '<span id=deep>Deep</span>'</script>
            """)
        #expect(try await page.state("#deep")["count"] as? Int == 1)
        #expect(try await page.state("#inner")["count"] as? Int == 1)
    }
}

@MainActor
struct DevelopmentSelectorTests {
    @Test func acceptsUpToTheByteCeiling() {
        let ascii = String(repeating: "a", count: 2_048)
        #expect(PageRuntime.validate(selector: ascii) == .success(ascii))
        // A 3-byte character straddling the boundary: 2,046 ASCII + one 3-byte scalar = 2,049 bytes.
        let straddle = String(repeating: "a", count: 2_046) + "€"
        #expect(straddle.utf8.count == 2_049)
        #expect(PageRuntime.validate(selector: straddle) == .failure(.tooLong))
        #expect(PageRuntime.validate(selector: String(repeating: "a", count: 2_049)) == .failure(.tooLong))
        let exact = String(repeating: "a", count: 2_045) + "€"
        #expect(exact.utf8.count == 2_048)
        #expect(PageRuntime.validate(selector: exact) == .success(exact))
    }

    @Test func rejectsEmptyAndControlCharacterSelectors() {
        #expect(PageRuntime.validate(selector: "") == .failure(.empty))
        #expect(PageRuntime.validate(selector: "  \n ") == .failure(.empty))
        #expect(PageRuntime.validate(selector: "a\u{0}b") == .failure(.invalid))
    }

    @Test func styleAllowlistRespectsTheCeiling() {
        #expect(PageRuntime.inspectStyleProperties.count <= 64)
        #expect(Set(PageRuntime.inspectStyleProperties).count == PageRuntime.inspectStyleProperties.count)
    }
}

/// A selector is evaluated against the page, so attribute predicates are reads. Only exposed attributes may be tested.
@MainActor
struct DevelopmentSelectorPolicyTests {
    private static let page = """
        <body><form><input type=hidden name=csrf value="s3cr3t" data-token="s3cr3t"><input id=pw type=password value="pw123">
        <input id=name name=email value="a@b.test"><button data-testid=go class="primary big" aria-label="Go">Go</button>
        <a id=lnk href="https://x.test/p?sig=TOK9">link</a><select id=sel><option value="1">One</option></select></form></body>
        """

    @Test(arguments: [
        #"input[type=hidden][value^="s3"]"#,
        #"input[type=hidden][value="s3cr3t"]"#,
        #"body:has(input[type=hidden][value^="s3"])"#,
        #":is(input, textarea):not([value=""])"#,
        #"form:has(> input[type=hidden][value*=cr3])"#,
        #"input[type=hidden][v\61lue^="s3"]"#,
        #"input[type=hidden][VALUE^="s3"]"#,
        #"input[type=hidden][*|value^="s3"]"#,
        #"input[type=hidden][|value^="s3"]"#,
        #"input[type=hidden][value^='s3' i]"#,
        #"#pw[value="pw123"]"#,
        #"input[type=hidden][data-token^=s3]"#,
        #"a[href*="TOK9"]"#,
        #"a[href^="https://x.test/p?sig"]"#,
        #"a[src="x"]"#,
        #"option[value="1"]"#,
        #"[class="a"][onclick]"#,
    ])
    func unexposedAttributeReadsAreRejectedNotEmpty(selector: String) async throws {
        let page = await RuntimeHarness(html: Self.page)
        let found = try await page.find(selector)
        #expect(found["problem"] as? String == "unsafe", "\(selector): \(found.raw)")
        #expect(found["items"] == nil)
        let state = try await page.state(selector)
        #expect(state["problem"] as? String == "unsafe", "\(selector)")
        #expect(state["count"] == nil)
    }

    @Test(arguments: [
        "button", "#pw", ".primary", "button.primary.big", "[data-testid=go]", "[data-testid='go']", "[aria-label=Go]",
        "input[type=hidden]", "input[name=csrf]", "a[href]", "form > button:not([disabled])", "form:has(button.primary)", "input[type=password]#pw",
        "body :is(button, a)", "[id=lnk]", "[type]", "a[ href ]",
    ])
    func ordinaryStructuralSelectorsStillWork(selector: String) async throws {
        let page = await RuntimeHarness(html: Self.page)
        let found = try await page.find(selector)
        #expect(found["problem"] == nil, "\(selector): \(found.raw)")
        #expect((found["items"] as? [[String: Any]])?.isEmpty == false, "\(selector)")
    }

    @Test func readPageScopeAppliesTheSamePolicy() async throws {
        let page = await RuntimeHarness(html: Self.page)
        let result = try await page.run("return JSON.stringify(R.observe('', 1000, 10, 0, 0, 'body:has(input[type=hidden][value^=\"s3\"])', false));")
        #expect((result["error"] as? String)?.contains("scope") == true)
        let ok = try await page.run("return JSON.stringify(R.observe('', 1000, 10, 0, 0, 'form', false));")
        #expect(ok["error"] == nil)
    }
}

@MainActor
struct DevelopmentFindElementsTests {
    private static let list = "<ul>" + (0..<150).map { "<li class=item>Item \($0)</li>" }.joined() + "</ul>"

    @Test func paginatesWithHasMore() async throws {
        let page = await RuntimeHarness(html: Self.list)
        let first = try await page.find("li.item", offset: 0, limit: 100)
        #expect((first["items"] as? [[String: Any]])?.count == 100)
        #expect(first["hasMore"] as? Bool == true)
        #expect(first["offset"] as? Int == 0)
        #expect(first["returned"] as? Int == 100)
        let second = try await page.find("li.item", offset: 100, limit: 100)
        #expect((second["items"] as? [[String: Any]])?.count == 50)
        #expect(second["hasMore"] as? Bool == false)
        let names = (second["items"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names?.first == "Item 100")
        #expect(names?.last == "Item 149")
        let beyond = try await page.find("li.item", offset: 10_000, limit: 5)
        #expect((beyond["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(beyond["hasMore"] as? Bool == false)
    }

    @Test(arguments: [(-5, 10), (0, 0), (0, 101), (10_001, 5), (0, 5_000)])
    func outOfRangeOffsetOrLimitIsAnErrorNotClamped(offset: Int, limit: Int) async throws {
        let page = await RuntimeHarness(html: Self.list)
        let result = try await page.find("li.item", offset: offset, limit: limit)
        #expect(result["problem"] as? String == "range")
        #expect(result["items"] == nil)
    }

    @Test func invalidSelectorIsReportedNotEmptySuccess() async throws {
        let page = await RuntimeHarness(html: "<p>x</p>")
        let result = try await page.find("div[")
        #expect(result["problem"] as? String == "invalid")
        #expect(result["items"] == nil)
    }

    @Test func registersRefsAndDeclaresCoverage() async throws {
        let page = await RuntimeHarness(html: "<div id=a>One</div><div id=b>Two</div>")
        let result = try await page.find("div")
        let items = try #require(result["items"] as? [[String: Any]])
        let refs = items.compactMap { $0["r"] as? Int }
        #expect(refs.count == 2)
        #expect(Set(refs).count == 2)
        let tags = try await page.run("return JSON.stringify({ tag: window.__wsurfRefs[\(refs[0]) - 1].id });")
        #expect(tags["tag"] as? String == "a")
        let coverage = try #require(result["coverage"] as? [String: String])
        #expect(coverage["crossOriginFrames"] == "skipped")
        #expect(coverage["closedShadowRoots"] == "skipped")
        #expect(result["observation"] as? String != nil)
        #expect(result["document"] as? String != nil)
    }

    @Test func traversesOpenShadowRootsAndSameOriginFramesNotClosedOnes() async throws {
        let page = await RuntimeHarness(html: """
            <div id=open></div><div id=closed></div>
            <iframe srcdoc="<p class=t>frame</p>"></iframe>
            <script>
            document.getElementById('open').attachShadow({mode:'open'}).innerHTML = '<p class=t>open</p>';
            document.getElementById('closed').attachShadow({mode:'closed'}).innerHTML = '<p class=t>closed</p>';
            </script>
            """)
        let result = try await page.find("p.t")
        let names = (result["items"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(Set(names ?? []) == ["open", "frame"])
    }

    /// A ref from findAll is inspect-only until readPage's collect emits the same element as an ordinary control.
    @Test func foundRefsCarryNoActionAuthorityUntilReadPageEmitsThem() async throws {
        let page = await RuntimeHarness(html: "<div id=box>Box</div><button id=ok>Okay</button>")
        let items = try #require(try await page.find("#box, #ok")["items"] as? [[String: Any]])
        let box = try #require(items.first { $0["tag"] as? String == "div" }?["r"] as? Int)
        let button = try #require(items.first { $0["tag"] as? String == "button" }?["r"] as? Int)
        let found = try await page.run("""
            return JSON.stringify({
              boxStale: !!R.resolve(\(box), '', ['button', 'field', 'link']).stale,
              buttonStale: !!R.resolve(\(button), '', ['button']).stale,
              buttonByLabel: !!R.resolve(0, 'Okay', ['button']).el,
              matches: R.matchesRef(\(button)),
              inspectable: !R.inspect(\(button)).stale });
            """)
        #expect(found["boxStale"] as? Bool == true)
        #expect(found["buttonStale"] as? Bool == true)
        #expect(found["buttonByLabel"] as? Bool == false)
        #expect(found["matches"] as? Bool == false)
        #expect(found["inspectable"] as? Bool == true)  // inspection still works
        let promoted = try await page.run("""
            R.collect();
            return JSON.stringify({
              sameRef: R.collect().find(c => c.l === 'Okay')?.r === \(button),
              resolves: !!R.resolve(\(button), '', ['button']).el,
              boxStillStale: !!R.resolve(\(box), '', ['button', 'field', 'link']).stale });
            """)
        #expect(promoted["sameRef"] as? Bool == true)  // reusing the registered ref keeps its number
        #expect(promoted["resolves"] as? Bool == true)
        #expect(promoted["boxStillStale"] as? Bool == true)
    }

    @Test func collectThenFindKeepsAnOrdinaryControlActionable() async throws {
        let page = await RuntimeHarness(html: "<button id=ok>Okay</button>")
        let ref = try await page.run("return JSON.stringify({ r: R.collect().find(c => c.l === 'Okay').r });")["r"] as? Int ?? 0
        _ = try await page.find("button")
        let after = try await page.run("return JSON.stringify({ resolves: !!R.resolve(\(ref), '', ['button']).el, byLabel: !!R.resolve(0, 'Okay', ['button']).el });")
        #expect(after["resolves"] as? Bool == true)
        #expect(after["byLabel"] as? Bool == true)
    }

    @Test func aFoundHiddenDuplicateDoesNotMakeALabelAmbiguous() async throws {
        let page = await RuntimeHarness(html: "<button style='display:none'>Save</button><button>Save</button>")
        _ = try await page.run("R.collect(); return '{}';")
        let before = try await page.run("return JSON.stringify({ found: !!R.resolve(0, 'Save', ['button']).el });")
        #expect(before["found"] as? Bool == true)
        _ = try await page.find("button")
        let after = try await page.run("const r = R.resolve(0, 'Save', ['button']); return JSON.stringify({ found: !!r.el, ambiguous: !!r.ambiguous });")
        #expect(after["found"] as? Bool == true)
        #expect(after["ambiguous"] as? Bool == false)
    }

    @Test func aFoundOnlyElementThatChangesIsStaleForInspection() async throws {
        let page = await RuntimeHarness(html: "<div id=host><p id=p>x</p></div>")
        let items = try #require(try await page.find("#p")["items"] as? [[String: Any]])
        let ref = try #require(items.first?["r"] as? Int)
        _ = try await page.run("document.getElementById('host').innerHTML = '<p id=p>x</p>'; return '{}';")
        #expect(try await page.inspect(ref)["stale"] as? Bool == true)
    }

    @Test func aFormWithClobberingNamedControlsIsStillSummarised() async throws {
        let page = await RuntimeHarness(html: "<form id=f><input name=name><input name=id><input name=value></form>")
        let found = try await page.find("form")
        let item = try #require((found["items"] as? [[String: Any]])?.first)
        #expect(item["tag"] as? String == "form")
        #expect(found["problem"] == nil)
    }

    @Test func frameRootsAreListedOnce() async throws {
        let page = await RuntimeHarness(html: "<iframe srcdoc='<p>in</p>'></iframe>")
        let result = try await page.find("html")
        let refs = (result["items"] as? [[String: Any]])?.compactMap { $0["r"] as? Int } ?? []
        #expect(refs.count == 2)  // the document and the frame's document, each once
        #expect(Set(refs).count == refs.count)
    }

    @Test func neverEmitsFieldValuesOrHiddenContent() async throws {
        let page = await RuntimeHarness(html: """
            <input id=pw type=password value="hunter2-secret">
            <input id=hid type=hidden name=csrf value="hunter2-secret">
            <input id=txt value="hunter2-secret" placeholder="Search">
            <textarea id=ta>hunter2-secret</textarea>
            <div id=ce contenteditable>hunter2-secret</div>
            <select id=sel><option selected>hunter2-secret</option></select>
            <script id=sc>var token = "hunter2-secret"</script>
            """)
        let result = try await page.find("*", offset: 0, limit: 100)
        #expect(!result.raw.contains("hunter2-secret"), "\(result.raw)")
    }

    @Test func summariesStayBounded() async throws {
        let long = String(repeating: "word ", count: 500)
        let page = await RuntimeHarness(html: "<p id=p class='\(String(repeating: "c ", count: 200))'>\(long)</p>")
        let result = try await page.find("#p")
        let item = try #require((result["items"] as? [[String: Any]])?.first)
        #expect((item["name"] as? String ?? "").count <= 80)
        #expect((item["cls"] as? [String] ?? []).count <= 5)
        #expect(result.raw.utf8.count < 4_096)
    }
}

@MainActor
struct DevelopmentInspectTests {
    private func ref(_ page: RuntimeHarness, _ selector: String) async throws -> Int {
        let items = try #require(try await page.find(selector)["items"] as? [[String: Any]])
        return try #require(items.first?["r"] as? Int)
    }

    @Test func reportsBoxModelAndFlexLayoutOfANonInteractiveElement() async throws {
        let page = await RuntimeHarness(html: """
            <style>
            #box { box-sizing: content-box; width: 200px; height: 100px; margin: 10px 20px; padding: 5px 6px 7px 8px;
                   border: 3px solid black; display: flex; flex-direction: column; justify-content: center; gap: 4px; }
            </style>
            <div id=box><span>a</span><span>b</span></div>
            """)
        let inspected = try await page.inspect(try await ref(page, "#box"))
        let box = try #require(inspected["box"] as? [String: Any])
        #expect(box["boxSizing"] as? String == "content-box")
        let margin = try #require(box["margin"] as? [String: Double])
        #expect(margin == ["top": 10, "right": 20, "bottom": 10, "left": 20])
        let padding = try #require(box["padding"] as? [String: Double])
        #expect(padding == ["top": 5, "right": 6, "bottom": 7, "left": 8])
        let border = try #require(box["border"] as? [String: Double])
        #expect(border == ["top": 3, "right": 3, "bottom": 3, "left": 3])
        let content = try #require(box["content"] as? [String: Double])
        #expect(content == ["width": 200, "height": 100])
        let style = try #require(inspected["style"] as? [String: String])
        #expect(style["display"] == "flex")
        #expect(style["flex-direction"] == "column")
        #expect(style["justify-content"] == "center")
        let rect = try #require(inspected["rect"] as? [String: Double])
        #expect(rect["width"] == 220)  // 200 content + 14 padding + 6 border
    }

    @Test func contentBoxIsInLayoutPixelsUnderTransformAndCursorUrlsAreNotReported() async throws {
        let page = await RuntimeHarness(html: """
            <div id=t style="width:100px;height:40px;padding:5px;border:2px solid black;transform:scale(2);cursor:url(https://x.test/c.png?tok=SECRET9), auto"></div>
            """)
        let inspected = try await page.inspect(try await ref(page, "#t"))
        let content = try #require((inspected["box"] as? [String: Any])?["content"] as? [String: Double])
        #expect(content == ["width": 100, "height": 40])
        #expect(!inspected.raw.contains("SECRET9"))
    }

    @Test func reportsGridLayout() async throws {
        let page = await RuntimeHarness(html: "<style>#g{display:grid;grid-template-columns:100px 1fr;grid-template-rows:50px}</style><div id=g><i></i><i></i></div>")
        let inspected = try await page.inspect(try await ref(page, "#g"))
        let style = try #require(inspected["style"] as? [String: String])
        #expect(style["display"] == "grid")
        #expect(style["grid-template-columns"]?.hasPrefix("100px") == true)
    }

    @Test func attributesAreAllowlistedAndCappedAtThirtyTwo() async throws {
        let attributes = (0..<500).map { "data-x\($0)=\"v\($0)\"" }.joined(separator: " ")
        let aria = (0..<60).map { "aria-x\($0)=\"y\"" }.joined(separator: " ")
        let page = await RuntimeHarness(html: "<div id=d role=group title=T \(attributes) \(aria) onclick=\"steal()\"></div>")
        let inspected = try await page.inspect(try await ref(page, "#d"))
        let attrs = try #require(inspected["attributes"] as? [String: String])
        #expect(attrs.count <= 32)
        #expect(attrs["id"] == "d")
        #expect(attrs["role"] == "group")
        #expect(attrs.keys.allSatisfy { !$0.hasPrefix("data-") && $0 != "onclick" && $0 != "value" })
        #expect(inspected["attributesTotal"] as? Int == 564)
        #expect(inspected["attributesTruncated"] as? Bool == true)
    }

    @Test func ancestorsAreCappedAtSixteen() async throws {
        let open = String(repeating: "<div class=n>", count: 40)
        let close = String(repeating: "</div>", count: 40)
        let page = await RuntimeHarness(html: "\(open)<span id=leaf>x</span>\(close)")
        let inspected = try await page.inspect(try await ref(page, "#leaf"))
        #expect((inspected["ancestors"] as? [[String: Any]])?.count == 16)
        #expect(inspected["ancestorsTruncated"] as? Bool == true)
        let first = try #require((inspected["ancestors"] as? [[String: Any]])?.first)
        #expect(first["tag"] as? String == "div")  // nearest ancestor first
    }

    @Test func serializedOutputStaysUnderThirtyTwoKiB() async throws {
        let attributes = "title=\"t\(String(repeating: "x", count: 400))\""
        let wrappers = String(repeating: "<div class='\(String(repeating: "k ", count: 300))' style='font-family:\(String(repeating: "a", count: 3_000))'>", count: 30)
        let page = await RuntimeHarness(html: "\(wrappers)<p id=p \(attributes) style='font-family:\(String(repeating: "f", count: 5_000))'>x</p>\(String(repeating: "</div>", count: 30))")
        let inspected = try await page.inspect(try await ref(page, "#p"))
        #expect(inspected.raw.utf8.count <= 32 * 1_024)
        #expect(inspected["stale"] == nil)
    }

    @Test func omitsSecretsAndRawContent() async throws {
        let page = await RuntimeHarness(html: """
            <form><input id=pw type=password name=password value="hunter2-secret" data-token="hunter2-secret">
            <input id=hid type=hidden name=csrf value="hunter2-secret">
            <input id=txt value="hunter2-secret" placeholder="Search">
            <textarea id=ta>hunter2-secret</textarea>
            <div id=ce contenteditable>hunter2-secret</div>
            <a id=lnk href="https://user:hunter2-secret@x.test/a?token=hunter2-secret#frag">link</a></form>
            <iframe id=fr srcdoc="<p>frame</p>"></iframe>
            """)
        for selector in ["#pw", "#hid", "#txt", "#ta", "#ce", "#lnk", "form", "#fr"] {
            let inspected = try await page.inspect(try await ref(page, selector))
            #expect(!inspected.raw.contains("hunter2-secret"), "\(selector): \(inspected.raw)")
        }
        let hidden = try await page.inspect(try await ref(page, "#hid"))
        #expect((hidden["attributes"] as? [String: String]) == ["type": "hidden"])
        let link = try await page.inspect(try await ref(page, "#lnk"))
        #expect((link["attributes"] as? [String: String])?["href"] == "https://x.test/a")
    }

    @Test func replacedOrRemovedElementsAreStale() async throws {
        let page = await RuntimeHarness(html: "<div id=host><button id=b>Same</button></div>")
        let ref = try await ref(page, "#b")
        _ = try await page.run("document.getElementById('host').innerHTML = '<button id=b>Same</button>'; return '{}';")
        #expect(try await page.inspect(ref)["stale"] as? Bool == true)
        #expect(try await page.inspect(9_999)["stale"] as? Bool == true)
    }

    @Test func scrollGeometryIsReported() async throws {
        let page = await RuntimeHarness(html: "<div id=s style='width:100px;height:50px;overflow:auto'><div style='height:400px'>tall</div></div>")
        let inspected = try await page.inspect(try await ref(page, "#s"))
        let scroll = try #require(inspected["scroll"] as? [String: Double])
        #expect(scroll["clientHeight"] == 50)
        #expect((scroll["scrollHeight"] ?? 0) >= 400)
        #expect(scroll["scrollTop"] == 0)
    }
}
