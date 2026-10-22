// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A full-page capture needs development access until the pixels leave.
@MainActor
@Suite(.boundedWebViews)
struct MCPFullPageAccessTests {
    private typealias Rig = MCPFeedbackRig

    private static let tall = "<!doctype html><title>Tall</title><div style='height:2400px;background:linear-gradient(#fff,#06c)'>Tall page</div>"

    @Test func aFullPageCaptureAsksForDevelopmentAccessAfterEveryAwait() async throws {
        let rig = try await Rig.make(engine: .chromium, html: Self.tall, access: .development)
        defer { rig.close() }
        _ = try await rig.start(development: true)
        let view = rig.tab.page
        // Access is asked before the work, after the probe, after the capture and after the second probe; it dropping at any of
        // them refuses the image.
        for lasting in 0..<4 {
            var asked = 0
            let outcome = await PageDriver.screenshot(.fullPage, developmentAllowed: { asked += 1; return asked <= lasting }, in: view)
            #expect(outcome.failure == .needsDevelopment, "access dropped at ask \(lasting + 1): \(outcome)")
        }
        var asked = 0
        let held = await PageDriver.screenshot(.fullPage, developmentAllowed: { asked += 1; return true }, in: view)
        guard case .success(let capture) = held else {
            Issue.record("a held grant was refused: \(held)")
            return
        }
        #expect(capture.requiresDevelopment, "the caller asks once more before it attaches the image")
        #expect(asked == 4)
        #expect(await PageDriver.screenshot(.fullPage, in: view).failure == .needsDevelopment, "no grant is no capture")
    }

    @Test func developmentRevokedWhileACaptureWaitsItsTurnReturnsNoImage() async throws {
        let rig = try await Rig.make(engine: .chromium, html: Self.tall, access: .development)
        defer { rig.close() }
        _ = try await rig.start(development: true)
        rig.session.feedback.sleep = { _ in }
        #expect(try await rig.call("screenshotPage").isError == false)
        // The next capture waits for its turn, however quickly it follows; the site's setting drops to read only while it does.
        rig.session.feedback.captureInterval = .seconds(3_600)
        rig.session.feedback.sleep = { _ in rig.tab.assistantAccess.set(.readOnly) }
        let result = try await rig.call("screenshotPage", ["fullPage": true])
        #expect(result.isError == true)
        #expect(Rig.images(result).isEmpty, "no image after development access ended")
        #expect(Rig.content(result).contains(ScreenshotFailure.needsDevelopment.message), "\(Rig.content(result))")
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
