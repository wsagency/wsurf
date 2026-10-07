// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import AppKit
import Foundation
import Testing

@testable import WSurf

struct AgentProviderRetryTests {
    @Test func retriesAreBoundedAndHonorServerDelay() {
        let failure = OpenAIFailure(kind: .http, status: 429, retryAfter: 7)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 0, remoteActionsEnabled: false) == 7)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 2, remoteActionsEnabled: false) == nil)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 0, remoteActionsEnabled: true) == nil)
        #expect(AgentProviderRetry.delay(for: OpenAIFailure(kind: .http, status: 503, retryAfter: 120), attempt: 0, remoteActionsEnabled: false) == nil)
    }

    @Test func streamedRateLimitsWithoutHTTPStatusCanRetry() {
        let failure = OpenAIFailure.event(["error": ["code": "rate_limit_exceeded"]])
        #expect(failure.isRateLimited)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 0, remoteActionsEnabled: false, jitter: 0) == 2)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 1, remoteActionsEnabled: false, jitter: 0) == 4)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 2, remoteActionsEnabled: false) == nil)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 0, remoteActionsEnabled: true) == nil)
        for code in ["insufficient_quota", "billing_hard_limit_reached"] {
            #expect(!OpenAIFailure(kind: .http, status: 429, code: code).isRateLimited)
            #expect(!OpenAIFailure.event(["error": ["code": .string(code)]]).isRateLimited)
        }
    }
    @Test func serverErrorsKeepTheirExistingBackoffAndUsageIsNotRetried() {
        let failure = OpenAIFailure(kind: .http, status: 503)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 0, remoteActionsEnabled: false, jitter: 0) == 1)
        #expect(AgentProviderRetry.delay(for: failure, attempt: 1, remoteActionsEnabled: false, jitter: 0) == 2)
        var used = OpenAIFailure(kind: .incomplete, code: "rate_limit_exceeded")
        used.usage = .init(raw: ["input_tokens": 1])
        #expect(AgentProviderRetry.delay(for: used, attempt: 0, remoteActionsEnabled: false) == nil)
    }

    @Test func permanentErrorsAndUncertainDeliveryAreNotRetried() {
        for error in [OpenAIFailure(kind: .http, status: 401), .init(kind: .http, status: 429, code: "insufficient_quota"), .init(kind: .streamInterrupted)] {
            #expect(AgentProviderRetry.delay(for: error, attempt: 0, remoteActionsEnabled: false) == nil)
        }
        #expect(AgentProviderRetry.delay(for: URLError(.timedOut), attempt: 0, remoteActionsEnabled: false) == nil)
        #expect(AgentProviderRetry.delay(for: URLError(.networkConnectionLost), attempt: 0, remoteActionsEnabled: false) == nil)
        #expect(AgentProviderRetry.delay(for: URLError(.cannotConnectToHost), attempt: 1, remoteActionsEnabled: false, jitter: 0) == 2)
    }

    @Test func parsesRetryHeaders() {
        #expect(AgentProviderRetry.retryAfter("3") == 3)
        #expect(AgentProviderRetry.retryAfter(nil, milliseconds: "250") == 0.25)
        #expect(AgentProviderRetry.retryAfter("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 0)) == 60)
        #expect(AgentProviderRetry.retryAfter("bad") == nil)
    }
}

@MainActor
@Suite(.serialized)
struct AgentRetryWorkflowTests {
    @Test func retryDoesNotRepeatAnExecutedAction() async throws {
        let fixture = HarnessFixture([.calls(["typeOnPage"]), .failure(OpenAIFailure(kind: .http, status: 503, retryAfter: 0)), .text("Finished.")])
        await fixture.run()
        #expect(fixture.state.calls == 1)
        #expect(fixture.model.requests.count == 3)
        #expect(fixture.log.latestTrace(forTab: fixture.tabID)?.state == .completed)
    }

    @Test func streamedRateLimitRetriesWithoutRepeatingBrowserActions() async throws {
        let fixture = HarnessFixture([.calls(["typeOnPage"]),
                                     .failure(OpenAIFailure(kind: .incomplete, code: "rate_limit_exceeded", retryAfter: 0)), .text("Finished."),
        ])
        await fixture.run()
        #expect(fixture.state.calls == 1)
        #expect(fixture.model.requests.count == 3)
        #expect(fixture.log.latestTrace(forTab: fixture.tabID)?.state == .completed)
    }

