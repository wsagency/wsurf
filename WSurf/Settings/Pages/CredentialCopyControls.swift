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

/// The model's brief confirmation ("Password Copied", "Moved 3 credentials to Trash."), in the place the user is looking at: the list,
/// or the editor with History beside it. A notice that offers Undo shows the button when `undo` is given, which only the list does.
struct CredentialPageNotice: View {
    let model: CredentialSettingsModel
    var undo: (() -> Void)?

    var body: some View {
        if let notice = model.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SettingsNotice(symbol: "checkmark.circle", text: notice.text, level: .ready)
                if notice.offersUndo, let undo {
                    Button("Undo", action: undo)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }
            .onChange(of: notice, initial: true) { AccessibilityNotification.Announcement(notice.text).post() }
        }
    }
}
