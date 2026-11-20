// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct WebsiteControlsViewTests {
    @Test func aFreshSiteShowsAllPermissionRowsBeforeAnyHasBeenGranted() throws {
        let store = SitePermissions(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), persists: false)
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        tab.urlString = "https://article.example/read"
        func panelHeight() -> CGFloat {
            NSHostingView(rootView: SiteControlsPanel(browser: browser, tab: tab)).fittingSize.height
        }
        let withoutOrigin = panelHeight()
        tab.permissions.pageChanged(url: URL(string: tab.urlString))
        let fresh = panelHeight()
        #expect(fresh >= withoutOrigin + CGFloat(WebPermission.allCases.count) * 24, "all four rows fit in the main panel")
        for permission in WebPermission.allCases {
            tab.permissions.set(.deny, for: permission)
        }
        #expect(abs(panelHeight() - fresh) < 1, "changing a policy keeps the same rows in place")
    }

    @Test func clickingTheBadgeSwitchesOnlyTheCurrentTabAndLeavesTheAddressEditable() async throws {
        let browser = BrowserModel(database: .temporary())
        let coordinator = AppCoordinator(browser: browser)
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        _ = tab.page
        tab.urlString = "http://127.0.0.1:1/article"
        let model = AskSurfaceModel(placement: .toolbar, browser: browser, coordinator: coordinator)
        var address = CGRect.zero
        let row = AskSurfaceRow(model: model, sections: [], restingContent: model.restingContent,
                                placeholder: "", accessibilityValue: "", security: .none) { part, frame in
            if part == .address {
                address = frame
            }
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 36), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: row.frame(width: 660))
        window.contentView = host
        window.orderBack(nil)
        try #require(await waitUntil {
            host.layoutSubtreeIfNeeded()
            return address.width > 30
        })
        func click(at x: CGFloat) throws {
            let point = host.convert(CGPoint(x: x, y: host.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        // With no padlock, the engine is the first item on the address line. The address text follows it.
        let focusRequests = model.selectAllToken
        try click(at: address.minX + 10)
        #expect(await waitUntil(timeout: .seconds(4)) { tab.loadedEngine == .chromium })
        #expect(browser.sitePermissions.engine(for: browser.siteOrigin(for: tab)) == .webKit)
        #expect(model.selectAllToken == focusRequests)
        try click(at: address.midX)
        #expect(await waitUntil(timeout: .seconds(2)) { model.selectAllToken > focusRequests }, "text click at \(address) in \(host.bounds)")
    }
}