    @Test func exhaustedRateLimitPausesWithoutAnotherSummaryRequest() async throws {
        let failure = OpenAIFailure(kind: .http, code: "rate_limit_exceeded", retryAfter: 0)
        let fixture = HarnessFixture([.failure(failure), .failure(failure), .failure(failure), .text("Must not request a summary")])
        await fixture.run()
        #expect(fixture.model.requests.count == 3)
        let trace = fixture.log.latestTrace(forTab: fixture.tabID)
        #expect(trace?.stopReason == .rateLimited)
        #expect(trace?.state == .paused)
        #expect(trace?.response.contains("rate limit") == true)
        #expect(trace?.diagnostics.events.last?.values["status"] == "rate_limited")
    }

    @Test func retryRespectsTheRequestLimit() async throws {
        let fixture = HarnessFixture([.failure(OpenAIFailure(kind: .http, status: 429, retryAfter: 0)), .text("Unexpected retry")],
                                     policy: .init(maxModelRequests: 1))
        await fixture.run()
        #expect(fixture.log.latestTrace(forTab: fixture.tabID)?.stopReason == .requestLimit)
        #expect(fixture.model.requests.filter { !$0.contains("browser task is paused") }.count == 1)
        #expect(fixture.state.calls == 0)
    }
}
@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp)
struct AgentRetryBrowserRecoveryTests {
    @Test func rateLimitContinueKeepsTheOriginalWindowProfileAndExecutedBrowserAction() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/owner": .html("<button onclick=\"document.body.dataset.hits = Number(document.body.dataset.hits || 0) + 1\">Apply</button>"),
            "/other": .html("<button onclick=\"document.body.dataset.hits = Number(document.body.dataset.hits || 0) + 1\">Other</button>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let ownerURL = try server.url("/owner")
        let otherURL = try server.url("/other")
        let provider = try #require(ProviderCatalog.builtIn.first { $0.id == "anthropic" })
        let profiles = (0..<2).map {
            Profile(id: UUID(), name: "Retry owner \($0)", symbol: "person", color: .gray)
        }
        let contexts = profiles.map { BrowserProfileContext.shared(for: $0) }
        let ownerModelID = "retry-owner-\(UUID().uuidString)"
        let otherModelID = "other-window-\(UUID().uuidString)"
        for (context, modelID) in zip(contexts, [ownerModelID, otherModelID]) {
            context.modelSettings.providerID = provider.id
            context.modelSettings.setModel(modelID, for: provider)
        }

        let app = BrowserApplication()
        let delays = RetryDelayRecorder()
        let failure = OpenAIFailure(kind: .http, status: 429, code: "rate_limit_exceeded")
        let ownerModel = RecoveryModel([
            .readPage, .clickLatest,
            .failure(failure), .failure(failure), .failure(failure),
            .continuationText("Continued."),
        ])
        let otherModel = RecoveryModel([.text("Wrong profile selected.")])
        let providers = RecoveryProviders(
            models: [ownerModelID: ownerModel, otherModelID: otherModel],
            delays: delays,
            onRetry: { [weak app] in
                if let app, let changingWindow = app.windows.last {
                    app.focus(changingWindow)
                }
            }
        )

        let owner = makeWindow(contexts[0], in: app, providers: providers)
        let changing = makeWindow(contexts[1], in: app, providers: providers)
        let nativeWindows = [owner, changing].map { coordinator in
            let native = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: .borderless, backing: .buffered, defer: true
            )
            native.isReleasedWhenClosed = false
            coordinator.extensions.register(browser: coordinator.browser, window: native)
            return native
        }
        let ownerTab = owner.browser.newTab(url: ownerURL)
        let otherTab = changing.browser.newTab(url: otherURL)
        for (window, tab) in zip(nativeWindows, [ownerTab, otherTab]) {
            window.contentView = tab.page
            window.orderBack(nil)
        }
        #expect(await PageSettle.untilIdle(ownerTab.page, timeout: .seconds(30)))
        #expect(await PageSettle.untilIdle(otherTab.page, timeout: .seconds(30)))
        ownerTab.assistantAccess.persistsAnswers = false
        ownerTab.assistantAccess.pageChanged(url: ownerURL)
        ownerTab.assistantAccess.set(.control)
        app.focus(owner)

        func closeWindows() async {
            owner.closeWindow()
            changing.closeWindow()
            await ownerTab.waitForRetirement()
            await otherTab.waitForRetirement()
            for window in nativeWindows {
                window.contentView = nil
                window.close()
            }
        }
        defer {
            for profile in profiles {
                BrowserProfileContext.forget(profile.id)
                ProfileSettingsStore.forget(profile.id)
                try? FileManager.default.removeItem(at: profile.supportDirectory)
                try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
            }
        }

        do {
            #expect(owner.agentTurns.run(utterance: "Apply once and recover after rate limiting"))
            try #require(await waitUntil { !owner.agentTurns.isRunning })

            let paused = try #require(contexts[0].conversationLog.latestTrace(forTab: ownerTab.id))
            #expect(app.activeCoordinator === changing)
            #expect(paused.stopReason == .rateLimited)
            #expect(paused.state == .paused)
            #expect(paused.checkpoint.map { HarnessFixture.flattened($0.transcript).contains("Clicked") } == true)
            #expect(ownerModel.requests.count == 5)
            let recordedDelays = delays.values
            #expect(recordedDelays.count == 2)
            if recordedDelays.count == 2 {
                #expect((2...2.25).contains(recordedDelays[0]))
                #expect((4...4.25).contains(recordedDelays[1]))
            }
            #expect(ownerModel.transcripts.last.map { HarnessFixture.flattened($0).contains("Clicked") } == true)
            #expect(try await ownerTab.page.evaluateJavaScript("document.body.dataset.hits") as? String == "1")
            #expect(try await otherTab.page.evaluateJavaScript("document.body.dataset.hits || '0'") as? String == "0")

            contexts[0].conversationLog.saveBlocking()
            let restoredLog = ConversationLog(database: contexts[0].database)
            #expect(restoredLog.checkpoint(forTab: ownerTab.id) == paused.checkpoint)
            owner.agentTurns.adopt(log: restoredLog)
            owner.continueAgent()
            try #require(await waitUntil { !owner.agentTurns.isRunning })

            #expect(app.activeCoordinator === changing)
            #expect(ownerModel.requests.count == 6)
            #expect(ownerModel.transcripts.last.map { HarnessFixture.flattened($0).contains("Clicked") } == true)
            #expect(owner.agentTurns.reply.text == "Continued.")
            #expect(restoredLog.latestTrace(forTab: ownerTab.id)?.state == .completed)
            restoredLog.saveBlocking()
            #expect(try await ownerTab.page.evaluateJavaScript("document.body.dataset.hits") as? String == "1")
            #expect(try await otherTab.page.evaluateJavaScript("document.body.dataset.hits || '0'") as? String == "0")
            #expect(otherModel.requests.isEmpty)
        } catch {
            await closeWindows()
            throw error
        }
        await closeWindows()
    }

    private func makeWindow(
        _ context: BrowserProfileContext, in app: BrowserApplication, providers: RecoveryProviders
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            browser: BrowserModel(context: context, windowID: UUID()), modelProviders: providers
        )
        app.register(coordinator)
        coordinator.voiceConfigurationID = "apple:" + context.modelSettings.providerID
        coordinator.configureEngines()
        return coordinator
    }
}

