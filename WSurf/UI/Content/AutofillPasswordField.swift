// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct AutofillPasswordField: View {
    @Binding var password: String
    /// Adds a copy button; the save review leaves it out.
    var copy: (() -> Void)?
    @State private var isRevealed = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case hidden, revealed
    }

    var body: some View {
        LabeledContent("Password") {
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
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
                Button {
                    isRevealed.toggle()
                    focusedField = isRevealed ? .revealed : .hidden
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
                .help(isRevealed ? "Hide password" : "Show password")
                if let copy {
                    CredentialCopyButton(label: "Copy Password", action: copy).disabled(password.isEmpty)
                }
            }
        }
        .onDisappear { isRevealed = false }
    }
}
