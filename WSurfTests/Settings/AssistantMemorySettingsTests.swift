// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Settings › Assistant › Memory: the row's summary, editing, forgetting, turning memory off, and the private-window state.
@MainActor
struct AssistantMemorySettingsTests {
    private func store(remembers: Bool = true) -> AssistantFacts {
        let defaults = InMemoryUserDefaults(
            inheriting: UserDefaults(suiteName: AppDatabase.defaultsSuite("AssistantMemorySettingsTests-\(UUID().uuidString)"))!
        )
        let settings = LLMSettings(defaults: defaults)
        settings.remembersFacts = remembers
        return AssistantFacts(database: .temporary(), settings: settings)
    }

    @Test func theRowSaysWhatTheAssistantRemembers() {
        let facts = store(remembers: false)
        #expect(String(localized: AssistantMemoryPage.summary(for: facts)) == "Off")

        facts.isEnabled = true
        #expect(String(localized: AssistantMemoryPage.summary(for: facts)) == "None")

        facts.remember("diet", is: "vegetarian", source: .message)
        facts.remember("shoe size", is: "42", source: .answer)
        #expect(String(localized: AssistantMemoryPage.summary(for: facts)) == "2 notes")
    }

    @Test func aPrivateWindowHasNothingToShow() {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        #expect(context.assistantFacts == nil)
        #expect(String(localized: AssistantMemoryPage.summary(for: context.assistantFacts)) == "Not in private windows")
    }

    @Test func editingANoteKeepsItsSubjectAndWorksWithMemoryOff() throws {
        let facts = store()
        let note = try #require(facts.remember("usual colour", is: "Black", source: .answer))
        facts.isEnabled = false

        let edited = try #require(facts.update(note, to: "Brass"))

        #expect(edited.id == note.id)
        #expect(facts.facts.map(\.value) == ["Brass"])
        #expect(facts.facts.first?.source == .answer)
    }

    @Test func anEditThatLooksSensitiveIsRefusedAndTheNoteStays() throws {
        let facts = store()
        let note = try #require(facts.remember("bank", is: "Example Bank", source: .message))

        #expect(facts.update(note, to: "PIN 4821") == nil)
        #expect(facts.update(note, to: "4111 1111 1111 1111") == nil)
        #expect(facts.update(note, to: String(repeating: "a", count: AssistantFacts.valueLimit + 1)) == nil)
        #expect(facts.facts.map(\.value) == ["Example Bank"])
    }

    @Test func turningMemoryOffCanForgetEverythingOrKeepTheNotes() {
        let forgetting = store()
        forgetting.remember("diet", is: "vegetarian", source: .message)
        AssistantMemoryPage.turnOff(forgetting, forgettingEverything: true)
        #expect(!forgetting.isEnabled)
        #expect(forgetting.facts.isEmpty)

        let keeping = store()
        keeping.remember("diet", is: "vegetarian", source: .message)
        AssistantMemoryPage.turnOff(keeping, forgettingEverything: false)
        #expect(!keeping.isEnabled)
        #expect(keeping.facts.map(\.value) == ["vegetarian"])
    }

    @Test func forgettingOneNoteOrAllOfThem() throws {
        let facts = store()
        let diet = try #require(facts.remember("diet", is: "vegetarian", source: .message))
        facts.remember("shoe size", is: "42", source: .message)

        facts.forget(diet.id)
        #expect(facts.facts.map(\.subject) == ["shoe size"])
        facts.forgetAll()
        #expect(facts.facts.isEmpty)
    }

    @Test func searchMatchesSubjectsAndValues() {
        let facts = store()
        facts.remember("diet", is: "Vegetarian", source: .message)
        facts.remember("home city", is: "Zagreb", source: .message)

        #expect(AssistantMemoryPage.matching("veg", in: facts.facts).map(\.subject) == ["diet"])
        #expect(AssistantMemoryPage.matching("CITY", in: facts.facts).map(\.subject) == ["home city"])
        #expect(AssistantMemoryPage.matching("  ", in: facts.facts).count == 2)
    }

    @Test func theMemoryPageIsFoundBySearch() throws {
        let entry = try #require(SettingsIndex.all.first { $0.id == "assistant.memory" })
        #expect(entry.category == .provider)
        for query in ["memory", "remember", "about me", "forget"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "assistant.memory" }, "\(query)")
        }
    }
}
