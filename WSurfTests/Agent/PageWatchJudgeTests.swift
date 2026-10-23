// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AnyLanguageModel
import Foundation
import Testing
import UserNotifications

@testable import WSurf

/// The on-device model's stand-in, or a provider's that must never be asked: it records every prompt and answers with a fixed
/// finding.
private final class JudgeModel: LanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private let finding: PageWatchJudge.Finding
    private let change: PageWatchJudge.ChangeFinding

    init(
        finding: PageWatchJudge.Finding = .init(state: "", met: false, message: ""),
        change: PageWatchJudge.ChangeFinding = .init(kind: .viewCountOrDate, summary: "")
    ) {
        self.finding = finding
        self.change = change
    }

    var prompts: [String] {
        lock.withLock { seen }
    }

    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        lock.withLock { seen.append(prompt.description) }
        if let content = finding as? Content {
            return .init(content: content, rawContent: content.generatedContent, transcriptEntries: [])
        }
        guard let content = change as? Content else { throw HarnessFixtureFailure() }
        return .init(content: content, rawContent: content.generatedContent, transcriptEntries: [])
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        preconditionFailure("The watch judge does not stream")
    }
}

/// A page whose text the test changes between readings.
private nonisolated final class Versions: @unchecked Sendable {
    private let lock = NSLock()
    private var html = "<!doctype html><title>Kettle</title><main><p>Kettle $54.99</p></main>"

    var current: String {
        lock.withLock { html }
    }

    func set(_ next: String) {
        lock.withLock { html = next }
    }
}

@MainActor
private final class Delivered {
    var requests: [UNNotificationRequest] = []
}

