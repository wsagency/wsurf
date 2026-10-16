// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Drives the production offer path (resolver, prompt, opener) and lets a test hold the prompt open.
@MainActor
final class HandoffHarness {
    let app = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
    private(set) var prompts = 0
    private(set) var opened: [URL] = []
    private var presenter: CheckedContinuation<NSApplication.ModalResponse, Never>?
    var remembersApproval = false

    init() {
        ExternalApp.resolverForTesting = { [app] _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
        }
        ExternalApp.presenterForTesting = { [self] alert in
            prompts += 1
            if remembersApproval {
                alert.suppressionButton?.state = .on
            }
            return await withCheckedContinuation { presenter = $0 }
        }
        ExternalApp.openerForTesting = { [self] in opened.append($0) }
    }

    var isPrompting: Bool {
        presenter != nil
    }

    func answer(_ response: NSApplication.ModalResponse) {
        presenter?.resume(returning: response)
        presenter = nil
    }

    func tearDown() {
        answer(.alertSecondButtonReturn)
        ExternalApp.resolverForTesting = nil
        ExternalApp.presenterForTesting = nil
        ExternalApp.openerForTesting = nil
    }
}

@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp, .timeLimit(.minutes(1)))
struct AppHandoffApprovalTests {
    private let appURL = URL(string: "slack://open?code=secret")!

    /// A tab on `/sign-in` with its prompt for `appURL` open and held by the harness.
    private func tabWithOpenPrompt(
        _ harness: HandoffHarness,
        server: HTTPFixtureServer
    ) async throws -> BrowserTab {
        let tab = BrowserTab(opensBlank: false, privately: true)
        let signIn = try server.url("/sign-in")
        tab.load(signIn)
        try #require(await settled(tab, at: signIn))
        _ = try await tab.page.evaluateJavaScript("location.href = '\(appURL.absoluteString)'")
        try #require(await waitUntil { harness.isPrompting })
        return tab
    }

    @Test func approvingTheShownPromptOpensTheApp() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/sign-in": .html("<title>Sign in</title>")])
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        harness.answer(.alertFirstButtonReturn)
        try #require(await waitUntil { harness.opened.count == 1 })
        #expect(harness.opened == [appURL])
    }

    @Test func approvingAfterThePageMovesOnStillOpensTheApp() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/sign-in": .html("<title>Sign in</title>"),
            "/signed-in": .html("<title>Signed in</title>"),
        ])
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        let signedIn = try server.url("/signed-in")
        _ = try await tab.page.evaluateJavaScript("location.href = '/signed-in'")
        try #require(await settled(tab, at: signedIn))
        harness.answer(.alertFirstButtonReturn)
        try #require(await waitUntil { !harness.isPrompting && !ExternalApp.hasPendingOfferForTesting })
        #expect(harness.opened == [appURL], "the person approved this exact link; the page moving on does not withdraw it")
    }
}