@MainActor
private struct RecoveryProviders: ModelProviderResolving {
    let models: [String: RecoveryModel]
    let delays: RetryDelayRecorder
    let onRetry: @MainActor () -> Void

    func resolve(_ configuration: Provider) -> any ModelProvider {
        RecoveryProvider(configuration: configuration, models: models, delays: delays, onRetry: onRetry)
    }
}

@MainActor
private struct RecoveryProvider: ModelProvider {
    let configuration: Provider
    let models: [String: RecoveryModel]
    let delays: RetryDelayRecorder
    let onRetry: @MainActor () -> Void
    let capabilities: ModelProviderCapabilities = [.toolCalling]
    let availability: ModelProviderAvailability = .available

    func availableModels() async throws -> [String] {
        []
    }

    func makeAgent(
        model: String, reasoningEffort: LLMSettings.ReasoningEffort,
        toolkit: AgentToolkit, log: ConversationLog
    ) -> any AgentRunner {
        AnyLanguageModelAgent(
            name: configuration.name, modelID: model,
            executionPolicy: .init(requiresOutcomeVerification: false),
            model: models[model] ?? RecoveryModel([.failure(RecoveryFixtureError.unexpectedRequest)]),
            options: GenerationOptions(),
            budget: ContextBudget(
                windowTokens: 128_000, responseTokens: 2_000, inputTokens: 100_000,
                toolSchemaTokens: 0, instructionTier: .compact, toolTier: .full,
                toolOutput: .standard, retainedExchanges: 12, retainedToolRounds: 1
            ),
            retrySleep: { delay in
                delays.record(delay)
                await MainActor.run { onRetry() }
            },
            toolkit: toolkit, log: log
        )
    }
}

