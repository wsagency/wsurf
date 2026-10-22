// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP
import Testing

@testable import WSurf

/// The diff and the rendering of what an action changed, on digests built by hand.
@MainActor
struct PageActionFeedbackTests {
    private func control(
        _ ref: Int, _ kind: String = "button", _ label: String, inViewport: Bool = true, state extra: [String: String] = [:]
    ) -> PageDigest.Control {
        var state = ["text": label, "disabled": "false"]
        state.merge(extra) { $1 }
        return .init(ref: ref, kind: kind, label: label, state: state, inViewport: inViewport, line: "[\(ref)] \(kind) \"\(label)\"")
    }

    private func digest(
        document: String = "doc", url: String = "https://shop.test/", controls: [PageDigest.Control] = [], texts: [String] = [],
        focus: String? = nil, scrollY: Int = 0
    ) -> PageDigest {
        PageDigest(
            documentID: document, url: url, title: "Shop", snapshot: "s-\(controls.count)-\(texts.count)", controls: controls,
            controlTotal: controls.count, texts: texts, focus: focus, scrollY: scrollY, scrollHeight: 3_000, viewportHeight: 400)
    }

    @Test func aNewControlIsAddedAndAVanishedOneIsRemoved() {
        let before = digest(controls: [control(1, "link", "Home"), control(2, "button", "Add"), control(3, "button", "Old")])
        let after = digest(controls: [control(1, "link", "Home"), control(2, "button", "Add"), control(4, "button", "Checkout")])
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked “Add”.", before: before, after: after)
        #expect(effect.added == [.init(ref: 4, text: "[4] button \"Checkout\"")])
        #expect(effect.removed == [3])
        #expect(effect.navigation == .none)
        let text = effect.render().text
        #expect(text.hasPrefix("Clicked “Add”."))
        #expect(text.contains("added (1):\n[4] button \"Checkout\""))
        #expect(text.contains("removed: [3]"))
        #expect(effect.render().refs == [4])
    }

    @Test func changedStateIsReportedFieldByField() {
        let before = digest(controls: [
            control(1, "link", "Cart (0)"), control(2, "checkbox", "Gift", state: ["checked": "false"]),
            control(3, "field", "Note", state: ["value": ""]), control(4, "button", "Menu", state: ["expanded": "false"]),
        ])
        let after = digest(controls: [
            control(1, "link", "Cart (1)"), control(2, "checkbox", "Gift", state: ["checked": "true", "disabled": "true"]),
            control(3, "field", "Note", state: ["value": "hello"]), control(4, "button", "Menu", state: ["expanded": "true"]),
        ])
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked.", before: before, after: after)
        #expect(effect.changed.contains(.init(ref: 1, field: "text", from: "Cart (0)", to: "Cart (1)")))
        #expect(effect.changed.contains(.init(ref: 2, field: "checked", from: "false", to: "true")))
        #expect(effect.changed.contains(.init(ref: 2, field: "disabled", from: "false", to: "true")))
        #expect(effect.changed.contains(.init(ref: 3, field: "value", from: "", to: "hello")))
        #expect(effect.changed.contains(.init(ref: 4, field: "expanded", from: "false", to: "true")))
        let text = effect.render().text
        #expect(text.contains("[1] text \"Cart (0)\" → \"Cart (1)\""))
        #expect(text.contains("[2] checked false → true"))
    }

    @Test func aSensitiveFieldReportsThatItIsFilledNeverWhatItHolds() {
        let before = digest(controls: [control(1, "field", "Security code", state: ["filled": "false"])])
        let after = digest(controls: [control(1, "field", "Security code", state: ["filled": "true"])])
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked.", before: before, after: after)
        #expect(effect.changed == [.init(ref: 1, field: "filled", from: "false", to: "true")])
        #expect(effect.render().text.contains("[1] filled false → true"))
    }

    @Test func textThatOnlyRepeatsAControlLabelIsNotReportedTwice() {
        let before = digest(controls: [control(1, "link", "Cart (0)")], texts: ["Cart (0)", "Welcome"])
        let after = digest(controls: [control(1, "link", "Cart (1)")], texts: ["Cart (1)", "Welcome", "Added to cart"])
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked.", before: before, after: after)
        #expect(effect.textAdded == ["Added to cart"])
        #expect(effect.textRemoved.isEmpty)
    }

