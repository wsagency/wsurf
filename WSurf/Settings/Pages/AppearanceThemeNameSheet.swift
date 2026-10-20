// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What the theme name sheet is for.
enum ThemeNaming: Identifiable {
    /// Saves the shown theme as a new one, suggesting `name`.
    case save(name: String)
    case rename(ThemeDefinition)

    var id: String {
        switch self {
        case .save:
            "save"
        case .rename(let theme):
            "rename-\(theme.id)"
        }
    }
}

/// Asks for a theme's name: when saving the shown theme and when renaming a saved one. Names are trimmed and made
/// unique by the settings, so the sheet only keeps an empty or too long name from being sent.
struct ThemeNameSheet: View {
    let naming: ThemeNaming
    let commit: (String) -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(naming: ThemeNaming, commit: @escaping (String) -> Void) {
        self.naming = naming
        self.commit = commit
        switch naming {
        case .save(let name):
            _name = State(initialValue: name)
        case .rename(let theme):
            _name = State(initialValue: theme.name)
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var title: LocalizedStringResource {
        switch naming {
        case .save:
            "Save as Theme"
        case .rename:
            "Rename Theme"
        }
    }

    private var confirmTitle: LocalizedStringResource {
        switch naming {
        case .save:
            "Save"
        case .rename:
            "Rename"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.Font.row).fontWeight(.semibold)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Theme name")
                .focused($isFocused)
                .onSubmit(save)
            if trimmed.count > ThemeDefinition.nameLimit {
                Text("Use at most \(ThemeDefinition.nameLimit) characters.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    Text(confirmTitle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ThemeNames.isAcceptable(name))
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard ThemeNames.isAcceptable(name) else { return }
        commit(trimmed)
        dismiss()
    }
}
