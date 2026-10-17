// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

extension RuntimeHarness {
    /// `PageAccessibility.script` after the runtime, in the content world the driver uses.
    func outline(offset: Int = 0, scope: String = "") async throws -> Output {
        try await run(PageAccessibility.script + "return JSON.stringify(axTree(\(offset), \(try Self.literal(scope))));")
    }
}

extension RuntimeHarness.Output {
    var lines: [String] { (self["text"] as? String)?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? [] }

    /// The lines without their `[ref]` numbers, which depend on how many controls came before.
    var shape: [String] {
        lines.map { $0.replacingOccurrences(of: #"\[\d+\] "#, with: "", options: .regularExpression) }
    }
}

/// The outline runs the real runtime in an off-screen WKWebView; the MCP suite repeats the key cases through the tool on both engines.
@MainActor
struct PageAccessibilityTests {
    @Test(.boundedWebViews) func showsLandmarksHeadingsListsTablesAndControls() async throws {
        let page = await RuntimeHarness(html: """
            <header><a href="/">Home</a><nav aria-label="Primary"><ul><li><a href="/a">Alpha</a></li><li><a href="/b" aria-current="page">Beta</a></li></ul></nav></header>
            <main><h1>Checkout</h1><p>Plain text is not part of the outline.</p>
            <table><caption>Orders</caption><thead><tr><th>Item</th><th>Qty</th></tr></thead>
            <tbody><tr><td>Shirt</td><td>2</td></tr><tr><td><button>Edit</button></td><td></td></tr></tbody></table>
            <ul><li>One</li><li>Two <b>bold</b></li></ul>
            <section aria-label="Notes"><h2>Heading in a region</h2></section><section><h3>Unnamed section</h3></section></main>
            <footer><a href="/privacy">Privacy</a></footer>
            """)
        let tree = try await page.outline()
        #expect(
            tree.shape == [
                "banner", "  link \"Home\"", "  navigation \"Primary\"", "    list items=2", "      link \"Alpha\"",
                "      link \"Beta\" current=page", "main", "  heading \"Checkout\" level=1", "  table \"Orders\"", "    row",
                "      columnheader \"Item\"", "      columnheader \"Qty\"", "    row", "      cell \"Shirt\"", "      cell \"2\"", "    row",
                "      cell", "        button \"Edit\"", "  list items=2", "    listitem \"One\"", "    listitem \"Two bold\"",
                "  region \"Notes\"", "    heading \"Heading in a region\" level=2", "  heading \"Unnamed section\" level=3", "contentinfo",
                "  link \"Privacy\"",
            ], "\(tree.lines)")
        #expect(tree["total"] as? Int == 26)
        #expect(tree["hasMore"] as? Bool == false)
    }

    @Test(.boundedWebViews) func hiddenInertAndAriaHiddenNodesAreLeftOut() async throws {
        let page = await RuntimeHarness(html: """
            <button>Shown</button>
            <div hidden><button>hidden attribute</button></div>
            <div style="display:none"><button>display none</button></div>
            <div aria-hidden="true"><button>aria hidden</button></div>
            <div inert><button>inert</button></div>
            <button style="visibility:hidden">visibility hidden</button>
            <div style="visibility:hidden"><button style="visibility:visible">visible child</button></div>
            <details><summary>Closed</summary><a href="/x">inside closed details</a></details>
            <details open><summary>Open</summary><a href="/y">inside open details</a></details>
            <dialog><button>closed dialog</button></dialog>
            """)
        let tree = try await page.outline()
        let text = try #require(tree["text"] as? String)
        for hidden in ["hidden attribute", "display none", "aria hidden", "inert", "visibility hidden", "inside closed details", "closed dialog"] {
            #expect(!text.contains(hidden), "\(hidden) must not be listed: \(text)")
        }
        for shown in ["Shown", "visible child", "Closed", "inside open details"] {
            #expect(text.contains(shown), "\(shown) must be listed: \(text)")
        }
    }

    @Test(.boundedWebViews) func sensitiveFieldsShowRoleAndNameOnly() async throws {
        let page = await RuntimeHarness(html: """
            <label>Password <input type="password" value="hunter2-secret"></label>
            <input name="cardnumber" placeholder="Card number" value="4111111111111111" required>
            <input autocomplete="one-time-code" aria-label="Code" value="482913">
            <input aria-label="Search" value="hunter2-secret">
            <textarea aria-label="Notes">hunter2-secret</textarea>
            <select aria-label="Country"><option>hunter2-secret</option></select>
            <div role="textbox" contenteditable aria-label="Editor">hunter2-secret</div>
            <label for="plain">Plain</label><input id="plain" value="hunter2-secret">
            <div data-wsurf-payment-card role="textbox" aria-label="Card holder">4111</div>
            """)
        let tree = try await page.outline()
        let text = try #require(tree["text"] as? String)
        #expect(!text.contains("hunter2-secret") && !text.contains("4111") && !text.contains("482913"), "\(text)")
        #expect(
            tree.shape == [
                "textbox \"Password\" sensitive", "textbox \"Card number\" sensitive", "textbox \"Code\" sensitive",
                "textbox \"Search\"", "textbox \"Notes\"", "combobox \"Country\"", "textbox \"Editor\"", "textbox \"Plain\"",
                "textbox \"Card holder\" sensitive",
            ], "\(tree.lines)")
    }