    @Test func repeatedTextIsCountedNotCollapsed() {
        #expect(ActionEffect.difference(["a", "b", "a"], minus: ["a"]) == ["b", "a"])
        #expect(ActionEffect.difference(["a"], minus: ["a", "a"]).isEmpty)
    }

    @Test func focusMovesAreReported() {
        let before = digest(focus: "[5] field \"Name\"")
        let after = digest(focus: "[6] button \"Save\"")
        let moved = ActionEffect.make(action: "pressKey", status: "Sent Tab.", before: before, after: after)
        #expect(moved.render().text.contains("focus: [5] field \"Name\" → [6] button \"Save\""))
        let lost = ActionEffect.make(action: "pressKey", status: "Sent Escape.", before: before, after: digest())
        #expect(lost.focus == "[5] field \"Name\" → none")
        #expect(ActionEffect.make(action: "pressKey", status: "Sent Tab.", before: before, after: before).focus == nil)
    }

    @Test func aScrollReportsItsPositionAndNeverCountsLeavingTheViewportAsRemoval() {
        let before = digest(controls: [control(1, "link", "Top")], texts: ["Top text"])
        let after = digest(controls: [control(7, "link", "Deep")], texts: ["Deep text"], scrollY: 320)
        let effect = ActionEffect.make(action: "scrollPage", status: "Scrolled down.", before: before, after: after, viewportOnly: true)
        #expect(effect.removed.isEmpty)
        #expect(effect.textRemoved.isEmpty)
        #expect(effect.added.map(\.ref) == [7])
        #expect(effect.textAdded == ["Deep text"])
        #expect(effect.scroll == "320 of 2600 px")
    }

    @Test func aNewDocumentIsDescribedInsteadOfDiffed() {
        let before = digest(document: "one", controls: [control(1, "link", "Next")], texts: ["Page one"])
        let after = digest(
            document: "two", url: "https://shop.test/next",
            controls: [control(1, "link", "Back", inViewport: false), control(2, "button", "Buy")], texts: ["Page two", "Details"])
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked “Next”.", before: before, after: after)
        #expect(effect.navigation == .load)
        #expect(effect.url == "https://shop.test/next")
        #expect(effect.added.isEmpty && effect.removed.isEmpty && effect.changed.isEmpty)
        // Controls in the viewport come first: they are the ones a client can use without scrolling.
        #expect(effect.pageControls.map(\.ref) == [2, 1])
        let rendered = effect.render()
        #expect(rendered.text.contains("navigation: load → https://shop.test/next"))
        #expect(rendered.text.contains("page text: Page two Details"))
        #expect(rendered.refs == [1, 2])
    }

    @Test func anUnchangedPageSaysSoAndAStatusOnlyEffectDoesNot() {
        let same = digest(controls: [control(1, "link", "Home")], texts: ["Hello"])
        let effect = ActionEffect.make(action: "hoverOnPage", status: "Hovered.", before: same, after: same)
        #expect(effect.isEmpty)
        #expect(effect.render().text == "Hovered.\nNo visible change.")
        var refused = ActionEffect(action: "clickOnPage", status: "The control is covered by another element.")
        refused.statusOnly = true
        #expect(refused.render().text == "The control is covered by another element.")
    }

    @Test func sameDocumentNavigationReportsTheNewURL() {
        let before = digest(url: "https://shop.test/a")
        let after = digest(url: "https://shop.test/b")
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked.", before: before, after: after)
        #expect(effect.navigation == .sameDocument)
        #expect(effect.render().text.contains("navigation: sameDocument → https://shop.test/b"))
    }

    @Test func shrinkingGivesUpDetailUntilTheRenderingFits() {
        let many = (1...60).map { control($0 + 10, "link", "Product number \($0) with a fairly long visible name") }
        let before = digest()
        let after = digest(controls: many, texts: (1...20).map { "Paragraph \($0) " + String(repeating: "x", count: 150) })
        var effect = ActionEffect.make(action: "clickOnPage", status: "Clicked.", before: before, after: after)
        effect.console = .init(errors: 9, first: (1...9).map { "Error \($0) " + String(repeating: "e", count: 300) })
        var limits = ActionEffect.Limits()
        var sizes = [effect.render(limits).text.utf8.count]
        while limits.shrink() {
            sizes.append(effect.render(limits).text.utf8.count)
        }
        #expect(sizes.first! > 1_500)
        #expect(sizes.last! < 500, "\(sizes.last!)")
        #expect(sizes == sizes.sorted(by: >), "each step keeps the rendering the same size or smaller")
        #expect(effect.render(ActionEffect.Limits(added: 0)).text.contains("added: 60 controls; readPage lists them."))
        #expect(effect.render().truncated)
    }

