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
    /// Every request that reached the offer, with the origin it was attributed to.
    private(set) var requests: [(url: URL, origin: String)] = []
    /// Whether each prompt offered to remember the choice for the website.
    private(set) var offeredToRemember: [Bool] = []
    private(set) var drops: [(scheme: String, reason: ExternalApp.Drop)] = []
    private var presenter: CheckedContinuation<NSApplication.ModalResponse, Never>?
    /// Ticks the "always allow" box on every prompt.
    var remembersApproval = false
    /// Answers every prompt at once instead of holding it open.
    var autoAnswer: NSApplication.ModalResponse?

    init() {
        ExternalApp.resolverForTesting = { [app] _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: app.bundleIdentifier)
        }
        ExternalApp.presenterForTesting = { [self] alert in
            prompts += 1
            offeredToRemember.append(alert.showsSuppressionButton)
            if remembersApproval {
                alert.suppressionButton?.state = .on
            }
            if let autoAnswer {
                return autoAnswer
            }
            return await withCheckedContinuation { presenter = $0 }
        }
        ExternalApp.openerForTesting = { [self] in opened.append($0) }
        ExternalApp.requestObserverForTesting = { [self] url, origin in requests.append((url, origin)) }
        ExternalApp.dropObserverForTesting = { [self] scheme, reason in drops.append((scheme, reason)) }
    }

    var isPrompting: Bool {
        presenter != nil
    }

    var dropReasons: [ExternalApp.Drop] {
        drops.map(\.reason)
    }

    func answer(_ response: NSApplication.ModalResponse) {
        presenter?.resume(returning: response)
        presenter = nil
    }

    /// Answers the open prompt and waits until the offer has finished.
    func answerAndSettle(_ response: NSApplication.ModalResponse) async -> Bool {
        answer(response)
        return await waitUntil { !ExternalApp.hasPendingOfferForTesting }
    }

    func tearDown() {
        answer(.alertSecondButtonReturn)
        ExternalApp.resolverForTesting = nil
        ExternalApp.presenterForTesting = nil
        ExternalApp.openerForTesting = nil
        ExternalApp.requestObserverForTesting = nil
        ExternalApp.dropObserverForTesting = nil
    }
}

@MainActor
@Suite(.serialized, .exclusiveExternalApp, .timeLimit(.minutes(1)))
struct AppHandoffApprovalTests {
    private let appURL = URL(string: "slack://open?code=secret")!

    private func temporaryStore() -> (store: SitePermissions, file: URL) {
        let file = URL.temporaryDirectory.appending(path: "AppHandoffApproval-\(UUID().uuidString).json")
        return (SitePermissions(storageURL: file), file)
    }

    /// A tab on `/sign-in` with its prompt for `appURL` open and held by the harness.
    private func tabWithOpenPrompt(
        _ harness: HandoffHarness,
        server: HTTPFixtureServer,
        sitePermissions: SitePermissions? = nil
    ) async throws -> BrowserTab {
        let tab = sitePermissions.map { BrowserTab(opensBlank: false, sitePermissions: $0) }
            ?? BrowserTab(opensBlank: false, privately: true)
        let signIn = try server.url("/sign-in")
        tab.load(signIn)
        try #require(await settled(tab, at: signIn))
        _ = try await tab.page.evaluateJavaScript("location.href = '\(appURL.absoluteString)'")
        try #require(await waitUntil { harness.isPrompting })
        return tab
    }

    private func signInServer() async throws -> HTTPFixtureServer {
        try await HTTPFixtureServer.start(routes: [
            "/sign-in": .html("<title>Sign in</title>"),
            "/signed-in": .html("<title>Signed in</title>"),
        ])
    }

    // MARK: - The person's approval

