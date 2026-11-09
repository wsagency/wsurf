// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

struct AutofillPasswordField: View {
    @Binding var password: String
    /// Adds a copy button; the save review leaves it out.
    var copy: (() -> Void)?
    /// Asked before the field shows what it holds (the Credential Manager's editor asks for Touch ID); `false` keeps it masked. Hiding
    /// never asks. The save review leaves it out: what it shows was just typed on the page.
    var reveal: (() async -> Bool)?
    /// Whether the field may show what it holds at all; `false` keeps it masked whatever was clicked before. The editor passes
    /// whether it has answered its one prompt, which a replaced editor has not, though the field's own state stays.
    var mayReveal = true
    @State private var isRevealed = false
    /// Set while `reveal` is asked, so a second click starts no second prompt.
    @State private var isAsking = false
    /// Counts the times the field went away, so an answer that comes back after that shows nothing.
    @State private var disappearances = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case hidden, revealed
    }

    private var shows: Bool {
        isRevealed && mayReveal
    }

    var body: some View {
        LabeledContent("Password") {
            HStack(spacing: 6) {
                Group {
                    if shows {
                        TextField("Password", text: $password)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .revealed)
                    } else {
                        SecureField("Password", text: $password)
                            .focused($focusedField, equals: .hidden)
                    }
                }
                .labelsHidden()
                .privacySensitive()
                Button(action: toggle) {
                    Image(systemName: shows ? "eye.slash" : "eye")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isAsking)
                .accessibilityLabel(shows ? "Hide password" : "Show password")
                .help(shows ? "Hide password" : "Show password")
                if let copy {
                    CredentialCopyButton(label: "Copy Password", action: copy).disabled(password.isEmpty)
                }
            }
        }
        .onDisappear {
            isRevealed = false
            isAsking = false
            disappearances += 1
        }
    }

    private func toggle() {
        guard !shows, let reveal else {
            show(!shows)
            return
        }
        isAsking = true
        let asked = disappearances
        Task {
            let allowed = await reveal()
            guard asked == disappearances else { return }
            isAsking = false
            if allowed {
                show(true)
            }
        }
    }

    private func show(_ revealed: Bool) {
        isRevealed = revealed
        focusedField = revealed ? .revealed : .hidden
    }
}