    @Test func aRenderingNamesOnlyTheRefsItShows() {
        let after = digest(controls: (1...30).map { control($0, "button", "Button \($0)") })
        let effect = ActionEffect.make(action: "clickOnPage", status: "Clicked.", before: digest(), after: after)
        let shown = effect.render(.init(added: 10)).refs
        #expect(shown == Set(1...10))
        #expect(effect.render(.init(added: 10)).text.contains("… 20 more; readPage lists them."))
    }

    @Test func consoleErrorsAndFailedRequestsAreListedWithinTheirLimits() {
        var effect = ActionEffect(action: "clickOnPage", status: "Clicked.")
        effect.console = .init(errors: 5, first: ["a", "b", "c", "d"])
        effect.failedRequests = [.init(method: "POST", url: "https://shop.test/api", status: 500), .init(method: "GET", url: "https://x.test/", status: nil)]
        let text = effect.render().text
        #expect(text.contains("console: 5 new errors: \"a\" | \"b\" | \"c\""))
        #expect(text.contains("failed requests: POST https://shop.test/api 500 | GET https://x.test/ failed"))
        #expect(!text.contains("\"d\""))
    }

    @Test func effectsRoundTripAsJSON() throws {
        var effect = ActionEffect(action: "clickOnPage", status: "Clicked.")
        effect.added = [.init(ref: 3, text: "[3] button \"Go\"")]
        effect.changed = [.init(ref: 1, field: "text", from: "a", to: "b")]
        effect.popups = [.init(title: "Help", url: "https://shop.test/help")]
        let decoded = try JSONDecoder().decode(ActionEffect.self, from: JSONEncoder().encode(effect))
        #expect(decoded == effect)
    }

    // MARK: Diagnostics marks

    private func record(_ buffer: PageDiagnostics.Buffer, _ stream: PageDiagnostics.Stream, _ text: String, document: String = "d1") {
        buffer.append(stream: stream, timestamp: Date(), documentID: document, fields: ["level": "error", "text": .text(text)])
    }

    @Test func aMarkSeparatesOldRecordsFromNewOnes() {
        let buffer = PageDiagnostics.Buffer(connection: UUID(), tab: "t", documentID: "d1")
        for index in 0..<230 {
            record(buffer, .console, "old \(index)")
        }
        let mark = buffer.head(of: .console)
        #expect(buffer.records(of: .console, after: mark).isEmpty, "nothing is new yet")
        record(buffer, .console, "new one")
        record(buffer, .network, "other stream")
        record(buffer, .console, "new two")
        let fresh = buffer.records(of: .console, after: mark)
        #expect(fresh.compactMap { if case .text(let text)? = $0.fields["text"] { text } else { nil } } == ["new one", "new two"])
        #expect(buffer.records(of: .network, after: buffer.head(of: .network)).isEmpty)
        #expect(buffer.head(of: .network) != nil)
    }

    @Test func aNavigationInvalidatesTheMarkSoEverythingTheNewDocumentWroteIsNew() {
        let buffer = PageDiagnostics.Buffer(connection: UUID(), tab: "t", documentID: "d1")
        record(buffer, .console, "before")
        let mark = buffer.head(of: .console)
        buffer.reset(documentID: "d2")
        record(buffer, .console, "fresh", document: "d2")
        let fresh = buffer.records(of: .console, after: mark)
        #expect(fresh.count == 1)
        #expect(buffer.records(of: .console, after: nil).count == 1)
    }

    @Test func theBudgetDefaultsAndLimitsAreTheDocumentedOnes() {
        #expect(FeedbackBudget() == FeedbackBudget(nil))
        #expect(FeedbackBudget().maxBytes == 4_000 && FeedbackBudget().settleMs == 1_500)
        let custom = FeedbackBudget(.object(["maxBytes": 8_000, "settleMs": 300]))
        #expect(custom.maxBytes == 8_000 && custom.settleMs == 300)
    }
}
