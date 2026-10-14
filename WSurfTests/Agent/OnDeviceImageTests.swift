// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import Foundation
import Testing

@testable import WSurf

@MainActor
struct OnDeviceImageTests {
    private static let image = Transcript.ImageSegment(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")

    @Test func onDeviceAgentGetsAttachmentsButNeverScreenshotTools() {
        let onDevice = makeAgent(model: SystemLanguageModel.default)
        let hosted = makeAgent(model: HarnessScript([]))

        #expect(onDevice.acceptsImages)
        #expect(!onDevice.seesScreenshots)
        #expect(Set(onDevice.makeSession().tools.map(\.name)).isDisjoint(with: AgentToolCatalog.visualToolIDs))
        #expect(hosted.seesScreenshots)
        #expect(!Set(hosted.makeSession().tools.map(\.name)).isDisjoint(with: AgentToolCatalog.visualToolIDs))
    }

    @Test func aHostedModelWithoutImageInputStillLosesScreenshotTools() {
        let textOnly = makeAgent(model: HarnessScript([]), acceptsImages: false)

        #expect(!textOnly.seesScreenshots)
        #expect(Set(textOnly.makeSession().tools.map(\.name)).isDisjoint(with: AgentToolCatalog.visualToolIDs))
    }

    @Test(arguments: [true, false])
    func aPendingScreenshotReachesOnlyModelsThatSeeScreenshots(onDevice: Bool) async {
        let state = HarnessToolState()
        let agent = makeAgent(
            model: onDevice ? SystemLanguageModel.default : HarnessScript([]),
            toolOverrides: [HarnessTool(name: "readPage", state: state)]
        )
        state.output = { _ in
            agent.toolkit.setComputerScreenshot(Data("screenshot".utf8))
            return "Page text"
        }
        let call = Transcript.ToolCall(
            id: "call", toolName: "readPage", arguments: GeneratedContent(properties: ["value": GeneratedContent("x")])
        )

        let (output, failed) = await agent.execute(call: call, reply: AgentReplyModel(), event: { _, _ in })

        #expect(!failed)
        #expect(Self.imageCount(in: output.segments) == (onDevice ? 0 : 1))
        #expect(AnyLanguageModelAgent.text(in: output.segments).contains("Page text"))
        #expect(agent.toolkit.takePendingScreenshot() == nil)
    }

    @Test func restoredOnDeviceSessionKeepsPromptImagesButNotToolImages() {
        let session = makeAgent(model: SystemLanguageModel.default).makeSession(transcript: Self.transcript)

        #expect(Self.imageCounts(session.transcript) == [1, 0])
    }

    @Test func restoredHostedSessionKeepsBothImages() {
        let session = makeAgent(model: HarnessScript([])).makeSession(transcript: Self.transcript)

        #expect(Self.imageCounts(session.transcript) == [1, 1])
    }

    @Test func restoredSessionWithoutImageInputDropsEveryImage() {
        let session = makeAgent(model: SystemLanguageModel.default, acceptsImages: false)
            .makeSession(transcript: Self.transcript)

        #expect(Self.imageCounts(session.transcript) == [0, 0])
    }

    @Test func withoutToolImagesKeepsPromptImagesAndToolText() {
        let stripped = ModelImageSupport.withoutToolImages(Self.transcript)
        let toolText = stripped.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry else { return nil }
            return AnyLanguageModelAgent.text(in: output.segments)
        }

        #expect(Self.imageCounts(stripped) == [1, 0])
        #expect(toolText == ["Page"])
    }

    @Test func hostedImageSupportStaysPerWindowSettings() {
        let suites = [UUID().uuidString, UUID().uuidString]
        let defaults = suites.map { UserDefaults(suiteName: $0)! }
        defer { zip(defaults, suites).forEach { $0.removePersistentDomain(forName: $1) } }
        let rejecting = LLMSettings(defaults: defaults[0])
        let untouched = LLMSettings(defaults: defaults[1])
        let provider = ProviderCatalog.openAI

        ModelImageSupport.record(false, for: provider, model: "m", settings: rejecting)

        #expect(!ModelImageSupport.acceptsImages(for: provider, model: "m", settings: rejecting))
        #expect(ModelImageSupport.acceptsImages(for: provider, model: "m", settings: untouched))
    }

    private static var transcript: Transcript {
        Transcript(entries: [
            .prompt(.init(segments: [.text(.init(content: "What is this?")), .image(image)])),
            .toolOutput(.init(id: "call", toolName: "screenshotPage", segments: [.text(.init(content: "Page")), .image(image)])),
        ])
    }

    /// Image segments per transcript entry, so a dropped entry fails the comparison too.
    private static func imageCounts(_ transcript: Transcript) -> [Int] {
        transcript.map { entry in
            switch entry {
            case .prompt(let prompt):
                return imageCount(in: prompt.segments)
            case .toolOutput(let output):
                return imageCount(in: output.segments)
            default:
                return 0
            }
        }
    }

    private static func imageCount(in segments: [Transcript.Segment]) -> Int {
        segments.filter {
            if case .image = $0 {
                return true
            }
            return false
        }.count
    }

    private func makeAgent(
        model: any LanguageModel, acceptsImages: Bool = true, toolOverrides: [any Tool]? = nil
    ) -> AnyLanguageModelAgent {
        let log = ConversationLog(database: .temporary())
        return AnyLanguageModelAgent(
            name: "fixture", modelID: "fixture", toolOverrides: toolOverrides, model: model, options: GenerationOptions(),
            budget: ContextBudget(windowTokens: 128_000, responseTokens: 2_000, inputTokens: 100_000, toolSchemaTokens: 0,
                                  instructionTier: .compact, toolTier: .full, toolOutput: .standard, retainedExchanges: 12,
                                  retainedToolRounds: 1),
            acceptsImages: acceptsImages,
            enabledToolIDs: toolOverrides == nil ? AgentToolCatalog.visualToolIDs : nil,
            toolkit: AgentToolkit(browser: BrowserModel(database: .temporary()), media: MediaCenter(), log: log),
            log: log
        )
    }
}
