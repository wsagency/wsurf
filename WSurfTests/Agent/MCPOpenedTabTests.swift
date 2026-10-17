// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// A report names, and authorizes, only the tabs the shared page opened.
@MainActor
@Suite(.boundedWebViews)
struct MCPOpenedTabTests {
    private typealias Rig = MCPFeedbackRig

    private static let opener = "<!doctype html><title>Opener</title><a href='/popup' target='_blank'>Open help</a><button>Go</button>"

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/popup": .html("<!doctype html><title>Help</title><p>Help text</p>"),
        "/other": .html("<!doctype html><title>Other</title><p>Another site</p>"),
    ]

    /// Opens a tab the way a person or another window does, in the middle of the action: the announce pause is the one
    /// moment every action waits.
    private func click(_ label: String, in rig: Rig, whileOpening other: URL) async throws -> CallTool.Result {
        let read = try await rig.start()
        let ref = try Rig.ref(of: label, in: read)
        let browser = rig.browser
        return try await PageDriver.$pauseSleeper.withValue({ _ in
            await MainActor.run { _ = browser.newTab(url: other, activate: false) }
        }) {
            try await rig.call("clickOnPage", ["ref": .int(ref)])
        }
    }

    @Test func aTabAnotherWindowOpenedDuringAnActionIsNeitherReportedNorAuthorized() async throws {
        let rig = try await Rig.make(html: Self.opener, routes: Self.routes)
        defer { rig.close() }
        let result = try await click("Go", in: rig, whileOpening: try rig.server.url("/other"))
        #expect(result.isError == false, "\(Rig.text(result))")
        let stranger = try #require(rig.browser.tabs.first { $0 !== rig.tab })
        #expect(rig.browser.openerByTab[stranger.id] == nil, "nothing recorded this tab as opened by the shared page")
        #expect(await waitUntil { URL(string: stranger.urlString)?.path == "/other" }, "the tab has an address that could have been reported")
        #expect(!Rig.content(result).contains("opened:") && !Rig.text(result).contains("/other"), "\(Rig.content(result))")
        #expect(!rig.session.destinations.contains { $0.hasSuffix("/other") }, "its address is not one the connection may navigate to")
        let navigated = try await rig.call("navigate", ["url": .string(try rig.server.url("/other").absoluteString)])
        #expect(navigated.isError == true, "\(Rig.text(navigated))")
    }

    @Test func onlyThePopupTheSharedPageOpenedIsReportedWhenAnotherTabAppearsToo() async throws {
        let rig = try await Rig.make(html: Self.opener, routes: Self.routes)
        defer { rig.close() }
        let result = try await click("Open help", in: rig, whileOpening: try rig.server.url("/other"))
        #expect(result.isError == false, "\(Rig.text(result))")
        let content = Rig.content(result)
        #expect(content.contains("opened: ") && content.contains("/popup"), "\(content)")
        #expect(!content.contains("/other"), "\(content)")
        #expect(rig.session.destinations.contains { $0.hasSuffix("/popup") })
        #expect(!rig.session.destinations.contains { $0.hasSuffix("/other") })
        let popup = try #require(rig.browser.tabs.first { rig.browser.openerByTab[$0.id] == rig.tab.id })
        #expect(URL(string: popup.urlString)?.path == "/popup")
    }
}
