// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// Device emulation and element screenshots measured on both engines: a 200 x 100 CSS element of four coloured quadrants (red, green, blue, black) at a
/// non-zero offset, captured through `screenshotPage` at page zoom 1 and 1.5 and at the phone profile's device pixel ratio 3.
/// The reported CSS bounds, the 2:1 aspect, `scale` (bitmap width / 200) and the colour at each quadrant's centre must agree.
extension MCPDevelopmentOwnershipTests {
    static let quadrants = """
        <!doctype html><title>Quadrants</title><meta name="viewport" content="width=device-width">
        <style>
          body { margin: 0; background: #fff }
          #q { position: absolute; left: 40px; top: 30px; width: 200px; height: 100px; display: grid; grid-template: 50px 50px / 100px 100px }
          #q div:nth-child(1) { background: #f00 } #q div:nth-child(2) { background: #0f0 }
          #q div:nth-child(3) { background: #00f } #q div:nth-child(4) { background: #000 }
        </style>
        <div id=q><div></div><div></div><div></div><div></div></div>
        """

    /// What `screenshotPage` told the client about an image, and the image.
    struct Shot {
        let bounds: CGRect
        let scale: Double
        let bitmap: NSBitmapImageRep
        let report: String

        /// The nearest of red, green, blue, black and white at the centre of each quadrant (top-left, top-right, bottom-left,
        /// bottom-right). Chromium's captures come back in the display's colour space, so pure green is not (0, 255, 0) there:
        /// the palette keeps the hues apart by a wide margin, and white is the page background a misplaced crop would show.
        var quadrantColours: [String] {
            let palette: [(String, [Double])] = [
                ("red", [1, 0, 0]), ("green", [0, 1, 0]), ("blue", [0, 0, 1]), ("black", [0, 0, 0]), ("white", [1, 1, 1]),
            ]
            return [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { fx, fy in
                let cx = Int(Double(bitmap.pixelsWide) * fx), cy = Int(Double(bitmap.pixelsHigh) * fy)
                var sum = [0.0, 0.0, 0.0], count = 0.0
                for y in (cy - 2)...(cy + 2) {
                    for x in (cx - 2)...(cx + 2) {
                        guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        sum[0] += Double(colour.redComponent)
                        sum[1] += Double(colour.greenComponent)
                        sum[2] += Double(colour.blueComponent)
                        count += 1
                    }
                }
                let mean = sum.map { $0 / max(count, 1) }
                let nearest = palette.min {
                    zip($0.1, mean).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) < zip($1.1, mean).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
                }
                return nearest?.0 ?? "none"
            }
        }
    }

    /// Captures `#q` through the MCP tools the way a client does and parses the report it prints.
    func captureQuadrants(_ subject: MCPBrowserSession, _ tab: BrowserTab) async throws -> Shot {
        let result = try await screenshot(subject, tab, try await find(subject, tab, "#q"))
        #expect(result.isError == false, "\(text(result))")
        let report = text(result)
        let pattern = /x (-?\d+), y (-?\d+), (\d+) by (\d+); image scale ([\d.]+) px per CSS px/
        let match = try #require(report.firstMatch(of: pattern), "no geometry in: \(report)")
        let jpeg = try #require(images(result).first, "no image")
        let bitmap = try #require(NSBitmapImageRep(data: jpeg))
        return Shot(
            bounds: CGRect(x: Double(match.1)!, y: Double(match.2)!, width: Double(match.3)!, height: Double(match.4)!),
            scale: Double(match.5)!, bitmap: bitmap, report: String(report.prefix(200)))
    }

    private func expectQuadrants(_ shot: Shot, _ context: String) {
        let size = "\(shot.bitmap.pixelsWide)x\(shot.bitmap.pixelsHigh)"
        #expect(shot.bounds == CGRect(x: 40, y: 30, width: 200, height: 100), "\(context): bounds \(shot.bounds)")
        let aspect = Double(shot.bitmap.pixelsWide) / Double(shot.bitmap.pixelsHigh)
        #expect(abs(aspect - 2) < 0.03, "\(context): aspect \(aspect) for \(size)")
        // The reported scale is printed with two decimals.
        #expect(abs(shot.scale - Double(shot.bitmap.pixelsWide) / 200) < 0.01, "\(context): scale \(shot.scale) for \(size)")
        #expect(shot.quadrantColours == ["red", "green", "blue", "black"], "\(context): \(shot.quadrantColours) for \(size), \(shot.report)")
    }

