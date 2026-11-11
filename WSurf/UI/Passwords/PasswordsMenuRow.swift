// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// One credential in the popover: its title and what tells it from the others, never a value. Clicking copies its password (its
/// username when it has none), after Touch ID. The "…" menu and VoiceOver's actions offer the rest.
struct PasswordsMenuRow: View {
    let summary: CredentialSummary
    let isSelected: Bool
    let perform: (PasswordsMenuAction) -> Void

    private var offered: [PasswordsMenuAction] {
        PasswordsMenuAction.offered(for: summary)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let primary = PasswordsMenuAction.primary(for: summary) {
                    perform(primary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: summary.menuTitle).lineLimit(1)
                    if !summary.menuDetail.isEmpty {
                        Text(verbatim: summary.menuDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                ForEach(offered, id: \.self) { action in
                    Button(action.title) { perform(action) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More Actions"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        // A row is one element for VoiceOver, with the same actions the menu has.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary.menuLabel))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            ForEach(offered, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
    }
}

/// What a row draws of a credential. The title and the username are text a website supplied (a prefilled username that was saved), and
/// this popover sits over other apps: bidi, control and line-break characters are removed here (`displaySafe`), as the passkey prompts do.
/// Display only; the stored value, what is copied and what is searched never go through it.
nonisolated extension CredentialSummary {
    var menuTitle: String {
        title.displaySafe
    }

    /// The username and the website's host, each cleaned, empty ones left out.
    var menuDetail: String {
        [username, website?.host()].compactMap { $0 }.map { $0.displaySafe }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var menuLabel: String {
        [menuTitle, menuDetail].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
