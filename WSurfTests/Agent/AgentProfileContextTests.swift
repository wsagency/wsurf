// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import AppKit
import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews, .exclusiveExternalApp)
struct AgentProfileContextTests {
    @Test func concurrentTurnsKeepProfileSettings() async throws {
        let firstProvider = try #require(ProviderCatalog.builtIn.first { $0.id == "anthropic" })
        let secondProvider = try #require(ProviderCatalog.builtIn.first { $0.id == "google" })
        let profiles = (0..<3).map {
            Profile(id: UUID(), name: "Concurrent turn \($0)", symbol: "person", color: .gray)
        }
        let contexts = profiles.map { BrowserProfileContext.shared(for: $0) }
        let selections = [
            (firstProvider, "first-profile-model"), (secondProvider, "second-profile-model"),
            (ProviderCatalog.appleOnDevice, "third-profile-model"),
        ]
        for (context, selection) in zip(contexts, selections) {
            context.modelSettings.providerID = selection.0.id
            context.modelSettings.setModel(selection.1, for: selection.0)
            context.modelSettings.setDiscoveredContextWindow(128_000, for: selection.0, model: selection.1)
        }
        contexts[0].actionPolicy.allowAlways(.publication, host: "turn.example.test")
        contexts[1].actionPolicy.allowAlways(.purchase, host: "turn.example.test")
        let firstTurn = ContextTurn(answer: "First profile answer.")
        let secondTurn = ContextTurn(answer: "Second profile answer.")
        let providers = ContextProviders(turns: [
            "anthropic/first-profile-model": firstTurn,
            "google/second-profile-model": secondTurn,
        ])
        let app = BrowserApplication()
        let first = window(contexts[0], in: app, providers: providers)
        let second = window(contexts[1], in: app, providers: providers)
        let changing = window(contexts[0], in: app, providers: providers)
        let firstTab = first.browser.newTab()
        let secondTab = second.browser.newTab()
        let windows = [first, second, changing]
        let nativeWindows = windows.map { coordinator in
            let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            native.isReleasedWhenClosed = false
            coordinator.extensions.register(browser: coordinator.browser, window: native)
            return native
        }
        var promptedWindows: [NSWindow?] = []
        let speech = HarnessSpeech()
        var failure: (any Error)?
        do {
            try await AgentActionConsent.$decisionForTesting.withValue(.init { _, _, _, window in
                promptedWindows.append(window)
                return .decline
            }) {
                app.focus(first)
                #expect(first.agentTurns.run(utterance: "Inspect the first profile", speechOverride: speech))
                try #require(await waitUntil { firstTurn.gate.requestCount == 1 })
                app.focus(second)
                #expect(second.agentTurns.run(utterance: "Inspect the second profile", speechOverride: speech))
                try #require(await waitUntil { secondTurn.gate.requestCount == 1 })
                #expect(first.agentTurns.isRunning && second.agentTurns.isRunning)
                #expect(firstTurn.permissions == [[true, false]])
                #expect(secondTurn.permissions == [[false, true]])
                #expect(first.selectedProvider.id == "anthropic")
                #expect(first.selectedModel == "first-profile-model")
                #expect(second.selectedProvider.id == "google")
                #expect(second.selectedModel == "second-profile-model")

                // Change both the focused owner and its profile while two other windows
                // have real model/tool work suspended. Neither task may borrow that owner.
                app.focus(changing)
                changing.voiceConfigurationID = "apple:" + contexts[2].modelSettings.providerID
                changing.applyProfileStores(profiles[2])
                changing.profiles.markCurrent(profiles[2])
                #expect(app.activeCoordinator === changing)
                #expect(changing.context === contexts[2])
                #expect(changing.selectedModel == "third-profile-model")
                #expect(first.agentTurns.isRunning && second.agentTurns.isRunning)

                secondTurn.gate.open()
                try #require(await waitUntil { !second.agentTurns.isRunning })
                #expect(first.agentTurns.isRunning, "another profile's completion must not finish this turn")
                app.focus(second)
                firstTurn.gate.open()
                try #require(await waitUntil { !first.agentTurns.isRunning })

                #expect(firstTurn.permissions == [[true, false], [true, false]])
                #expect(secondTurn.permissions == [[false, true], [false, true]])
                try #require(promptedWindows.count == 4)
                #expect(promptedWindows[0] === nativeWindows[0])
                #expect(promptedWindows[1] === nativeWindows[1])
                #expect(promptedWindows[2] === nativeWindows[1])
                #expect(promptedWindows[3] === nativeWindows[0])
                let firstTrace = try #require(contexts[0].conversationLog.latestTrace(forTab: firstTab.id))
                let secondTrace = try #require(contexts[1].conversationLog.latestTrace(forTab: secondTab.id))
                #expect(firstTrace.providerID == "anthropic")
                #expect(secondTrace.providerID == "google")
                #expect(firstTrace.state == .completed)
                #expect(secondTrace.state == .completed)
                #expect(firstTrace.response == "First profile answer.")
                #expect(secondTrace.response == "Second profile answer.")
                #expect(contexts[0].conversationLog.latestTrace(forTab: secondTab.id) == nil)
                #expect(contexts[1].conversationLog.latestTrace(forTab: firstTab.id) == nil)
                #expect(contexts[2].conversationLog.latestTrace(forTab: firstTab.id) == nil)
                #expect(contexts[2].conversationLog.latestTrace(forTab: secondTab.id) == nil)
                #expect(contexts[2].actionPolicy.grants.isEmpty)
                let firstTranscript = try #require(firstTurn.script.transcripts.last)
                let secondTranscript = try #require(secondTurn.script.transcripts.last)
                #expect(HarnessFixture.flattened(firstTranscript).contains("publication=true purchase=false"))
                #expect(HarnessFixture.flattened(secondTranscript).contains("publication=false purchase=true"))
            }
        } catch {
            failure = error
        }
        // Release gated provider work even when an assertion throws, before retiring owners.
        firstTurn.gate.open()
        secondTurn.gate.open()
        #expect(await waitUntil { !first.agentTurns.isRunning && !second.agentTurns.isRunning })
        let tabs = windows.flatMap { $0.browser.tabs }
        windows.forEach { $0.closeWindow() }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        nativeWindows.forEach { $0.close() }
        for (profile, context) in zip(profiles, contexts) {
            context.conversationLog.saveBlocking()
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }
        if let failure {
            throw failure
        }
    }

