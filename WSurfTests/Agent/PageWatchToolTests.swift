// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AnyLanguageModel
import AppKit
import Foundation
import Testing

@testable import WSurf

/// Stands in for the on-device model where only its presence matters; the watches here are judged by the stub center.
private final class PresentModel: LanguageModel, @unchecked Sendable {
    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        throw HarnessFixtureFailure()
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        preconditionFailure("Not used")
    }
}

@MainActor
private final class Sheet {
    var asked: [PageWatchRequest] = []
    var answer: (PageWatchRequest) -> PageWatchRequest? = { $0 }

    var stub: AgentActionConsent.WatchStub {
        AgentActionConsent.WatchStub { [unowned self] request in
            asked.append(request)
            return answer(request)
        }
    }
}

/// A website on screen in a regular window whose profile uses a test center, and the center it replaced.
@MainActor
private struct Screen {
    let browser: BrowserModel
    let url: URL
    let server: HTTPFixtureServer
    let previous: PageWatchCenter?
}

@MainActor
private final class Readings {
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var reads = 0
}

/// A center that schedules like a real one, reads a fixed page and never sleeps through a test.
@MainActor
private func scheduledCenter() -> PageWatchCenter {
    PageWatchCenter(
        file: nil,
        schedules: true,
        launchHold: 0,
        sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
        fetch: { _ in PageWatchReading(title: "Kettle", text: "Kettle $54.99", url: nil) },
        judge: { _, _ in PageWatchVerdict(met: false, state: "$54.99", message: "") },
        classify: { _, _ in PageWatchVerdict(met: false, state: "", message: "") },
        notify: { _, _ in }
    )
}

