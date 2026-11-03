// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Chromium's native find: the bookkeeping of what CEF reports, and the find bar driving a real Chromium page.
@MainActor
@Suite(.serialized)
struct ChromiumFindTests {
    @Test func aSearchAnswersWithItsFinalResult() {
        let find = ChromiumFind()
        var answers: [ChromiumFind.Result] = []
        #expect(!find.begin("cat"), "the first text starts a search")
        find.wait { answers.append($0) }
        find.receive(identifier: 1, count: 1, active: 1, isFinal: false)
        #expect(answers.isEmpty, "a partial count is not an answer")
        find.receive(identifier: 1, count: 3, active: 1, isFinal: true)
        #expect(answers == [ChromiumFind.Result(total: 3, active: 1)])

        #expect(find.begin("cat"), "the same text continues the search")
        find.wait { answers.append($0) }
        find.receive(identifier: 1, count: -1, active: 2, isFinal: true)
        #expect(answers.last == ChromiumFind.Result(total: 3, active: 2), "a find-next update without a count keeps the count")
    }

    @Test func aReplacedSearchIsIgnored() {
        let find = ChromiumFind()
        _ = find.begin("a")
        find.receive(identifier: 4, count: 9, active: 1, isFinal: true)
        _ = find.begin("ab")
        var answer: ChromiumFind.Result?
        find.wait { answer = $0 }
        find.receive(identifier: 4, count: 9, active: 5, isFinal: true)
        #expect(answer == nil, "the old search's late report is not the new one's")
        find.receive(identifier: 5, count: 2, active: 1, isFinal: true)
        #expect(answer == ChromiumFind.Result(total: 2, active: 1))
    }

    @Test func noMatchesLeavesNoActiveMatch() {
        let find = ChromiumFind()
        _ = find.begin("zzz")
        find.receive(identifier: 1, count: 0, active: 0, isFinal: true)
        #expect(find.latest == ChromiumFind.Result(total: 0, active: 0))
    }

    @Test func endingASearchForgetsItAndItsWaiters() {
        let find = ChromiumFind()
        _ = find.begin("a")
        var called = false
        find.wait { _ in called = true }
        find.end()
        find.receive(identifier: 1, count: 1, active: 1, isFinal: true)
        #expect(!called)
        #expect(!find.begin("a"), "the same text after the end is a new search")
    }

    @Test func theSessionShowsTheActiveMatchTheEngineReports() {
        var active = 2
        let session = FindSession()
        session.driver = FindDriver(
            find: { _, _, completion in completion(true) },
            countMatches: { _, completion in completion(5) },
            clearHighlight: {},
            activeMatch: { active }
        )
        session.open()
        session.query = "a"
        session.queryDidChange()
        #expect(session.currentMatch == 2, "the engine's own position, not the first")
        active = 4
        session.find()
        #expect(session.currentMatch == 4)
    }

    @Test func clearingTheFieldClearsTheHighlights() {
        var cleared = 0
        let session = FindSession()
        session.driver = FindDriver(
            find: { _, _, completion in completion(true) },
            countMatches: { _, completion in completion(1) },
            clearHighlight: { cleared += 1 }
        )
        session.open()
        session.query = "a"
        session.queryDidChange()
        #expect(cleared == 0)
        session.query = ""
        session.queryDidChange()
        #expect(cleared == 1)
    }

    @Test(.boundedWebViews)
    func theFindBarCountsAndStepsThroughAChromiumPage() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Find</title><p>needle one</p><p>Needle two</p><p>hay</p><p>NEEDLE three</p>")
        ])
        let url = try server.url("/")
        let profile = Profile(id: UUID(), name: "Chromium find", symbol: "globe", color: .gray)
        let context = BrowserProfileContext(profile: profile)
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        var committed: URL?
        page.onNavigationCommitted = { [weak page] _ in committed = page?.url }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer { window.close() }

        let session = FindSession()
        session.driver = .browserPage { page }
        do {
            page.load(URLRequest(url: url))
            try #require(await waitUntil { committed == url && !page.isLoading })

            session.open()
            session.query = "needle"
            session.queryDidChange()
            #expect(await waitUntil { session.totalMatches == 3 && session.currentMatch == 1 }, "case is ignored")
            session.find()
            #expect(await waitUntil { session.currentMatch == 2 })
            session.find()
            #expect(await waitUntil { session.currentMatch == 3 })
            session.find()
            #expect(await waitUntil { session.currentMatch == 1 }, "past the last match wraps")
            session.find(backwards: true)
            #expect(await waitUntil { session.currentMatch == 3 }, "before the first match wraps")

            session.query = "absent"
            session.queryDidChange()
            #expect(await waitUntil { session.noMatches && session.totalMatches == 0 })

            session.close()
            #expect(native.find.query.isEmpty, "closing the bar ends the search")
        } catch {
            await page.close()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            throw error
        }
        await page.close()
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
    }
}
