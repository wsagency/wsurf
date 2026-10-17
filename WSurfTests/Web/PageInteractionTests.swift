// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageInteractionTests {
    private func page(_ body: String) async -> BrowserPage {
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        let page = BrowserPage(webKit: view, context: BrowserProfileContext(profile: .privateBrowsing()))
        page.loadHTMLString("<!doctype html><body>\(body)</body>", baseURL: nil)
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(20)))
        return page
    }

    private func js(_ view: BrowserPage, _ script: String) async -> Any? {
        try? await view.evaluateJavaScript(script)
    }

    @Test func readOnlyDatePickerExposesClickableDays() async {
        let view = await page("""
            <input id='date' aria-label='Departure date' readonly value='September 23'>
            <div id='calendar' hidden><h3>September</h3>
              <div role='gridcell' tabindex='0' aria-disabled='true'>22</div>
              <div id='day' role='gridcell' tabindex='0'><div>29</div></div>
              <div role='gridcell'>Static cell</div>
              <div role='gridcell' tabindex='0'><button>30</button></div>
            </div>
            <script>
              document.querySelector('#date').addEventListener('click', () => document.querySelector('#calendar').hidden=false);
              document.querySelector('#day').addEventListener('click', () => {
                document.querySelector('#date').value='September 29'; document.querySelector('#calendar').hidden=true;
              });
            </script>
            """)
        let initial = await PageDriver.snapshot(view)
        #expect(initial.contains("(read-only)"))
        let calendar = await PageDriver.click(ref: 0, label: "Departure date", in: view)
        #expect(calendar.contains("button \"29\""))
        #expect(calendar.contains("button \"22\" (disabled)"))
        #expect(!calendar.contains("button \"Static cell\""))
        #expect(calendar.components(separatedBy: "button \"30\"").count == 2)
        let disabled = await PageDriver.click(ref: 0, label: "22", in: view)
        #expect(disabled.contains("disabled"))
        let selected = await PageDriver.click(ref: 0, label: "29", in: view)
        #expect(selected.hasPrefix("Clicked"))
        #expect(await js(view, "document.querySelector('#date').value") as? String == "September 29")
    }

    @Test func observationCannotBeReusedAfterNavigationOrRetargeting() async throws {
        let view = await page("<button id='a' onclick='window.hit=true'>Ordinary action</button>")
        _ = await PageDriver.snapshot(view)
        _ = await js(view, "document.querySelector('button').textContent='Delete account'")
        _ = await PageDriver.click(ref: 1, label: "", in: view)
        #expect(await js(view, "window.hit === undefined") as? Bool == true)
        view.loadHTMLString("<button onclick='window.hit=true'>New document</button>", baseURL: nil)
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        _ = await PageDriver.click(ref: 1, label: "", in: view)
        #expect(await js(view, "window.hit === undefined") as? Bool == true)
    }

    @Test func coveredAndDisabledControlsDoNotRunHandlers() async {
        let view = await page(
            """
            <button style='position:absolute;left:20px;top:20px' onclick='window.hit=true'>Covered</button>
            <div style='position:fixed;inset:0;background:white;z-index:10'></div>
            <select disabled><option>A</option><option>B</option></select>
            """)
        _ = await PageDriver.snapshot(view)
        #expect(!(await PageDriver.click(ref: 1, label: "", in: view)).hasPrefix("Clicked"))
        #expect(!(await PageDriver.selectOption("B", ref: 2, field: "", in: view)).hasPrefix("Selected"))
        #expect(await js(view, "window.hit === undefined && document.querySelector('select').value === 'A'") as? Bool == true)
    }

    @Test func aMovingControlIsNotClickedUntilItSettles() async {
        let view = await page(
            """
            <style>@keyframes move { from { transform:translateX(0) } to { transform:translateX(300px) } }
            button { animation:move 1s infinite alternate linear }</style>
            <button onclick='window.hit=true'>Moving target</button>
            """)
        _ = await PageDriver.snapshot(view)
        #expect(!(await PageDriver.click(ref: 1, label: "", in: view)).hasPrefix("Clicked"))
        #expect(await js(view, "window.hit === undefined") as? Bool == true)
        _ = await js(view, "document.querySelector('button').style.animation='none'")
        #expect((await PageDriver.click(ref: 1, label: "", in: view)).hasPrefix("Clicked"))
    }

    @Test func enterHandledByPageSubmitsExactlyOnce() async {
        let view = await page(
            """
            <form onsubmit='window.submits=(window.submits||0)+1;return false'>
            <input aria-label='Query' onkeydown="if(event.key==='Enter'){event.preventDefault();this.form.requestSubmit()}">
            </form>
            """)
        _ = await PageDriver.snapshot(view)
        _ = await PageDriver.type(text: "query", intoField: "", ref: 1, submit: true, in: view)
        #expect(await js(view, "window.submits") as? Int == 1)
    }

    @Test func rejectedFieldValueIsNotReportedAsTypedOrSubmitted() async {
        let view = await page("""
            <form onsubmit='window.submits=(window.submits||0)+1;return false'>
            <input aria-label='Query' oninput="this.value='rejected'">
            </form>
            """)
        _ = await PageDriver.snapshot(view)
        let result = await PageDriver.type(text: "wanted", intoField: "", ref: 1, submit: true, in: view)
        #expect(!result.hasPrefix("Typed"))
        #expect(result.contains("did not retain"))
        #expect(await js(view, "window.submits || 0") as? Int == 0)
    }

    @Test func delayedFieldResetIsVerifiedWithoutRepeatingTheWrite() async {
        let view = await page("""
            <input aria-label='Name' oninput="window.writes=(window.writes||0)+1;setTimeout(()=>this.value='',50)">
            """)
        _ = await PageDriver.snapshot(view)
        let result = await PageDriver.type(text: "Ada", intoField: "", ref: 1, submit: false, in: view)
        #expect(result.contains("did not retain"))
        #expect(result.contains("observationID:"))
        #expect(await js(view, "window.writes") as? Int == 1)
    }

    @Test func rejectedSelectionAndEarlierBatchResetsAreNotCountedAsSuccess() async {
        let view = await page("""
            <input aria-label='First'>
            <input aria-label='Second' oninput="document.querySelector('input').value=''">
            <select aria-label='Choice' onchange="this.value='a'"><option value='a'>A</option><option value='b'>B</option></select>
            """)
        _ = await PageDriver.snapshot(view)
        let selection = await PageDriver.selectOption("b", ref: 3, field: "", in: view)
        #expect(!selection.hasPrefix("Selected"))
        let result = await PageDriver.fillFields([
            .init(ref: 1, value: "first", select: false), .init(ref: 2, value: "second", select: false),
        ], in: view)
        #expect(result.hasPrefix("Filled 1 of 2 fields."), "\(result)")
        #expect(result.contains("[1] not verified"))
    }

    @Test func queriesReachDeepTextAndControlPaginationPreservesRefs() async throws {
        let buttons = (1...100).map { "<button>Choice \($0)</button>" }.joined()
        let view = await page("<p>\(String(repeating: "filler ", count: 2000))RareNeedle</p>" + buttons)
        let query = await PageDriver.snapshot(view, lookingFor: "RareNeedle Choice 100")
        #expect(query.contains("RareNeedle"))
        #expect(query.contains("Choice 100"))
        _ = await PageDriver.snapshot(view)
        let page = await PageDriver.snapshot(view, textLimit: 0, controlLimit: 10, controlOffset: 90)
        #expect(page.contains("[100]"))
        let observation = try #require(PageDriver.observation(in: view))
        #expect(!observation.refs.contains(1))
    }

    @Test func clickingARefTheObservationOmittedActsOnlyOnceItIsListed() async throws {
        let buttons = (1...12).map { "<button onclick='document.body.dataset.clicked=\"\($0)\"'>Choice \($0)</button>" }.joined()
        let view = await page(buttons)
        _ = await PageDriver.snapshot(view, textLimit: 0, controlLimit: 3)
        #expect(!(try #require(PageDriver.observation(in: view)).refs.contains(9)))
        _ = await PageDriver.click(ref: 9, label: "", in: view)
        #expect(await js(view, "document.body.dataset.clicked === undefined") as? Bool == true)

        _ = await PageDriver.snapshot(view, textLimit: 0, controlLimit: 12)
        #expect(try #require(PageDriver.observation(in: view)).refs.contains(9))
        _ = await PageDriver.click(ref: 9, label: "", in: view)
        #expect(await js(view, "document.body.dataset.clicked") as? String == "9")
    }

    @Test func batchFillWritesListedFieldsAndLeavesAnOmittedOneUntouched() async throws {
        let view = await page((1...12).map { "<input aria-label='Field \($0)'>" }.joined())
        _ = await PageDriver.snapshot(view, textLimit: 0, controlLimit: 3)
        let listed = try #require(PageDriver.observation(in: view)).refs
        #expect(listed.contains(1) && !listed.contains(9))
        _ = await PageDriver.fillFields([
            .init(ref: 1, value: "kept", select: false), .init(ref: 9, value: "unseen", select: false),
        ], in: view)
        #expect(await js(view, "document.querySelectorAll('input')[0].value") as? String == "kept")
        #expect(await js(view, "document.querySelectorAll('input')[8].value") as? String == "")
    }

    @Test func calendarPaginationRecoversFromRefOffsetsAndChangedQueries() async {
        let controls = (1...13).map { "<button>Control \($0)</button>" }.joined()
        let days = (1...30).map {
            "<div role='gridcell' tabindex='0' style='display:inline-block;width:30px;height:30px' aria-disabled='\($0 < 23)'>\($0)</div>"
        }.joined()
        let view = await page(controls + "<h3>September</h3>" + days)
        let initial = await PageDriver.snapshot(view)
        #expect(initial.contains("button \"29\""))
        let restarted = await PageDriver.snapshot(view, lookingFor: "calendar dates September 29", controlOffset: 140)
        #expect(restarted.contains("button \"29\""))
        #expect(restarted.contains("pagination restarted at 0"))
        let filtered = await PageDriver.snapshot(view, lookingFor: "September calendar controls date 29", controlOffset: 40, viewportOnly: true)
        #expect(filtered.contains("button \"29\""))
        #expect(filtered.contains("pagination restarted at 0"))
        let overflow = await PageDriver.snapshot(view, lookingFor: "September calendar controls date 29", controlOffset: 140, viewportOnly: true)
        #expect(overflow.contains("button \"29\""))
        #expect(overflow.contains("offset exceeds"))
        #expect(overflow.contains("controlOffset=40"))
        let continued = await PageDriver.snapshot(view, lookingFor: "September calendar controls date 29", controlOffset: 40, viewportOnly: true)
        #expect(!continued.contains("pagination restarted"))
        #expect(!continued.contains("button \"29\""))
    }

    @Test func labelActionsRejectObservationsFromThePreviousDocument() async throws {
        let view = await page("<button>29</button>")
        _ = await PageDriver.snapshot(view)
        let before = try #require(PageDriver.observation(in: view))
        view.loadHTMLString("<button onclick='window.hit=true'>29</button>", baseURL: nil)
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(20)))
        _ = await PageDriver.$expectedObservation.withValue(before.id) {
            await PageDriver.click(ref: 0, label: "29", in: view)
        }
        #expect(await js(view, "window.hit === undefined") as? Bool == true)
    }

    @Test func compactBudgetAppliesAfterActionsIncludingLongOptions() async {
        let options = (1...80).map { "<option>Option \($0) \(String(repeating: "&amp;", count: 80))</option>" }.joined()
        let view = await page(
            "<button>Ordinary action</button><select aria-label='Options'>\(options)</select>" + String(repeating: "<p>Text and details</p>", count: 100))
        await PageDriver.$outputBudget.withValue(.init(textCharacters: 800, controls: 12, totalCharacters: 2000)) {
            _ = await PageDriver.snapshot(view)
            let output = await PageDriver.click(ref: 1, label: "", in: view)
            #expect(AgentToolkit.untrusted(output).utf8.count <= 2000)
            #expect(output.contains("observationID:"))
        }
    }

    @Test func compactQueriesKeepTheMatchWithMultibyteText() async {
        let view = await page("<p>\(String(repeating: "文🙂", count: 2000))重要な結果</p>")
        await PageDriver.$outputBudget.withValue(.init(textCharacters: 800, controls: 12, totalCharacters: 2000)) {
            let output = await PageDriver.snapshot(view, lookingFor: "重要な結果")
            #expect(output.contains("重要な結果"))
            #expect(AgentToolkit.untrusted(output).utf8.count <= 2000)
        }
    }

    @Test func longSelectedLabelsStayInsideTheCompactBudget() async {
        let view = await page("<select aria-label='Choices'><option>A</option><option value='chosen'>\(String(repeating: "&amp;", count: 2000))</option></select>")
        await PageDriver.$outputBudget.withValue(.init(textCharacters: 800, controls: 12, totalCharacters: 2000)) {
            _ = await PageDriver.snapshot(view)
            let output = await PageDriver.selectOption("chosen", ref: 1, field: "", in: view)
            #expect(output.hasPrefix("Selected"), "\(output)")
            #expect(AgentToolkit.untrusted(output).utf8.count <= 2000)
        }
    }

    @Test func batchingWaitsForNavigationOnceAndReturnsOneObservation() async {
        let view = await page((1...8).map { "<input aria-label='Field \($0)'>" }.joined())
        _ = await PageDriver.snapshot(view)
        var interactionWaits = 0
        await PageSettle.$interactionObserver.withValue({ interactionWaits += 1 }) {
            for ref in 1...8 {
                let result = await PageDriver.type(text: "individual", intoField: "", ref: ref, submit: false, in: view)
                #expect(result.hasPrefix("Typed"), "\(result)")
            }
        }
        #expect(interactionWaits == 8)
        interactionWaits = 0
        let batch = await PageSettle.$interactionObserver.withValue({ interactionWaits += 1 }) {
            await PageDriver.fillFields((1...8).map { .init(ref: $0, value: "batch", select: false) }, in: view)
        }
        #expect(batch.hasPrefix("Filled 8 of 8"))
        #expect(batch.components(separatedBy: "observationID:").count == 2)
        #expect(interactionWaits == 1)
        #expect(await js(view, "Array.from(document.querySelectorAll('input')).every(input => input.value === 'batch')") as? Bool == true)
    }

    @Test func aColdReadinessQueryStillTypesIntoAStableControl() async throws {
        let view = await page("<input id='field' aria-label='Field'>")
        _ = await PageDriver.snapshot(view)
        _ = try await view.evaluateJavaScript("""
            const animations = Element.prototype.getAnimations;
            let delayed = false;
            Element.prototype.getAnimations = function () {
              if (!delayed && this.id === 'field') {
                delayed = true;
                const end = performance.now() + 1100;
                while (performance.now() < end) {}
              }
              return animations.call(this);
            };
            true
            """, in: nil, contentWorld: PageAutomationGuard.world)
        let result = await PageDriver.type(text: "cold", intoField: "", ref: 1, submit: false, in: view)
        #expect(await js(view, "document.querySelector('#field').value") as? String == "cold", "\(result)")
    }

    @Test func checkedStateIsIdempotentAndDropdownInspectionContinues() async {
        let options = (1...40).map { "<option>Option \($0)</option>" }.joined()
        let view = await page(
            "<input type='checkbox' aria-label='Remember' onchange='window.changes=(window.changes||0)+1'><select aria-label='Choices'>\(options)</select>")
        _ = await PageDriver.snapshot(view)
        #expect((await PageDriver.setChecked(ref: 1, checked: true, in: view)).hasPrefix("Set checked"))
        #expect((await PageDriver.setChecked(ref: 1, checked: true, in: view)).hasPrefix("Checked state"))
        #expect(await js(view, "window.changes") as? Int == 1)
        let inspected = await PageDriver.inspectControl(ref: 2, offset: 20, in: view)
        #expect(inspected.contains("Option 21"))
        #expect(inspected.contains("nextOffset"))
    }

    @Test func checkedPostconditionUsesTheRefreshedExecutionScope() async throws {
        let view = await page("<input type='checkbox' aria-label='Remember'>")
        _ = await PageDriver.snapshot(view)
        let prior = try #require(PageDriver.observation(in: view))
        let scope = PageAutomationGuard(documentURL: prior.url, snapshot: prior.id, validate: { true })
        let output = await PageAutomationGuard.$current.withValue(scope) {
            await PageDriver.$expectedObservation.withValue(prior.id) {
                await PageDriver.setChecked(ref: 1, checked: true, in: view)
            }
        }
        #expect(output.hasPrefix("Set checked state to true."), "\(output)")
        #expect(PageDriver.observation(in: view)?.id != prior.id)
    }

    @Test func waitsForAsyncTextAndReportsTimeout() async {
        let view = await page("<p id='status'>Pending</p>")
        _ = await js(view, "setTimeout(()=>document.querySelector('p').textContent='Complete',180);true")
        #expect((await PageDriver.waitForPage(condition: "text", value: "Complete", timeout: 2, in: view)).hasPrefix("Condition met."))
        #expect((await PageDriver.waitForPage(condition: "text", value: "Missing", timeout: 1, in: view)).hasPrefix("Timed out"))
    }

    @Test func waitsForElementStateAndRejectsBadSelectors() async {
        let view = await page("<button id='go' disabled>Go</button><p id='gone'>Soon</p><p class='dup'>a</p><p class='dup'>b</p>")
        _ = await js(view, "setTimeout(()=>{document.querySelector('#go').disabled=false;document.querySelector('#gone').remove()},180);true")
        #expect((await PageDriver.waitForPage(condition: "elementEnabled", value: "#go", timeout: 2, in: view)).hasPrefix("Condition met."))
        #expect((await PageDriver.waitForPage(condition: "elementHidden", value: "#gone", timeout: 2, in: view)).hasPrefix("Condition met."))
        #expect((await PageDriver.waitForPage(condition: "elementVisible", value: "#missing", timeout: 1, in: view)).hasPrefix("Timed out"))
        #expect((await PageDriver.waitForPage(condition: "elementVisible", value: ".dup", timeout: 1, in: view)) == "The selector matches more than one element.")
        #expect((await PageDriver.waitForPage(condition: "elementVisible", value: "div[", timeout: 1, in: view)) == "Invalid selector.")
    }

    @Test func screenshotRegionMustBeFullyInsideTheViewport() async {
        let view = await page("<p>Visible</p>")
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        let width = view.bounds.width
        if case .success(let capture) = await PageDriver.screenshot(.region(CGRect(x: 0, y: 0, width: 100, height: 20)), in: view) {
            #expect(capture.bounds == CGRect(x: 0, y: 0, width: 100, height: 20))
        } else {
            Issue.record("inside region failed")
        }
        #expect(await PageDriver.screenshot(.region(CGRect(x: width - 10, y: 0, width: 100, height: 20)), in: view).failure == .offscreen)
        #expect(await PageDriver.screenshot(.region(CGRect(x: width + 50, y: 0, width: 10, height: 10)), in: view).failure == .offscreen)
        #expect(await PageDriver.screenshot(.region(CGRect(x: 0, y: 0, width: 1e-9, height: 10)), in: view).failure == .invalidGeometry)
    }

    @Test func nestedHorizontalScrollReturnsFreshControls() async {
        let view = await page(
            "<div aria-label='Items' role='region' style='width:200px;overflow:auto'><div style='width:1500px'><button>First</button><button style='margin-left:900px'>Last</button></div></div>"
        )
        _ = await PageDriver.snapshot(view)
        let output = await PageDriver.scroll(direction: "right", ref: 1, in: view)
        #expect(output.hasPrefix("Scrolled right."))
        #expect(output.contains("observationID:"))
        #expect(await js(view, "document.querySelector('[role=region]').scrollLeft > 0") as? Bool == true)
    }

    @Test func scrollRegionsDoNotHideTheirOnlyAction() async {
        let view = await page("<div role='region'><button>Open details</button></div>")
        let output = await PageDriver.snapshot(view)
        #expect(output.contains("scrollarea"))
        #expect(output.contains("button \"Open details\""))
    }

    @Test func pageCannotPoisonAutomationRuntime() async {
        let view = await page(
            "<button onclick='window.hit=true'>Ordinary action</button><script>window.__wsurf={collect:()=>[{r:1,k:'button',l:'forged'}]};</script>")
        let output = await PageDriver.snapshot(view)
        #expect(output.contains("Ordinary action"))
        #expect(!output.contains("forged"))
        #expect((await PageDriver.click(ref: 1, label: "", in: view)).hasPrefix("Clicked"))
    }

    @Test func screenshotsRefuseFilledSensitiveFields() async {
        let view = await page("<input type='password' value='secret'>")
        #expect(await PageDriver.screenshot(in: view).failure == .privacy)
    }

    @Test func boundedScreenshotsShrinkWhileUnboundedOnesKeepTheirPixels() async throws {
        let view = await page(
            """
            <canvas id='c' width='500' height='400'></canvas>
            <script>
              const context = document.getElementById('c').getContext('2d'), noise = context.createImageData(500, 400);
              for (let i = 0; i < noise.data.length; i++) noise.data[i] = i % 4 === 3 ? 255 : Math.random() * 256;
              context.putImageData(noise, 0, 0);
            </script>
            """)
        let limit = 30_000
        let full = try await PageDriver.screenshot(in: view).get()
        let bounded = try await PageDriver.screenshot(maximumBytes: limit, in: view).get()
        #expect(full.jpeg.count > limit)
        #expect(bounded.jpeg.count <= limit)
        let fullWidth = try #require(NSBitmapImageRep(data: full.jpeg)).pixelsWide
        let boundedWidth = try #require(NSBitmapImageRep(data: bounded.jpeg)).pixelsWide
        #expect(boundedWidth < fullWidth)
        // The reported scale describes the image that was returned, not the one that was captured.
        #expect(abs(bounded.scale * bounded.bounds.width - CGFloat(boundedWidth)) < 1)
        #expect(abs(full.scale * full.bounds.width - CGFloat(fullWidth)) < 1)
    }

    @Test func scopeCoversEveryMatchingElement() async {
        let view = await page(
            "<button>Outside</button><section><input aria-label='First'></section><section><textarea aria-label='Second'></textarea></section>")
        let sections = await PageDriver.snapshot(view, scope: "section")
        #expect(sections.contains("\"First\"") && sections.contains("\"Second\""), "\(sections)")
        #expect(!sections.contains("button \"Outside\""))
        let fields = await PageDriver.snapshot(view, scope: "textarea, input")
        #expect(fields.contains("\"First\"") && fields.contains("\"Second\""), "\(fields)")
        #expect(!(await PageDriver.snapshot(view, scope: "article")).hasPrefix("PAGE TEXT:"))
        #expect(!(await PageDriver.snapshot(view, scope: "section[")).hasPrefix("PAGE TEXT:"))

        let shadow = await page(
            """
            <div class='host'></div><button>Outside</button>
            <script>document.querySelector('.host').attachShadow({ mode: 'open' }).innerHTML = '<button>Inside shadow</button>';</script>
            """)
        let hosted = await PageDriver.snapshot(shadow, scope: ".host")
        #expect(hosted.contains("button \"Inside shadow\"") && !hosted.contains("button \"Outside\""), "\(hosted)")
    }

    @Test func sensitiveEditableTextIsRedactedAndCannotBeOverwritten() async {
        let view = await page("<div contenteditable='true' aria-label='Recovery phrase'>hidden-recovery-words</div>")
        let output = await PageDriver.snapshot(view)
        #expect(!output.contains("hidden-recovery-words"))
        #expect(output.contains("filled, hidden"))
        #expect(!(await PageDriver.type(text: "replacement", intoField: "", ref: 1, submit: false, in: view)).hasPrefix("Typed"))
        #expect(await PageDriver.screenshot(in: view).failure == .privacy)
    }

    @Test func backgroundHoverIsUnavailableAndNativeKeyboardReachesWebKit() async {
        let view = await page(
            """
            <style>#hover:hover + #revealed { display:block } #revealed { display:none }</style>
            <button id='hover' onmouseenter="document.querySelector('#revealed').style.display='block'">Reveal</button><p id='revealed'>Hover details</p>
            <input aria-label='Input' onkeydown='window.lastKey=event.key'>
            """)
        let window = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        _ = await PageDriver.snapshot(view)
        let hover = await PageDriver.hover(ref: 1, in: view)
        // A background window is not hoverable: the move is refused, never claimed, and no handler ran.
        #expect(hover.hasPrefix("Hover needs"), "\(hover)")
        #expect(await js(view, "document.querySelector('#revealed').style.display") as? String == "")
        let key = await PageDriver.pressKey("ArrowDown", ref: 2, in: view)
        #expect(key.hasPrefix("Sent ArrowDown"), "\(key)")
        #expect(await js(view, "window.lastKey") as? String == "ArrowDown")
        if case .failure(let failure) = await PageDriver.screenshot(in: view) { Issue.record("screenshot failed: \(failure)") }
    }

    /// Native, not run by the headless component package. A ref inside a same-origin iframe is captured where it really is:
    /// through the frame's border and padding, and only the part the frame shows, never the neighbouring page.
    @Test func anElementInsideAnIframeIsCroppedThroughTheFrameGeometry() async {
        let view = await page(
            """
            <iframe id='f' style='position:absolute;left:30px;top:40px;width:200px;height:100px;border:5px solid black;padding:20px'
              srcdoc="<body style='margin:0'><button style='position:absolute;left:10px;top:12px;width:60px;height:24px'>Go</button>\
            <button style='position:absolute;left:180px;top:12px;width:60px;height:24px'>Edge</button></body>"></iframe>
            """)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        var loaded = false
        for _ in 0..<50 where !loaded {
            loaded = await js(view, "!!document.getElementById('f').contentDocument?.querySelector('button')") as? Bool == true
            if !loaded {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        _ = await PageDriver.snapshot(view)
        // The frame's content box starts at its border box (30, 40) plus 5 px border plus 20 px padding.
        func check(_ ref: Int, _ expected: CGRect) async {
            switch await PageDriver.screenshot(.element(ref: ref), in: view) {
            case .success(let capture):
                #expect(abs(capture.bounds.minX - expected.minX) <= 0.5 && abs(capture.bounds.minY - expected.minY) <= 0.5, "\(capture.bounds)")
                #expect(abs(capture.bounds.width - expected.width) <= 0.5 && abs(capture.bounds.height - expected.height) <= 0.5, "\(capture.bounds)")
            case .failure(let failure):
                Issue.record("ref \(ref): \(failure)")
            }
        }
        await check(1, CGRect(x: 65, y: 77, width: 60, height: 24))
        await check(2, CGRect(x: 235, y: 77, width: 20, height: 24))
    }

    /// Native, not run by the headless component package. A key is never reported as delivered to a page that does not hold
    /// keyboard focus.
    @Test func aKeyIsRefusedWhenThePageIsNotTheFirstResponder() async throws {
        let view = await page("<input aria-label='Input' onkeydown='window.lastKey=event.key'>")
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        func event() throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        }
        #expect(window.makeFirstResponder(nil))
        #expect(!view.sendKeyEvent(try event()))
        #expect(window.makeFirstResponder(view))
        #expect(view.sendKeyEvent(try event()))
    }

    /// Native, not run by the headless component package. A non-interactive element that only `findElements` registered
    /// is captured under development access and refused otherwise; control refs keep working without it; a vanished
    /// element stays stale rather than reading as a permission failure.
    @Test func foundOnlyElementsNeedDevelopmentAccessToBeCaptured() async throws {
        let view = await page("<div id='box' style='width:80px;height:30px;background:red'>Box</div><button>Go</button>")
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        let found = await PageDriver.findElements(selector: "#box", offset: 0, limit: 5, in: view)
        let ref = try #require(found.components(separatedBy: "\"r\":").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) }, "\(found)")
        #expect(await PageDriver.screenshot(.element(ref: ref), in: view).failure == .needsDevelopment)
        if case .failure(let failure) = await PageDriver.screenshot(.element(ref: ref), developmentAllowed: { true }, in: view) {
            Issue.record("development capture failed: \(failure)")
        }
        // Access dropping during the capture is caught before the pixels are returned.
        var asked = 0
        let dropped = await PageDriver.screenshot(.element(ref: ref), developmentAllowed: { asked += 1; return asked == 1 }, in: view)
        #expect(dropped.failure == .needsDevelopment)
        _ = await js(view, "document.getElementById('box').remove(); true")
        #expect(await PageDriver.screenshot(.element(ref: ref), developmentAllowed: { true }, in: view).failure == .stale)
    }

    @Test func aControlRefIsCapturedWithoutDevelopmentAccess() async {
        let view = await page("<button style='width:80px;height:30px'>Go</button>")
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        _ = await PageDriver.snapshot(view)
        if case .failure(let failure) = await PageDriver.screenshot(.element(ref: 1), in: view) { Issue.record("control capture failed: \(failure)") }
    }
}

