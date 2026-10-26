// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The parts of the Open Link items of a context menu that need no page. `OpenInNewTabTests` drives the real menus of both engines.
@MainActor
struct OpenInNewTabMenuTests {
    /// Stands for WebKit's menu target: what the item did before WSurf wrapped it.
    private final class Probe: NSObject {
        var chosen: [String] = []

        @objc func choose(_ sender: NSMenuItem) {
            chosen.append(sender.identifier?.rawValue ?? "?")
        }
    }

    private func openedMenu(_ identifiers: [String], target: Probe, in view: TabWebView) throws -> NSMenu {
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = NSMenu()
        for identifier in identifiers {
            let item = NSMenuItem(title: identifier, action: #selector(Probe.choose(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.target = target
            menu.addItem(item)
        }
        view.willOpenMenu(menu, with: event)
        return menu
    }

    private func item(_ identifier: String, in menu: NSMenu) throws -> Int {
        try #require(menu.items.firstIndex { $0.identifier?.rawValue == identifier })
    }

    @Test(.boundedWebViews, arguments: [
        "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenMediaInNewWindow",
    ])
    func choosingANewTabItemIsThePersonsOwnWindowAndStillDoesWhatTheItemDid(identifier: String) throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        let probe = Probe()
        let menu = try openedMenu([identifier], target: probe, in: view)
        #expect(!view.takeNewWindowChoice(), "nothing was chosen yet")

        menu.performActionForItem(at: try item(identifier, in: menu))

        #expect(probe.chosen == [identifier], "the item still does what WebKit made it do")
        #expect(view.takeNewWindowChoice(), "the window WebKit asks for next is the person's")
        #expect(!view.takeNewWindowChoice(), "and only that one")
    }

    @Test(.boundedWebViews) func otherItemsAreNotAChoiceOfANewWindow() throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        let probe = Probe()
        let menu = try openedMenu(["WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierOpenLink"], target: probe, in: view)

        menu.performActionForItem(at: try item("WKMenuItemIdentifierCopyLink", in: menu))
        menu.performActionForItem(at: try item("WKMenuItemIdentifierOpenLink", in: menu))

        #expect(probe.chosen == ["WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierOpenLink"])
        #expect(!view.takeNewWindowChoice(), "a script's pop-up is still refused after them")
    }

    @Test(.boundedWebViews) func aMenuThatOpensAgainWrapsItsItemsOnce() throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        let probe = Probe()
        let identifier = "WKMenuItemIdentifierOpenLinkInNewWindow"
        _ = try openedMenu([identifier], target: probe, in: view)
        let menu = try openedMenu([identifier], target: probe, in: view)

        menu.performActionForItem(at: try item(identifier, in: menu))

        #expect(probe.chosen == [identifier], "once, not once per time the menu opened")
        #expect(view.takeNewWindowChoice())
    }

    // MARK: - A link in a frame

    /// The page's own hit test finds no link in a frame of another site, so WSurf's own items take the link WebKit reported under
    /// the pointer (`hoveredLinkURL`). No page runs here, which leaves the page's hit test with nothing, as it has for a frame.
    private func frameLinkMenu(hovering link: URL?, in view: TabWebView) throws -> NSMenu {
        view.hoveredLinkURL = link
        return try openedMenu(["WKMenuItemIdentifierOpenLinkInNewWindow"], target: Probe(), in: view)
    }

    @Test(.boundedWebViews) func aLinkInAFrameOpensInANewWindowAndAPrivateOne() throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        var asked: [(String, Bool)] = []
        view.onOpenLinkInNewWindow = { asked.append(($0.absoluteString, $1)) }
        let menu = try frameLinkMenu(hovering: URL(string: "https://frame.example/page"), in: view)

        menu.performActionForItem(at: try item("WSurfOpenLinkInNewWindow", in: menu))
        menu.performActionForItem(at: try item("WSurfOpenLinkInNewPrivateWindow", in: menu))

        #expect(asked.map(\.0) == ["https://frame.example/page", "https://frame.example/page"])
        #expect(asked.map(\.1) == [false, true])
    }

    @Test(.boundedWebViews) func aLinkInAFrameOpensInPeekAndIsSummarized() throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        var peeked: [String] = []
        var summarized: [String] = []
        view.onPeekLink = { peeked.append($0.absoluteString) }
        view.onSummarizeLink = { url, _ in summarized.append(url.absoluteString) }
        let menu = try frameLinkMenu(hovering: URL(string: "https://frame.example/page"), in: view)

        for entry in menu.items {
            let action = entry.action.map(NSStringFromSelector) ?? ""
            if action == "peekAtContextLink" || action == "summarizeContextLink" {
                menu.performActionForItem(at: menu.index(of: entry))
            }
        }

        #expect(peeked == ["https://frame.example/page"] && summarized == ["https://frame.example/page"])
    }

    @Test(.boundedWebViews) func aLinkMenuWithNoLinkUnderThePointerOpensNothing() throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        var asked = 0
        view.onOpenLinkInNewWindow = { _, _ in asked += 1 }
        let menu = try frameLinkMenu(hovering: nil, in: view)

        menu.performActionForItem(at: try item("WSurfOpenLinkInNewWindow", in: menu))

        #expect(asked == 0)
    }

    // MARK: - Chromium

    @Test func aChromiumLinkMenuOffersATabAWindowAndAPrivateWindow() {
        let commands = ChromiumClient.linkCommands(isPrivate: false)

        #expect(commands.map(\.opening) == [.tab, .window, .privateWindow])
        #expect(Set(commands.map(\.id)).count == 3, "each has an id of its own")
        #expect(!commands.map(\.id).contains(ChromiumClient.pickCredentialCommand))
        #expect(commands.allSatisfy { (26_500...28_500).contains($0.id) }, "ids the engine leaves to the application")
    }

    @Test func aPrivateChromiumTabOffersNoPlainWindow() {
        let commands = ChromiumClient.linkCommands(isPrivate: true)

        #expect(commands.map(\.opening) == [.tab, .privateWindow])
        #expect(commands.map(\.id) == ChromiumClient.linkCommands(isPrivate: false).filter { $0.opening != .window }.map(\.id),
                "the same ids as in a plain tab")
    }
}
