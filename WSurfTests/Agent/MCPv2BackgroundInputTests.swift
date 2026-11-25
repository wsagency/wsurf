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
        <button id=picker class=box style="top: 370px" onclick="document.body.dataset.picked = 'asked'; hidden.click()">Pick</button>
        <input id=hidden type=file style="display: none">
        <a id=link class=box style="top: 420px" href="/other">Linked page</a>
        <a id=wrapped class=box style="left: 200px; top: 420px" href="/other"><span id=icon style="display: block; height: 36px"></span></a>
        <button id=swap class=box style="top: 470px" onmouseover="swapOnHover(this)">Harmless</button>
        <button id=relabel class=box style="left: 200px; top: 470px" onmouseover="this.textContent = 'Delete account'"
          onclick="document.body.dataset.relabelled = 'clicked'">Harmless too</button>
        <script>
          window.events = [];
          for (const type of ['click', 'dblclick', 'contextmenu', 'auxclick', 'mousemove', 'wheel', 'keydown', 'mousedown', 'mouseup']) {
            document.addEventListener(type, e => window.events.push({ type, trusted: e.isTrusted, button: e.button, shift: e.shiftKey,
              meta: e.metaKey, key: e.key || '', target: e.target.id || '' }), true);
          }
          document.addEventListener('contextmenu', e => e.preventDefault());
          // A link around a component: the point hits an element inside the component's shadow root.
          icon.attachShadow({ mode: 'open' }).innerHTML = '<span style="display: block; height: 36px">Icon</span>';
          // A page that puts another element under the pointer when it arrives, between the move and the press.
          function swapOnHover(el) {
            const other = document.createElement('button');
            other.id = 'pay'; other.className = 'box'; other.style.top = '470px'; other.textContent = 'Delete account';
            other.onclick = () => { document.body.dataset.paid = 'yes'; };
            el.replaceWith(other);
          }
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

    // MARK: Modifier clicks are the agent's, not the person's

    /// A link clicked with Shift, Command or Command+Shift through the agent opens at most a background tab: no Peek, the person's
    /// tab stays selected, and their focus does not move. Option on a link (a download) is refused before anything is sent.
    @Test func modifierClicksOnALinkNeverPeekOrTakeThePersonsPlace() async throws {
        let routes: [String: HTTPFixtureServer.Response] = ["/": .html(Self.page), "/other": .html("<p>Other</p>")]
        try await MCPPhase2Rig.with(engine: .chromium, routes: routes) { rig in
            var peeked: [URL] = []
            rig.browser.onOpenInPeek = { _, url, _ in peeked.append(url) }
            let responder = rig.window.firstResponder
            let point = try await rig.centre(of: "link")
            for modifiers in ["shift", "command", "command+shift"] {
                let before = rig.browser.tabs.count
                let clicked = try await rig.call(
                    "clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y), "modifiers": .string(modifiers)])
                #expect(clicked.isError == false, "\(modifiers): \(MCPPhase2Rig.text(clicked))")
                #expect(await waitUntil(timeout: .seconds(10)) { rig.browser.tabs.count > before }, "\(modifiers): a tab opened")
                #expect(peeked.isEmpty, "\(modifiers): no Peek")
                #expect(rig.browser.activeTabID == rig.owner.id, "\(modifiers): the person's tab stays selected")
                #expect(rig.window.firstResponder === responder, "\(modifiers): focus did not move")
            }
            let wrapped = try await rig.centre(of: "wrapped")
            for target in [point, wrapped] {
                let option = try await rig.call("clickOnPage", rig.shared, ["x": .double(target.x), "y": .double(target.y), "modifiers": "option"])
                #expect(option.isError == true && MCPPhase2Rig.text(option).contains("Option-click"), "\(MCPPhase2Rig.text(option))")
            }
            #expect(rig.shared.page.url?.path == "/", "the link was never followed")
        }
    }

    // MARK: The target is checked again before the press

    @Test func anElementSwappedInOnHoverIsNeverPressed() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            var asked: [SensitiveAction.Category] = []
            let swap = try await rig.centre(of: "swap")
            let swapped = try await AgentActionConsent.$decisionForTesting.withValue(.init { _, category, _, _ in
                asked.append(category)
                return .allowOnce
            }) {
                try await rig.call("clickOnPage", rig.shared, ["x": .double(swap.x), "y": .double(swap.y)])
            }
            #expect(swapped.isError == true && MCPPhase2Rig.text(swapped).contains("another element"), "\(MCPPhase2Rig.text(swapped))")
            #expect(await rig.js("document.body.dataset.paid || ''") as? String == "", "the swapped-in button was not pressed")
            #expect(asked.isEmpty, "approval was never given for the element that appeared")

            let relabel = try await rig.centre(of: "relabel")
            let changed = try await rig.call("clickOnPage", rig.shared, ["x": .double(relabel.x), "y": .double(relabel.y)])
            #expect(changed.isError == true && MCPPhase2Rig.text(changed).contains("changed under the pointer"), "\(MCPPhase2Rig.text(changed))")
            #expect(await rig.js("document.body.dataset.relabelled || ''") as? String == "", "the relabelled button was not pressed")
        }
    }

    @Test func focusEmulationEndsWhenTheUserTakesTheTabBack() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let read = try await rig.call("readPage", rig.shared)
            let field = try MCPPhase2Rig.ref("field", "Field", in: read)
            let pressed = try await rig.call("pressKey", rig.shared, ["ref": .int(field), "key": "x", "modifiers": ""])
            #expect(pressed.isError == false, "\(MCPPhase2Rig.text(pressed))")
            let chromium = try #require(rig.shared.page.chromium)
            #expect(chromium.agentFocusEmulated, "a parked page is focused for the agent's keys")
            rig.session.handBack(rig.shared)
            #expect(!chromium.agentFocusEmulated, "taking the tab back ends it")
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

    /// A button whose own handler opens a hidden file input: the hit test sees only a button, so the engine's chooser is what
    /// must not appear. Nobody planned a selection and the page is out of sight, so WSurf cancels it.
    @Test func aButtonThatOpensAFileInputShowsNoPanel() async throws {
        try await MCPPhase2Rig.with(engine: .chromium, routes: ["/": .html(Self.page)]) { rig in
            let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let point = try await rig.centre(of: "picker")
            let clicked = try await rig.call("clickOnPage", rig.shared, ["x": .double(point.x), "y": .double(point.y)])
            #expect(clicked.isError == false, "\(MCPPhase2Rig.text(clicked))")
            #expect(await waitUntil { await rig.js("document.body.dataset.picked || ''") as? String == "asked" }, "the handler ran")
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig.window.attachedSheet == nil, "no file panel on the window")
            #expect(!NSApp.windows.contains { !windows.contains(ObjectIdentifier($0)) && $0 is NSOpenPanel }, "no file panel at all")
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
