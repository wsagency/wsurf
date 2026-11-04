// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

/// Linen's preference step (`AgentRequestConstraints.preference`, `AgentToolkit.preferenceRefusal`): a request that names a preference
/// only the person knows, such as "my usual colour", is not acted on until the assistant has asked them with askUser, unless a note
/// already answers it. The first page change before that is refused once, with nothing changed, and the first prompt says why.
///
/// The question counts as answered only when the question model handed back a reply the person gave (`AgentQuestionModel`'s `given`
/// answers). Nothing here reads the askUser transcript, which a page or the model can write into.
nonisolated struct AgentPreferenceGate: Sendable, Equatable {
    /// The tools that change a page by its controls (Linen's list).
    static let actions: Set<String> = ["clickOnPage", "typeOnPage", "fillFields", "selectOption", "setChecked"]

    /// The preference the request names and no note answers, such as "my usual colour"; nil when there is none.
    let preference: String?
    private(set) var isAnswered = false
    private(set) var wasReminded = false

    /// `isKnown` says whether a note answers the preference the request names.
    init(request: String, isKnown: (String) -> Bool) {
        preference = Self.preference(in: request).flatMap { isKnown($0) ? nil : $0 }
    }

    /// "my usual colour" in "Set the lamp to my usual colour."
    static func preference(in request: String) -> String? {
        let text = request.lowercased()
        return text.range(of: #"\bmy (usual|favou?rite|preferred|regular|normal|own) [a-z]+"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// The line the first prompt carries while the preference is unknown.
    var hint: String {
        guard let preference else { return "" }
        return "[The request mentions “\(preference)”, which you do not know. Ask the user with askUser before you change anything.]\n"
    }

    /// The person's own replies from one askUser call; an empty list (skipped, cancelled, or no one there) answers nothing.
    mutating func noteAnswers(_ given: [String]) {
        if given.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            isAnswered = true
        }
    }

    /// The refusal for the first page change while the preference is still unknown; nil for every other call, and after it once.
    mutating func refusal(for toolName: String) -> String? {
        guard let preference, !isAnswered, !wasReminded, Self.actions.contains(toolName) else { return nil }
        wasReminded = true
        return "This request depends on \(preference), which only the user knows. Nothing was changed. Ask them with askUser first."
    }
}
