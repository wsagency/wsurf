// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AnyLanguageModel
import Foundation
import Testing

@testable import WSurf

/// The assistant writes notes about the person after a task, with an injected stand-in for the on-device model, and uses them in
/// the first prompt of the next task.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct AssistantFactWriterTests {
    private func profile(remembers: Bool = true) -> BrowserProfileContext {
        let context = BrowserProfileContext(profile: Profile(id: UUID(), name: "Facts writer", symbol: "person", color: .blue))
        context.modelSettings.remembersFacts = remembers
        return context
    }

    private func fixture(
        _ actions: [HarnessScript.Action] = [],
        context: BrowserProfileContext,
        state: HarnessToolState? = nil,
        factModel: (() -> (any LanguageModel)?)?
    ) -> HarnessFixture {
        HarnessFixture(actions, state: state, browser: BrowserModel(context: context), factModel: factModel)
    }

    @Test func theWriterGetsOnlyTheTypedWordsAndTheAnswers() async throws {
        let context = profile()
        let state = HarnessToolState()
        state.output = { call in
            call == 1 ? "The page sells the Zeta lamp in Teal." : "Q: Which colour do you usually pick?\nA: Brass"
        }
        let writer = FactModel([("usual lamp colour", "Brass", false)])
        let subject = fixture([.calls(["readPage"]), .calls(["askUser"]), .text("Done.")], context: context, state: state) { writer }

        let id = await subject.run("[Pages in context:\n1. Lamps (shop.test) ← ACTIVE]\nSet the lamp to my usual colour")
        #expect(writer.prompts.isEmpty, "nothing is written before the turn model asks")
        await subject.agent.rememberFacts(fromTask: id)

        #expect(writer.prompts == [AssistantFactWriter.prompt(said: "Set the lamp to my usual colour\nBrass", notes: [])])
        for leaked in ["Zeta", "Teal", "shop.test", "Pages in context", "Which colour"] {
            #expect(!(writer.prompts.first ?? "").contains(leaked), "the writer saw \(leaked)")
        }
        #expect(context.assistantFacts?.facts.map(\.value) == ["Brass"])
        #expect(!subject.model.requests.contains { $0.contains("WHAT THE USER SAID") }, "the chat model is never asked to write notes")
    }

    @Test func aRequestToForgetRemovesTheNote() async throws {
        let context = profile()
        let facts = try #require(context.assistantFacts)
        facts.remember("shoe size", is: "42", source: .message)
        let subject = fixture(context: context) { FactModel([("My shoe size", "", true)]) }

        await subject.agent.rememberFacts(fromTask: await subject.run("Forget my shoe size"))

        #expect(facts.facts.isEmpty)
    }

    @Test func theStoreStillRefusesWhatLooksSensitive() async throws {
        let context = profile()
        let subject = fixture(context: context) { FactModel([("bank pin", "4821", false), ("diet", "vegetarian", false)]) }

        await subject.agent.rememberFacts(fromTask: await subject.run("My bank PIN is 4821 and I am vegetarian"))

        #expect(context.assistantFacts?.facts.map(\.subject) == ["diet"])
    }

    @Test func withoutTheOnDeviceModelNothingIsWritten() async throws {
        let context = profile()
        let subject = fixture(context: context) { nil }

        await subject.agent.rememberFacts(fromTask: await subject.run("My shoe size is 42"))

        #expect(context.assistantFacts?.facts.isEmpty == true)
        #expect(!subject.model.requests.contains { $0.contains("WHAT THE USER SAID") }, "the writer never falls back to the chat model")
    }

    @Test func nothingIsWrittenWhileMemoryIsOff() async throws {
        let context = profile(remembers: false)
        let writer = FactModel([("shoe size", "42", false)])
        let subject = fixture(context: context) { writer }

        await subject.agent.rememberFacts(fromTask: await subject.run("My shoe size is 42"))

        #expect(writer.prompts.isEmpty)
        #expect(context.assistantFacts?.facts.isEmpty == true)
    }

    @Test func aPrivateWindowNeitherWritesNorReadsNotes() async throws {
        let writer = FactModel([("shoe size", "42", false)])
        let subject = fixture(context: BrowserProfileContext(profile: .privateBrowsing()), factModel: { writer })

        await subject.agent.rememberFacts(fromTask: await subject.run("My shoe size is 42"))

        #expect(writer.prompts.isEmpty)
        #expect(subject.agent.toolkit.rememberedContext().isEmpty)
    }

    @Test func aProfileSwitchDuringTheWriteKeepsNothing() async throws {
        let context = profile()
        let other = profile()
        let writer = FactModel([("shoe size", "42", false)], waits: true)
        let browser = BrowserModel(context: context)
        let subject = HarnessFixture([], browser: browser, factModel: { writer })
        let id = await subject.run("My shoe size is 42")

        let writing = Task { await subject.agent.rememberFacts(fromTask: id) }
        try #require(await writer.gate.waitForRequest())
        browser.context = other
        writer.gate.open()
        await writing.value

        #expect(context.assistantFacts?.facts.isEmpty == true)
        #expect(other.assistantFacts?.facts.isEmpty == true)
    }

    @Test func aCancelledWriteKeepsNothing() async throws {
        let context = profile()
        let writer = FactModel([("shoe size", "42", false)], waits: true)
        let subject = fixture(context: context) { writer }
        let id = await subject.run("My shoe size is 42")

        let writing = Task { await subject.agent.rememberFacts(fromTask: id) }
        try #require(await writer.gate.waitForRequest())
        writing.cancel()
        writer.gate.open()
        await writing.value

        #expect(context.assistantFacts?.facts.isEmpty == true)
    }

    @Test func aCancelledTurnLeavesNothingToWrite() async throws {
        let context = profile()
        let state = HarnessToolState()
        state.output = { _ in
            try await Task.sleep(for: .seconds(60))
            return "late"
        }
        let writer = FactModel([("shoe size", "42", false)])
        let subject = fixture([.calls(["readPage"])], context: context, state: state) { writer }

        let turn = Task { await subject.run("My shoe size is 42") }
        try #require(await waitUntil { state.calls == 1 })
        turn.cancel()
        await subject.agent.rememberFacts(fromTask: await turn.value)

        #expect(writer.prompts.isEmpty)
        #expect(context.assistantFacts?.facts.isEmpty == true)
    }

    @Test func notesReachOnlyTheFirstPromptOfANewTask() async throws {
        let context = profile()
        try #require(context.assistantFacts).remember("diet", is: "vegetarian", source: .message)
        let subject = fixture(context: context, factModel: nil)

        await subject.run("Find a dinner recipe")
        await subject.run("", isContinuation: true)

        let first = try #require(subject.model.requests.first)
        #expect(first.hasPrefix("[What you remember about the user"))
        #expect(first.contains("diet: vegetarian"))
        #expect(first.contains("Find a dinner recipe"))
        #expect(!(subject.model.requests.last ?? "").contains("diet: vegetarian"))
    }

    @Test func notesAreLeftOutWhileMemoryIsOff() async throws {
        let context = profile()
        let facts = try #require(context.assistantFacts)
        facts.remember("diet", is: "vegetarian", source: .message)
        facts.isEnabled = false
        let subject = fixture(context: context, factModel: nil)

        await subject.run("Find a dinner recipe")

        #expect(!(subject.model.requests.first ?? "").contains("vegetarian"))
    }

    @Test func theNoteBlockIsBounded() {
        let facts = (0..<AssistantFacts.capacity + 5).map { index in
            AssistantFacts.Fact(
                id: UUID(), subject: "note \(index)", value: String(repeating: "x", count: AssistantFacts.valueLimit),
                source: .message, savedAt: Date()
            )
        }
        let block = AssistantFacts.context(for: facts)
        let listed = block.components(separatedBy: "note ").count - 1

        #expect(listed > 0 && listed < AssistantFacts.capacity)
        #expect(block.count <= AssistantFacts.contextLimit + 200)
        #expect(block.contains("note 0:"), "the newest notes come first")
        #expect(AssistantFacts.context(for: []).isEmpty)
    }

    @Test func onlyThePersonsOwnWordsAreKept() {
        #expect(AgentToolkit.userText(of: "[Pages in context:\n1. A (a.test)]\nHello") == "Hello")
        #expect(AgentToolkit.userText(of: "[Pages in context:\n1. A (a.test)]\n") == "")
        #expect(AgentToolkit.userText(of: "Plain request") == "Plain request")
        let output = """
            Q: Which colour?
            A: Brass
            Q: Which size?
            A: No preference, you choose from: S · M
            Choose sensible answers yourself for the rest and carry on, without asking again: Which shop?
            """
        #expect(AgentToolkit.answers(in: output) == ["Brass"])
        #expect(AgentToolkit.answers(in: "No one is there to answer. Carry on with what you have.").isEmpty)
    }

    /// Connected apps have no tool for memory, and the code they reach never names it.
    @Test func connectedAppsCannotReachMemory() throws {
        let tools = MCPToolCatalog.entries.map { "\($0.name)\n\($0.description)".lowercased() }
        #expect(tools.count > 10)
        for text in tools {
            for word in ["memory", "remember", "assistantfact"] {
                #expect(!text.contains(word), "an MCP tool mentions \(word): \(text.prefix(60))")
            }
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "WSurf/MCP"), includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for name in ["AssistantFact", "assistantFact", "rememberedContext", "writeFacts", "rememberFacts", "AssistantMemoryPage"] {
                #expect(!source.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
        #expect(scanned > 0)
    }
}

/// The on-device model's stand-in: it records what it was asked and answers with fixed note changes, optionally only once the
/// test opens its gate.
private final class FactModel: LanguageModel, @unchecked Sendable {
    let gate = ResponseGate()
    private let lock = NSLock()
    private var seen: [String] = []
    private let notes: [(subject: String, value: String, forget: Bool)]

    init(_ notes: [(subject: String, value: String, forget: Bool)], waits: Bool = false) {
        self.notes = notes
        if !waits {
            gate.open()
        }
    }

    var prompts: [String] {
        lock.withLock { seen }
    }

    func respond<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        lock.withLock { seen.append(prompt.description) }
        await withCheckedContinuation { continuation in
            gate.submit { continuation.resume() }
        }
        let changes = AssistantFactWriter.Changes(changes: notes.map {
            AssistantFactWriter.Change(subject: $0.subject, value: $0.value, forget: $0.forget)
        })
        guard let content = changes as? Content else { throw HarnessFixtureFailure() }
        return .init(content: content, rawContent: content.generatedContent, transcriptEntries: [])
    }

    func streamResponse<Content>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        preconditionFailure("The note writer does not stream")
    }
}
