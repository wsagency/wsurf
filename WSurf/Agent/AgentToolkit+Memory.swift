// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel
import Foundation

/// Assistant memory for the in-app assistant only: connected apps have no path to it. Linen's preference gate (refusing control
/// until the assistant asks about an unknown preference) is not ported; WSurf's consent and policy layers gate control.
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

    /// Asks `model` which notes `said` adds, changes or forgets, and keeps them. Nothing is kept when the task was cancelled or
    /// the window changed profile while the model worked. The store's filter still refuses anything that looks sensitive.
    func writeFacts(from said: String, using model: any LanguageModel) async {
        guard !said.isEmpty, let facts = assistantFacts, facts.isEnabled else { return }
        let changes = await AssistantFactWriter.changes(said: said, notes: facts.facts, model: model)
        guard !Task.isCancelled, assistantFacts === facts else { return }
        for change in changes {
            let kept = facts.facts.first { $0.subject == AssistantFacts.normalized(change.subject) }
            if change.forget {
                if let kept {
                    facts.forget(kept.id)
                }
            } else if kept?.value != change.value {
                facts.remember(change.subject, is: change.value, source: .message)
            }
        }
    }
}