    private func window(
        _ context: BrowserProfileContext, in app: BrowserApplication, providers: ContextProviders
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            browser: BrowserModel(context: context, windowID: UUID()), modelProviders: providers
        )
        app.register(coordinator)
        // Model configuration is under test, not downloading SpeechAnalyzer assets.
        coordinator.voiceConfigurationID = "apple:" + context.modelSettings.providerID
        coordinator.configureEngines()
        return coordinator
    }

    @Test func rateLimitAfterActionDoesNotReplayOrSummarize() async throws {
        let provider = try #require(ProviderCatalog.builtIn.first { $0.id == "anthropic" })
        let profiles = (0..<2).map {
            Profile(id: UUID(), name: "Rate-limit owner \($0)", symbol: "person", color: .gray)
        }
        let contexts = profiles.map { BrowserProfileContext.shared(for: $0) }
        let firstSettings = contexts[0].modelSettings
        firstSettings.providerID = provider.id
        firstSettings.setModel("rate-limit-owner-model", for: provider)
        contexts[0].actionPolicy.allowAlways(.publication, host: "turn.example.test")
        contexts[1].actionPolicy.allowAlways(.purchase, host: "turn.example.test")
        let app = BrowserApplication()
        let failure = OpenAIFailure(kind: .http, code: "rate_limit_exceeded", retryAfter: 0)
        let turn = ContextTurn(
            answer: "",
            toolName: "typeOnPage",
            actions: [.calls(["typeOnPage"]), .failure(failure), .failure(failure), .failure(failure), .text("Must not summarize")],
            beforeAction: { [weak app] in
                if let app, let changing = app.windows.last {
                    app.focus(changing)
                }
            },
            waitForRelease: false
        )
        let providers = ContextProviders(turns: ["anthropic/rate-limit-owner-model": turn])
        func window(_ context: BrowserProfileContext) -> AppCoordinator {
            let coordinator = AppCoordinator(
                browser: BrowserModel(context: context, windowID: UUID()), modelProviders: providers
            )
            app.register(coordinator)
            coordinator.voiceConfigurationID = "apple:" + context.modelSettings.providerID
            coordinator.configureEngines()
            return coordinator
        }
        let first = window(contexts[0])
        let changing = window(contexts[1])
        let nativeWindows = [first, changing].map { coordinator in
            let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            native.isReleasedWhenClosed = false
            coordinator.extensions.register(browser: coordinator.browser, window: native)
            return native
        }
        let tab = first.browser.newTab()
        app.focus(first)
        #expect(first.agentTurns.run(utterance: "Read the page"))
        try #require(await waitUntil { !first.agentTurns.isRunning })

        let trace = try #require(contexts[0].conversationLog.latestTrace(forTab: tab.id))
        #expect(app.activeCoordinator === changing)
        #expect(turn.state.calls == 1)
        #expect(turn.script.requests.count == 4)
        #expect(turn.permissions == [[true, false], [true, false]])
        #expect(trace.stopReason == .rateLimited)
        #expect(trace.state == .paused)
        #expect(trace.response.contains("rate limit"))
        #expect(trace.progressUpdates.isEmpty == false)

        let tabs = [first, changing].flatMap { $0.browser.tabs }
        [first, changing].forEach { $0.closeWindow() }
        for tab in tabs {
            await tab.waitForRetirement()
        }
        nativeWindows.forEach { $0.close() }
        for (profile, context) in zip(profiles, contexts) {
            context.conversationLog.saveBlocking()
            BrowserProfileContext.forget(profile.id)
            ProfileSettingsStore.forget(profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        }
    }
}

