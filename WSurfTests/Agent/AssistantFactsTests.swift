// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct AssistantFactsTests {
    /// Empty defaults that never reach a preference file.
    private func freshDefaults() -> InMemoryUserDefaults {
        // ponytail-merge: test-hygiene routes every test suite through `defaultsSuite`; this wave-2a suite now does too.
        InMemoryUserDefaults(inheriting: UserDefaults(suiteName: AppDatabase.defaultsSuite("AssistantFactsTests-\(UUID().uuidString)"))!)
    }

    private func settings(remembers: Bool = true) -> LLMSettings {
        let settings = LLMSettings(defaults: freshDefaults())
        if remembers {
            settings.remembersFacts = true
        }
        return settings
    }

    private func store(remembers: Bool = true, database: AppDatabase = .temporary()) -> AssistantFacts {
        AssistantFacts(database: database, settings: settings(remembers: remembers))
    }

    @Test func aFactIsSavedOnceAndUpdatedInPlace() throws {
        let facts = store()

        let first = try #require(facts.remember("My usual colour", is: "Black", source: .answer))
        let second = try #require(facts.remember("usual colour", is: "Brass.", source: .message))

        #expect(first.id == second.id)
        #expect(facts.facts.map(\.value) == ["Brass"])
        #expect(facts.facts.first?.subject == "usual colour")
    }

    @Test func notesSurviveReopeningTheDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantFacts-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = settings()
        AssistantFacts(database: AppDatabase(at: url), settings: shared).remember("shoe size", is: "42", source: .message)

        let reopened = AssistantFacts(database: AppDatabase(at: url), settings: shared)
        #expect(reopened.facts.map(\.value) == ["42"])
    }

    @Test func rememberingIsOffUntilThePersonTurnsItOn() {
        let defaults = freshDefaults()
        let settings = LLMSettings(defaults: defaults)
        #expect(!settings.remembersFacts)
        let facts = AssistantFacts(database: .temporary(), settings: settings)

        #expect(facts.remember("shoe size", is: "42", source: .message) == nil)
        #expect(facts.facts.isEmpty)

        settings.remembersFacts = true
        #expect(defaults.object(forKey: "assistant.facts.enabled") as? Bool == true)
        #expect(facts.remember("shoe size", is: "42", source: .message) != nil)
    }

    @Test func theSettingBelongsToOneProfile() {
        let work = LLMSettings(defaults: freshDefaults())
        let home = LLMSettings(defaults: freshDefaults())
        work.remembersFacts = true

        #expect(work.remembersFacts)
        #expect(!home.remembersFacts)
    }

    @Test func emptyAndOverlongNotesAreRefused() {
        let facts = store()

        #expect(facts.remember("  ", is: "value", source: .message) == nil)
        #expect(facts.remember("subject", is: " . ", source: .message) == nil)
        #expect(facts.remember("hobby", is: String(repeating: "a", count: AssistantFacts.valueLimit + 1), source: .message) == nil)
        #expect(facts.remember(String(repeating: "b", count: AssistantFacts.subjectLimit + 1), is: "x", source: .message) == nil)
        #expect(facts.remember("hobby", is: String(repeating: "a", count: AssistantFacts.valueLimit), source: .message) != nil)
        #expect(facts.facts.count == 1)
    }

    @Test func onlyTheNewestNotesAreKept() {
        let facts = store()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        for index in 0...AssistantFacts.capacity {
            facts.remember("note \(index)", is: "value", source: .message, at: start.addingTimeInterval(Double(index)))
        }

        #expect(facts.facts.count == AssistantFacts.capacity)
        #expect(facts.facts.first?.subject == "note \(AssistantFacts.capacity)")
        #expect(!facts.facts.contains { $0.subject == "note 0" })

        // Updating an old note makes it the newest, so it is not the next one dropped.
        facts.remember("note 1", is: "changed", source: .message, at: start.addingTimeInterval(100))
        facts.remember("note extra", is: "value", source: .message, at: start.addingTimeInterval(101))
        #expect(facts.facts.contains { $0.subject == "note 1" })
        #expect(!facts.facts.contains { $0.subject == "note 2" })
    }

    @Test(arguments: [
        ("bank card", "4242 4242 4242 4242"),
        ("card", "5555-5555-5555-4444"),
        ("salary account", "DE89 3704 0044 0532 0130 00"),
        ("email password", "hunter2"),
        ("note", "my password is hunter2"),
        ("bank pin", "1234"),
        ("login", "verification code 482913"),
        ("otp", "482913"),
        ("github", "api key ghp_abc"),
        ("wallet", "seed phrase apple banana"),
        ("passport", "X1234567"),
        ("phone", "+385 91 234 5678"),
    ])
    func sensitiveDetailsAreNeverSaved(subject: String, value: String) {
        let facts = store()

        #expect(facts.remember(subject, is: value, source: .message) == nil)
        #expect(facts.facts.isEmpty)
    }

    @Test(arguments: [
        ("shoe size", "42"),
        ("home city", "Zagreb"),
        ("diet", "vegetarian"),
        ("usual coffee", "2 sugars"),
        ("birth year", "1984"),
    ])
    func ordinaryDetailsAreSaved(subject: String, value: String) {
        #expect(store().remember(subject, is: value, source: .message) != nil)
    }

    @Test func forgettingRemovesOneOrEveryNote() throws {
        let facts = store()
        let shoe = try #require(facts.remember("shoe size", is: "42", source: .message))
        facts.remember("diet", is: "vegetarian", source: .message)

        facts.forget(shoe.id)
        #expect(facts.facts.map(\.subject) == ["diet"])

        facts.forgetAll()
        #expect(facts.facts.isEmpty)
    }

    /// Forgetting still works with the setting off, so turning it off never strands a note.
    @Test func forgettingWorksWithTheSettingOff() throws {
        let settings = settings()
        let facts = AssistantFacts(database: .temporary(), settings: settings)
        facts.remember("diet", is: "vegetarian", source: .message)
        settings.remembersFacts = false

        facts.forgetAll()
        #expect(facts.facts.isEmpty)
    }

    @Test func aPrivateWindowHasNoStore() {
        #expect(BrowserProfileContext(profile: .privateBrowsing()).assistantFacts == nil)
    }

    @Test func aProfileKeepsItsOwnNotes() throws {
        let work = BrowserProfileContext(profile: Profile(id: UUID(), name: "Facts work", symbol: "briefcase", color: .blue))
        let home = BrowserProfileContext(profile: Profile(id: UUID(), name: "Facts home", symbol: "house", color: .green))
        work.modelSettings.remembersFacts = true
        home.modelSettings.remembersFacts = true

        let workFacts = try #require(work.assistantFacts)
        let homeFacts = try #require(home.assistantFacts)
        workFacts.remember("shoe size", is: "42", source: .message)

        #expect(workFacts.facts.count == 1)
        #expect(homeFacts.facts.isEmpty)
    }

    @Test func mcpNeverNamesTheNotes() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "WSurf/MCP"), includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for name in ["AssistantFact", "assistantFact", "remembersFacts"] {
                #expect(!source.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
        #expect(scanned > 0)
    }
}
