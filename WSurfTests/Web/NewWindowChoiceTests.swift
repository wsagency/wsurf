// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What the pop-up gate lets through after the person chooses a New Tab item of WebKit's context menu. WebKit does not call that
/// window the person's own, so a choice is remembered for the one window that has the address that was chosen. A page's own
/// pop-up in that moment is not that window, and must not use the choice up either.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct NewWindowChoiceTests {
    private final class StubAction: WKNavigationAction {
        var stubbedRequest = URLRequest(url: URL(string: "https://example.com/")!)
        /// What `_isUserInitiated` answers: neither a script's pop-up nor WebKit's window for a menu item is a click.
        nonisolated(unsafe) var stubbedUserInitiated = false

        override var request: URLRequest {
            stubbedRequest
        }

        override var navigationType: WKNavigationType {
            .other
        }

        override var modifierFlags: NSEvent.ModifierFlags {
            []
        }

        override nonisolated func value(forKey key: String) -> Any? {
            key == "_isUserInitiated" ? stubbedUserInitiated : super.value(forKey: key)
        }
    }

    /// Stands for WebKit's menu target: what an item did before WSurf wrapped it.
    private final class Probe: NSObject {
        var chosen = 0

        @objc func choose(_ sender: NSMenuItem) {
            chosen += 1
        }
    }

    private static let page = URL(string: "https://page.example/")!
    private static let link = "https://link.example/target"
    private static let linkIdentifier = "WKMenuItemIdentifierOpenLinkInNewWindow"

    /// A tab of a site that blocks pop-ups, whose windows are counted.
    @MainActor
    private final class Rig {
        let tab: BrowserTab
        let delegate: TabNavigationDelegate
        let view: TabWebView
        var opened: [WKWebView] = []

        init() throws {
            let permissions = SitePermissions(
                storageURL: AppDatabase.supportDirectory.appendingPathComponent("NewWindowChoice-\(UUID().uuidString).json"))
            permissions.setPopups(.blockAndNotify, for: SitePermissions.origin(for: NewWindowChoiceTests.page))
            tab = BrowserTab(sitePermissions: permissions)
            tab.popups.pageChanged(url: NewWindowChoiceTests.page)
            delegate = TabNavigationDelegate(tab: tab)
            view = try #require(tab.page.webKit as? TabWebView)
            tab.onNewWindow = { [unowned self] window, _ in opened.append(window) }
        }

        /// Opens a menu with the items WebKit offers on a link and returns it.
        func openMenu(hovering link: String? = NewWindowChoiceTests.link, items: [String] = [NewWindowChoiceTests.linkIdentifier]) throws -> (NSMenu, Probe) {
            view.hoveredLinkURL = link.flatMap(URL.init(string:))
            let probe = Probe()
            let menu = NSMenu()
            for identifier in items {
                let item = NSMenuItem(title: identifier, action: #selector(Probe.choose(_:)), keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
                item.target = probe
                menu.addItem(item)
            }
            view.willOpenMenu(menu, with: try event())
            return (menu, probe)
        }

        func event() throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        func choose(_ identifier: String, in menu: NSMenu) throws {
            menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.identifier?.rawValue == identifier }))
        }

        /// WebKit asks the tab for a window to open `address`, which nobody's click started.
        func askForWindow(_ address: String) -> WKWebView? {
            let action = StubAction()
            action.stubbedRequest = URLRequest(url: URL(string: address)!)
            return delegate.webView(
                view, createWebViewWith: WebViewPool.makeConfiguration(), for: action, windowFeatures: WKWindowFeatures()
            )
        }
    }

    @Test func aPagesPopupAroundTheChoiceIsRefusedAndTheChosenWindowOpens() throws {
        let rig = try Rig()
        let (menu, _) = try rig.openMenu()
        #expect(rig.askForWindow("https://evil.example/before") == nil, "before the choice")

        try rig.choose(Self.linkIdentifier, in: menu)

        #expect(rig.askForWindow("https://evil.example/during") == nil, "a page's window in the moment of the choice")
        #expect(rig.opened.isEmpty)
        #expect(rig.tab.popups.blocked?.absoluteString == "https://evil.example/during")
        #expect(rig.askForWindow(Self.link) != nil, "the window the person chose is still theirs after that")
        #expect(rig.opened.count == 1)
        #expect(rig.askForWindow("https://evil.example/after") == nil, "and the choice is used up")
        #expect(rig.askForWindow(Self.link) == nil, "even for the same address a second time")
        #expect(rig.opened.count == 1)
    }

    @Test(arguments: ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierOpenMediaInNewWindow"])
    func aChoiceOfAnImageOrVideoIsForItsOwnAddressAlone(identifier: String) throws {
        let rig = try Rig()
        let picture = "https://img.example/picture.png"
        let (menu, probe) = try rig.openMenu(hovering: Self.link, items: [identifier])
        rig.view.contextImageURL = URL(string: picture)

        try rig.choose(identifier, in: menu)

        #expect(probe.chosen == 1, "the item still does what WebKit made it do")
        #expect(rig.askForWindow(Self.link) == nil, "the link under the pointer is not what the item opens")
        #expect(rig.askForWindow(picture) != nil, "its own address is")
        #expect(rig.askForWindow(picture) == nil, "once")
    }

    @Test func aChoiceWithoutAnAddressLeavesTheGateOn() throws {
        let rig = try Rig()
        let (menu, probe) = try rig.openMenu(hovering: nil)

        try rig.choose(Self.linkIdentifier, in: menu)

        #expect(probe.chosen == 1)
        #expect(rig.askForWindow(Self.link) == nil, "WSurf cannot tell what WebKit will open, so it is a pop-up like any other")
    }

    @Test func openFrameIsNotWrappedForItNamesNoAddress() throws {
        let rig = try Rig()
        let identifier = "WKMenuItemIdentifierOpenFrameInNewWindow"
        let (menu, probe) = try rig.openMenu(items: [identifier])

        try rig.choose(identifier, in: menu)

        #expect(probe.chosen == 1, "it is WebKit's own item, as it was")
        #expect(rig.askForWindow(Self.link) == nil)
    }

    @Test func anUnusedChoiceIsGoneWhenAnotherMenuOpens() throws {
        let rig = try Rig()
        var (menu, _) = try rig.openMenu()
        try rig.choose(Self.linkIdentifier, in: menu)

        (menu, _) = try rig.openMenu()

        #expect(rig.askForWindow(Self.link) == nil, "a menu that opens drops the choice before it")
        #expect(rig.opened.isEmpty)
    }

    @Test func anUnusedChoiceIsGoneWhenAMenuCloses() async throws {
        let rig = try Rig()
        let (menu, _) = try rig.openMenu()
        try rig.choose(Self.linkIdentifier, in: menu)
        try await Task.sleep(for: .milliseconds(120))

        rig.view.didCloseMenu(menu, with: try rig.event())

        #expect(rig.askForWindow(Self.link) == nil, "a menu that closes drops a choice nobody used")
        #expect(rig.opened.isEmpty)
    }

    /// The order of the menu's action and its close is AppKit's. Either way the window of a choice made a moment ago is still on
    /// its way when the menu closes, and opens.
    @Test func aChoiceMadeAMomentAgoSurvivesTheClosingOfItsMenu() throws {
        let rig = try Rig()
        let (menu, _) = try rig.openMenu()
        try rig.choose(Self.linkIdentifier, in: menu)

        rig.view.didCloseMenu(menu, with: try rig.event())

        #expect(rig.askForWindow(Self.link) != nil)
        #expect(rig.opened.count == 1)
    }

    @Test func aChoiceLapsesWhenItsWindowIsNotAskedForInTime() throws {
        let rig = try Rig()
        rig.view.newWindowChoiceLifetime = .zero
        let (menu, _) = try rig.openMenu()

        try rig.choose(Self.linkIdentifier, in: menu)

        #expect(rig.askForWindow(Self.link) == nil, "a window that comes later is not the choice")
        rig.view.newWindowChoiceLifetime = .seconds(60)
        #expect(rig.askForWindow(Self.link) == nil, "and the choice is gone, not only late")
    }

    @Test func aWindowTheMenuDidNotChooseIsRefusedWhereBlockingIsOnAndAllowedWhereItIsNot() throws {
        let rig = try Rig()
        #expect(rig.askForWindow(Self.link) == nil)

        rig.tab.sitePermissions.setPopups(.allow, for: SitePermissions.origin(for: Self.page))

        #expect(rig.askForWindow(Self.link) != nil, "the site may open pop-ups")
    }
}