private nonisolated final class RecoveryModel: LanguageModel, @unchecked Sendable {
    enum Action {
        case readPage
        case clickLatest
        case failure(any Error)
        case continuationText(String)
        case text(String)
    }

    private let lock = NSLock()
    private var actions: [Action]
    private var prompts: [String] = []
    private var seen: [Transcript] = []

    var requests: [String] {
        lock.withLock { prompts }
    }
    var transcripts: [Transcript] {
        lock.withLock { seen }
    }

    init(_ actions: [Action]) {
        self.actions = actions
    }

    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        let action = lock.withLock { () -> Action? in
            prompts.append(prompt.description)
            seen.append(session.transcript)
            if prompt.description.contains("historical checkpoint") || prompt.description.contains("browser task is paused") {
                return nil
            }
            guard !actions.isEmpty else { return nil }
            return actions.removeFirst()
        }
        guard let action else { throw RecoveryFixtureError.unexpectedRequest }
        let call: Transcript.ToolCall?
        let text: String
        switch action {
        case .readPage:
            call = Transcript.ToolCall(id: UUID().uuidString, toolName: "readPage", arguments: GeneratedContent(properties: [:]))
            text = ""
        case .clickLatest:
            let output = session.transcript.reversed().lazy.compactMap { entry -> String? in
                guard case .toolOutput(let output) = entry else { return nil }
                return output.segments.compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }.joined(separator: "\n")
            }.first ?? ""
            guard let observationID = output.components(separatedBy: "observationID: ").last?
                .components(separatedBy: .newlines).first,
                !observationID.isEmpty else { throw RecoveryFixtureError.missingObservation }
            call = Transcript.ToolCall(id: UUID().uuidString, toolName: "clickOnPage", arguments: GeneratedContent(properties: [
                "observationID": GeneratedContent(observationID),
                "ref": GeneratedContent(1),
                "label": GeneratedContent("Apply"),
            ]))
            text = ""
        case .failure(let error):
            throw error
        case .text(let answer):
            call = nil
            text = answer
        case .continuationText(let answer):
            let transcript = String(decoding: (try? JSONEncoder().encode(session.transcript)) ?? Data(), as: UTF8.self)
            guard transcript.contains(AgentCheckpoint.resumePrompt) else { throw RecoveryFixtureError.unexpectedRequest }
            call = nil
            text = answer
        }
        let entries: [Transcript.Entry] = call.map { [.toolCalls(.init([$0]))] } ?? []
        if let call, let delegate = session.toolExecutionDelegate {
            await delegate.didGenerateToolCalls([call], in: session)
            guard case .stop = await delegate.toolCallDecision(for: call, in: session) else {
                throw RecoveryFixtureError.toolWasNotAccepted
            }
        }
        guard let content = text as? Content else { throw RecoveryFixtureError.unexpectedContent }
        return .init(content: content, rawContent: GeneratedContent(text), transcriptEntries: entries[...])
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        fatalError("Recovery provider fixture does not stream")
    }
}

private enum RecoveryFixtureError: Error {
    case unexpectedRequest
    case missingObservation
    case toolWasNotAccepted
    case unexpectedContent
}

private nonisolated final class RetryDelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] {
        lock.withLock { recorded }
    }
    func record(_ delay: Double) {
        lock.withLock { recorded.append(delay) }
    }
}
