// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// MCP v2 Phase 2, Part A: trusted pointer and keyboard input through DevTools in a Chromium tab parked out of sight. The
/// person's tab stays selected, the window's first responder does not move, and the page sees `isTrusted` events. A parked
/// WebKit tab refuses with a way forward. The protections of a ref click hold at a point too: file inputs, password reveal
/// toggles on a protected form, and consequential buttons.
@MainActor
@Suite(.serialized, .boundedWebViews, .noAnnouncePause)
struct MCPv2BackgroundInputTests {
    static let page = """
        <!doctype html><title>Input</title><meta name="viewport" content="width=device-width">
        <style>
          body { margin: 0; font: 14px -apple-system, sans-serif; }
          .box { position: absolute; left: 20px; width: 140px; height: 36px; }
          #target { top: 20px } #hover { top: 70px; background: #eee } #field { top: 120px }
          #scroller { position: absolute; left: 300px; top: 20px; width: 160px; height: 100px; overflow: auto }
          #pw { top: 170px } #reveal { top: 170px; left: 180px; width: 36px }
          #upload { top: 220px; display: block } #file { position: absolute; left: 400px; top: 220px }
          #delete { top: 270px } #knob { top: 320px; background: #cde; touch-action: none }
        </style>
        <button id=target class=box>Target</button>
        <div id=hover class=box onmouseover="document.title = 'Hovered'">Hover me</div>
        <input id=field class=box aria-label=Field>
        <div id=scroller><div style="height: 1200px">Tall</div></div>
        <form id=login onsubmit="event.preventDefault()">
          <input id=pw class=box type=password aria-label=Password autocomplete=current-password>
          <button id=reveal class=box type=button onclick="pw.type = pw.type === 'password' ? 'text' : 'password'"><svg width=16 height=16></svg></button>
        </form>
        <label id=upload class=box for=file>Upload</label><input id=file type=file aria-label=File>
        <button id=delete class=box onclick="document.body.dataset.deleted = 'yes'">Delete account</button>
        <div id=knob class=box>Knob</div>
        <script>
          window.events = [];
          for (const type of ['click', 'dblclick', 'contextmenu', 'auxclick', 'mousemove', 'wheel', 'keydown', 'mousedown', 'mouseup']) {
            document.addEventListener(type, e => window.events.push({ type, trusted: e.isTrusted, button: e.button, shift: e.shiftKey,
              meta: e.metaKey, key: e.key || '', target: e.target.id || '' }), true);
          }
          document.addEventListener('contextmenu', e => e.preventDefault());
        </script>
        """

    private func events(_ rig: MCPPhase2Rig, _ type: String) async -> [[String: Any]] {
        let all = await rig.js("window.events") as? [[String: Any]] ?? []
        return all.filter { $0["type"] as? String == type }
    }

    /// Nothing the person sees changed: their tab is selected, the shared page stays parked, focus stayed where it was.
    private func expectUntouched(_ rig: MCPPhase2Rig, responder: NSResponder?, _ engine: BrowserEngine) {
        #expect(rig.browser.activeTabID == rig.owner.id, "\(engine): the person's tab stays selected")
        #expect(rig.shared.page.isParked, "\(engine): the shared page stays out of sight")
        #expect(rig.window.firstResponder === responder, "\(engine): the window's first responder did not move")
    }

    // MARK: Chromium in the background

