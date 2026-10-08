// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp)
struct NavigationPolicyTests {
    private final class StubAction: WKNavigationAction {
        var stubbedRequest = URLRequest(url: URL(string: "https://example.com/")!)
        var stubbedType: WKNavigationType = .other
        var stubbedModifiers: NSEvent.ModifierFlags = []
        var stubbedButton = 0
        var stubbedDownload = false

        override var request: URLRequest {
            stubbedRequest
        }

        override var navigationType: WKNavigationType {
            stubbedType
        }

        override var modifierFlags: NSEvent.ModifierFlags {
            stubbedModifiers
        }

        override var buttonNumber: Int {
            stubbedButton
        }

        override var shouldPerformDownload: Bool {
            stubbedDownload
        }

        override var targetFrame: WKFrameInfo? {
            nil
        }
    }

    private func subject(extensionBase: URL? = nil) -> (BrowserTab, TabNavigationDelegate) {
        let tab: BrowserTab
        if let extensionBase {
            tab = BrowserTab(extensionHost: ExtensionPageHost(
                configuration: WebViewPool.makeConfiguration(),
                baseURL: extensionBase,
                name: "Stub Extension",
                icon: nil
            ))
        } else {
            tab = BrowserTab()
        }
        return (tab, TabNavigationDelegate(tab: tab))
    }

    private func decide(
        _ delegate: TabNavigationDelegate,
        _ tab: BrowserTab,
        _ action: StubAction
    ) throws -> WKNavigationActionPolicy? {
        let webKit = try #require(tab.page.webKit)
        var decided: WKNavigationActionPolicy?
        delegate.webView(webKit, decidePolicyFor: action) { decided = $0 }
        return decided
    }

    private func action(
        _ address: String,
        type: WKNavigationType = .other,
        modifiers: NSEvent.ModifierFlags = [],
        button: Int = 0
    ) -> StubAction {
        let stub = StubAction()
        stub.stubbedRequest = URLRequest(url: URL(string: address)!)
        stub.stubbedType = type
        stub.stubbedModifiers = modifiers
        stub.stubbedButton = button
        return stub
    }

    /// WebKit's number for the middle button, which is not NSEvent's 2.
    private static let middleButton = 4

    // MARK: - Ordinary navigation

    @Test func anOrdinaryWebPageIsAllowed() throws {
        let (tab, delegate) = subject()
        #expect(try decide(delegate, tab, action("https://example.com/page")) == .allow)
    }

    @Test func aPlainHTTPPageIsStillTheWebAndIsAllowed() throws {
        let (tab, delegate) = subject()
        #expect(try decide(delegate, tab, action("http://example.com/page")) == .allow)
    }

    @Test func aRequestThatAsksToBeDownloadedIsNotNavigatedTo() throws {
        let (tab, delegate) = subject()
        let stub = action("https://example.com/archive.zip")
        stub.stubbedDownload = true

        #expect(try decide(delegate, tab, stub) == .download)
    }

    // MARK: - Links that leave the browser

