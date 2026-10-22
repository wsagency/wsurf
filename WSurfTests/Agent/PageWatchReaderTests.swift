// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

private func watch(_ url: URL, access: PageWatch.Access = .anonymous) -> PageWatch {
    PageWatch(id: UUID(), url: url, title: "", condition: "", interval: 3600, access: access, created: .now, nextCheck: .now)
}

/// The hidden reader: whose sign-ins it uses, what it refuses, and that it keeps one view open at a time.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageWatchReaderTests {
    private let article = "<!doctype html><title>Kettle</title><main><p>Kettle $54.99</p><p>In stock</p></main>"

    /// A center that reads with the real reader and judges every page as "not yet".
    private func center(_ context: BrowserProfileContext) -> PageWatchCenter {
        let verdict = PageWatchVerdict(met: false, state: "", message: "")
        return PageWatchCenter(
            file: nil,
            schedules: false,
            queue: PageWatchReader.queue,
            fetch: { [context] watch in await PageWatchReader.read(watch, in: context) },
            judge: { _, _ in verdict },
            classify: { _, _ in verdict },
            notify: { _, _ in }
        )
    }

    @Test(arguments: [PageWatch.Access.anonymous, .signedIn])
    func onlyAWatchWithYourSignInsSendsTheProfilesCookies(access: PageWatch.Access) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/kettle": .html(article)])
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let url = try server.url("/kettle")
        let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "profile", .path: "/", .originURL: url]))
        await context.dataStore.httpCookieStore.setCookie(cookie)

        let reading = try #require(await PageWatchReader.read(watch(url, access: access), in: context))

        #expect(reading.text.contains("Kettle $54.99"))
        #expect(reading.url == url)
        let head = try #require(server.lastRequestHead(for: "/kettle")).lowercased()
        #expect(head.contains("session=profile") == (access == .signedIn))
        #expect(PageWatchReader.openViews == 0, "the view is closed after the reading")
    }

    @Test func aSiteDeniedToTheAssistantIsNeverFetched() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/kettle": .html(article)])
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let url = try server.url("/kettle")
        context.sitePermissions.setAssistantAccess(.deny, for: SitePermissions.origin(for: url))

        let result = await PageWatchCenter.live(for: context).start(url: url, title: "", condition: "", everyMinutes: 60)

        #expect(result == .denied)
        #expect(server.lastRequestHead(for: "/kettle") == nil)
    }

    @Test func aPageThatMovesElsewhereIsNotWatched() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/login": .html(article)]) { request in
            request.path == "/kettle" ? .redirect(to: URL(string: "/login")!) : nil
        }
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let url = try server.url("/kettle")

        let reading = try #require(await PageWatchReader.read(watch(url), in: context))
        let result = await center(context).start(url: url, title: "", condition: "", everyMinutes: 60)

        #expect(reading.url?.path() == "/login")
        #expect(result == .unreadable)
    }

    @Test func aChallengePageIsNotAReading() async throws {
        let challenge = """
            <!doctype html><title>Just a moment</title>
            <body><form id="challenge-form"></form><p>Checking your browser before you continue.</p></body>
            """
        let server = try await HTTPFixtureServer.start(routes: ["/kettle": .html(challenge)])
        let url = try server.url("/kettle")

        let reading = await PageWatchReader.read(watch(url), in: BrowserProfileContext(profile: .privateBrowsing()))

        #expect(reading == nil)
    }

    @Test func aSiteSetToChromiumIsReadWithWebKitAndSaysSo() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/kettle": .html(article)])
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let url = try server.url("/kettle")
        #expect(!PageWatchReader.readsWithWebKitInstead(url, permissions: context.sitePermissions))

        context.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        let reading = try #require(await PageWatchReader.read(watch(url), in: context))

        #expect(PageWatchReader.readsWithWebKitInstead(url, permissions: context.sitePermissions))
        #expect(reading.text.contains("In stock"))
        #expect(String(localized: PageWatchReader.webKitNote).contains("WebKit"))
    }

    @Test func watchesReadOnePageAtATimeAndCloseEveryView() async throws {
        let gate = ResponseGate()
        let server = try await HTTPFixtureServer.start(routes: ["/one": .html(article, gate: gate), "/two": .html(article)])
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let first = center(context)
        let second = center(context)
        let one = try server.url("/one")
        let two = try server.url("/two")

        let reading = Task { await first.start(url: one, title: "", condition: "", everyMinutes: 60) }
        #expect(await gate.waitForRequest())
        let waiting = Task { await second.start(url: two, title: "", condition: "", everyMinutes: 60) }
        #expect(await waitUntil { PageWatchReader.queue.pending == 1 })
        #expect(PageWatchReader.openViews == 1)
        #expect(server.lastRequestHead(for: "/two") == nil)
        gate.open()
        let results = [await reading.value, await waiting.value]

        #expect(results.allSatisfy { if case .watching = $0 { true } else { false } })
        #expect(PageWatchReader.openViews == 0)
    }

    @Test func aPageThatOpensAWindowOpensNothing() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/kettle": .html(article + "<script>window.open('/other')</script>"),
            "/other": .html("<p>Other</p>"),
        ])
        let url = try server.url("/kettle")

        let reading = try #require(await PageWatchReader.read(watch(url), in: BrowserProfileContext(profile: .privateBrowsing())))

        #expect(reading.text.contains("Kettle"))
        #expect(server.lastRequestHead(for: "/other") == nil)
    }

    @Test func aDownloadIsNeitherReadNorSaved() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/file": .download(Data("kettle".utf8), filename: "kettle.bin")])
        let url = try server.url("/file")

        let reading = await PageWatchReader.read(watch(url), in: BrowserProfileContext(profile: .privateBrowsing()))

        #expect(reading == nil)
        #expect(server.lastRequestHead(for: "/file") != nil)
    }

    @Test func theHiddenViewFollowsOnlyWebAddresses() {
        #expect(PageWatchRefusals.allows(URL(string: "https://shop.example/kettle"), inMainFrame: true))
        #expect(!PageWatchRefusals.allows(URL(string: "about:blank"), inMainFrame: true))
        #expect(PageWatchRefusals.allows(URL(string: "about:blank"), inMainFrame: false))
        #expect(!PageWatchRefusals.allows(URL(string: "zoommtg://join?confno=1"), inMainFrame: false))
        #expect(!PageWatchRefusals.allows(URL(string: "file:///etc/hosts"), inMainFrame: true))
    }

    @Test func aPrivateWindowHasNoWatches() {
        #expect(BrowserProfileContext(profile: .privateBrowsing()).pageWatches == nil)
    }
}