    /// Chromium keeps page zoom per host, and the fixture pages of the other tests run in parallel on 127.0.0.1: this page
    /// is served from `localhost` so a zoom set here reaches no other test. Zoom 1 and 1.5 run one after the other.
    @Test(arguments: BrowserEngine.allCases)
    func elementScreenshotScaleAtZoomAndDeviceScale(engine: BrowserEngine) async throws {
        try await withFixture(engine: engine, html: Self.quadrants, host: "localhost") { _, browser, tab in
            let window = await show(tab)
            defer {
                tab.page.pageZoom = 1
                hide(window)
            }
            let subject = session(browser)
            try await requestDevelopment(subject)
            for zoom in [1.0, 1.5] {
                tab.page.pageZoom = CGFloat(zoom)
                let expectedWidth = 500 / zoom
                #expect(
                    await waitUntil {
                        let width = (try? await tab.page.evaluateJavaScript("window.innerWidth")) as? NSNumber
                        return width.map { abs($0.doubleValue - expectedWidth) <= 1 } ?? false
                    }, "\(engine): the viewport follows zoom \(zoom)")
                expectQuadrants(try await captureQuadrants(subject, tab), "\(engine) zoom \(zoom)")
            }
        }
    }

    @Test(.enabled(if: MCPDevelopmentOwnershipTests.foreground))
    func elementScreenshotScaleAtPhoneDeviceScaleOnChromium() async throws {
        try await withFixture(engine: .chromium, html: Self.quadrants) { _, browser, tab in
            let window = await show(tab)
            defer { hide(window) }
            let subject = session(browser)
            try await requestDevelopment(subject)
            let applied = try await call(subject, "emulateDevice", tab, ["profile": "phone", "orientation": "portrait"])
            #expect(status(applied) == "ok", "\(text(applied))")
            expectQuadrants(try await captureQuadrants(subject, tab), "chromium phone")
        }
    }

    @Test(.enabled(if: MCPDevelopmentOwnershipTests.foreground))
    func phoneProfileAppliesDPRTouchAndMobileOnChromium() async throws {
        try await withFixture(engine: .chromium, html: Self.quadrants) { _, browser, tab in
            let window = await show(tab)
            defer { hide(window) }
            let hostRatio = try #require(try await tab.page.evaluateJavaScript("window.devicePixelRatio") as? Double)
            let subject = session(browser)
            try await requestDevelopment(subject)
            let applied = try await call(subject, "emulateDevice", tab, ["profile": "phone", "orientation": "portrait"])
            #expect(status(applied) == "ok", "\(text(applied))")
            let measured = try #require(applied.structuredContent?.objectValue?["viewport"]?.objectValue)
            #expect(measured["innerWidth"]?.intValue == 390)
            #expect(measured["innerHeight"]?.intValue == 844)
            #expect(measured["devicePixelRatio"]?.doubleValue == 3)
            #expect(measured["touch"]?.boolValue == true)
            // The page sees the same axes the report claims: pixel ratio, touch input and a coarse pointer.
            #expect(try await tab.page.evaluateJavaScript("window.devicePixelRatio") as? Double == 3)
            #expect(try await tab.page.evaluateJavaScript("navigator.maxTouchPoints") as? Int == 5)
            #expect(try await tab.page.evaluateJavaScript("matchMedia('(pointer: coarse)').matches") as? Bool == true)
            // Resetting removes every axis the profile applied.
            _ = try await call(subject, "resetDevelopment", tab)
            #expect(
                await waitUntil {
                    (try? await tab.page.evaluateJavaScript("window.devicePixelRatio")) as? Double == hostRatio
                }, "the pixel ratio is restored to \(hostRatio)")
            #expect(try await tab.page.evaluateJavaScript("navigator.maxTouchPoints") as? Int == 0)
            #expect(try await tab.page.evaluateJavaScript("matchMedia('(pointer: coarse)').matches") as? Bool == false)
        }
    }
}
