// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import WebKit
import XCTest

@testable import WSurf

/// What the app's page scripts cost a load: the same 30 KB login page with ten `srcdoc` iframes (eleven frames, the shape of an
/// ad-heavy page) loaded in a `BrowserTab` of an ordinary profile, which installs every page script, autofill and WebAuthn among them.
/// A bare `WKWebView` loads the same page once first for the comparison, printed as `WSURF-PAGE-SCRIPTS`; the budget is the tab's.
nonisolated final class PageScriptPerformanceTests: XCTestCase, @unchecked Sendable {
    static let frames = 10
    static let loadsPerPass = 5

    static func page(_ index: Int) -> String {
        let rows = (0..<200).map { "<p>Paragraph \($0) of page \(index) with <a href='#\($0)'>a link</a> and some text.</p>" }.joined()
        let frame = "<iframe srcdoc=\"<p>ad frame</p><form><input type=text name=q></form>\" width=300 height=100></iframe>"
        return """
        <!doctype html><html><head><title>Page \(index)</title></head><body>
        <form><input type=email name=email autocomplete=username><input type=password name=password></form>
        \(String(repeating: frame, count: frames))\(rows)</body></html>
        """
    }

    @MainActor
    static func spin(timeout: TimeInterval = 20, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        return condition()
    }

    @MainActor
    static func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    /// An ordinary profile's tab on a non-persistent store: nothing is written to a real profile.
    @MainActor
    static func makeTab() -> BrowserTab {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        let context = BrowserProfileContext(profile: Profile(id: UUID(), name: "Page scripts", symbol: "globe", color: .gray))
        return BrowserTab(adopting: webView, opensBlank: false, privately: false, context: context)
    }

    @MainActor
    static func load(_ tab: BrowserTab, _ index: Int) {
        tab.loadHTML(page(index), baseURL: URL(string: "https://load-\(index).example/"))
        _ = spin { tab.isLoading || !tab.hasNoPageYet }
        XCTAssertTrue(spin { !tab.isLoading }, "page \(index) loaded")
    }

    @MainActor
    static func bareMilliseconds() -> Double {
        // The pool's process pool and a non-persistent store, without a single script or handler.
        let configuration = WebViewPool.makeConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.websiteDataStore = .nonPersistent()
        let bare = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        let window = window(showing: bare)
        defer { window.contentView = nil; window.close() }
        var total = 0.0
        for index in 0..<(loadsPerPass * 3) {
            let started = ContinuousClock.now
            bare.loadHTMLString(page(index), baseURL: URL(string: "https://bare-\(index).example/"))
            _ = spin { bare.isLoading }
            _ = spin { !bare.isLoading }
            if index >= loadsPerPass {
                let elapsed = (ContinuousClock.now - started).components
                total += Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            }
        }
        return total / Double(loadsPerPass * 2)
    }

    func testLoadingAPageWithTenFrames() {
        MainActor.assumeIsolated {
            print(String(format: "WSURF-PAGE-SCRIPTS bare meanMsPerLoad=%.2f", Self.bareMilliseconds()))
            let tab = Self.makeTab()
            let window = Self.window(showing: tab.page.nativeView)
            var index = 0
            Self.load(tab, index)
            measure(metrics: [XCTClockMetric()], options: .budgeted) {
                for _ in 0..<Self.loadsPerPass {
                    index += 1
                    Self.load(tab, index)
                }
            }
            for script in tab.page.webKit?.configuration.userContentController.userScripts ?? [] {
                let names = script.source.matches(of: /__wsurf[A-Za-z]+/).map { String($0.output) }.filter { $0 != "__wsurfSend" }
                print("WSURF-PAGE-SCRIPTS script bytes=\(script.source.utf8.count) mainFrameOnly=\(script.isForMainFrameOnly) "
                    + "first=\(names.first ?? String(script.source.prefix(40)).replacingOccurrences(of: "\n", with: " "))")
            }
            window.contentView = nil
            window.close()
            tab.detach()
        }
    }
}