/// Judging on this Mac only, and what a watch's notification says.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PageWatchJudgeTests {
    private let page = URL(string: "https://shop.example/kettle")!

    private func watch(condition: String) -> PageWatch {
        PageWatch(id: UUID(), url: page, title: "Kettle", condition: condition, interval: 3600, created: .now, nextCheck: .now)
    }

    @Test func theOnDeviceModelJudgesTheConditionFromFencedPageText() async throws {
        let model = JudgeModel(finding: .init(state: "$42.99, in stock", met: true, message: "The price dropped to $42.99."))
        let reading = PageWatchReading(title: "Kettle", text: "Kettle $42.99 In stock", url: page)

        let verdict = try #require(await PageWatchJudge.judge(watch(condition: "price below $50"), reading: reading, model: model))

        #expect(verdict == PageWatchVerdict(met: true, state: "$42.99, in stock", message: "The price dropped to $42.99."))
        let prompt = try #require(model.prompts.first)
        #expect(prompt.contains("WAITING FOR: price below $50"))
        #expect(prompt.contains("<page-content untrusted=\"true\">"))
    }

    @Test func onlyAChangeThatMattersMeetsAWatchForAnyChange() async throws {
        let pair = PageWatchChange.Pair(removed: "Kettle $54.99", added: "Kettle $42.99")
        let counter = JudgeModel(change: .init(kind: .viewCountOrDate, summary: "The view count went up."))
        let price = JudgeModel(change: .init(kind: .priceOrAvailability, summary: "The price is now $42.99."))

        let ignored = try #require(await PageWatchJudge.classify(pair, model: counter))
        let told = try #require(await PageWatchJudge.classify(pair, model: price))

        #expect(!ignored.met)
        #expect(told == PageWatchVerdict(met: true, state: "", message: "The price is now $42.99."))
    }

    @Test func withoutTheOnDeviceModelNoProviderIsAsked() async {
        let cloud = JudgeModel(finding: .init(state: "$42.99", met: true, message: "Met."))
        let pair = PageWatchChange.Pair(removed: "Kettle $54.99", added: "Kettle $42.99")
        let reading = PageWatchReading(title: "Kettle", text: "Kettle $42.99", url: page)

        let (available, change, verdict) = await PageWatchJudge.$onDevice.withValue({ nil }) {
            await UtilityModelSource.$make.withValue({ cloud }) {
                (
                    PageWatchJudge.isAvailable,
                    await PageWatchJudge.classify(pair),
                    await PageWatchJudge.judge(watch(condition: "price below $50"), reading: reading)
                )
            }
        }

        #expect(!available)
        #expect(change == PageWatchVerdict(met: true, state: "", message: String(localized: "The page changed.")))
        #expect(verdict == nil, "a condition is never guessed")
        #expect(cloud.prompts.isEmpty)
    }

    @Test func anUnchangedPageNeverAsksTheModel() async throws {
        let model = JudgeModel(finding: .init(state: "$54.99", met: false, message: ""))
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let center = PageWatchCenter(
            file: nil,
            schedules: false,
            now: { date },
            fetch: { _ in PageWatchReading(title: "Kettle", text: "Kettle $54.99", url: nil) },
            judge: { watch, reading in await PageWatchJudge.judge(watch, reading: reading, model: model) },
            classify: { _, pair in await PageWatchJudge.classify(pair, model: model) },
            notify: { _, _ in }
        )
        let started = await center.start(url: page, title: "", condition: "price below $50", everyMinutes: 60)
        guard case .watching = started else {
            Issue.record("no watch: \(started)")
            return
        }
        date += 3600

        await center.checkDue()

        #expect(model.prompts.count == 1, "only the first reading was judged")
        #expect(center.watches.first?.lastChecked == date)
    }

    @Test func aNotificationNamesTheSiteAndConditionButNoPageText() throws {
        var watched = watch(condition: "price below $50")
        watched.snapshot = "Kettle $42.99 In stock. Secret offer code KETTLE42."
        watched.state = "$42.99, in stock"
        let profileID = UUID()

        let met = NotificationBridge.request(for: watched, .met, profileID: profileID)
        let unreachable = NotificationBridge.request(for: watched, .unreachable, profileID: profileID)

        #expect(met.identifier == watched.id.uuidString)
        #expect(met.trigger == nil)
        #expect(met.content.title == "shop.example")
        #expect(met.content.body.contains("price below $50"))
        for request in [met, unreachable] {
            let shown = [request.content.title, request.content.subtitle, request.content.body].joined(separator: " ")
            #expect(!shown.contains("42.99"))
            #expect(!shown.contains("KETTLE42"))
            #expect(!shown.contains("Kettle"), "the page's own title is page text too")
        }
        let routed = try #require(NotificationBridge.watchedPage(in: met.content.userInfo))
        #expect(routed.url == page)
        #expect(routed.profileID == profileID)
    }

    @Test func aWebsitesNotificationCannotOpenAWatchedPage() {
        #expect(NotificationBridge.watchedPage(in: ["link": "https://shop.example"]) == nil)
        #expect(NotificationBridge.watchedPage(in: [
            "wsurf.watch.url": "file:///etc/hosts", "wsurf.watch.profile": UUID().uuidString,
        ]) == nil)
    }

    @Test func missedNoticesAreKeptForTheWatchesTabAndCleared() {
        let center = PageWatchCenter(
            file: nil, schedules: false, fetch: { _ in nil }, judge: { _, _ in nil }, classify: { _, _ in nil }, notify: { _, _ in }
        )
        for index in 0...PageWatch.limit {
            center.noteMissed(watch(condition: "condition \(index)"), .met)
        }

        #expect(center.missed.count == PageWatch.limit)
        #expect(center.missed.last?.condition == "condition \(PageWatch.limit)")
        center.dismissMissed()
        #expect(center.missed.isEmpty)
    }

    /// The live center end to end without Apple Intelligence: the change is told from the text, the notice WSurf may not show
    /// is kept, and no provider is asked.
    @Test func aLiveWatchWithoutTheOnDeviceModelKeepsANoticeItCouldNotShow() async throws {
        let versions = Versions()
        let server = try await HTTPFixtureServer.start(routes: [:]) { request in
            request.path == "/kettle" ? .html(versions.current) : nil
        }
        let url = try server.url("/kettle")
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let center = PageWatchCenter.live(for: context)
        let cloud = JudgeModel()
        let delivered = Delivered()
        let stub = NotificationBridge.DeliveryStub { request in
            delivered.requests.append(request)
            return false
        }

        let noticed = await PageWatchJudge.$onDevice.withValue({ nil }) {
            await UtilityModelSource.$make.withValue({ cloud }) {
                await NotificationBridge.$watchDeliveryForTesting.withValue(stub) {
                    await changeOnce(center, url: url, versions: versions)
                }
            }
        }

        #expect(noticed)
        #expect(center.missed.map(\.notice) == [.met])
        #expect(center.watches.isEmpty, "a met watch ends")
        #expect(cloud.prompts.isEmpty)
        let request = try #require(delivered.requests.first)
        #expect(request.content.body == String(localized: "The page changed."))
        #expect(!request.content.body.contains("49.99") && !request.content.title.contains("49.99"))
        withExtendedLifetime(context) {}
    }

    private func changeOnce(_ center: PageWatchCenter, url: URL, versions: Versions) async -> Bool {
        guard case .watching(let watch) = await center.start(url: url, title: "", condition: "", everyMinutes: 60) else { return false }
        versions.set("<!doctype html><title>Kettle</title><main><p>Kettle $49.99</p></main>")
        await center.check(watch.id)
        return await waitUntil { center.missed.count == 1 }
    }
}