    @Test func chromiumClicksAtAPointWithTrustedInputInTheBackground() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let responder = rig.window.firstResponder
            let point = try await rig.centre(of: "target")
            let clicked = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y)])
            #expect(clicked.isError == false, "\(MCPPhase2Rig.text(clicked))")
            #expect(await waitUntil { await !events(rig, "click").isEmpty })
            let click = try #require(await events(rig, "click").first)
            #expect(click["trusted"] as? Bool == true, "a DevTools click is trusted input")
            #expect(click["target"] as? String == "target")

            let right = try await rig.call(
                "clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y), "button": "right"])
            #expect(right.isError == false, "\(MCPPhase2Rig.text(right))")
            #expect(await waitUntil { await events(rig, "contextmenu").first?["trusted"] as? Bool == true })
            #expect(await events(rig, "contextmenu").first?["button"] as? Int == 2)

            let double = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y), "clickCount": 2])
            #expect(double.isError == false, "\(MCPPhase2Rig.text(double))")
            #expect(await waitUntil { await events(rig, "dblclick").first?["trusted"] as? Bool == true })

            let shifted = try await rig.call(
                "clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y), "modifiers": "shift"])
            #expect(shifted.isError == false, "\(MCPPhase2Rig.text(shifted))")
            #expect(await waitUntil { await events(rig, "click").contains { $0["shift"] as? Bool == true } })

            let control = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y), "modifiers": "control"])
            #expect(control.isError == true && MCPPhase2Rig.text(control).contains("Control"), "\(MCPPhase2Rig.text(control))")
            expectUntouched(rig, responder: responder, .chromium)
        }
    }

    @Test func chromiumClicksARefWithPointerInputInTheBackground() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let target = try MCPPhase2Rig.ref("button", "Target", in: read)
            let clicked = try await rig.call("clickOnPage", rig.shared, ["ref": .int(target), "pointer": true])
            #expect(clicked.isError == false, "\(MCPPhase2Rig.text(clicked))")
            #expect(await waitUntil { await events(rig, "click").first?["trusted"] as? Bool == true })
        }
    }

    @Test func chromiumHoversScrollsAndTypesInTheBackground() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let responder = rig.window.firstResponder
            let hover = try await rig.centre(of: "hover")
            let hovered = try await rig.call("hoverOnPage", rig.shared, ["x": .double(hover.x), "y": .double(hover.y)])
            #expect(hovered.isError == false, "\(MCPPhase2Rig.text(hovered))")
            #expect(await waitUntil { await rig.js("document.title") as? String == "Hovered" })
            #expect(await events(rig, "mousemove").first?["trusted"] as? Bool == true)

            let scroller = try await rig.centre(of: "scroller")
            let scrolled = try await rig.call(
                "scrollPage", rig.shared, ["direction": "down", "x": .double(scroller.x), "y": .double(scroller.y)])
            #expect(scrolled.isError == false, "\(MCPPhase2Rig.text(scrolled))")
            #expect(await waitUntil { (await rig.js("document.getElementById('scroller').scrollTop") as? Double ?? 0) > 0 })
            #expect(await events(rig, "wheel").first?["trusted"] as? Bool == true)

            let read = try await rig.call("readPage", rig.shared)
            let field = try MCPPhase2Rig.ref("field", "Field", in: read)
            for key in ["h", "i"] {
                let pressed = try await rig.call("pressKey", rig.shared, ["ref": .int(field), "key": .string(key), "modifiers": ""])
                #expect(pressed.isError == false, "\(MCPPhase2Rig.text(pressed))")
            }
            #expect(await waitUntil { await rig.js("document.getElementById('field').value") as? String == "hi" })
            #expect(await events(rig, "keydown").allSatisfy { $0["trusted"] as? Bool == true })
            let left = try await rig.call("pressKey", rig.shared, ["ref": .int(field), "key": "ArrowLeft", "modifiers": "shift"])
            #expect(left.isError == false, "\(MCPPhase2Rig.text(left))")

            for (key, modifiers) in [("W", "command"), ("Q", "command"), ("C", "command"), ("T", "control"), ("V", "command")] {
                let refused = try await rig.call("pressKey", rig.shared, ["ref": .int(field), "key": .string(key), "modifiers": .string(modifiers)])
                #expect(refused.isError == true, "\(modifiers)+\(key) is never sent: \(MCPPhase2Rig.text(refused))")
                #expect(MCPPhase2Rig.text(refused).contains("never sent"), "\(MCPPhase2Rig.text(refused))")
            }
            #expect(await rig.js("document.getElementById('field').value") as? String == "hi", "no refused chord reached the page")
            expectUntouched(rig, responder: responder, .chromium)
            #expect(!rig.browser.tabs.isEmpty && rig.window.isVisible, "no app shortcut closed anything")
        }
    }

    @Test func chromiumDragsWithPointerInputInTheBackground() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let target = try MCPPhase2Rig.ref("button", "Target", in: read)
            let dragged = try await rig.call("dragOnPage", rig.shared, ["ref": .int(target), "dx": 40, "dy": 0, "pointer": true])
            #expect(dragged.isError == false, "\(MCPPhase2Rig.text(dragged))")
            #expect(await waitUntil { await events(rig, "mouseup").first?["trusted"] as? Bool == true })
            #expect(rig.shared.page.isParked)
        }
    }

    // MARK: WebKit in the background

    @Test func webKitRefusesBackgroundPointerAndKeyboardWithAWayForward() async throws {
        try await MCPPhase2Rig.with(engine: .webKit, routes: ["/": .html(Self.page)]) { rig in
            let point = try await rig.centre(of: "target")
            let clicked = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y)])
            #expect(clicked.isError == true)
            #expect(MCPPhase2Rig.text(clicked).contains("switchTab"), "\(MCPPhase2Rig.text(clicked))")
            let read = try await rig.call("readPage", rig.shared)
            let hover = try MCPPhase2Rig.ref("button", "Target", in: read)
            let hovered = try await rig.call("hoverOnPage", rig.shared, ["ref": .int(hover)])
            #expect(hovered.isError == true && MCPPhase2Rig.text(hovered).contains("Chromium"), "\(MCPPhase2Rig.text(hovered))")
            let pressed = try await rig.call("pressKey", rig.shared, ["ref": .int(hover), "key": "Enter"])
            #expect(pressed.isError == true && MCPPhase2Rig.text(pressed).contains("switchTab"), "\(MCPPhase2Rig.text(pressed))")
            #expect(await events(rig, "click").isEmpty, "nothing reached the page")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func developmentInfoReportsBackgroundInput(engine: BrowserEngine) async throws {
        try await MCPPhase2Rig.with(engine: engine, routes: ["/": .html(Self.page)]) { rig in
            let info = try await rig.call("getDevelopmentInfo", rig.shared)
            let capabilities = try #require(info.structuredContent?.objectValue?["capabilities"]?.objectValue, "\(MCPPhase2Rig.text(info))")
            let expected = engine == .chromium ? "supported" : "unsupported"
            #expect(capabilities["backgroundPointer"]?.stringValue == expected)
            #expect(capabilities["backgroundKeyboard"]?.stringValue == expected)
            #expect((capabilities["backgroundInputReason"] != nil) == (engine == .webKit))
        }
    }

    // MARK: Protections at a point

    @Test func aPointClickNeverOpensAFileChooser() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            for id in ["upload", "file"] {
                let point = try await rig.centre(of: id)
                let clicked = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y)])
                #expect(clicked.isError == true, "\(id): \(MCPPhase2Rig.text(clicked))")
                #expect(MCPPhase2Rig.text(clicked).contains("chooseFilesOnPage"), "\(id): \(MCPPhase2Rig.text(clicked))")
            }
            #expect(await events(rig, "click").isEmpty)
            #expect(rig.window.attachedSheet == nil, "no file panel")
        }
    }

    @Test func aRevealToggleIsRefusedWhileAPasswordIsFilled() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let password = try MCPPhase2Rig.ref("field", "Password", in: read)
            let typed = try await rig.call("typeOnPage", rig.shared, ["ref": .int(password), "text": "Phase2-Secret!42"])
            #expect(typed.isError == false, "\(MCPPhase2Rig.text(typed))")
            let point = try await rig.centre(of: "reveal")
            let atPoint = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y)])
            #expect(atPoint.isError == true && MCPPhase2Rig.text(atPoint).contains("Revealing"), "\(MCPPhase2Rig.text(atPoint))")
            #expect(!MCPPhase2Rig.text(atPoint).contains("Phase2-Secret!42"))
            #expect(await rig.js("document.getElementById('pw').type") as? String == "password", "the password stays hidden")
            #expect(await events(rig, "click").isEmpty)
        }
    }

    @Test func aConsequentialButtonAtAPointStillNeedsApproval() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            var asked: [SensitiveAction.Category] = []
            let point = try await rig.centre(of: "delete")
            let declined = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, _ in
                asked.append(category)
                return .decline
            }) {
                try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y)])
            }
            #expect(declined.isError == true, "\(MCPPhase2Rig.text(declined))")
            #expect(asked == [.deletion])
            #expect(await rig.js("document.body.dataset.deleted || ''") as? String == "", "the button was not clicked")
        }
    }
}