/// The assistant's watch tools: the person's yes every time, the limit, private windows, and what the chat model sees.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageWatchToolTests {
    private let delivery = NotificationBridge.DeliveryStub { _ in true }

    private func toolkit(_ browser: BrowserModel) -> AgentToolkit {
        AgentToolkit(browser: browser, media: MediaCenter(), log: ConversationLog(database: .temporary()))
    }

    private func pageOnScreen(_ center: PageWatchCenter) async throws -> Screen {
        let server = try await HTTPFixtureServer.start(routes: ["/kettle": .html("<title>Kettle</title><p>Kettle $54.99</p>")])
        let url = try server.url("/kettle")
        let browser = BrowserModel(database: .temporary())
        let previous = browser.context.pageWatches
        browser.context.pageWatches = center
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        return Screen(browser: browser, url: url, server: server, previous: previous)
    }

    private func restore(_ browser: BrowserModel, _ previous: PageWatchCenter?, _ center: PageWatchCenter) {
        center.shutDown()
        browser.context.pageWatches = previous
    }

    @Test func theAssistantAsksEveryTimeAndADeclineWatchesNothing() async throws {
        let center = scheduledCenter()
        let screen = try await pageOnScreen(center)
        defer { restore(screen.browser, screen.previous, center) }
        let subject = toolkit(screen.browser)
        let sheet = Sheet()

        sheet.answer = { _ in nil }
        let declined = await AgentActionConsent.$watchDecisionForTesting.withValue(sheet.stub) {
            await subject.watchPage(condition: "", everyMinutes: 60)
        }
        #expect(declined.contains("didn’t agree"))
        #expect(center.watches.isEmpty)

        sheet.answer = { $0 }
        let outputs = await AgentActionConsent.$watchDecisionForTesting.withValue(sheet.stub) {
            await NotificationBridge.$watchDeliveryForTesting.withValue(delivery) {
                await PageWatchJudge.$onDevice.withValue({ PresentModel() }) {
                    [
                        await subject.watchPage(condition: "", everyMinutes: 60),
                        await subject.watchPage(condition: "back in stock", everyMinutes: 30),
                    ]
                }
            }
        }

        #expect(outputs.allSatisfy { $0.hasPrefix("Watching") })
        #expect(sheet.asked.count == 3, "one question per watch, and the decline asked too")
        #expect(sheet.asked.last == PageWatchRequest(
            url: screen.url, title: "Kettle", condition: "back in stock", minutes: 30, readsWithWebKitInstead: false
        ))
        #expect(center.watches.map(\.condition) == ["", "back in stock"])
        withExtendedLifetime(screen.server) {}
    }

    @Test func thePersonDecidesWhetherAWatchUsesTheirSignIns() async throws {
        let center = scheduledCenter()
        let screen = try await pageOnScreen(center)
        defer { restore(screen.browser, screen.previous, center) }
        let sheet = Sheet()
        sheet.answer = { request in
            var answer = request
            answer.access = .signedIn
            return answer
        }

        let output = await AgentActionConsent.$watchDecisionForTesting.withValue(sheet.stub) {
            await NotificationBridge.$watchDeliveryForTesting.withValue(delivery) {
                await toolkit(screen.browser).watchPage(condition: "", everyMinutes: 60)
            }
        }

        #expect(sheet.asked.first?.access == .anonymous, "the sheet starts without the person's sign-ins")
        #expect(center.watches.first?.access == .signedIn)
        #expect(output.contains("with the person’s sign-ins"))
        withExtendedLifetime(screen.server) {}
    }

    @Test func noWatchStartsPastTwentyAndThePersonIsNotAsked() async throws {
        let center = scheduledCenter()
        let screen = try await pageOnScreen(center)
        defer { restore(screen.browser, screen.previous, center) }
        for index in 0..<PageWatch.limit {
            _ = await center.start(url: screen.url, title: "", condition: "condition \(index)", everyMinutes: 60)
        }
        let sheet = Sheet()

        let output = await AgentActionConsent.$watchDecisionForTesting.withValue(sheet.stub) {
            await toolkit(screen.browser).watchPage(condition: "", everyMinutes: 60)
        }

        #expect(output.contains("up to \(PageWatch.limit) pages"))
        #expect(sheet.asked.isEmpty)
        #expect(center.watches.count == PageWatch.limit)
        withExtendedLifetime(screen.server) {}
    }

    @Test func aPrivateWindowCannotWatchPages() async {
        let browser = BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID())
        let subject = toolkit(browser)
        let sheet = Sheet()

        let output = await AgentActionConsent.$watchDecisionForTesting.withValue(sheet.stub) {
            await subject.watchPage(condition: "", everyMinutes: 60)
        }

        #expect(output.contains("Private windows can’t watch pages"))
        #expect(sheet.asked.isEmpty)
        #expect(subject.listWatches() == "Private windows have no page watches.")
        #expect(subject.stopWatch(matching: "kettle") == "Private windows have no page watches.")
    }

    @Test func listingShowsALastStateOnlyWhereTheAssistantMayRead() async throws {
        let center = scheduledCenter()
        let browser = BrowserModel(database: .temporary())
        let previous = browser.context.pageWatches
        browser.context.pageWatches = center
        let url = try #require(URL(string: "https://watch-listing.example/kettle"))
        let origin = SitePermissions.origin(for: url)
        defer {
            browser.context.sitePermissions.setAssistantAccess(nil, for: origin)
            restore(browser, previous, center)
        }
        _ = await center.start(url: url, title: "", condition: "price below $50", everyMinutes: 60)
        let subject = toolkit(browser)

        browser.context.sitePermissions.setAssistantAccess(.ask, for: origin)
        let asking = subject.listWatches()
        browser.context.sitePermissions.setAssistantAccess(.readOnly, for: origin)
        let reading = subject.listWatches()

        #expect(asking.contains("price below $50") && asking.contains(url.absoluteString))
        #expect(!asking.contains("$54.99") && !asking.contains("Kettle"), "no page text where the assistant may not read")
        #expect(reading.contains("Last seen:") && reading.contains("$54.99") && reading.contains("Kettle"))
        #expect(reading.contains("<page-content untrusted=\"true\">"))
        #expect(subject.stopWatch(matching: "price below") == "Stopped watching watch-listing.example.")
        #expect(center.watches.isEmpty)
    }

    /// Connected apps have no path to watches: nothing under WSurf/MCP names them.
    @Test func connectedAppsCannotReachWatches() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "WSurf/MCP"), includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for name in ["PageWatch", "pageWatches", "watchPage", "listWatches", "stopWatch", "WatchesPanel"] {
                #expect(!source.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
        #expect(scanned > 0)
    }
}

/// View › Watch This Page… and the Watches tab.
@MainActor
@Suite(.serialized)
struct PageWatchUITests {
    private let page = URL(string: "https://shop.example/kettle")!

    private func watch(failures: Int = 0) -> PageWatch {
        var watch = PageWatch(
            id: UUID(), url: page, title: "", condition: "", interval: 3600, access: .signedIn, created: .now, nextCheck: .now
        )
        watch.failures = failures
        return watch
    }

