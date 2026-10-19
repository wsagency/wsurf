// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A small button beside a value that copies it. What it copies, and under which unlock, is the model's business (`copy(_:of:)`).
struct CredentialCopyButton: View {
    let label: LocalizedStringKey
    var extent: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .frame(width: extent, height: extent)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The model's brief "Copied" confirmation, in the place the user is looking at: the list, or the editor with History beside it.
struct CredentialCopyNotice: View {
    let model: CredentialSettingsModel

    var body: some View {
        if let text = model.copyNotice {
            SettingsNotice(symbol: "checkmark.circle", text: text, level: .ready)
        }
    }
}