    @Test(.boundedWebViews)
    func approvingTheShownPromptOpensTheApp() async throws {
        let server = try await signInServer()
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL])
        #expect(harness.drops.isEmpty)
    }

    @Test(.boundedWebViews)
    func approvingAfterThePageMovesOnStillOpensTheApp() async throws {
        let server = try await signInServer()
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
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL], "the person approved this exact link; the page moving on does not withdraw it")
        #expect(harness.drops.isEmpty)
    }

    @Test(.boundedWebViews)
    func approvingAfterThePageMovesToAnotherSiteOpensNothing() async throws {
        let server = try await signInServer()
        let elsewhere = try await HTTPFixtureServer.start(routes: ["/elsewhere": .html("<title>Elsewhere</title>")])
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer {
            tab.detach()
            withExtendedLifetime((server, elsewhere)) {}
        }
        let destination = try elsewhere.url("/elsewhere")
        _ = try await tab.page.evaluateJavaScript("location.href = '\(destination.absoluteString)'")
        try #require(await settled(tab, at: destination))
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened.isEmpty)
        #expect(harness.dropReasons == [.siteChanged])
        #expect(harness.drops.first?.scheme == "slack")
    }

    @Test(.boundedWebViews)
    func approvingAfterTheTabClosesOpensNothing() async throws {
        let server = try await signInServer()
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer { withExtendedLifetime(server) {} }
        tab.detach()
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened.isEmpty)
        #expect(harness.dropReasons == [.tabClosed])
    }

    @Test(.boundedWebViews)
    func decliningOpensNothingAndIsNotADrop() async throws {
        let server = try await signInServer()
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        try #require(await harness.answerAndSettle(.alertSecondButtonReturn))
        #expect(harness.opened.isEmpty)
        #expect(harness.drops.isEmpty, "the person said no; nothing was lost silently")
    }

    @Test(.boundedWebViews)
    func anApprovalOpensOnlyTheLinkThatWasShown() async throws {
        let server = try await signInServer()
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        let other = "slack://open?code=other"
        _ = try await tab.page.evaluateJavaScript("location.href = '\(other)'")
        try #require(await waitUntil { harness.dropReasons == [.busy] })
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL], "a second request must not ride on the approval of the first")

        _ = try await tab.page.evaluateJavaScript("location.href = '\(other)'")
        try #require(await waitUntil { harness.isPrompting })
        #expect(harness.prompts == 2, "an approval is spent by the link it was given for")
        try #require(await harness.answerAndSettle(.alertSecondButtonReturn))
        #expect(harness.opened == [appURL])
    }

    @Test(.boundedWebViews)
    func alwaysAllowStaysWithTheSiteThatAsked() async throws {
        let server = try await signInServer()
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        harness.remembersApproval = true
        defer { harness.tearDown() }
        let tab = try await tabWithOpenPrompt(harness, server: server, sitePermissions: store)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        let signedIn = try server.url("/signed-in")
        _ = try await tab.page.evaluateJavaScript("location.href = '/signed-in'")
        try #require(await settled(tab, at: signedIn))
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL])
        let site = SitePermissions.origin(for: signedIn)
        #expect(tab.externalApps.allows(harness.app, from: site))
        #expect(store.externalAppRecords.keys.sorted() == [site])
        #expect(!tab.externalApps.allows(harness.app, from: "http://example.invalid"))
        await store.waitForPendingSave()
    }

    // MARK: - Which frame asked

    @Test(.boundedWebViews, arguments: [
        "history.pushState({}, '', '/step-2')",
        "history.replaceState({}, '', '/step-2')",
        "location.hash = '#step-2'",
    ])
    func aPageThatChangedItsOwnAddressIsStillRecognized(change: String) async throws {
        let server = try await signInServer()
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = BrowserTab(opensBlank: false, privately: true)
        defer {
            tab.detach()
            withExtendedLifetime(server) {}
        }
        let signIn = try server.url("/sign-in")
        tab.load(signIn)
        try #require(await settled(tab, at: signIn))
        _ = try await tab.page.evaluateJavaScript(change)
        _ = try await tab.page.evaluateJavaScript("location.href = '\(appURL.absoluteString)'")
        try #require(await waitUntil { harness.isPrompting || !harness.drops.isEmpty })
        #expect(harness.dropReasons.isEmpty)
        #expect(harness.requests.map(\.origin) == [SitePermissions.origin(for: signIn)])
        #expect(harness.offeredToRemember == [true])
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL])
    }

    @Test(.boundedWebViews)
    func aFormSubmittedAfterReplaceStateIsAttributedToTheAuthorizationSite() async throws {
        let authServer = try await HTTPFixtureServer.start(routes: ["/finish": .redirect(to: appURL)])
        let authURL = try authServer.url("/finish")
        let server = try await HTTPFixtureServer.start(routes: [
            "/form": .html("<title>Form</title><form action='\(authURL.absoluteString)' method='get'></form>"),
        ])
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = BrowserTab(opensBlank: false, privately: true)
        defer {
            tab.detach()
            withExtendedLifetime((authServer, server)) {}
        }
        let form = try server.url("/form")
        tab.load(form)
        try #require(await settled(tab, at: form))
        _ = try await tab.page.evaluateJavaScript("history.replaceState({}, '', '/form?step=2')")
        _ = try await tab.page.evaluateJavaScript("document.forms[0].submit()")
        try #require(await waitUntil { harness.isPrompting || !harness.drops.isEmpty })
        #expect(harness.dropReasons.isEmpty)
        #expect(harness.requests.map(\.origin) == [SitePermissions.origin(for: authURL)])
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL])
    }

    // MARK: - A source that cannot be told apart

    /// A page with two identical frames; either one jumps to the app when it hears from the page.
    private func twoIdenticalFrames() async throws -> (top: HTTPFixtureServer, frames: HTTPFixtureServer) {
        let frames = try await HTTPFixtureServer.start(routes: [
            "/frame": .html("""
                <script>addEventListener('message', () => location.href = '\(appURL.absoluteString)');
                parent.postMessage('ready', '*');</script>
                """),
        ])
        let frameURL = try frames.url("/frame")
        let top = try await HTTPFixtureServer.start(routes: [
            "/": .html("""
                <script>window.ready = 0; addEventListener('message', e => { if (e.data === 'ready') window.ready++; });</script>
                <iframe src='\(frameURL.absoluteString)'></iframe><iframe src='\(frameURL.absoluteString)'></iframe>
                """),
            "/next": .html("<title>Next</title>"),
        ])
        return (top, frames)
    }

    private func loadedTwoFrames(
        _ servers: (top: HTTPFixtureServer, frames: HTTPFixtureServer),
        sitePermissions: SitePermissions
    ) async throws -> BrowserTab {
        let tab = BrowserTab(opensBlank: false, sitePermissions: sitePermissions)
        let url = try servers.top.url("/")
        tab.load(url)
        try #require(await settled(tab, at: url))
        try #require(await waitUntil { (try? await tab.page.evaluateJavaScript("window.ready === 2")) as? Bool == true })
        return tab
    }

    @Test(.boundedWebViews)
    func twoIdenticalFramesAskOnceWithoutNamingASite() async throws {
        let servers = try await twoIdenticalFrames()
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        harness.remembersApproval = true
        defer { harness.tearDown() }
        let tab = try await loadedTwoFrames(servers, sitePermissions: store)
        defer {
            tab.detach()
            withExtendedLifetime(servers) {}
        }
        _ = try await tab.page.evaluateJavaScript(
            "document.querySelectorAll('iframe').forEach(f => f.contentWindow.postMessage('go', '*')); true")
        try #require(await waitUntil { harness.dropReasons == [.busy] })
        #expect(harness.prompts == 1, "the second frame's request does not stack a second prompt")
        #expect(harness.requests.map(\.origin) == ["", ""], "neither frame can be told from the other, so neither names a site")
        #expect(harness.offeredToRemember == [false])
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened == [appURL])
        #expect(store.externalAppRecords.isEmpty)
    }

    @Test(.boundedWebViews)
    func anUnattributedApprovalDoesNotSurviveThePageMovingOn() async throws {
        let servers = try await twoIdenticalFrames()
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        let tab = try await loadedTwoFrames(servers, sitePermissions: store)
        defer {
            tab.detach()
            withExtendedLifetime(servers) {}
        }
        _ = try await tab.page.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage('go', '*'); true")
        try #require(await waitUntil { harness.isPrompting })
        let next = try servers.top.url("/next")
        _ = try await tab.page.evaluateJavaScript("location.href = '/next'")
        try #require(await settled(tab, at: next))
        try #require(await harness.answerAndSettle(.alertFirstButtonReturn))
        #expect(harness.opened.isEmpty, "with no site to hold the page to, the page that asked is the only thing to hold")
        #expect(harness.dropReasons == [.documentChanged])
    }

    // MARK: - The offer itself

    private func offer(
        _ harness: HandoffHarness,
        store: SitePermissions,
        staleness: () async -> ExternalApp.Drop?,
        approvalStaleness: (() async -> ExternalApp.Drop?)? = nil
    ) async {
        harness.autoAnswer = .alertFirstButtonReturn
        await ExternalApp.offerToOpen(
            appURL, from: "https://example.com", policy: TabExternalAppPolicy(store: store), in: nil,
            staleness: staleness, approvalStaleness: approvalStaleness
        )
    }

    @Test func theApprovalCheckJudgesAnApprovalInPlaceOfTheRequestCheck() async {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        var checks = 0
        await offer(harness, store: store, staleness: {
            checks += 1
            return checks > 2 ? .documentChanged : nil
        }, approvalStaleness: { nil })
        #expect(checks == 2, "the request is checked before the prompt and after the app lookup, not after the answer")
        #expect(harness.opened == [appURL])
        #expect(harness.drops.isEmpty)
    }

    @Test func withoutAnApprovalCheckTheRequestCheckStillGatesTheOpen() async {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        var checks = 0
        await offer(harness, store: store, staleness: {
            checks += 1
            return checks > 2 ? .documentChanged : nil
        })
        #expect(harness.opened.isEmpty)
        #expect(harness.dropReasons == [.documentChanged])
    }

    @Test func aRefusedApprovalOpensAndRemembersNothing() async {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        harness.remembersApproval = true
        defer { harness.tearDown() }
        await offer(harness, store: store, staleness: { nil }, approvalStaleness: { .siteChanged })
        #expect(harness.opened.isEmpty)
        #expect(harness.dropReasons == [.siteChanged])
        #expect(harness.drops.first?.scheme == "slack", "only the scheme is reported, never the link")
        #expect(store.externalAppRecords.isEmpty)
    }

    @Test func aRequestWithNowhereToAskIsDroppedWithAReason() async {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = HandoffHarness()
        defer { harness.tearDown() }
        ExternalApp.presenterForTesting = nil
        await ExternalApp.offerToOpen(
            appURL, from: "https://example.com", policy: TabExternalAppPolicy(store: store), in: nil, isCurrent: { true }
        )
        #expect(harness.prompts == 0)
        #expect(harness.opened.isEmpty)
        #expect(harness.dropReasons == [.noWindow])
    }
}
