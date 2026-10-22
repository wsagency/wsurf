// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
import Foundation
import MCP

/// `compareTabs`: two shared tabs that show one page, usually in different engines, and what differs between them.
@MainActor
extension MCPBrowserSession {
    /// One tab of a comparison, with the page it started on. Every await of the comparison is followed by a check that it is
    /// still that page.
    private struct Side {
        let tab: BrowserTab
        let view: BrowserPage
        let generation: Int
        let url: URL
        var layout = MCPCompareTools.Layout()

        var engine: String {
            view.chromium != nil ? "chromium" : "webkit"
        }

        var value: Value {
            .object(["tabID": .string(tab.id.uuidString), "engine": .string(engine)])
        }
    }

    func compareTabs(_ arguments: [String: Value]) async -> CallTool.Result {
        guard let first = arguments["tabA"]?.stringValue.flatMap(UUID.init(uuidString:)),
            let second = arguments["tabB"]?.stringValue.flatMap(UUID.init(uuidString:)), first != second
        else { return MCPCompareTools.result(.invalidInput, message: "tabA and tabB must be the IDs of two different tabs.") }
        guard let tabA = sharedTab(first), let tabB = sharedTab(second) else { return failure("This tab is not shared with this connection.") }
        guard mayProceed(tabA, capability: .development), mayProceed(tabB, capability: .development) else {
            return MCPCompareTools.result(.denied, message: "Comparing needs development access to both tabs.")
        }
        keepInWindow(tabA)
        keepInWindow(tabB)
        guard isReachable(tabA), isReachable(tabB) else {
            return MCPCompareTools.result(.invalidInput, message: "Both tabs must be on screen or kept in this window. openComparison opens them that way.")
        }
        guard tabA.developmentRelation(of: id) != .other, tabB.developmentRelation(of: id) != .other else {
            return MCPCompareTools.result(.ownershipConflict, message: "Another connection is using development tools on one of these tabs. Nothing was compared.")
        }
        for tab in [tabA, tabB] {
            tab.setExternalAutomationWorking(true)
            tab.realizeDeferredSession()
        }
        defer {
            for tab in [tabA, tabB] {
                tab.setExternalAutomationWorking(false)
            }
        }
        var sides: [Side] = []
        for tab in [tabA, tabB] {
            let view = tab.page
            let generation = tab.pageGeneration
            guard tab.isLive(view, generation: generation), await PageSettle.untilIdle(view), tab.isLive(view, generation: generation),
                let url = webURL(of: tab)
            else { return MCPCompareTools.result(.pageGone, message: "A page is not ready. Try again once it has loaded.") }
            sides.append(Side(tab: tab, view: view, generation: generation, url: url))
        }
        return await compare(sides[0], sides[1], arguments: arguments)
    }

    private func compare(_ first: Side, _ second: Side, arguments: [String: Value]) async -> CallTool.Result {
        var a = first, b = second
        guard let layoutA = await measure(a), let layoutB = await measure(b) else {
            return MCPCompareTools.result(.pageGone, message: "A page did not answer. Try again.")
        }
        a.layout = layoutA
        b.layout = layoutB
        guard MCPCompareTools.sameViewport(a.layout, b.layout) else {
            return MCPCompareTools.result(
                .invalidInput,
                message: "The tabs differ in size. Give both the same size with setViewport, or put them side by side with openComparison. "
                    + "Chromium may not apply setViewport while WSurf is in the background.",
                [
                    "a": .object(["viewport": Self.viewportValue(a.layout)]),
                    "b": .object(["viewport": Self.viewportValue(b.layout)]),
                ])
        }
        var fields: [String: Value] = [
            "a": a.value, "b": b.value, "viewport": Self.viewportValue(a.layout), "layout": MCPCompareTools.layoutValue(a.layout, b.layout),
        ]
        let shot = await screenshotComparison(a, b, wantsImage: arguments["image"]?.boolValue == true)
        fields["screenshot"] = shot.value
        if arguments["diagnostics"]?.boolValue != false {
            fields["diagnostics"] = await diagnosticsComparison(a.tab, b.tab)
        }
        // The last await is behind us: what is returned is still within this connection's access.
        guard mayProceed(a.tab, capability: .development), mayProceed(b.tab, capability: .development),
            a.tab.isLive(a.view, generation: a.generation), b.tab.isLive(b.view, generation: b.generation)
        else { return MCPCompareTools.result(.stale, message: "Page access changed while comparing. Its contents were not returned.") }
        return MCPCompareTools.result(.ok, fields, image: shot.image)
    }