@MainActor
private final class ContextTurn {
    let script: HarnessScript
    let state = HarnessToolState()
    let gate = ResponseGate()
    private(set) var permissions: [[Bool]] = []
    let toolName: String

    init(answer: String, toolName: String = "readPage", actions: [HarnessScript.Action]? = nil,
         beforeAction: @escaping () -> Void = {}, waitForRelease: Bool = true) {
        self.toolName = toolName
        script = HarnessScript(actions ?? [.calls([toolName]), .text(answer)])
        state.output = { [weak self] _ in
            guard let self else { throw HarnessFixtureFailure() }
            beforeAction()
            permissions.append(await permits())
            if waitForRelease {
                await withCheckedContinuation { continuation in
                    gate.submit { continuation.resume() }
                }
            }
            let allowed = await permits()
            permissions.append(allowed)
            return "publication=\(allowed[0]) purchase=\(allowed[1])"
        }
    }

    private func permits() async -> [Bool] {
        let publication = await AgentActionConsent.permit(
            label: "Publish", category: .publication, host: "turn.example.test"
        )
        let purchase = await AgentActionConsent.permit(
            label: "Buy", category: .purchase, host: "turn.example.test"
        )
        return [publication, purchase]
    }
}

@MainActor
private struct ContextProviders: ModelProviderResolving {
    let turns: [String: ContextTurn]

    func resolve(_ configuration: Provider) -> any ModelProvider {
        ContextProvider(configuration: configuration, turns: turns)
    }
}

@MainActor
private struct ContextProvider: ModelProvider {
    let configuration: Provider
    let turns: [String: ContextTurn]
    let capabilities: ModelProviderCapabilities = [.toolCalling]
    let availability: ModelProviderAvailability = .available

    func availableModels() async throws -> [String] {
        []
    }

    func makeAgent(
        model: String, reasoningEffort: LLMSettings.ReasoningEffort,
        toolkit: AgentToolkit, log: ConversationLog
    ) -> any AgentRunner {
        let turn = turns[configuration.id + "/" + model]
        return AnyLanguageModelAgent(
            name: configuration.name, modelID: model,
            executionPolicy: .init(requiresOutcomeVerification: false),
            toolOverrides: turn.map { [HarnessTool(name: $0.toolName, state: $0.state)] } ?? [],
            model: turn?.script ?? HarnessScript([.text("Wrong profile model selected.")]),
            options: GenerationOptions(),
            budget: ContextBudget(
                windowTokens: 128_000, responseTokens: 2_000, inputTokens: 100_000,
                toolSchemaTokens: 0, instructionTier: .compact, toolTier: .full,
                toolOutput: .standard, retainedExchanges: 12, retainedToolRounds: 1
            ),
            toolkit: toolkit, log: log
        )
    }
}
