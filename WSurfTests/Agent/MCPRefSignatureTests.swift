// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A ref keeps the control the client last saw listed.
@MainActor
@Suite(.boundedWebViews)
struct MCPRefSignatureTests {
    private typealias Rig = MCPFeedbackRig

    private static let buttons = (1...25).map { "<button class=b onclick=\"window.hit='b\($0)'\">Item \($0)</button>" }.joined()

    @Test(arguments: BrowserEngine.allCases)
    func aRefWhoseControlChangedWithoutBeingListedAgainIsRefused(engine: BrowserEngine) async throws {
        // One click renames all 25 buttons; the report lists 20 of the changes, so the last five are never shown.
        let html = """
            <!doctype html><title>Relabel</title>
            <button onclick="document.querySelectorAll('.b').forEach((b, i) => { b.textContent = 'Renamed ' + (i + 1); })">Relabel all</button>
            \(Self.buttons)
            """
        let rig = try await Rig.make(engine: engine, html: html)
        defer { rig.close() }
        let read = try await rig.start()
        let relabel = try Rig.ref(of: "Relabel all", in: read)
        let first = try Rig.ref(of: "Item 1", in: read), third = try Rig.ref(of: "Item 3", in: read)
        let last = try Rig.ref(of: "Item 25", in: read)

        let renamed = try await rig.call("clickOnPage", ["ref": .int(relabel)])
        #expect(renamed.isError == false, "\(Rig.text(renamed))")
        let content = Rig.content(renamed)
        #expect(content.contains("[\(first)] text \"Item 1\" → \"Renamed 1\""), "\(content)")
        #expect(!content.contains("[\(last)] text"), "the last change was not listed: \(content)")
        #expect(content.contains("more changes"), "\(content)")

        // The client never saw what "Item 25" became: its ref is refused, not carried over to the new label.
        let unseen = try await rig.call("clickOnPage", ["ref": .int(last)])
        #expect(unseen.isError == true, "\(Rig.text(unseen))")
        #expect(try await rig.tab.page.evaluateJavaScript("window.hit === undefined") as? Bool == true)
        // A control the report did list follows its new label.
        let listed = try await rig.call("clickOnPage", ["ref": .int(first)])
        #expect(listed.isError == false, "\(Rig.text(listed))")
        #expect(try await rig.tab.page.evaluateJavaScript("window.hit") as? String == "b1")

        // A control replaced by another element is refused as well, and the reply to a read lists it afresh.
        _ = try await rig.tab.page.evaluateJavaScript(
            "const old = document.querySelectorAll('.b')[2]; old.replaceWith(old.cloneNode(true)); 0")
        let replaced = try await rig.call("clickOnPage", ["ref": .int(third)])
        #expect(replaced.isError == true, "\(Rig.text(replaced))")
        let again = try await rig.call("readPage")
        let fresh = try Rig.ref(of: "Renamed 3", in: again)
        #expect(fresh != third)
        #expect(try await rig.call("clickOnPage", ["ref": .int(fresh)]).isError == false)
    }
}
