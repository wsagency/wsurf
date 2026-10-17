// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// What an action reports, how big the reply is, and how long the page is waited for, through the MCP session on both engines.
@MainActor
@Suite(.boundedWebViews)
struct MCPActionFeedbackTests {
    private typealias Rig = MCPFeedbackRig

    private func ref(_ label: String, _ read: CallTool.Result) throws -> Int {
        try Rig.ref(of: label, in: read)
    }

    private func textBytes(_ result: CallTool.Result) -> Int {
        Rig.text(result).utf8.count
    }

    /// The first image of a reply, decoded.
    private func image(_ result: CallTool.Result) throws -> NSBitmapImageRep {
        let data = try #require(Rig.images(result).first, "no image in \(Rig.text(result))")
        return try #require(NSBitmapImageRep(data: data))
    }

    private func cost(_ result: CallTool.Result) -> [String: Value] {
        Rig.object(result)["cost"]?.objectValue ?? [:]
    }

    // MARK: What changed

    @Test(arguments: BrowserEngine.allCases)
    func aClickReportsChangedControlsWithoutAFullSnapshot(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        let read = try await rig.start()
        let add = try ref("Add to cart", read), cart = try ref("Cart (0)", read)
        let fullBytes = textBytes(read)

        // No observationID: a ref stays valid for as long as its document does.
        let result = try await rig.call("clickOnPage", ["ref": .int(add)])
        #expect(result.isError == false, "\(Rig.text(result))")
        let content = Rig.content(result)
        #expect(content.contains("Clicked “Add to cart”."), "\(content)")
        #expect(content.contains("button \"Checkout\""), "a control the click created is added: \(content)")
        #expect(content.contains("[\(cart)] text \"Cart (0)\" → \"Cart (1)\""), "\(content)")
        #expect(content.contains("Added to cart"), "new text near the target: \(content)")
        #expect(!content.contains("PAGE TEXT:") && !content.contains("CONTROLS:"), "no full snapshot: \(content)")
        let object = Rig.object(result)
        #expect(object["status"]?.stringValue == "ok")
        #expect(object["action"]?.stringValue == "clickOnPage")
        #expect(object["navigation"]?.stringValue == "none")
        #expect(object["observationID"]?.stringValue?.isEmpty == false)
        #expect(object["diagnostics"]?.stringValue == "off", "console and network are reported only while capture runs")
        // The byte budget: about 1 KB for a click on a page whose full read is several times that.
        let bytes = textBytes(result)
        #expect(bytes <= 1_536, "\(bytes) bytes: \(Rig.text(result))")
        #expect(bytes * 3 < fullBytes, "\(bytes) bytes against a full read of \(fullBytes)")
        #expect(cost(result)["bytes"]?.intValue == bytes, "the reply states its own size")
        #expect(cost(result)["totalMs"]?.intValue ?? .max < 5_000)
    }

