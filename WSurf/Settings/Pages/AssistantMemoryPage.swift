// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// Settings › Assistant › Memory: the notes the assistant keeps about the person in this profile, to see, edit and forget, and
/// the switch that turns memory on. A private window keeps no notes, so its page says so and offers nothing to change.
struct AssistantMemoryPage: View {
    let facts: AssistantFacts?
    let onBack: () -> Void

    @State private var isEnabled: Bool
    @State private var query = ""
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var editRefused = false
    @State private var confirmingForgetAll = false
    @State private var confirmingTurnOff = false

    init(facts: AssistantFacts?, onBack: @escaping () -> Void) {
        self.facts = facts
        self.onBack = onBack
        _isEnabled = State(initialValue: facts?.isEnabled ?? false)
    }

    /// The drill-in row on the Assistant page.
    struct OverviewSection: View {
        let facts: AssistantFacts?
        let open: () -> Void

        var body: some View {
            SettingsSection(title: "Memory", symbol: "square.and.pencil") {
                DrillInRow(
                    title: "Memory",
                    caption: "Notes about you that the assistant keeps on this Mac.",
                    detail: AssistantMemoryPage.summary(for: facts),
                    action: open
                )
            }
        }
    }

    static func summary(for facts: AssistantFacts?) -> LocalizedStringResource {
        guard let facts else { return "Not in private windows" }
        guard facts.isEnabled else { return "Off" }
        return facts.facts.isEmpty ? "None" : "\(facts.facts.count) notes"
    }

    /// Turning memory off, from the "Also forget everything?" question.
    static func turnOff(_ facts: AssistantFacts, forgettingEverything: Bool) {
        facts.isEnabled = false
        if forgettingEverything {
            facts.forgetAll()
        }
    }

    var body: some View {
        SubPageHeader(backTitle: "Assistant", onBack: onBack)

        SettingsPageHeader(
            title: "Memory",
            caption: "What the assistant remembers about you. It saves your answers and what you ask it to remember. It never saves page content, passwords, or payment details."
        )

        if let facts {
            content(facts)
        } else {
            SettingsCard {
                SettingsEmptyState(
                    symbol: "eye.slash",
                    title: "Not available in private windows",
                    caption: "A private window keeps no notes about you, and the assistant uses none there."
                )
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder private func content(_ facts: AssistantFacts) -> some View {
        SettingsCard {
            DetailRow(
                title: "Remember things about me",
                caption: isEnabled && !AnyLanguageModelAgent.isSystemModelAvailable
                    ? "New notes need Apple Intelligence, which is off or unavailable. The assistant still uses the notes it has."
                    : "When this is off, the assistant can’t save or recall anything."
            ) {
                SettingsToggle(Binding(
                    get: { isEnabled },
                    set: { on in
                        if !on, !facts.facts.isEmpty {
                            confirmingTurnOff = true
                        } else {
                            facts.isEnabled = on
                            isEnabled = on
                        }
                    }
                ))
            }
            .settingsAnchor("assistant.memory")
        }
        .padding(.top, 6)
        .confirmationDialog("Also forget everything?", isPresented: $confirmingTurnOff) {
            Button("Forget Everything", role: .destructive) {
                Self.turnOff(facts, forgettingEverything: true)
                isEnabled = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Keep Notes") {
                Self.turnOff(facts, forgettingEverything: false)
                isEnabled = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Memory turns off either way. Kept notes stay on this Mac until you forget them.")
        }

        if facts.facts.count > 5 {
            SearchFieldChrome {
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.secondary)
                    .fieldPlaceholder("Search memory", isShowing: query.isEmpty)
            }
            .padding(.top, 12)
        }

        SettingsSection(
            title: "Notes",
            symbol: "square.and.pencil",
            footnote: """
                Notes are written on this Mac. When you use a cloud model, the notes it needs are sent with your request. \
                Forgetting a note stops it being used. Earlier conversations keep what they said.
                """
        ) {
            let shown = Self.matching(query, in: facts.facts)
            if facts.facts.isEmpty {
                SettingsEmptyState(
                    symbol: "square.and.pencil",
                    title: "Nothing remembered",
                    caption: "Things appear here when you answer the assistant or ask it to remember something."
                )
            } else if shown.isEmpty {
                SettingsEmptyState(symbol: "magnifyingglass", title: "No matches", caption: "Try a different word.")
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 {
                        RowSeparator()
                    }
                    row(for: fact, in: facts)
                }
            }
        }
        .padding(.top, 6)

        if !facts.facts.isEmpty {
            SectionActions {
                SettingsButton(title: "Forget All…", isDestructive: true, symbol: "trash") {
                    confirmingForgetAll = true
                }
            }
            .confirmationDialog("Forget everything the assistant remembers?", isPresented: $confirmingForgetAll) {
                Button("Forget All", role: .destructive) { facts.forgetAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The assistant will ask again when it needs these details.")
            }
        }
    }

    static func matching(_ query: String, in facts: [AssistantFacts.Fact]) -> [AssistantFacts.Fact] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return facts }
        return facts.filter { $0.subject.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle) }
    }

    @ViewBuilder private func row(for fact: AssistantFacts.Fact, in facts: AssistantFacts) -> some View {
        if editingID == fact.id {
            DetailRow(
                verbatimTitle: Self.title(for: fact),
                verbatimCaption: editRefused
                    ? String(localized: "This can’t be saved. It is too long, or it looks like a password, code or number.") : nil,
                layout: .stacked
            ) {
                HStack(spacing: 8) {
                    FieldChrome(isFocused: true) {
                        TextField("", text: $draft)
                            .textFieldStyle(.plain)
                            .onSubmit { save(fact, in: facts) }
                    }
                    SettingsButton(title: "Save") { save(fact, in: facts) }
                    SettingsButton(title: "Cancel") { editingID = nil }
                }
            }
        } else {
            DetailRow(verbatimTitle: Self.title(for: fact), verbatimCaption: fact.value + " · " + Self.origin(of: fact)) {
                HStack(spacing: 8) {
                    SettingsButton(title: "Edit") {
                        draft = fact.value
                        editRefused = false
                        editingID = fact.id
                    }
                    SettingsButton(title: "Forget", isDestructive: true) {
                        facts.forget(fact.id)
                    }
                }
            }
        }
    }

    private func save(_ fact: AssistantFacts.Fact, in facts: AssistantFacts) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != fact.value else {
            editingID = nil
            return
        }
        editRefused = facts.update(fact, to: value) == nil
        if !editRefused {
            editingID = nil
        }
    }

    private static func title(for fact: AssistantFacts.Fact) -> String {
        fact.subject.prefix(1).uppercased() + fact.subject.dropFirst()
    }

    private static func origin(of fact: AssistantFacts.Fact) -> String {
        let day = fact.savedAt.formatted(date: .abbreviated, time: .omitted)
        switch fact.source {
        case .answer:
            return String(localized: "Saved \(day) from your answer")
        case .message:
            return String(localized: "Saved \(day) from your message")
        case .model:
            return String(localized: "Saved \(day) by the assistant")
        }
    }
}
