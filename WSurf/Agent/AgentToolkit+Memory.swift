// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import Foundation

/// Assistant memory for the in-app assistant only: connected apps have no path to it. Linen's preference step, asking about a
/// preference the assistant does not know before acting, is `AgentPreferenceGate`, kept by the run.
extension AgentToolkit {
    /// What the person typed, without the "[Pages in context: …]" block the turn puts before it. A continuation has none.
    nonisolated static func userText(of utterance: String) -> String {
        guard utterance.hasPrefix("[Pages in context:"), let end = utterance.range(of: "]\n") else { return utterance }
        return String(utterance[end.upperBound...])
    }

    /// The notes for the first prompt of a new task; empty while memory is off and in a private window.
    func rememberedContext() -> String {
        guard let facts = assistantFacts, facts.isEnabled else { return "" }
        return AssistantFacts.context(for: facts.facts)
    }

    /// Whether a note answers `preference` ("my usual colour"). Never while memory is off or in a private window: then the assistant
    /// asks.
    func knowsPreference(_ preference: String) -> Bool {
        guard let facts = assistantFacts, facts.isEnabled else { return false }
        return facts.fact(about: preference) != nil
    }

    /// Asks `model` which notes `said` adds, changes or forgets, and keeps them. Nothing is kept when the task was cancelled or
    /// the window changed profile while the model worked. The store's filter still refuses anything that looks sensitive. Returns the
    /// notes written, for the "Remembered …" line.
    @discardableResult
    func writeFacts(from said: String, using model: any LanguageModel) async -> [AgentMemoryUpdate] {
        guard !said.isEmpty, let facts = assistantFacts, facts.isEnabled else { return [] }
        let changes = await AssistantFactWriter.changes(said: said, notes: facts.facts, model: model)
        guard !Task.isCancelled, assistantFacts === facts else { return [] }
        var updates: [AgentMemoryUpdate] = []
        for change in changes {
            let kept = facts.facts.first { $0.subject == AssistantFacts.normalized(change.subject) }
            if change.forget {
                if let kept {
                    facts.forget(kept.id)
                }
            } else if kept?.value != change.value, let fact = facts.remember(change.subject, is: change.value, source: .message) {
                // A subject written twice in one go keeps the value it had before the first write, for Undo.
                let earlier = updates.firstIndex { $0.factID == fact.id }
                let previous = earlier.map { updates[$0].previous } ?? kept?.value
                updates.removeAll { $0.factID == fact.id }
                updates.append(AgentMemoryUpdate(factID: fact.id, subject: fact.subject, value: fact.value, previous: previous))
            }
        }
        return updates
    }
}