@MainActor
private final class Upkeep {
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var reads = 0
    var mayRead = true
    var notices: [PageWatchCenter.Notice] = []

    lazy var center = PageWatchCenter(
        file: nil,
        schedules: false,
        now: { [unowned self] in date },
        fetch: { [unowned self] _ in
            reads += 1
            return PageWatchReading(title: "Kettle", text: "Kettle $54.99, reading \(reads)", url: nil)
        },
        judge: { _, _ in PageWatchVerdict(met: false, state: "$54.99", message: "") },
        classify: { _, _ in PageWatchVerdict(met: false, state: "", message: "") },
        notify: { [unowned self] _, notice in notices.append(notice) },
        canRead: { [unowned self] in mayRead }
    )

    func watch(condition: String = "") async -> PageWatch? {
        let result = await center.start(
            url: URL(string: "https://shop.example/kettle")!, title: "", condition: condition, everyMinutes: 60
        )
        guard case .watching(let watch) = result else { return nil }
        return watch
    }
}

/// What the schedule does while it may not read (Low Power Mode, memory pressure), and what Clear History leaves.
@MainActor
struct PageWatchUpkeepTests {
    @Test func aPassThatMayNotReadPostponesInsteadOfFailing() async throws {
        let upkeep = Upkeep()
        let watch = try #require(await upkeep.watch())
        upkeep.mayRead = false
        upkeep.date += 3600

        await upkeep.center.checkDue()

        let kept = try #require(upkeep.center.watches.first)
        #expect(upkeep.reads == 1, "only the first reading")
        #expect(kept.failures == 0)
        #expect(kept.nextCheck == watch.nextCheck + 3600)
        #expect(upkeep.notices.isEmpty)
    }

    @Test func aWatchThatExpiresWhileReadingsWaitStillEnds() async throws {
        let upkeep = Upkeep()
        _ = try #require(await upkeep.watch())
        upkeep.mayRead = false
        upkeep.date += PageWatch.lifetime + 1

        await upkeep.center.checkDue()

        #expect(upkeep.center.watches.isEmpty)
        #expect(upkeep.notices == [.expired])
        #expect(upkeep.reads == 1)
    }

    @Test func clearingHistoryForgetsPageTextButKeepsTheFingerprint() async throws {
        let upkeep = Upkeep()
        let watch = try #require(await upkeep.watch(condition: "price below $50"))
        #expect(watch.snapshot != nil && watch.state != nil)

        upkeep.center.forgetPageText()

        let kept = try #require(upkeep.center.watches.first)
        #expect(kept.snapshot == nil)
        #expect(kept.state == nil)
        #expect(kept.fingerprint == watch.fingerprint)
    }
}
