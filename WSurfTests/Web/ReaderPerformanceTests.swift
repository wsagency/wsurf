// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import WebKit
import XCTest

@testable import WSurf

// XCTest owns and runs one instance serially. Sendable lets its synchronous
// measurement callback enter the app target's main-actor boundary.
nonisolated final class ReaderPerformanceTests: XCTestCase, @unchecked Sendable {
    /// What the test keeps between its steps.
    @MainActor
    private final class Fixture {
        var server: HTTPFixtureServer?
        var page: BrowserPage?
        var window: NSWindow?
        var context: BrowserProfileContext?
        var article: ReaderArticle?
    }

    /// Runs `work` to its end from this synchronous test. The test is not an actor job itself, so the wait spins the run loop
    /// that the work's main-actor steps need; waiting inside an async test left them queued behind the test, and it hung.
    @MainActor
    private func finish(_ work: @escaping @MainActor () async -> Void) {
        let done = XCTestExpectation(description: "async step")
        Task {
            await work()
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 120), .completed)
    }

    /// One extraction of a 200 KB article from a live WebKit page: the script goes to the page, Readability runs in its world
    /// and the answer is decoded.
    func testExtractingALongArticle() {
        MainActor.assumeIsolated {
            let fixture = Fixture()
            finish {
                do {
                    let server = try await HTTPFixtureServer.start(
                        routes: ["/news/long": .html(ReaderFixtures.longArticle(bytes: 200_000))]
                    )
                    let url = try server.url("/news/long")
                    let configuration = interactiveWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    let context = BrowserProfileContext(profile: .privateBrowsing())
                    let page = BrowserPage(
                        webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration),
                        context: context
                    )
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = page
                    window.orderBack(nil)
                    fixture.server = server
                    fixture.context = context
                    fixture.page = page
                    fixture.window = window
                    page.load(URLRequest(url: url))
                    let loaded = await waitUntil { page.url == url && !page.isLoading }
                    XCTAssertTrue(loaded)
                    fixture.article = await ReaderExtractor.article(in: page)
                } catch {
                    XCTFail("The fixture page did not load: \(error)")
                }
            }
            guard let page = fixture.page, let first = fixture.article else {
                return XCTFail("The 200 KB article was not extracted once before measuring.")
            }
            XCTAssertGreaterThan(first.blocks.count, 400)
            XCTAssertGreaterThan(first.content.utf8.count, 150_000)

            let options = XCTMeasureOptions()
            options.iterationCount = 5
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                fixture.article = nil
                finish { fixture.article = await ReaderExtractor.article(in: page) }
            }

            XCTAssertEqual(fixture.article, first)
            finish {
                fixture.window?.contentView = nil
                fixture.window?.close()
                await fixture.page?.close()
                await fixture.context?.endPrivateSession()
            }
            withExtendedLifetime(fixture.server) {}
        }
    }
}