    private static func viewportValue(_ layout: MCPCompareTools.Layout) -> Value {
        .object(["width": .int(layout.viewportWidth), "height": .int(layout.viewportHeight)])
    }

    // MARK: Measuring

    /// The guard of one side: the comparison goes on only while its page is the one it started on and the connection still has
    /// development access to it.
    private func guardScope(_ side: Side) -> PageAutomationGuard {
        PageAutomationGuard(
            documentURL: side.url.absoluteString, snapshot: nil,
            validate: { [weak self, weak tab = side.tab, weak view = side.view, generation = side.generation] in
                guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                return self.mayProceed(tab, capability: .development)
            })
    }

    private func measure(_ side: Side) async -> MCPCompareTools.Layout? {
        await PageAutomationGuard.$current.withValue(guardScope(side)) {
            await PageDriver.evaluateJSON(PageDriver.scripted(MCPCompareTools.Layout.script), in: side.view).flatMap { MCPCompareTools.Layout($0) }
        }
    }

    // MARK: Pixels

    /// What the pixel comparison reports, and the picture of it when one was asked for.
    private struct Shot {
        var value: Value
        var image: Data?
    }

    private func screenshotComparison(_ a: Side, _ b: Side, wantsImage: Bool) async -> Shot {
        guard let grid = PageImageDiff.grid(forCSS: CGSize(width: a.layout.viewportWidth, height: a.layout.viewportHeight)) else {
            return Shot(value: Self.notCompared("The viewport has no area."))
        }
        var lumas: [PageImageDiff.Luma] = []
        for (index, side) in [a, b].enumerated() {
            switch await capture(side, width: grid.width) {
            case .success(let image):
                guard let luma = PageImageDiff.luma(of: image, width: grid.width, height: grid.height) else {
                    return Shot(value: Self.notCompared("A screenshot could not be read."))
                }
                lumas.append(luma)
            case .failure(let failure):
                return Shot(value: Self.notCompared("\(index == 0 ? "a" : "b"): \(failure.message)"))
            }
        }
        let diff = PageImageDiff.compare(lumas[0], lumas[1], scale: Double(grid.width) / Double(a.layout.viewportWidth))
        let picture = wantsImage ? PageImageDiff.overlayJPEG(lumas[0], diff, limit: MCPCompareTools.imageBytes) : nil
        return Shot(value: MCPCompareTools.screenshotValue(diff), image: picture)
    }

    private static func notCompared(_ reason: String) -> Value {
        .object(["compared": false, "reason": .string(reason)])
    }

    /// The viewport of `side` as an image `width` pixels wide, through the path `screenshotPage` takes: the same refusals, and
    /// the Developer tier's masking of filled sensitive fields.
    private func capture(_ side: Side, width: Int) async -> Result<CGImage, ScreenshotFailure> {
        await throttleCapture()
        let outcome = await PageAutomationGuard.$current.withValue(guardScope(side)) {
            await PageDriver.screenshot(
                .viewport, developmentAllowed: { false }, maximumBytes: nil, maxWidth: width, masking: screenshotMasking(for: side.tab), in: side.view)
        }
        switch outcome {
        case .success(let capture):
            guard let image = NSBitmapImageRep(data: capture.jpeg)?.cgImage else { return .failure(.captureFailed) }
            return .success(image)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    // MARK: Console and network

    /// What the console and network captures of the two tabs saw differently. Only where this connection runs the capture on both.
    private func diagnosticsComparison(_ a: BrowserTab, _ b: BrowserTab) async -> Value {
        var seen: [MCPCompareTools.Observed] = []
        for tab in [a, b] {
            guard tab.developmentRelation(of: id) == .own, let diagnostics = tab.developmentOwner?.diagnostics else {
                return .object([
                    "compared": false,
                    "reason": "Capture is not running on both tabs. Call startDiagnostics on each, reload both with reloadPage, then compare again.",
                ])
            }
            guard await diagnostics.sync() else { return Self.notCompared("A capture stopped because its page left this connection's access.") }
            seen.append(
                MCPCompareTools.observed(
                    console: diagnostics.buffer.records(of: .console, after: nil), network: diagnostics.buffer.records(of: .network, after: nil),
                    scrub: scrubbed))
        }
        return MCPCompareTools.differences(seen[0], seen[1])
    }
}