    @Test func theMenuItemIsHiddenInAPrivateWindowAndNeedsAWebsite() {
        let privately = AppCoordinator.watchMenuState(isPrivate: true, url: page)
        let regular = AppCoordinator.watchMenuState(isPrivate: false, url: page)
        let blank = AppCoordinator.watchMenuState(isPrivate: false, url: nil)
        let file = AppCoordinator.watchMenuState(isPrivate: false, url: URL(filePath: "/tmp/kettle.html"))

        #expect(!privately.isShown && !privately.isEnabled)
        #expect(regular.isShown && regular.isEnabled)
        #expect(blank.isShown && !blank.isEnabled)
        #expect(file.isShown && !file.isEnabled)
    }

    @Test func aPrivateWindowHasNoWatchCenterToKeepNoticesIn() {
        #expect(BrowserProfileContext(profile: .privateBrowsing()).pageWatches == nil)
        #expect(PageWatchRow.badge(for: nil) == 0)
    }

    @Test func thePrivateWindowsMenuHidesWatchThisPage() throws {
        let coordinator = AppCoordinator(browser: BrowserModel(context: BrowserProfileContext(profile: .privateBrowsing()), windowID: UUID()))
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.title == String(localized: "Watch This Page…") })

        #expect(!menu.validateMenuItem(item))
        #expect(item.isHidden)
    }

    @Test func rowsSayHowEachWatchIsReadAndWhetherItWaits() async {
        let permissions = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory.appending(path: "watch-rows-\(UUID().uuidString).json"),
            persists: false
        )
        permissions.setEngine(.chromium, for: SitePermissions.origin(for: page))
        let center = PageWatchCenter(
            file: nil,
            schedules: false,
            fetch: { _ in PageWatchReading(title: "", text: "Kettle $54.99", url: nil) },
            judge: { _, _ in nil },
            classify: { _, _ in nil },
            notify: { _, _ in }
        )

        #expect(PageWatchRow(watch: watch(), readsWithWebKitInstead: false).status == .watching)
        #expect(PageWatchRow(watch: watch(failures: PageWatch.failureLimit), readsWithWebKitInstead: false).status == .unreachable)
        #expect(PageWatchRow(watch: watch(), readsWithWebKitInstead: false).usesSignIns)
        #expect(PageWatchRow(watch: watch(), readsWithWebKitInstead: false).title == "shop.example")
        #expect(PageWatchRow.rows(center, permissions: permissions).isEmpty)
        _ = await center.start(url: page, title: "", condition: "", everyMinutes: 60)
        #expect(PageWatchRow.rows(center, permissions: permissions).map(\.readsWithWebKitInstead) == [true])
        #expect(PageWatchRow.badge(for: center) == 0)
        center.noteMissed(watch(), .met)
        #expect(PageWatchRow.badge(for: center) == 1)
        #expect(PageWatchRow.badge(for: nil) == 0)
        #expect(String(localized: PageWatchesSettingsSection.summary(for: nil)) == String(localized: "Not in private windows"))
    }

    @Test func aPausedWatchIsNotReadUntilItResumes() async throws {
        let clock = Readings()
        let center = PageWatchCenter(
            file: nil,
            schedules: false,
            now: { clock.date },
            fetch: { _ in
                clock.reads += 1
                return PageWatchReading(title: "Kettle", text: "Kettle $54.99, reading \(clock.reads)", url: nil)
            },
            judge: { _, _ in nil },
            classify: { _, _ in PageWatchVerdict(met: false, state: "", message: "") },
            notify: { _, _ in }
        )
        guard case .watching(let watch) = await center.start(url: page, title: "", condition: "", everyMinutes: 60) else {
            Issue.record("no watch")
            return
        }

        center.setAllPaused(true)
        clock.date += 3600
        await center.checkDue()
        let paused = try #require(center.watches.first)
        #expect(clock.reads == 1)
        #expect(paused.isPaused && paused.isPausedByPerson && !paused.isUnreachable)
        #expect(PageWatchRow(watch: paused, readsWithWebKitInstead: false).status == .paused)

        center.setPaused(watch.id, false)
        await center.checkDue()
        #expect(clock.reads == 2)
        #expect(center.watches.first?.isPaused == false)
    }
}