extension PageInteractionTests {
    private func withPage(
        engine: BrowserEngine, url: URL,
        configure: (BrowserPage) -> Void = { _ in },
        body: (BrowserPage) async throws -> Void
    ) async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let view: BrowserPage
        if engine == .webKit {
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration),
                context: context
            )
        } else {
            try ChromiumRuntime.shared.ensureInitialized()
            view = BrowserPage(chromium: ChromiumPage(context: context))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        do {
            configure(view)
            view.load(URLRequest(url: url))
            try #require(await waitUntil { view.url == url && !view.isLoading })
            try await body(view)
        } catch {
            await view.close()
            await context.endPrivateSession()
            throw error
        }
        await view.close()
        await context.endPrivateSession()
    }

    private func observedFields(in view: BrowserPage, firstValue: String) async throws -> [PageDriver.FieldValue] {
        _ = await PageDriver.readRenderedPage(view)
        let refs = try #require(PageDriver.observation(in: view)?.refs.sorted())
        try #require(refs.count == 2)
        return [
            .init(ref: refs[0], value: firstValue, select: false),
            .init(ref: refs[1], value: "must-not-write", select: false),
        ]
    }

    @Test(arguments: BrowserEngine.allCases)
    func formFillStopsAtDocumentOrGrantBoundary(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/start": .html("""
                <input aria-label="First" oninput="window.__wsurfSend('formWrite', 'first');location.href='/replacement'">
                <input aria-label="Second">
                """),
            "/replacement": .html("""
                <input aria-label="Replacement" oninput="window.replacementWrites=(window.replacementWrites||0)+1">
                <input aria-label="Replacement second">
                """),
        ])
        defer { withExtendedLifetime(server) {} }
        var firstWrites = 0
        let replacementURL = try server.url("/replacement")
        try await withPage(engine: engine, url: server.url("/start"), configure: { view in
            view.addScriptMessageHandler(name: "formWrite", in: .page) { _ in firstWrites += 1 }
        }) { view in
            let fields = try await observedFields(in: view, firstValue: "navigate")
            _ = await PageDriver.fillFields(fields, in: view)
            try #require(await waitUntil { view.url == replacementURL && !view.isLoading })
            #expect(firstWrites == 1)
            #expect(try await view.evaluateJavaScript("window.replacementWrites || 0") as? Int == 0)
            #expect(try await view.evaluateJavaScript("document.querySelectorAll('input')[1].value") as? String == "")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func formFillStopsAfterCancellation(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <input aria-label="First" oninput="window.firstWrites=(window.firstWrites||0)+1;window.__wsurfSend('formWrite', 'first')">
                <input aria-label="Second">
                """),
        ])
        defer { withExtendedLifetime(server) {} }
        var task: Task<String, Never>?
        try await withPage(engine: engine, url: server.url(), configure: { view in
            view.addScriptMessageHandler(name: "formWrite", in: .page) { _ in task?.cancel() }
        }) { view in
            let fields = try await observedFields(in: view, firstValue: "write-once")
            let batch = Task { await PageDriver.fillFields(fields, in: view) }
            task = batch
            _ = await batch.value
            #expect(batch.isCancelled)
            #expect(try await view.evaluateJavaScript("window.firstWrites") as? Int == 1)
            #expect(try await view.evaluateJavaScript("document.querySelectorAll('input')[1].value") as? String == "")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func formFillStopsAfterApprovalRevocation(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <input aria-label="First" oninput="window.firstWrites=(window.firstWrites||0)+1;window.__wsurfSend('formWrite', 'first')">
                <input aria-label="Second">
                """),
        ])
        defer { withExtendedLifetime(server) {} }
        var permission: TabAssistantAccessCenter?
        try await withPage(engine: engine, url: server.url(), configure: { view in
            let access = TabAssistantAccessCenter(store: view.context.sitePermissions)
            permission = access
            view.addScriptMessageHandler(name: "formWrite", in: .page) { _ in access.set(.deny) }
        }) { view in
            let access = try #require(permission)
            access.pageChanged(url: view.url)
            access.set(.control)
            let fields = try await observedFields(in: view, firstValue: "write-once")
            let observation = try #require(PageDriver.observation(in: view))
            let scope = PageAutomationGuard(
                documentURL: observation.url, snapshot: observation.id,
                validate: { access.effectivePolicy.allows(.control) }
            )
            _ = await PageAutomationGuard.$current.withValue(scope) {
                await PageDriver.fillFields(fields, in: view)
            }
            #expect(access.effectivePolicy == .deny)
            #expect(try await view.evaluateJavaScript("window.firstWrites") as? Int == 1)
            #expect(try await view.evaluateJavaScript("document.querySelectorAll('input')[1].value") as? String == "")
        }
    }

    @Test(arguments: ["checkbox", "select"], ["aria-readonly", "data-wsurf-payment-card"])
    func formEligibilityIsRecheckedAfterAnnouncement(kind: String, attribute: String) async throws {
        let control = kind == "checkbox"
            ? "<input id='target' aria-label='Choice' type='checkbox'>"
            : "<select id='target' aria-label='Choice'><option>A</option><option>B</option></select>"
        let view = await page(control + """
            <script>window.changes=0;document.addEventListener('change',()=>window.changes++);</script>
            """)
        _ = await PageDriver.readRenderedPage(view)
        _ = await PageDriver.$pauseSleeper.withValue({ @MainActor _ in
            _ = try? await view.evaluateJavaScript("document.querySelector('#target').setAttribute('\(attribute)', 'true')")
        }) {
            await PageDriver.fillFields([
                .init(ref: 1, value: kind == "checkbox" ? "true" : "B", select: kind == "select"),
            ], in: view, announced: true)
        }
        #expect(await js(view, "window.changes") as? Int == 0)
        if kind == "checkbox" {
            #expect(await js(view, "document.querySelector('#target').checked") as? Bool == false)
        } else {
            #expect(await js(view, "document.querySelector('#target').value") as? String == "A")
        }
    }

    // Slice 1 native probes (docs/superpowers/plans/2026-10-14-mcp-development-mode.md, Task 1).
    // They assert the shared contract on both engines; a failure on one engine reproduces a static risk.
    @Test(arguments: BrowserEngine.allCases)
    func pressKeyDeliversKeyDownAndKeyUpToFocusedControl(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <input aria-label="Input" onkeydown="window.keys=(window.keys||'')+'d'" onkeyup="window.keys+='u'">
                """),
        ])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url()) { view in
            _ = await PageDriver.readRenderedPage(view)
            let ref = try #require(PageDriver.observation(in: view)?.refs.sorted().first)
            let result = await PageDriver.pressKey("ArrowDown", ref: ref, in: view)
            let delivered = try await view.evaluateJavaScript("window.keys || ''") as? String
            #expect(delivered == "du", "engine \(engine): result \(result)")
            #expect(result.hasPrefix("Sent ArrowDown") == (delivered == "du"), "reported success must match delivery: \(result)")
            #expect(try await view.evaluateJavaScript("document.activeElement.tagName") as? String == "INPUT")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func goBackReportsActualNavigation(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/a": .html("<h1>Page A</h1>"), "/b": .html("<h1>Page B</h1>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let first = try server.url("/a")
        let second = try server.url("/b")
        try await withPage(engine: engine, url: first) { view in
            let none = await PageDriver.goBack(in: view)
            #expect(none == "There is no page to go back to.", "engine \(engine): \(none)")
            // The startup page is not a history entry. The list is read asynchronously, so wait for the first page to appear in it.
            #expect(await waitUntil {
                let list = view.backForwardList
                return list.currentItem?.url == first && list.backList.isEmpty
            }, "engine \(engine): \(view.backForwardList.backList.map(\.url))")
            view.load(URLRequest(url: second))
            try #require(await waitUntil { view.url == second && !view.isLoading })
            let back = await PageDriver.goBack(in: view)
            #expect(back.hasPrefix("Went back."), "engine \(engine): \(back)")
            #expect(view.url == first, "engine \(engine): url \(String(describing: view.url))")
            #expect(back.contains("Page A"), "engine \(engine): \(back)")
        }
    }

    /// Holds the startup-entry reset open from a test: Chromium has answered it, the page has not yet applied the answer.
    @MainActor
    private final class StartupResetGate {
        private(set) var reached = false
        private let stream: AsyncStream<Void>
        private let release: AsyncStream<Void>.Continuation

        init() {
            (stream, release) = AsyncStream.makeStream(of: Void.self)
        }

        func wait() async {
            reached = true
            for await _ in stream {}
        }

        func open() {
            release.finish()
        }
    }

    private func freshChromiumTab(
        resetCommand: @escaping @MainActor (ChromiumPage) async throws -> Void,
        body: (BrowserPage, URL, URL) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/a": .html("<h1>Page A</h1>"), "/b": .html("<h1>Page B</h1>")])
        defer { withExtendedLifetime(server) {} }
        let first = try server.url("/a")
        let second = try server.url("/b")
        try await withPage(
            engine: .chromium, url: first,
            configure: { view in
                view.chromium?.startupResetCommand = { [weak chromium = view.chromium] in
                    if let chromium {
                        try await resetCommand(chromium)
                    }
                }
            }
        ) { view in
            try await body(view, first, second)
        }
    }

    /// The window the report describes: Chromium counts the startup page until its history reset has been applied, and may
    /// report that on any loading change meanwhile.
    @Test func goBackOnAFreshChromiumTabNeverReachesTheStartupPage() async throws {
        let gate = StartupResetGate()
        defer { gate.open() }
        try await freshChromiumTab(resetCommand: { chromium in
            _ = try await chromium.command("Page.resetNavigationHistory")
            await gate.wait()
        }) { view, first, second in
            let chromium = try #require(view.chromium)
            try #require(await waitUntil { gate.reached })
            chromium.didChangeLoading(false, canGoBack: true, canGoForward: false)
            #expect(!view.canGoBack, "Back must not see the startup page while the reset is pending")
            let none = await PageDriver.goBack(in: view)
            #expect(none == "There is no page to go back to.", "\(none)")
            #expect(view.url == first, "url \(String(describing: view.url))")
            gate.open()
            #expect(await waitUntil {
                let list = view.backForwardList
                return list.currentItem?.url == first && list.backList.isEmpty
            }, "\(view.backForwardList.backList.map(\.url))")
            #expect(!view.canGoBack)
            // Once the reset has landed, Back is driven by real history again.
            view.load(URLRequest(url: second))
            try #require(await waitUntil { view.url == second && !view.isLoading && view.canGoBack })
            let back = await PageDriver.goBack(in: view)
            #expect(back.hasPrefix("Went back."), "\(back)")
            #expect(view.url == first, "url \(String(describing: view.url))")
        }
    }

    /// Chromium refuses the reset ("Not attached to an active page") when it arrives while the first commit is still swapping
    /// renderers. The page asks again, and Back stays closed until a reset has landed.
    @Test func aRefusedStartupResetIsRetriedUntilTheStartupPageIsGone() async throws {
        let gate = StartupResetGate()
        defer { gate.open() }
        var attempts = 0
        try await freshChromiumTab(resetCommand: { chromium in
            attempts += 1
            if attempts < 3 {
                throw ChromiumError.protocolFailure("Not attached to an active page")
            }
            _ = try await chromium.command("Page.resetNavigationHistory")
            await gate.wait()
        }) { view, first, second in
            let chromium = try #require(view.chromium)
            try #require(await waitUntil { gate.reached })
            #expect(attempts == 3)
            chromium.didChangeLoading(false, canGoBack: true, canGoForward: false)
            #expect(!view.canGoBack, "Back stays closed while the reset is being retried")
            gate.open()
            #expect(await waitUntil {
                let list = view.backForwardList
                return list.currentItem?.url == first && list.backList.isEmpty
            }, "\(view.backForwardList.backList.map(\.url))")
            #expect(!view.canGoBack)
            view.load(URLRequest(url: second))
            try #require(await waitUntil { view.url == second && !view.isLoading && view.canGoBack })
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func goBackHandlesSameDocumentHistory(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<h1>Same doc</h1>")])
        defer { withExtendedLifetime(server) {} }
        try await withPage(engine: engine, url: server.url()) { view in
            _ = try await view.evaluateJavaScript("history.pushState({}, '', '/pushed'); 0")
            try #require(await waitUntil { view.url?.path == "/pushed" })
            let back = await PageDriver.goBack(in: view)
            #expect(back.hasPrefix("Went back."), "engine \(engine): \(back)")
            #expect(await waitUntil { view.url?.path == "/" }, "engine \(engine): url \(String(describing: view.url))")
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self {
            error
        } else {
            nil
        }
    }
}
