// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing

@testable import WSurf

/// `editDOM` and the full form of `inspectElement`: what an app may change and read in the page, and what it may not. Cases that
/// depend on the engine run on WebKit and on the embedded Chromium.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPDOMEditTests {
    static let page = """
        <!doctype html><title>Editing</title>
        <div id=app class=shell>
          <h1 id=title class="hero big">Hello</h1>
          <p id=note>Some text</p>
          <ul id=list><li>one</li></ul>
          <a id=link href="/next">Next</a>
        </div>
        <form id=login>
          <input id=user name=username value=alice>
          <input id=pw name=pw type=password aria-label="Password">
          <input id=card name=card autocomplete=cc-number aria-label="Card number" value="4242 4242 4242 4242">
        </form>
        <input type=hidden id=token value="tok-abc-123">
        <div id=ring class="__wsurf-ring">ring</div>
        <input id=marked data-wsurf-password aria-label="Marked">
        <iframe id=frame srcdoc="<!doctype html><p id=inner>Inner</p>"></iframe>
        """

    /// The page's markup, to show that a refused edit changed nothing.
    private func markup(_ rig: ScriptingRig) async throws -> String {
        try #require(try await rig.page("document.body.outerHTML") as? String)
    }

    // MARK: Edits

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func domEditsApplyAndAreLogged(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            let attribute = try await rig.edit("setAttribute", ["selector": "#title", "name": "data-state", "value": "ready"])
            #expect(attribute.status == "ok", "\(attribute.allText)")
            #expect(attribute.fields["target"]?.stringValue == "h1#title.hero.big")
            #expect(try await rig.page("document.getElementById('title').getAttribute('data-state')") as? String == "ready")

            // By ref, from findElements.
            let found = try await rig.find("#title")
            let byRef = try await rig.edit(
                "setAttribute", ["ref": .int(found.ref), "observationID": .string(found.observation), "name": "class", "value": "hero small"])
            #expect(byRef.status == "ok", "\(byRef.allText)")
            #expect(try await rig.page("document.getElementById('title').className") as? String == "hero small")

            #expect(try await rig.edit("removeAttribute", ["selector": "#title", "name": "data-state"]).status == "ok")
            #expect(try await rig.page("document.getElementById('title').hasAttribute('data-state')") as? Bool == false)

            #expect(try await rig.edit("setText", ["selector": "#note", "value": "New text"]).status == "ok")
            #expect(try await rig.page("document.getElementById('note').textContent") as? String == "New text")

            let style = try await rig.edit("setStyle", ["selector": "#note", "name": "color", "value": "red", "important": true])
            #expect(style.status == "ok", "\(style.allText)")
            #expect(try await rig.page("document.getElementById('note').style.getPropertyPriority('color')") as? String == "important")
            let rejected = try await rig.edit("setStyle", ["selector": "#note", "name": "color", "value": "not a colour"])
            #expect(rejected.status == "invalidInput", "\(rejected.allText)")

            let inserted = try await rig.edit("insert", ["selector": "#note", "tag": "section", "value": "Inserted", "position": "afterend"])
            #expect(inserted.status == "ok", "\(inserted.allText)")
            #expect(inserted.fields["inserted"]?.stringValue == "section")
            #expect(try await rig.page("document.getElementById('note').nextElementSibling.outerHTML") as? String == "<section>Inserted</section>")

            #expect(try await rig.edit("remove", ["selector": "#list"]).status == "ok")
            #expect(try await rig.page("document.getElementById('list') === null") as? Bool == true)

            // The Developer tier lifts the attribute rule of selectors; a hidden field is found by its value.
            let hidden = try await rig.edit("setAttribute", ["selector": "input[type=hidden][value^=tok-]", "name": "data-seen", "value": "1"])
            #expect(hidden.status == "ok", "\(hidden.allText)")

            // Each call is in Agent Activity with what it did, and the values the edits carried are the user's to read.
            let entries = rig.session.activity.entries.filter { $0.event == .tool("editDOM") }
            #expect(entries.count == 9, "\(entries.count)")
            #expect(entries.filter { $0.outcome == .failed }.count == 1, "only the rejected style failed")
            let details = entries.compactMap(\.detail)
            #expect(details.first == "setAttribute data-state = \"ready\" on #title", "\(details)")
            #expect(details.contains { $0.hasPrefix("insert <section>") && $0.contains("Inserted") && $0.contains("on #note") })
            #expect(details.contains { $0.hasPrefix("remove") && $0.hasSuffix("on #list") })
            #expect(entries.contains { $0.target == "element \(found.ref)" })
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func editsRefuseWSurfsOwnPageSensitiveFieldsAndAnythingThatRunsCode(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            let before = try await markup(rig)
            func refused(_ op: String, _ arguments: [String: Value], _ status: String = "denied") async throws {
                let result = try await rig.edit(op, arguments)
                #expect(result.status == status, "\(op) \(arguments): \(result.allText)")
            }

            // WSurf's own page elements and marks.
            try await refused("setText", ["selector": "#ring", "value": "x"])
            try await refused("remove", ["selector": ".__wsurf-ring"])
            try await refused("setAttribute", ["selector": "#marked", "name": "title", "value": "x"])
            try await refused("setAttribute", ["selector": "#title", "name": "data-wsurf-password", "value": ""])
            try await refused("removeAttribute", ["selector": "#title", "name": "data-wsurf-contact"])

            // Password, code and card fields, whatever the operation; changing what makes a field sensitive included.
            for selector in ["#pw", "#card"] {
                try await refused("setAttribute", ["selector": .string(selector), "name": "type", "value": "text"])
                try await refused("setAttribute", ["selector": .string(selector), "name": "autocomplete", "value": "off"])
                try await refused("removeAttribute", ["selector": .string(selector), "name": "aria-label"])
                try await refused("setStyle", ["selector": .string(selector), "name": "color", "value": "red"])
                try await refused("remove", ["selector": .string(selector)])
            }

            // Code: handlers, script URLs, and elements that load a document or a script.
            try await refused("setAttribute", ["selector": "#title", "name": "onclick", "value": "alert(1)"])
            try await refused("setAttribute", ["selector": "#title", "name": "ONMOUSEOVER", "value": "alert(1)"])
            try await refused("setAttribute", ["selector": "#link", "name": "href", "value": "javascript:alert(1)"])
            try await refused("setAttribute", ["selector": "#link", "name": "href", "value": " java\tscript:alert(1)"])
            try await refused("setAttribute", ["selector": "#frame", "name": "srcdoc", "value": "<p>x</p>"])
            for tag in ["script", "iframe", "object", "embed", "link", "meta", "base"] {
                try await refused("insert", ["selector": "#app", "tag": .string(tag)])
            }
            try await refused("remove", ["selector": "body"])
            try await refused("remove", ["selector": "html"])

            // Malformed requests, ambiguous or missing targets.
            try await refused("insert", ["selector": "#app", "tag": "1x"], "invalidInput")
            await #expect(throws: (any Error).self) { try await rig.edit("insert", ["selector": "#app", "tag": "div", "position": "inside"]) }
            try await refused("setAttribute", ["selector": "#title", "name": "bad name", "value": "x"], "denied")
            try await refused("setText", ["selector": "h1, p", "value": "x"], "invalidInput")
            try await refused("setText", ["selector": "#nothing", "value": "x"], "invalidInput")
            try await refused("setText", ["selector": "((", "value": "x"], "invalidInput")
            try await refused("setText", ["selector": "#title", "ref": 1, "value": "x"], "invalidInput")
            try await refused("setText", ["value": "x"], "invalidInput")
            try await refused("setAttribute", ["selector": "#title", "name": "title"], "invalidInput")
            try await refused("setText", ["selector": "#title", "value": .string(String(repeating: "x", count: MCPToolCatalog.maximumEditValueBytes + 1))], "invalidInput")

            // An element inside a frame is out of reach, by selector and by ref.
            try await refused("setText", ["selector": "#inner", "value": "x"], "invalidInput")
            let inner = try await rig.find("#inner")
            try await refused("setText", ["ref": .int(inner.ref), "observationID": .string(inner.observation), "value": "x"])
            // A ref the observation does not know, and one from another observation, are stale.
            let title = try await rig.find("#title")
            try await refused("setText", ["ref": .int(title.ref), "observationID": "not-the-observation", "value": "x"], "stale")
            try await refused("setText", ["ref": 9_999, "value": "x"], "stale")

            #expect(try await markup(rig) == before, "nothing a refused edit asked for was done")
            // The edits above are all in Agent Activity, refused or not.
            #expect(rig.session.activity.entries.filter { $0.event == .tool("editDOM") }.allSatisfy { $0.outcome == .failed })
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func editsNeedDeveloperAccessNotDevelopment() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let before = try await markup(rig)
            try rig.trust.setStanding(.development, for: rig.client.id)
            let refused = try await rig.edit("setText", ["selector": "#title", "value": "x"])
            #expect(refused.isError == true)
            #expect(refused.allText.contains("Developer access"), "\(refused.allText)")
            #expect(try await markup(rig) == before)
        }
    }

    // MARK: Selectors

    @Test(.timeLimit(.minutes(3)))
    func unrestrictedSelectorsOnlyOnDeveloperSites() async throws {
        let selector: Value = "input[type=hidden][value^=tok-]"
        try await ScriptingRig.with(html: Self.page) { rig in
            let developer = try await rig.call("findElements", ["selector": selector])
            #expect(developer.isError == false, "\(developer.allText)")
            let matches = try Self.items(developer)
            #expect(matches.count == 1)

            // Development reads only what the runtime exposes: a selector on a hidden field's value would recover it.
            try rig.trust.setStanding(.development, for: rig.client.id)
            let development = try await rig.call("findElements", ["selector": selector])
            #expect(development.allText.contains("not exposed"), "\(development.allText)")
            #expect(try await rig.call("findElements", ["selector": "#title"]).isError == false)

            // And once the page is off the developer sites there is no access to either.
            try rig.trust.setIncludesThisMac(false)
            #expect(try await rig.call("findElements", ["selector": selector]).isError == true)
        }
    }

    private static func items(_ result: CallTool.Result) throws -> [[String: Any]] {
        try #require(try ScriptingRig.payload(result, prefix: "ELEMENTS:")["items"] as? [[String: Any]])
    }

    // MARK: Full inspection

    @Test(.timeLimit(.minutes(3)), arguments: BrowserEngine.allCases)
    func fullInspectionShowsAttributesButNeverTypedSecrets(engine: BrowserEngine) async throws {
        try await ScriptingRig.with(engine: engine, html: Self.page) { rig in
            let typedSecret = "Zx9-wire-Pa$$word!"
            let read = try await rig.call("readPage")
            let content = try #require(read.fields["content"]?.stringValue)
            let line = try #require(content.split(separator: "\n").first { $0.contains("field \"Password\"") })
            let passwordRef = try #require(Int(line.dropFirst().prefix { $0.isNumber }))
            let typed = try await rig.call("typeOnPage", ["ref": .int(passwordRef), "text": .string(typedSecret), "secret": true])
            #expect(typed.isError == false, "\(typed.allText)")
            // The page copies what was typed into markup the reader can see.
            _ = try await rig.page("document.getElementById('note').setAttribute('data-echo', document.getElementById('pw').value); 1")

            let note = try await rig.find("#note")
            let full = try await rig.call(
                "inspectElement", ["observationID": .string(note.observation), "ref": .int(note.ref), "full": true])
            #expect(full.isError == false, "\(full.allText)")
            #expect(!full.allText.contains(typedSecret), "the page's copy of the typed secret")
            let element = try ScriptingRig.payload(full, prefix: "ELEMENT:")
            let detail = try #require(element["full"] as? [String: Any])
            let attributes = try #require(detail["attributes"] as? [String: String])
            #expect(attributes["id"] == "note")
            #expect(attributes["data-echo"]?.contains("‹") == true, "the attribute is there, with the secret hidden: \(attributes)")
            #expect((detail["computed"] as? [String: String])?.count ?? 0 > 40, "all computed properties")
            #expect((detail["outerHTML"] as? String)?.hasPrefix("<p id=\"note\"") == true)

            // The computed properties named are the ones returned.
            let some = try await rig.call(
                "inspectElement",
                ["observationID": .string(note.observation), "ref": .int(note.ref), "full": true, "properties": "display, color"])
            let computed = try #require((try ScriptingRig.payload(some, prefix: "ELEMENT:")["full"] as? [String: Any])?["computed"] as? [String: String])
            #expect(Set(computed.keys) == ["display", "color"])

            // Field values are blanked in the markup; a card number never shows, as a value or in any attribute.
            let card = try await rig.find("#card")
            let cardFull = try await rig.call(
                "inspectElement", ["observationID": .string(card.observation), "ref": .int(card.ref), "full": true])
            #expect(cardFull.isError == false, "\(cardFull.allText)")
            #expect(!cardFull.allText.contains("4242"), "\(cardFull.allText)")
            let user = try await rig.find("#user")
            let userFull = try await rig.call(
                "inspectElement", ["observationID": .string(user.observation), "ref": .int(user.ref), "full": true])
            let userHTML = try #require((try ScriptingRig.payload(userFull, prefix: "ELEMENT:")["full"] as? [String: Any])?["outerHTML"] as? String)
            #expect(userHTML == "<input id=\"user\" name=\"username\">", "the field's value is blanked in the markup")

            // WSurf's own elements are not inspected.
            let ring = try await rig.find("#ring")
            let own = try await rig.call("inspectElement", ["observationID": .string(ring.observation), "ref": .int(ring.ref), "full": true])
            #expect(own.allText.contains("belongs to WSurf"), "\(own.allText)")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func fullInspectionIsForTheDeveloperTierOnly() async throws {
        try await ScriptingRig.with(html: Self.page) { rig in
            let note = try await rig.find("#note")
            try rig.trust.setStanding(.development, for: rig.client.id)
            let arguments: [String: Value] = ["observationID": .string(note.observation), "ref": .int(note.ref)]
            let refused = try await rig.call("inspectElement", arguments.merging(["full": true]) { $1 })
            #expect(refused.isError == true)
            #expect(refused.allText.contains("Developer access"), "\(refused.allText)")
            let properties = try await rig.call("inspectElement", arguments.merging(["properties": "color"]) { $1 })
            #expect(properties.isError == true)
            // The ordinary inspection is unchanged.
            let plain = try await rig.call("inspectElement", arguments)
            #expect(plain.isError == false, "\(plain.allText)")
            #expect(try ScriptingRig.payload(plain, prefix: "ELEMENT:")["full"] == nil)
        }
    }

    @Test func computedPropertyNamesAreChecked() {
        #expect(MCPBrowserSession.computedPropertyNames(nil) == [])
        #expect(MCPBrowserSession.computedPropertyNames("  ") == [])
        #expect(MCPBrowserSession.computedPropertyNames("display, -webkit-appearance,color") == ["display", "-webkit-appearance", "color"])
        #expect(MCPBrowserSession.computedPropertyNames("display,") == nil)
        #expect(MCPBrowserSession.computedPropertyNames("a b") == nil)
        #expect(MCPBrowserSession.computedPropertyNames("color;x") == nil)
        #expect(MCPBrowserSession.computedPropertyNames(Array(repeating: "color", count: 33).joined(separator: ",")) == nil)
        #expect(MCPBrowserSession.computedPropertyNames(Array(repeating: "color", count: 32).joined(separator: ","))?.count == 32)
    }
}
