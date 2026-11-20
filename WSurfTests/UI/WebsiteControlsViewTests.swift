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

    @Test(arguments: [true, false])
    func theEngineBadgeAndAddressHaveSeparateClickTargets(clickBadge: Bool) async throws {
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
        // With no padlock, the engine is the first item on the address line. The address text follows it.
        let focusRequests = model.selectAllToken
        if clickBadge {
            try click(x: address.minX + 10, in: host, window: window)
            #expect(await waitUntil(timeout: .seconds(4)) { tab.loadedEngine == .chromium })
            #expect(browser.sitePermissions.engine(for: browser.siteOrigin(for: tab)) == .webKit)
            #expect(model.selectAllToken == focusRequests)
        } else {
            try click(x: address.midX, in: host, window: window)
            #expect(await waitUntil(timeout: .seconds(2)) { model.selectAllToken > focusRequests })
            #expect(tab.loadedEngine == .webKit)
        }
    }
    @Test func clickingTheToolbarPinPinsAndUnpinsThePage() throws {
        let browser = BrowserModel(database: .temporary())
        let coordinator = AppCoordinator(browser: browser)
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        tab.urlString = "https://article.example/read"
        let host = NSHostingView(rootView: PinBadge(coordinator: coordinator).frame(width: 42, height: 32))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try click(x: host.bounds.midX, in: host, window: window)
        #expect(tab.isShowingPin)
        try click(x: host.bounds.midX, in: host, window: window)
        #expect(tab.pinnedURL == nil)
    }

    private func click(x: CGFloat, in host: NSView, window: NSWindow) throws {
        let point = host.convert(CGPoint(x: x, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
    }

    @Test func aSignInReturnNamesItsSessionAndWebsiteDefaultInSiteControls() throws {
        let store = SitePermissions(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), persists: false)
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        defer { browser.closeAllTabs(saving: false) }
        let tab = browser.newTab()
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/u/0/r/week?pli=1"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        tab.urlString = calendar.absoluteString
        let section = SiteHandlingSection(browser: browser, tab: tab)
        #expect(section.engineExplanation == nil)
        store.setEngine(.chromium, for: SitePermissions.origin(for: calendar))
        var submitted = URLRequest(url: calendar)
        submitted.httpMethod = "POST"
        submitted.httpBody = Data("selection=week".utf8)
        try #require(tab.permitsEngineNavigation(submitted, isMainFrame: true))
        let postExplanation = String(localized: try #require(section.engineExplanation))
        try #require(tab.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
        try #require(tab.permitsEngineNavigation(URLRequest(url: calendar), isMainFrame: true))
        try #require(tab.loadedEngine == .webKit)
        let signInExplanation = String(localized: try #require(section.engineExplanation))
        #expect(signInExplanation != postExplanation)
        #expect(signInExplanation.contains(String(localized: BrowserEngine.chromium.label)))
    }

    @Test(.boundedWebViews) func aSignInPostStillInChromiumNamesItsActualEngine() throws {
        let store = SitePermissions(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), persists: false)
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        defer { browser.closeAllTabs(saving: false) }
        let calendar = try #require(URL(string: "https://calendar.google.com"))
        let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
        store.setEngine(.chromium, for: SitePermissions.origin(for: calendar))
        let tab = browser.makeTab(for: calendar)
        browser.tabs.append(tab)
        tab.urlString = calendar.absoluteString
        try #require(tab.page.engine == .chromium)
        var submitted = URLRequest(url: signIn)
        submitted.httpMethod = "POST"
        submitted.httpBody = Data("prompt=select_account".utf8)
        try #require(tab.permitsEngineNavigation(submitted, isMainFrame: true))
        tab.urlString = signIn.absoluteString
        let section = SiteHandlingSection(browser: browser, tab: tab)
        let explanation = try #require(section.engineExplanation)
        #expect(String(localized: explanation).contains(String(localized: BrowserEngine.chromium.label)))
        tab.urlString = "https://callback.example/signed-in"
        let returned = String(localized: try #require(section.engineExplanation))
        #expect(returned.contains(String(localized: BrowserEngine.chromium.label)))
        #expect(returned.contains(String(localized: BrowserEngine.webKit.label)))
    }

}
