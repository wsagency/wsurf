// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Key chords and drags on live pages, on both engines.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageInputTests {
    // MARK: Fixtures

    private func withPage(
        engine: BrowserEngine, html: String, body: (BrowserPage, NSWindow) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><body style='margin:0'>\(html)</body>")])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration), context: context)
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            view = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        do {
            view.load(URLRequest(url: url))
            try #require(await waitUntil { view.url == url && !view.isLoading })
            try await body(view, window)
        } catch {
            await view.close()
            await context.endPrivateSession()
            throw error
        }
        await view.close()
        await context.endPrivateSession()
    }

    private func records(_ view: BrowserPage, _ name: String) async throws -> [[String: Any]] {
        let json = try await view.evaluateJavaScript("JSON.stringify(window.\(name) || [])") as? String
        return (try JSONSerialization.jsonObject(with: Data((json ?? "[]").utf8)) as? [[String: Any]]) ?? []
    }

    private func ref(labelled label: String, in view: BrowserPage) async throws -> Int {
        let observation = await PageDriver.readRenderedPage(view)
        let line = try #require(observation.split(separator: "\n").first { $0.contains("\"\(label)\"") }, "\(label) in \(observation)")
        let close = try #require(line.firstIndex(of: "]"))
        return try #require(Int(line[line.index(after: line.startIndex)..<close]))
    }

    private static let recorder = """
        <script>window.keys = [];
        for (const type of ['keydown', 'keyup']) document.addEventListener(type, e => window.keys.push({
          type, key: e.key, code: e.code, shift: e.shiftKey, alt: e.altKey, ctrl: e.ctrlKey, meta: e.metaKey, trusted: e.isTrusted }), true);
        </script>
        """

    /// Everything Command or Control could reach outside the page: the app's own shortcuts, as menu items that only record.
    @MainActor
    private final class MenuProbe: NSObject {
        private(set) var fired: [String] = []
        private var previous: NSMenu?

        @objc func fire(_ sender: NSMenuItem) {
            fired.append(sender.title)
        }

        func install() {
            previous = NSApp.mainMenu
            let root = NSMenu(), top = NSMenuItem(), submenu = NSMenu()
            root.addItem(top)
            top.submenu = submenu
            let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            var items = "wqtnlrpsofhm,cxv".map { (String($0), NSEvent.ModifierFlags.command) }
            items += [(left, .command), (right, .command), ("w", .control), ("q", .control), ("[", .command), ("]", .command)]
            for (key, flags) in items {
                let item = NSMenuItem(title: "\(flags == .command ? "Command" : "Control")+\(key)", action: #selector(fire(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = flags
                item.target = self
                submenu.addItem(item)
            }
            NSApp.mainMenu = root
        }

        func restore() {
            NSApp.mainMenu = previous
        }
    }

    // MARK: Chords

    private struct ChordCase {
        let key: String
        let modifiers: String
        let name: String
        let event: String
        let code: String
        let shift: Bool
        let alt: Bool
    }

    @Test(arguments: BrowserEngine.allCases)
    func shiftAndOptionChordsReachThePage(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: "<input aria-label='Query'>" + Self.recorder) { view, _ in
            let input = try await ref(labelled: "Query", in: view)
            let cases = [
                ChordCase(key: "ArrowLeft", modifiers: "shift+option", name: "Shift+Option+ArrowLeft", event: "ArrowLeft", code: "ArrowLeft", shift: true, alt: true),
                ChordCase(key: "b", modifiers: "option", name: "Option+B", event: "b", code: "KeyB", shift: false, alt: true),
                ChordCase(key: "a", modifiers: "shift", name: "Shift+A", event: "A", code: "KeyA", shift: true, alt: false),
                ChordCase(key: "?", modifiers: "", name: "Shift+/", event: "?", code: "Slash", shift: true, alt: false),
                ChordCase(key: "PageDown", modifiers: "", name: "PageDown", event: "PageDown", code: "PageDown", shift: false, alt: false),
                ChordCase(key: "Tab", modifiers: "shift", name: "Shift+Tab", event: "Tab", code: "Tab", shift: true, alt: false),
            ]
            for item in cases {
                _ = try await view.evaluateJavaScript("window.keys = []; document.querySelector('input').focus()")
                let result = await PageDriver.pressKey(item.key, ref: input, modifiers: item.modifiers, in: view)
                #expect(result.hasPrefix("Sent \(item.name)."), "engine \(engine): \(result)")
                try #require(await waitUntil { try await records(view, "keys").count >= 2 }, "\(item.name) on \(engine)")
                let events = try await records(view, "keys")
                #expect(events.compactMap { $0["type"] as? String } == ["keydown", "keyup"], "\(item.name) on \(engine)")
                for event in events {
                    #expect(event["key"] as? String == item.event, "\(item.name) on \(engine): \(event)")
                    #expect(event["code"] as? String == item.code, "\(item.name) on \(engine): \(event)")
                    #expect(event["shift"] as? Bool == item.shift, "\(item.name) on \(engine): \(event)")
                    #expect(event["alt"] as? Bool == item.alt, "\(item.name) on \(engine): \(event)")
                    #expect(event["ctrl"] as? Bool == false)
                    #expect(event["meta"] as? Bool == false)
                    #expect(event["trusted"] as? Bool == true)
                }
            }
        }
    }

    /// The fixture's input holds `abc`, is focused and has no recorded keys.
    private static func resetInput(caret: Int) -> String {
        "(() => { window.keys = []; const i = document.querySelector('input'); i.value = 'abc'; i.focus(); i.setSelectionRange(\(caret), \(caret)); })()"
    }

    private static let allowedCommandChords: [(key: String, modifiers: String, event: String)] = [
        ("a", "command", "a"), ("z", "command", "z"), ("z", "command+shift", "Z"), ("ArrowLeft", "command", "ArrowLeft"),
        ("ArrowRight", "command+shift", "ArrowRight"), ("ArrowUp", "command", "ArrowUp"), ("ArrowDown", "command", "ArrowDown"),
        ("Enter", "command", "Enter"), ("Backspace", "command", "Backspace"), ("Delete", "command", "Delete"),
    ]

    @Test(arguments: BrowserEngine.allCases)
    func allowedCommandChordsAreDelivered(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: "<input aria-label='Query' value='abc'>" + Self.recorder) { view, _ in
            let input = try await ref(labelled: "Query", in: view)
            for item in Self.allowedCommandChords {
                _ = try await view.evaluateJavaScript(Self.resetInput(caret: 3))
                let result = await PageDriver.pressKey(item.key, ref: input, modifiers: item.modifiers, in: view)
                #expect(result.hasPrefix("Sent Command"), "engine \(engine): \(item.key) \(item.modifiers): \(result)")
                try #require(await waitUntil { try await records(view, "keys").count >= 2 }, "\(item.key) on \(engine)")
                let events = try await records(view, "keys")
                #expect(events.compactMap { $0["type"] as? String } == ["keydown", "keyup"], "\(item.key) on \(engine)")
                for event in events {
                    #expect(event["key"] as? String == item.event, "\(item.key) on \(engine): \(event)")
                    #expect(event["meta"] as? Bool == true, "\(item.key) on \(engine): \(event)")
                    #expect(event["ctrl"] as? Bool == false)
                    #expect(event["trusted"] as? Bool == true)
                }
            }
            // Select All is completed natively, as it is for the assistant.
            _ = try await view.evaluateJavaScript(Self.resetInput(caret: 1))
            _ = await PageDriver.pressKey("a", ref: input, modifiers: "command", in: view)
            #expect(try await view.evaluateJavaScript("(() => { const i = document.querySelector('input'); return i.selectionStart === 0 && i.selectionEnd === 3; })()") as? Bool == true)
        }
    }

    /// A chord the boundary refuses is never turned into a key event, so neither the page nor any menu sees it. A key an
    /// engine hands back to the app would reach these menu items; none fires, for refused and for allowed chords alike.
    @Test(arguments: BrowserEngine.allCases)
    func chordsNeverCloseTabsOrReachMenus(engine: BrowserEngine) async throws {
        let probe = MenuProbe()
        probe.install()
        defer { probe.restore() }
        try await withPage(engine: engine, html: "<input aria-label='Query' value='abc'><button>Plain</button>" + Self.recorder) { view, window in
            let windowsBefore = NSApp.windows.count
            let input = try await ref(labelled: "Query", in: view)
            let button = try await ref(labelled: "Plain", in: view)
            let refused: [(String, String)] =
                "wqtnlrpsofhm,cxv".map { (String($0), "command") } + [
                    ("w", "command+shift"), ("q", "command+shift"), ("w", "control"), ("q", "control"), ("a", "control"), ("i", "command+option"),
                    ("Escape", "command+option"), ("Tab", "command"), ("Space", "command"), ("[", "command"), ("]", "command"),
                ]
            for (key, modifiers) in refused {
                let result = await PageDriver.pressKey(key, ref: input, modifiers: modifiers, in: view)
                #expect(!result.hasPrefix("Sent"), "engine \(engine): \(key) \(modifiers): \(result)")
            }
            // Command with a text-editing key goes to a text field only: elsewhere an unhandled one reaches the menu (Back, say).
            for key in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Backspace", "Delete"] {
                let notTextField = await PageDriver.pressKey(key, ref: button, modifiers: "command", in: view)
                #expect(notTextField.contains("is sent only to a text field"), "engine \(engine): \(key): \(notTextField)")
            }
            #expect(try await records(view, "keys").isEmpty, "a refused chord reached the page on \(engine)")
            for item in Self.allowedCommandChords {
                _ = try await view.evaluateJavaScript(Self.resetInput(caret: 3))
                _ = await PageDriver.pressKey(item.key, ref: input, modifiers: item.modifiers, in: view)
            }
            #expect(probe.fired.isEmpty, "a key reached the app's menu on \(engine): \(probe.fired)")
            #expect(window.isVisible)
            #expect(NSApp.windows.count == windowsBefore, "a window opened or closed on \(engine)")
        }
    }

    @Test func commandEnterOnAConsequentialControlNeedsApproval() async throws {
        try await withPage(
            engine: .webKit, html: "<button onkeydown='window.keyed = true'>Send message</button>"
        ) { view, _ in
            let button = try await ref(labelled: "Send message", in: view)
            let declined = await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in .decline }) {
                await PageDriver.pressKey("Enter", ref: button, modifiers: "command", in: view)
            }
            #expect(declined.contains("declined"), "\(declined)")
            #expect(try await view.evaluateJavaScript("window.keyed === undefined") as? Bool == true)
            let allowed = await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in .allowOnce }) {
                await PageDriver.pressKey("Enter", ref: button, modifiers: "command", in: view)
            }
            #expect(allowed.hasPrefix("Sent Command+Enter"), "\(allowed)")
            #expect(try await view.evaluateJavaScript("window.keyed === true") as? Bool == true)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func chordsNeverReachSensitiveFields(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: "<input aria-label='Password' type='password'>" + Self.recorder) { view, _ in
            let field = try await ref(labelled: "Password", in: view)
            for (key, modifiers) in [("a", "shift"), ("Enter", "command"), ("ArrowLeft", "shift+option")] {
                let result = await PageDriver.pressKey(key, ref: field, modifiers: modifiers, in: view)
                #expect(result.contains("sensitive"), "engine \(engine): \(key) \(modifiers): \(result)")
            }
            let log = try await records(view, "keys")
            #expect(log.isEmpty, "nothing reached the password field on \(engine)")
        }
    }

    /// The assistant's tool passes no modifiers: it keeps its twelve named keys, and nothing else is sent.
    @Test func theAssistantsPressKeyKeepsItsOriginalKeys() async throws {
        try await withPage(engine: .webKit, html: "<input aria-label='Query'>" + Self.recorder) { view, _ in
            let input = try await ref(labelled: "Query", in: view)
            for key in ["PageDown", "a", "?", "Command+W"] {
                let result = await PageDriver.pressKey(key, ref: input, in: view)
                #expect(result.hasPrefix("Use Enter, Tab, Escape, Space,"), "\(key): \(result)")
            }
            let log = try await records(view, "keys")
            #expect(log.isEmpty, "a refused key sent nothing")
            let sent = await PageDriver.pressKey("ArrowDown", ref: input, in: view)
            #expect(sent.hasPrefix("Sent ArrowDown."), "\(sent)")
            try #require(await waitUntil { try await records(view, "keys").count >= 2 })
        }
    }

    // MARK: Drag

    private static let dragPage = """
        <style>.box { position: absolute; width: 100px; height: 50px; border: 1px solid #000; }</style>
        <div id="card" class="box" style="left: 20px; top: 20px" draggable="true" role="button" aria-label="Card" data-testid="card">Card</div>
        <div id="zone" class="box" style="left: 220px; top: 20px" role="button" aria-label="Zone" data-testid="zone">Zone</div>
        <div id="far" class="box" style="left: 20px; top: 1600px" role="button" aria-label="Far" data-testid="far">Far</div>
        <div id="handle" class="box" style="left: 20px; top: 120px" role="button" aria-label="Handle" data-testid="handle">Handle</div>
        <input id="secret" type="password" style="position: absolute; left: 220px; top: 120px" aria-label="Pass">
        <button id="off" style="position: absolute; left: 220px; top: 180px" disabled>Off</button>
        <input id="file" type="file" style="position: absolute; left: 220px; top: 240px">
        <iframe id="frame" srcdoc="<div id='inner' data-testid='inner' style='width:60px;height:40px;background:#ccc'>Inner</div>"
          style="position: absolute; left: 20px; top: 240px; width: 150px; height: 100px; border: 0"></iframe>
        <script>
        window.log = [];
        document.getElementById('zone').addEventListener('dragover', e => e.preventDefault());
        for (const type of ['dragstart', 'dragenter', 'dragover', 'drop', 'dragend', 'pointerdown', 'pointermove', 'pointerup',
          'mousedown', 'mousemove', 'mouseup']) {
          document.addEventListener(type, e => window.log.push({
            type, id: e.target.id || e.target.tagName.toLowerCase(), x: Math.round(e.clientX), y: Math.round(e.clientY),
            buttons: e.buttons, trusted: e.isTrusted }), true);
        }
        </script>
        """

    private func types(_ log: [[String: Any]], _ id: String) -> [String] {
        log.filter { $0["id"] as? String == id }.compactMap { $0["type"] as? String }
    }

    @Test(arguments: BrowserEngine.allCases)
    func dragBetweenRefsDeliversDragAndDropEvents(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.dragPage) { view, _ in
            let card = try await ref(labelled: "Card", in: view)
            let zone = try await ref(labelled: "Zone", in: view)
            let result = await PageDriver.drag(from: .ref(card), to: .end(.ref(zone)), pointer: false, in: view)
            #expect(result.hasPrefix("Sent drag from “Card” to “Zone” (DOM events)."), "engine \(engine): \(result)")
            let log = try await records(view, "log")
            #expect(types(log, "card").contains("dragstart") && types(log, "card").contains("dragend"), "\(engine): \(log)")
            #expect(types(log, "zone").contains("dragenter") && types(log, "zone").contains("drop"), "\(engine): \(log)")
            let drop = try #require(log.first { $0["type"] as? String == "drop" })
            #expect(abs((drop["x"] as? Int ?? -1) - 271) <= 2, "the drop lands on the zone's centre: \(drop)")
            #expect(drop["trusted"] as? Bool == false, "DOM drags are untrusted events")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func selectorsAndOffsetsFindDraggablesThatAreNotControls(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.dragPage) { view, _ in
            let bySelector = await PageDriver.drag(
                from: .selector("[data-testid=card]"), to: .end(.selector("[data-testid=zone]")), pointer: false, in: view)
            #expect(bySelector.hasPrefix("Sent drag from “Card” to “Zone”"), "engine \(engine): \(bySelector)")
            #expect(types(try await records(view, "log"), "zone").contains("drop"))
            _ = try await view.evaluateJavaScript("window.log = []")
            let byOffset = await PageDriver.drag(from: .selector("#card"), to: .offset(dx: 200, dy: 0), pointer: false, in: view)
            #expect(byOffset.contains("the point (200, 0) CSS pixels away"), "engine \(engine): \(byOffset)")
            #expect(types(try await records(view, "log"), "zone").contains("drop"), "an offset lands on whatever is there")
            // A handle that is not draggable gets the pointer and mouse sequence instead.
            _ = try await view.evaluateJavaScript("window.log = []")
            _ = await PageDriver.drag(from: .selector("#handle"), to: .offset(dx: 80, dy: 0), pointer: false, in: view)
            let handle = types(try await records(view, "log"), "handle")
            #expect(handle.first == "pointerdown" && handle.last == "mouseup" && handle.contains("pointermove"), "\(engine): \(handle)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func dragIntoAFrameIsRefused(engine: BrowserEngine) async throws {
        try await withPage(engine: engine, html: Self.dragPage) { view, _ in
            let from = await PageDriver.drag(from: .selector("#inner"), to: .offset(dx: 50, dy: 0), pointer: false, in: view)
            let into = await PageDriver.drag(from: .selector("#card"), to: .end(.selector("#inner")), pointer: false, in: view)
            #expect(from.contains("inside a frame"), "engine \(engine): \(from)")
            #expect(into.contains("inside a frame"), "engine \(engine): \(into)")
            let log = try await records(view, "log")
            #expect(log.isEmpty, "nothing was dispatched on \(engine)")
        }
    }

    @Test func dragRefusesWhatCannotTakePart() async throws {
        try await withPage(engine: .webKit, html: Self.dragPage) { view, _ in
            @MainActor func refusal(_ from: String, _ to: PageDriver.DragDestination) async -> String {
                await PageDriver.drag(from: .selector(from), to: to, pointer: false, in: view)
            }
            #expect(await refusal("#card", .end(.selector("#secret"))).contains("sensitive"))
            #expect(await refusal("#secret", .offset(dx: 5, dy: 0)).contains("sensitive"))
            #expect(await refusal("#card", .end(.selector("#off"))).contains("disabled"))
            #expect(await refusal("#card", .end(.selector("#file"))).contains("File inputs"))
            #expect(await refusal("#card", .end(.selector("#far"))).contains("outside the viewport"))
            #expect(await refusal("#card", .offset(dx: 2000, dy: 0)).contains("outside the viewport"))
            #expect(await refusal("#nothing", .offset(dx: 5, dy: 0)).contains("No element matches"))
            #expect(await refusal(".box", .offset(dx: 5, dy: 0)).contains("more than one visible element"))
            #expect(await refusal("input[value^=a]", .offset(dx: 5, dy: 0)).contains("not exposed"))
            #expect(await refusal("", .offset(dx: 5, dy: 0)).contains("selector must be"))
            let log = try await records(view, "log")
            #expect(log.isEmpty, "a refused drag dispatched nothing")
        }
    }

    @Test func aDragStillNeedsTheApprovalAClickWould() async throws {
        let page = Self.dragPage.replacingOccurrences(of: "aria-label=\"Zone\"", with: "aria-label=\"Delete account\"")
        try await withPage(engine: .webKit, html: page) { view, _ in
            let declined = await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, _ in .decline }) {
                await PageDriver.drag(from: .selector("#card"), to: .end(.selector("#zone")), pointer: false, in: view)
            }
            #expect(declined.contains("declined"), "\(declined)")
            let log = try await records(view, "log")
            #expect(log.isEmpty, "a declined drag dispatched nothing")
        }
    }

    @Test func aRefFromAnOlderObservationCannotDrive() async throws {
        try await withPage(engine: .webKit, html: Self.dragPage) { view, _ in
            let card = try await ref(labelled: "Card", in: view)
            let zone = try await ref(labelled: "Zone", in: view)
            let result = await PageDriver.$expectedObservation.withValue("an-older-observation") {
                await PageDriver.drag(from: .ref(card), to: .end(.ref(zone)), pointer: false, in: view)
            }
            #expect(!result.hasPrefix("Sent"), "\(result)")
            let log = try await records(view, "log")
            #expect(log.isEmpty)
        }
    }

    // MARK: Pointer drag

    @Test func chromiumPointerDragWorksWithWSurfInTheBackground() async throws {
        try await withPage(engine: .chromium, html: Self.dragPage) { view, window in
            #expect(!window.isKeyWindow, "the window is in the background")
            let result = await PageDriver.drag(from: .selector("#handle"), to: .offset(dx: 120, dy: 0), pointer: true, in: view)
            #expect(result.hasPrefix("Sent drag from “Handle”"), "\(result)")
            #expect(result.contains("(pointer input)"))
            let log = try await records(view, "log")
            let down = try #require(log.first { $0["type"] as? String == "mousedown" }, "\(log)")
            let up = try #require(log.first { $0["type"] as? String == "mouseup" }, "\(log)")
            #expect(down["trusted"] as? Bool == true && up["trusted"] as? Bool == true, "pointer input is trusted: \(log)")
            #expect(down["id"] as? String == "handle" && abs((down["x"] as? Int ?? -1) - 71) <= 2, "the press is at the handle's centre: \(down)")
            #expect(abs((up["x"] as? Int ?? -1) - 191) <= 2, "the release is 120 px away: \(up)")
            let moves = log.filter { $0["type"] as? String == "mousemove" && $0["buttons"] as? Int == 1 }
            #expect(moves.count >= 3, "the button stays down while moving: \(log)")
            #expect(!window.isKeyWindow, "nothing activated the window")
        }
    }

    @Test func chromiumPointerDragIsExactAtPageZoom() async throws {
        try await withPage(engine: .chromium, html: Self.dragPage) { view, _ in
            view.pageZoom = 1.5
            try #require(await waitUntil { (try? await view.evaluateJavaScript("window.innerWidth") as? Int).map { $0 < 400 } ?? false })
            let expected = try #require(
                try await view.evaluateJavaScript("(() => { const r = document.getElementById('handle').getBoundingClientRect(); return Math.round(r.left + r.width / 2); })()") as? Int)
            let result = await PageDriver.drag(from: .selector("#handle"), to: .offset(dx: 60, dy: 0), pointer: true, in: view)
            #expect(result.hasPrefix("Sent drag"), "\(result)")
            let down = try #require(try await records(view, "log").first { $0["type"] as? String == "mousedown" })
            #expect(abs((down["x"] as? Int ?? -1) - expected) <= 2, "the press lands on the handle at zoom 1.5: \(down) vs \(expected)")
        }
    }

    /// A synthetic press on a draggable element would start a browser drag session that nothing can finish.
    @Test func aDraggableSourceIsRefusedInPointerMode() async throws {
        try await withPage(engine: .chromium, html: Self.dragPage) { view, _ in
            let result = await PageDriver.drag(from: .selector("#card"), to: .offset(dx: 100, dy: 0), pointer: true, in: view)
            #expect(result.contains("starts a browser drag session"), "\(result)")
            let log = try await records(view, "log")
            #expect(log.isEmpty, "nothing was pressed")
        }
    }

    /// Native mouse events reach a window of an inactive app, so a WebKit pointer drag needs no foreground session.
    @Test func webKitPointerDragDeliversTrustedEvents() async throws {
        try await withPage(engine: .webKit, html: Self.dragPage) { view, window in
            #expect(!window.isKeyWindow, "the window is in the background")
            let result = await PageDriver.drag(from: .selector("#handle"), to: .offset(dx: 120, dy: 0), pointer: true, in: view)
            #expect(result.hasPrefix("Sent drag from “Handle”"), "\(result)")
            #expect(result.contains("(pointer input)"))
            let log = try await records(view, "log")
            let down = try #require(log.first { $0["type"] as? String == "mousedown" }, "\(log)")
            let up = try #require(log.first { $0["type"] as? String == "mouseup" }, "\(log)")
            #expect(down["trusted"] as? Bool == true && up["trusted"] as? Bool == true, "pointer input is trusted: \(log)")
            #expect(down["id"] as? String == "handle" && abs((down["x"] as? Int ?? -1) - 71) <= 2, "the press is at the handle's centre: \(down)")
            #expect(abs((up["x"] as? Int ?? -1) - 191) <= 2, "the release is 120 px away: \(up)")
            #expect(log.contains { $0["type"] as? String == "mousemove" && $0["trusted"] as? Bool == true }, "the pointer moved: \(log)")
        }
    }
}