    @Test(arguments: ["mailto:someone@example.com", "tel:+15550100", "zoommtg://zoom.us/join?confno=1"])
    func aLinkForAnotherAppNeverNavigates(address: String) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Source page</title><a id='external'>Open app</a>"),
        ])
        let source = try server.url()
        let tab = BrowserTab(opensBlank: false)
        var requestedURL: URL?
        var requestedOrigin: String?
        ExternalApp.requestObserverForTesting = { url, origin in
            requestedURL = url
            requestedOrigin = origin
        }
        defer {
            ExternalApp.requestObserverForTesting = nil
            tab.detach()
            withExtendedLifetime(server) {}
        }
        tab.load(source)
        try #require(await settled(tab, at: source))
        _ = try await tab.page.callAsyncJavaScript(
            "const link = document.getElementById('external'); link.href = address; link.click();",
            arguments: ["address": address], in: nil, contentWorld: .page
        )
        try #require(await waitUntil { requestedURL != nil })
        #expect(requestedURL == URL(string: address))
        #expect(requestedOrigin == SitePermissions.origin(for: source))
        #expect(tab.page.url == source)
        #expect(tab.title == "Source page")
        #expect(!tab.page.canGoBack)
    }

    @Test func theSchemesThePageIsAllowedToDriveItselfWith() throws {
        let (tab, delegate) = subject()
        for address in ["about:blank", "data:text/html,hi", "blob:https://example.com/x"] {
            #expect(try decide(delegate, tab, action(address)) == .allow, "\(address)")
        }
    }

    // MARK: - Modifier clicks

    @Test func commandClickingALinkOpensATabInsteadOfNavigating() throws {
        let (tab, delegate) = subject()
        var opened: (URL, Bool)?
        tab.onOpenInNewTab = { opened = ($0, $1) }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .linkActivated, modifiers: [.command]
        ))

        #expect(policy == .cancel)
        #expect(opened?.0.absoluteString == "https://example.com/target")
        #expect(opened?.1 == false)
    }

    @Test func commandShiftClickingAsksForTheTabToBeActivated() throws {
        let (tab, delegate) = subject()
        var opened: (URL, Bool)?
        tab.onOpenInNewTab = { opened = ($0, $1) }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .linkActivated, modifiers: [.command, .shift]
        ))

        #expect(policy == .cancel)
        #expect(opened?.1 == true)
    }

    @Test func shiftClickingALinkPeeksAtIt() throws {
        let (tab, delegate) = subject()
        var peeked: URL?
        tab.onOpenInPeek = { url, _ in peeked = url }
        tab.onOpenInNewTab = { _, _ in Issue.record("shift alone must not open a tab") }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .linkActivated, modifiers: [.shift]
        ))

        #expect(policy == .cancel)
        #expect(peeked?.absoluteString == "https://example.com/target")
    }

    @Test func commandShiftIsATabRatherThanAPeek() throws {
        let (tab, delegate) = subject()
        tab.onOpenInNewTab = { _, _ in }
        tab.onOpenInPeek = { _, _ in Issue.record("command-shift must not peek") }

        _ = try decide(delegate, tab, action(
            "https://example.com/target", type: .linkActivated, modifiers: [.command, .shift]
        ))
    }

    @Test func middleClickingALinkOpensATabInTheBackground() throws {
        let (tab, delegate) = subject()
        var opened: (URL, Bool)?
        tab.onOpenInNewTab = { opened = ($0, $1) }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .linkActivated, button: Self.middleButton
        ))

        #expect(policy == .cancel)
        #expect(opened?.0.absoluteString == "https://example.com/target")
        #expect(opened?.1 == false)
    }

    @Test func shiftMiddleClickingAsksForTheTabToBeActivated() throws {
        let (tab, delegate) = subject()
        var opened: (URL, Bool)?
        tab.onOpenInNewTab = { opened = ($0, $1) }
        tab.onOpenInPeek = { _, _ in Issue.record("shift with the middle button must not peek") }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target",
            type: .linkActivated,
            modifiers: [.shift],
            button: Self.middleButton
        ))

        #expect(policy == .cancel)
        #expect(opened?.1 == true)
    }

    @Test func theMiddleButtonIsIgnoredWhenThePageNavigatesItself() throws {
        let (tab, delegate) = subject()
        tab.onOpenInNewTab = { _, _ in Issue.record("a redirect must not open a tab") }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .other, button: Self.middleButton
        ))

        #expect(policy == .allow)
    }

    @Test func modifiersAreIgnoredWhenThePageNavigatesItself() throws {
        let (tab, delegate) = subject()
        tab.onOpenInNewTab = { _, _ in Issue.record("a redirect must not open a tab") }
        tab.onOpenInPeek = { _, _ in Issue.record("a redirect must not peek") }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .other, modifiers: [.command, .shift]
        ))

        #expect(policy == .allow)
    }

    @Test func aPlainClickJustNavigates() throws {
        let (tab, delegate) = subject()
        tab.onOpenInNewTab = { _, _ in Issue.record("a plain click must not open a tab") }

        let policy = try decide(delegate, tab, action(
            "https://example.com/target", type: .linkActivated
        ))

        #expect(policy == .allow)
    }

    // MARK: - Hovered links

    private final class StubHit: NSObject {
        @objc var absoluteLinkURL: URL?

        init(_ url: URL?) {
            absoluteLinkURL = url
        }
    }

    @Test func hoveringALinkNamesItsDestination() throws {
        let (tab, delegate) = subject()
        let webKit = try #require(tab.page.webKit)

        delegate.webView(
            webKit,
            mouseDidMoveOverElement: StubHit(URL(string: "https://example.com/target")),
            withFlags: [],
            userInfo: nil
        )

        #expect(tab.hoveredLink?.absoluteString == "https://example.com/target")
    }

    @Test func movingOffTheLinkClearsTheDestination() throws {
        let (tab, delegate) = subject()
        let webKit = try #require(tab.page.webKit)
        delegate.webView(
            webKit,
            mouseDidMoveOverElement: StubHit(URL(string: "https://example.com/target")),
            withFlags: [],
            userInfo: nil
        )

        delegate.webView(webKit, mouseDidMoveOverElement: StubHit(nil), withFlags: [], userInfo: nil)

        #expect(tab.hoveredLink == nil)
    }

    /// The hit test result is a private WebKit class read by key; anything
    /// that does not answer for the key means no link, never a crash.
    @Test func aResultWithoutTheLinkKeyReadsAsNoLink() throws {
        let (tab, delegate) = subject()
        let webKit = try #require(tab.page.webKit)

        delegate.webView(webKit, mouseDidMoveOverElement: NSObject(), withFlags: [], userInfo: nil)

        #expect(tab.hoveredLink == nil)
    }

    @Test func aNavigationDropsTheHoveredLink() throws {
        let (tab, delegate) = subject()
        let webKit = try #require(tab.page.webKit)
        delegate.webView(
            webKit,
            mouseDidMoveOverElement: StubHit(URL(string: "https://example.com/target")),
            withFlags: [],
            userInfo: nil
        )

        delegate.webView(webKit, didCommit: nil)

        #expect(tab.hoveredLink == nil)
    }

    // MARK: - How the visit is recorded

    @Test func aClickedLinkIsRecordedAsALink() throws {
        let (tab, delegate) = subject()
        _ = try decide(delegate, tab, action("https://example.com/a", type: .linkActivated))
        #expect(tab.pendingTransition == .link)
    }

    @Test func goingBackIsRecordedAsGoingBack() throws {
        let (tab, delegate) = subject()
        _ = try decide(delegate, tab, action("https://example.com/a", type: .backForward))
        #expect(tab.pendingTransition == .backForward)
    }

    @Test func aReloadIsRecordedAsAReload() throws {
        let (tab, delegate) = subject()
        _ = try decide(delegate, tab, action("https://example.com/a", type: .reload))
        #expect(tab.pendingTransition == .reload)
    }

    @Test func anUnattributableNavigationKeepsTheReasonAlreadyRecorded() throws {
        let (tab, delegate) = subject()
        _ = try decide(delegate, tab, action("https://example.com/a", type: .linkActivated))

        _ = try decide(delegate, tab, action("https://example.com/b", type: .other))

        #expect(tab.pendingTransition == .link)
    }

    // MARK: - Extension pages

    private static let base = URL(string: "webkit-extension://abcdef/popup.html")!

    @Test func anExtensionPageMayMoveAroundItsOwnOrigin() throws {
        let (tab, delegate) = subject(extensionBase: Self.base)
        tab.onNavigationOutsideExtension = { _ in Issue.record("its own origin is not outside") }

        #expect(try decide(delegate, tab, action("webkit-extension://abcdef/options.html")) == .allow)
    }

    @Test func anExtensionPageLeavingItsOriginIsHandedBackToTheBrowser() throws {
        let (tab, delegate) = subject(extensionBase: Self.base)
        var handedBack: URL?
        tab.onNavigationOutsideExtension = { handedBack = $0 }

        let policy = try decide(delegate, tab, action("https://example.com/page"))

        #expect(policy == .cancel)
        #expect(handedBack?.absoluteString == "https://example.com/page")
    }

    @Test func anotherExtensionsOriginIsAlsoOutside() throws {
        let (tab, delegate) = subject(extensionBase: Self.base)
        var handedBack: URL?
        tab.onNavigationOutsideExtension = { handedBack = $0 }

        let policy = try decide(delegate, tab, action("webkit-extension://ffffff/popup.html"))

        #expect(policy == .cancel)
        #expect(handedBack != nil)
    }

    @Test func anExtensionPageKeepsItsBlankFrames() throws {
        let (tab, delegate) = subject(extensionBase: Self.base)
        tab.onNavigationOutsideExtension = { _ in Issue.record("about: is not a destination") }

        #expect(try decide(delegate, tab, action("about:blank")) == .allow)
    }

    @Test func anOrdinaryTabHasNoExtensionBoundaryToCross() throws {
        let (tab, delegate) = subject()
        tab.onNavigationOutsideExtension = { _ in Issue.record("a web tab has no extension origin") }

        #expect(try decide(delegate, tab, action("https://example.com/page")) == .allow)
    }
}