    @Test(arguments: BrowserEngine.allCases)
    func typingSelectingAndCheckingReportTheirChanges(engine: BrowserEngine) async throws {
        let html = Rig.shop.replacingOccurrences(of: "<button id=add>", with: "<label><input type=checkbox id=gift> Gift wrap</label><button id=add>")
        let rig = try await Rig.make(engine: engine, html: html)
        defer { rig.close() }
        let read = try await rig.start()

        let typed = try await rig.call("typeOnPage", ["ref": .int(try ref("Gift note", read)), "text": "For Ada"])
        #expect(typed.isError == false, "\(Rig.text(typed))")
        let typedContent = Rig.content(typed)
        #expect(typedContent.contains("value \"\" → \"For Ada\""), "\(typedContent)")
        #expect(typedContent.contains("focus: none → ") && typedContent.contains("Gift note"), "the field took focus: \(typedContent)")

        let selected = try await rig.call("selectOption", ["ref": .int(try ref("Size", read)), "option": "42"])
        #expect(selected.isError == false, "\(Rig.text(selected))")
        #expect(Rig.content(selected).contains("value \"40\" → \"42\""), "\(Rig.content(selected))")

        let checked = try await rig.call("setChecked", ["ref": .int(try ref("Gift wrap", read)), "checked": true])
        #expect(checked.isError == false, "\(Rig.text(checked))")
        #expect(Rig.content(checked).contains("checked false → true"), "\(Rig.content(checked))")
        for result in [typed, selected, checked] { #expect(textBytes(result) <= 1_536, "\(Rig.text(result))") }
    }

    @Test(arguments: BrowserEngine.allCases)
    func fillFieldsAndScrollingReportTheirOutcome(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        let read = try await rig.start()
        let filled = try await rig.call("fillFields", [
            "fields": .array([
                .object(["ref": .int(try ref("Gift note", read)), "value": "hi", "select": false]),
                .object(["ref": .int(try ref("Size", read)), "value": "41", "select": true]),
            ]),
        ])
        #expect(filled.isError == false, "\(Rig.text(filled))")
        let filledContent = Rig.content(filled)
        #expect(filledContent.contains("Filled 2 of 2 fields."), "\(filledContent)")
        #expect(filledContent.contains("value \"\" → \"hi\"") && filledContent.contains("value \"40\" → \"41\""), "\(filledContent)")

        let scrolled = try await rig.call("scrollPage", ["direction": "down"])
        #expect(scrolled.isError == false, "\(Rig.text(scrolled))")
        let scrolledContent = Rig.content(scrolled)
        #expect(scrolledContent.contains("Scrolled down."), "\(scrolledContent)")
        #expect(scrolledContent.range(of: #"scroll: \d+ of \d+ px"#, options: .regularExpression) != nil, "\(scrolledContent)")
        #expect(!scrolledContent.contains("removed:"), "leaving the viewport is not a removal: \(scrolledContent)")
        #expect(textBytes(scrolled) <= 2_048, "\(textBytes(scrolled)) bytes")
    }

    @Test(arguments: BrowserEngine.allCases)
    func focusMovesAreReported(engine: BrowserEngine) async throws {
        let html = "<!doctype html><title>Focus</title><button onclick=\"document.getElementById('n').focus()\">Jump</button><input id=n aria-label='Name'>"
        let rig = try await Rig.make(engine: engine, html: html)
        defer { rig.close() }
        let read = try await rig.start()
        let result = try await rig.call("clickOnPage", ["ref": .int(try ref("Jump", read))])
        #expect(result.isError == false, "\(Rig.text(result))")
        #expect(Rig.content(result).contains("focus: none → [") && Rig.content(result).contains("field \"Name\""), "\(Rig.content(result))")
    }

    @Test(arguments: BrowserEngine.allCases)
    func aSensitiveFieldIsReportedAsFilledNeverWithItsValue(engine: BrowserEngine) async throws {
        let html = """
            <!doctype html><title>Code</title><input id=code aria-label='Security code'>
            <button onclick="document.getElementById('code').value='SECRET-7731'">Fill code</button>
            """
        let rig = try await Rig.make(engine: engine, html: html)
        defer { rig.close() }
        let read = try await rig.start()
        let result = try await rig.call("clickOnPage", ["ref": .int(try ref("Fill code", read))])
        #expect(result.isError == false, "\(Rig.text(result))")
        #expect(Rig.content(result).contains("filled false → true"), "\(Rig.content(result))")
        #expect(!Rig.text(result).contains("SECRET-7731"), "the value never leaves the page")
    }

    @Test(arguments: BrowserEngine.allCases)
    func newConsoleErrorsAndFailedRequestsAppearOnlyWithCapture(engine: BrowserEngine) async throws {
        let html = """
            <!doctype html><title>Errors</title><div id=out></div>
            <button onclick="console.error('boom happened'); fetch('/missing').then(r => { document.getElementById('out').textContent = 'status ' + r.status; })">Break</button>
            """
        // Without capture the reply says so and reports neither.
        let plain = try await Rig.make(engine: engine, html: html)
        defer { plain.close() }
        let plainRead = try await plain.start()
        let quiet = try await plain.call("clickOnPage", ["ref": .int(try ref("Break", plainRead))])
        #expect(Rig.object(quiet)["diagnostics"]?.stringValue == "off")
        #expect(!Rig.content(quiet).contains("console:") && !Rig.content(quiet).contains("failed requests:"), "\(Rig.content(quiet))")

        let rig = try await Rig.make(engine: engine, html: html, access: .development)
        defer { rig.close() }
        let read = try await rig.start(development: true)
        #expect(try await rig.call("startDiagnostics").isError == false)
        let result = try await rig.call("clickOnPage", ["ref": .int(try ref("Break", read))])
        #expect(result.isError == false, "\(Rig.text(result))")
        let content = Rig.content(result)
        #expect(content.contains("console: 1 new error: \"boom happened\""), "\(content)")
        #expect(content.contains("failed requests: GET ") && content.contains("/missing 404"), "\(content)")
        #expect(Rig.object(result)["diagnostics"] == nil, "capture is running")
        // Reported once: the next action starts from the end of both streams.
        let again = try await rig.call("scrollPage", ["direction": "down"])
        #expect(!Rig.content(again).contains("boom happened"), "\(Rig.content(again))")
    }

    @Test(arguments: BrowserEngine.allCases)
    func aNavigationDescribesTheNewPageAndOffersItsControls(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(
            engine: engine, html: "<!doctype html><title>First</title><a href='/next'>Continue</a>",
            routes: ["/next": .html("<!doctype html><title>Next page</title><p>Second page text</p><button>Next step</button>")])
        defer { rig.close() }
        let read = try await rig.start()
        let result = try await rig.call("clickOnPage", ["ref": .int(try ref("Continue", read))])
        #expect(result.isError == false, "\(Rig.text(result))")
        let object = Rig.object(result)
        #expect(object["navigation"]?.stringValue == "load")
        #expect(object["url"]?.stringValue?.hasSuffix("/next") == true)
        let content = Rig.content(result)
        #expect(content.contains("Second page text") && content.contains("button \"Next step\""), "\(content)")
        // The new page's control is usable without another read.
        let step = try ref("Next step", result)
        #expect(try await rig.call("clickOnPage", ["ref": .int(step)]).isError == false)
    }

    @Test func aTabTheActionOpenedIsReportedAndItsAddressCountsAsObserved() async throws {
        let rig = try await Rig.make(
            html: "<!doctype html><title>Opener</title><a href='/popup' target='_blank'>Open help</a>",
            routes: ["/popup": .html("<!doctype html><title>Help</title><p>Help text</p>")])
        defer { rig.close() }
        let read = try await rig.start()
        let result = try await rig.call("clickOnPage", ["ref": .int(try ref("Open help", read))])
        #expect(result.isError == false, "\(Rig.text(result))")
        #expect(rig.browser.tabs.count == 2, "the click opened a tab")
        let content = Rig.content(result)
        #expect(content.contains("opened: ") && content.contains("/popup"), "\(content)")
        // The new tab is not shared, but the address the page itself chose may be navigated to from here.
        #expect(rig.session.destinations.contains { $0.hasSuffix("/popup") })
        let opened = try #require(rig.browser.tabs.first { $0 !== rig.tab })
        let listed = try await rig.call("listTabs")
        #expect(!Rig.text(listed).contains(opened.id.uuidString), "the opened tab is not shared")
    }

    // MARK: Stable refs

    @Test(arguments: BrowserEngine.allCases)
    func refsStayValidAcrossActionsInOneDocument(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        let read = try await rig.start()
        let firstID = try #require(Rig.object(read)["observationID"]?.stringValue)
        let add = try ref("Add to cart", read), note = try ref("Gift note", read)
        #expect(try await rig.call("clickOnPage", ["ref": .int(add)]).isError == false)
        // A ref from the read still works after the click re-observed the page, with or without an observation ID.
        #expect(try await rig.call("typeOnPage", ["ref": .int(note), "text": "one"]).isError == false)
        let latest = try #require(Rig.object(try await rig.call("typeOnPage", ["ref": .int(note), "text": "two"]))["observationID"]?.stringValue)
        #expect(try await rig.call("clickOnPage", ["ref": .int(add), "observationID": .string(latest)]).isError == false)
        // An observation ID that is sent must still be the latest one.
        let stale = try await rig.call("clickOnPage", ["ref": .int(add), "observationID": .string(firstID)])
        #expect(stale.isError == true)
        #expect(try await rig.tab.page.evaluateJavaScript("document.getElementById('cart').textContent") as? String == "Cart (2)")
    }

    @Test(arguments: BrowserEngine.allCases)
    func aChangedOrForeignDocumentRefIsRefused(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        let read = try await rig.start()
        let add = try ref("Add to cart", read), product = try ref("Product number 1", read)
        // The control was relabelled after it was read: the ref no longer names what the client saw.
        _ = try await rig.tab.page.evaluateJavaScript("document.getElementById('add').textContent = 'Delete account'; 0")
        let retargeted = try await rig.call("clickOnPage", ["ref": .int(add)])
        #expect(retargeted.isError == true, "\(Rig.text(retargeted))")
        #expect(try await rig.tab.page.evaluateJavaScript("document.getElementById('cart').textContent") as? String == "Cart (0)")
        // A ref from another document is refused as well.
        let moved = try await rig.call("clickOnPage", ["ref": .int(product)])
        #expect(moved.isError == false, "\(Rig.text(moved))")
        #expect(Rig.object(moved)["navigation"]?.stringValue == "load")
        let foreign = try await rig.call("clickOnPage", ["ref": .int(add)])
        #expect(foreign.isError == true, "\(Rig.text(foreign))")
    }

    // MARK: Budgets

    @Test(arguments: BrowserEngine.allCases)
    func budgetCapsBytesAndSettleTime(engine: BrowserEngine) async throws {
        // The click adds 40 links and a ticker that never stops changing, so the page never goes quiet.
        let html = """
            <!doctype html><title>Busy</title><p id=tick></p><ul id=list></ul>
            <button onclick="
              for (let i = 0; i < 40; i++) {
                const a = document.createElement('a'); a.href = '/item/' + i; a.textContent = 'Item number ' + i + ' of the long list';
                document.getElementById('list').append(a, ' ');
              }
              setInterval(() => { document.getElementById('tick').textContent = performance.now(); }, 10)">Load</button>
            """
        let rig = try await Rig.make(engine: engine, html: html)
        defer { rig.close() }
        let read = try await rig.start()
        let result = try await rig.call("clickOnPage", ["ref": .int(try ref("Load", read)), "budget": .object(["maxBytes": 1_000, "settleMs": 200])])
        #expect(result.isError == false, "\(Rig.text(result))")
        #expect(textBytes(result) <= 1_000, "\(textBytes(result)) bytes: \(Rig.text(result))")
        #expect(cost(result)["truncated"]?.boolValue == true)
        let settle = try #require(cost(result)["settleMs"]?.intValue)
        #expect(settle <= 200 + 600, "the page never goes quiet, so the wait ends at its ceiling plus scheduling: \(settle) ms")
        #expect(Rig.content(result).contains("added"), "\(Rig.content(result))")
        // Out-of-range limits are refused before anything runs.
        await #expect(throws: (any Error).self) {
            _ = try await rig.call("clickOnPage", ["ref": .int(1), "budget": .object(["maxBytes": 10])])
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func fullResultModeMatchesTheOldSnapshot(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        let read = try await rig.start()
        let add = try ref("Add to cart", read)
        let result = try await rig.call("clickOnPage", ["ref": .int(add), "result": "full"])
        #expect(result.isError == false, "\(Rig.text(result))")
        let content = Rig.content(result)
        #expect(content.contains("Clicked “Add to cart”. PAGE TEXT:"), "\(content.prefix(200))")
        #expect(content.contains("CONTROLS:") && content.contains("observationID: "))
        let object = Rig.object(result)
        #expect(object["observationID"]?.stringValue?.isEmpty == false)
        #expect(object["cost"] == nil && object["action"] == nil, "the full result keeps its old shape")
        #expect(textBytes(result) > 3_000)
    }

    // MARK: Failures and screenshots

    private static let covered = """
        <!doctype html><title>Covered</title><button style='position:absolute;left:30px;top:30px;width:120px;height:40px'>Hidden away</button>
        <div style='position:fixed;inset:0;background:#fc0;z-index:10'>Overlay</div>
        """

    @Test(arguments: BrowserEngine.allCases)
    func screenshotOnFailureIsElementFirstAndOnRequestOnly(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine, html: Self.covered)
        defer { rig.close() }
        rig.session.feedback.sleep = { _ in }
        let read = try await rig.start()
        let target = try ref("Hidden away", read)

        let plain = try await rig.call("clickOnPage", ["ref": .int(target)])
        #expect(plain.isError == true)
        #expect(Rig.content(plain).contains("covered"), "\(Rig.content(plain))")
        #expect(Rig.images(plain).isEmpty, "no image unless one was asked for")

        let element = try await rig.call("clickOnPage", ["ref": .int(target), "screenshotOnFailure": "element"])
        #expect(element.isError == true)
        let elementImage = try #require(Rig.images(element).first)
        #expect(elementImage.count <= MCPBrowserSession.failureImageBytes)
        #expect(Rig.content(element).contains("screenshot: element"), "\(Rig.content(element))")

        let viewport = try await rig.call("clickOnPage", ["ref": .int(target), "screenshotOnFailure": "viewport"])
        let viewportImage = try #require(Rig.images(viewport).first)
        let narrow = try #require(NSBitmapImageRep(data: elementImage)).pixelsWide
        let wide = try #require(NSBitmapImageRep(data: viewportImage)).pixelsWide
        #expect(narrow < wide, "the element image (\(narrow) px) is smaller than the viewport image (\(wide) px)")

        // The full-result mode honours the option too.
        let full = try await rig.call("clickOnPage", ["ref": .int(target), "result": "full", "screenshotOnFailure": "element"])
        #expect(full.isError == true && Rig.images(full).count == 1)
    }

    @Test(arguments: BrowserEngine.allCases)
    func maxWidthDownscalesAndReportsTheScale(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        rig.session.feedback.sleep = { _ in }
        _ = try await rig.start()
        let measured = try await rig.tab.page.evaluateJavaScript("window.innerWidth") as? Int
        let viewportWidth = try #require(measured)

        let natural = try await rig.call("screenshotPage")
        #expect(natural.isError == false, "\(Rig.text(natural))")
        let naturalWidth = try image(natural).pixelsWide
        #expect(naturalWidth <= viewportWidth, "one image pixel per CSS pixel at most: \(naturalWidth) px for \(viewportWidth) CSS px")

        let small = try await rig.call("screenshotPage", ["maxWidth": 320])
        let smallWidth = try image(small).pixelsWide
        #expect(smallWidth <= 320 && smallWidth >= 300, "\(smallWidth)")
        let scale = try #require(Rig.content(small).range(of: #"image scale (\d+\.\d+)"#, options: .regularExpression))
        let reported = try #require(Double(Rig.content(small)[scale].dropFirst("image scale ".count)))
        #expect(abs(reported - Double(smallWidth) / Double(viewportWidth)) < 0.02, "the scale describes the image returned: \(reported)")
        let smallBytes = try #require(Rig.images(small).first?.count), naturalBytes = try #require(Rig.images(natural).first?.count)
        #expect(smallBytes < naturalBytes)
        await #expect(throws: (any Error).self) { _ = try await rig.call("screenshotPage", ["maxWidth": 100]) }
    }

    @Test(arguments: BrowserEngine.allCases)
    func capturesAreThrottledToTwoASecond(engine: BrowserEngine) async throws {
        let rig = try await Rig.make(engine: engine)
        defer { rig.close() }
        var waits: [Duration] = []
        rig.session.feedback.sleep = { waits.append($0) }
        _ = try await rig.start()
        #expect(try await rig.call("screenshotPage").isError == false)
        #expect(waits.isEmpty, "the first capture is not delayed")
        #expect(try await rig.call("screenshotPage").isError == false)
        let wait = try #require(waits.first)
        #expect(waits.count == 1 && wait > .milliseconds(100) && wait <= .milliseconds(500), "\(waits)")
    }

    @Test(arguments: BrowserEngine.allCases)
    func fullPageIsChromiumOnlyAndNeedsDevelopmentAccess(engine: BrowserEngine) async throws {
        let html = "<!doctype html><title>Tall</title><div style='height:2400px;background:linear-gradient(#fff,#06c)'>Tall page</div>"
        let denied = try await Rig.make(engine: engine, html: html)
        defer { denied.close() }
        denied.session.feedback.sleep = { _ in }
        _ = try await denied.start()
        let refused = try await denied.call("screenshotPage", ["fullPage": true])
        #expect(refused.isError == true && Rig.content(refused).contains("development access"), "\(Rig.content(refused))")

        let rig = try await Rig.make(engine: engine, html: html, access: .development)
        defer { rig.close() }
        rig.session.feedback.sleep = { _ in }
        _ = try await rig.start(development: true)
        let result = try await rig.call("screenshotPage", ["fullPage": true])
        if engine == .chromium {
            #expect(result.isError == false, "\(Rig.text(result))")
            let page = try image(result)
            #expect(page.pixelsHigh > page.pixelsWide * 3 / 2, "the image covers the page below the viewport: \(page.pixelsWide) x \(page.pixelsHigh)")
            #expect(Rig.content(result).contains("the full page"), "\(Rig.content(result).prefix(200))")
        } else {
            #expect(result.isError == true && Rig.content(result).contains("Chromium"), "\(Rig.content(result))")
            #expect(Rig.images(result).isEmpty)
        }
    }

    // MARK: The in-app assistant

    @Test func theInAppAssistantStillGetsSnapshots() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        let page = rig.tab.page
        let snapshot = await PageDriver.snapshot(page)
        let add = try Rig.ref(of: "Add to cart", inText: snapshot)
        let output = await PageDriver.click(ref: add, label: "", in: page)
        #expect(output.hasPrefix("Clicked"), "\(output)")
        #expect(output.contains("PAGE TEXT:") && output.contains("CONTROLS:") && output.contains("observationID: "), "\(output.prefix(200))")
        #expect(output.utf8.count > 2_000)
    }
}