    @Test(.boundedWebViews) func namesStatesAndLevelsFollowTheMarkup() async throws {
        let page = await RuntimeHarness(html: """
            <label for="e">Email <span>(required)</span></label><input id="e" type="email" required>
            <input type="checkbox" id="g" checked><label for="g">Gift wrap</label>
            <input type="checkbox" id="m"><label for="m">Mixed</label>
            <button disabled>Pay</button>
            <button aria-expanded="false" aria-haspopup="menu">More</button>
            <button aria-pressed="true">Toggle</button>
            <input type="submit" value="Send"><input type="image" alt="Go">
            <div role="switch" aria-checked="true" aria-label="Dark mode"></div>
            <div role="tablist"><div role="tab" aria-selected="true">One</div><div role="tab">Two</div></div>
            <h2 role="heading" aria-level="4">Level four</h2>
            <img src="x.png" alt="Logo"><img src="y.png" alt=""><img src="z.png">
            <a href="/img"><img src="q.png" alt="Same"></a>
            <div role="alert">Saved <b>ok</b></div>
            <input aria-label="Qty" type="number" readonly aria-invalid="true">
            <fieldset><legend>Shipping</legend><input type="radio" aria-label="Standard"></fieldset>
            <div id="m1" hidden>Referenced</div><button aria-labelledby="m1">Hidden name</button>
            <script>document.getElementById('m').indeterminate = true</script>
            """)
        let tree = try await page.outline()
        #expect(
            tree.shape == [
                "textbox \"Email (required)\" required", "checkbox \"Gift wrap\" checked", "checkbox \"Mixed\" mixed", "button \"Pay\" disabled",
                "button \"More\" collapsed haspopup=menu", "button \"Toggle\" pressed", "button \"Send\"", "button \"Go\"",
                "switch \"Dark mode\" checked", "tablist", "  tab \"One\" selected", "  tab \"Two\"", "heading \"Level four\" level=4",
                "img \"Logo\"", "img", "link \"Same\"", "alert \"Saved ok\"", "spinbutton \"Qty\" readonly invalid",
                "group \"Shipping\"", "  radio \"Standard\" unchecked", "button \"Referenced\"",
            ], "\(tree.lines)")
        #expect(tree["unnamed"] as? Int == 0)
    }

    @Test(.boundedWebViews) func controlRefsAreTheOnesReadPageHandsOut() async throws {
        let page = await RuntimeHarness(html: "<main><button>Save</button><a href='/x'>Open</a><input aria-label='Name'><div role=switch aria-checked=true>Unlabelled</div></main>")
        let tree = try await page.outline()
        let refs = try #require(tree["refs"] as? [Int])
        #expect(refs.count == 3)
        #expect(tree.lines.filter { $0.contains("[") }.count == 3, "a control readPage does not list has no ref: \(tree.lines)")
        for ref in refs {
            let valid = try await page.run("return JSON.stringify({ ok: R.matchesRef(\(ref)), kind: R.kindOf(window.__wsurfRefs[\(ref) - 1]) });")
            #expect(valid["ok"] as? Bool == true, "ref \(ref)")
        }
        let snapshot = try await page.run("return JSON.stringify({ id: window.__wsurfSnapshot });")
        #expect(snapshot["id"] as? String == tree["snapshot"] as? String)
    }

    @Test(.boundedWebViews) func unnamedControlsAreCountedNotHidden() async throws {
        let page = await RuntimeHarness(html: "<input><input type=checkbox><button></button><img src=x.png><a href='/x'>Named</a>")
        let tree = try await page.outline()
        #expect(tree["unnamed"] as? Int == 3)
        #expect(tree.shape.contains("textbox") && tree.shape.contains("checkbox unchecked") && tree.shape.contains("img"), "\(tree.lines)")
    }

    @Test(.boundedWebViews) func scopeLimitsTheOutlineAndABadScopeIsAnError() async throws {
        let page = await RuntimeHarness(html: "<nav aria-label='Menu'><a href='/a'>A</a></nav><main id='m'><button>Inside</button></main><footer><a href='/z'>Z</a></footer>")
        let scoped = try await page.outline(scope: "#m")
        #expect(scoped.shape == ["main", "  button \"Inside\""])
        let missing = try await page.outline(scope: "#nope")
        #expect(missing["error"] as? String == "No element matches that scope.")
        let unsafe = try await page.outline(scope: "input[type=hidden][value^=s3]")
        #expect((unsafe["error"] as? String)?.contains("scope") == true)
        #expect(unsafe["text"] == nil)
    }

    @Test(.boundedWebViews) func openShadowRootsAndSameOriginFramesAreIncludedOthersAreSkipped() async throws {
        let page = await RuntimeHarness(html: """
            <div id="open"></div><div id="closed"></div>
            <iframe title="Same origin" srcdoc="<h2>Framed</h2><button>In frame</button>"></iframe>
            <iframe title="Sandboxed" sandbox srcdoc="<button>Unreachable</button>"></iframe>
            <script>
            document.getElementById('open').attachShadow({mode:'open'}).innerHTML = '<button>Open shadow</button><slot></slot>';
            document.getElementById('closed').attachShadow({mode:'closed'}).innerHTML = '<button>Closed shadow</button>';
            </script>
            """)
        let tree = try await page.outline()
        #expect(
            tree.shape == [
                "button \"Open shadow\"", "iframe \"Same origin\"", "  heading \"Framed\" level=2", "  button \"In frame\"", "iframe \"Sandboxed\" skipped",
            ], "\(tree.lines)")
        #expect(tree["skippedFrames"] as? Int == 1)
        #expect(!(tree["text"] as? String ?? "").contains("Closed shadow"))
    }

    @Test(.boundedWebViews) func aLongPageIsBoundedAndPagesWithoutGapsOrRepeats() async throws {
        let items = (0..<900).map { "<li><a href='/i\($0)'>Item \($0)</a></li>" }.joined()
        let page = await RuntimeHarness(html: "<main><ul>\(items)</ul></main>")
        var seen: [String] = []
        var offset = 0
        var pages = 0
        while true {
            let tree = try await page.outline(offset: offset)
            let count = try #require(tree["count"] as? Int)
            #expect(count <= PageAccessibility.maxNodes)
            #expect((tree["text"] as? String ?? "").utf8.count <= PageAccessibility.maxBytes)
            #expect(tree["start"] as? Int == offset)
            seen += tree.lines
            pages += 1
            guard tree["hasMore"] as? Bool == true else { break }
            offset += count
        }
        // main, list, and 900 links (each unnamed item is folded into its link)
        #expect(seen.count == 902)
        #expect(pages == 3)
        #expect(seen.last?.contains("Item 899") == true)
        #expect(Set(seen).count == seen.count, "no line is listed twice")
        let beyond = try await page.outline(offset: 10_000)
        #expect(beyond["count"] as? Int == 0 && beyond["hasMore"] as? Bool == false)
    }

    @Test(.boundedWebViews) func theByteBudgetEndsAPageBeforeTheNodeLimit() async throws {
        // 100-character names whose characters all escape to 5 bytes: far fewer than 400 lines fit.
        let name = String(repeating: "&", count: 100)
        let page = await RuntimeHarness(html: "<main>" + (0..<300).map { _ in "<button>\(name)</button>" }.joined() + "</main>")
        let tree = try await page.outline()
        let count = try #require(tree["count"] as? Int)
        #expect(count > 1 && count < 100, "\(count)")
        #expect(tree["hasMore"] as? Bool == true)
        let delivered = AgentToolkit.untrusted(try #require(tree["text"] as? String)).utf8.count
        #expect(delivered <= PageAccessibility.maxBytes + 128, "\(delivered)")
        let next = try await page.outline(offset: count)
        #expect((next["count"] as? Int ?? 0) > 0)
    }

    @Test(.boundedWebViews) func namesAreClippedAndFieldValuesNeverBecomePartOfAName() async throws {
        let long = String(repeating: "word ", count: 80)
        let page = await RuntimeHarness(html: """
            <button>\(long)</button>
            <button>Pay <input value="hunter2-secret"> now</button>
            <label>Wrapped <textarea>hunter2-secret</textarea></label>
            <a href="/x"><span contenteditable>hunter2-secret</span> link</a>
            """)
        let tree = try await page.outline()
        let first = try #require(tree.lines.first)
        #expect(first.hasSuffix("\u{2026}\""), "\(first)")
        #expect(first.count < 130)
        #expect(!(tree["text"] as? String ?? "").contains("hunter2-secret"))
        #expect(tree.lines.contains { $0.contains("button \"Pay now\"") })
    }

    @Test(.boundedWebViews) func anEmptyPageHasNoNodes() async throws {
        let page = await RuntimeHarness(html: "<p>Only text here.</p>")
        let tree = try await page.outline()
        #expect(tree["count"] as? Int == 0 && tree["total"] as? Int == 0)
        #expect(tree["text"] as? String == "")
    }
}
