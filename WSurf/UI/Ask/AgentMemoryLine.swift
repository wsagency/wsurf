// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

/// Linen's "Remembered …" line under the answer whose words a note was written from. Undo takes back what this turn wrote: a new note
/// is forgotten, a changed one gets its earlier value back. Once nothing it wrote is still kept (undone, edited or forgotten since),
/// the line is crossed out and offers nothing. The notes themselves are seen, edited and forgotten in Settings › Assistant › Memory.
struct AgentMemoryLine: View {
    let updates: [AgentMemoryUpdate]
    let facts: AssistantFacts

    private var kept: [AgentMemoryUpdate] {
        updates.filter { facts.status(of: $0) == .kept }
    }

    private var summary: String {
        guard updates.count == 1, let update = updates.first else {
            return String(localized: "Remembered \(updates.count) things")
        }
        return String(localized: "Remembered \(update.subject): \(update.value)")
    }

    /// Every note on its own line, for the pointer and VoiceOver.
    private var details: String {
        updates.map { "\($0.subject): \($0.value)" }.joined(separator: "\n")
    }

    var body: some View {
        let isCrossedOut = kept.isEmpty
        HStack(spacing: 6) {
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(verbatim: summary)
                .font(Theme.Font.caption)
                .lineLimit(1)
                .strikethrough(isCrossedOut)
                .opacity(isCrossedOut ? 0.5 : 1)
                .help(Text(verbatim: details))
                .accessibilityLabel(Text(verbatim: isCrossedOut ? String(localized: "Undone: \(details)") : summary))
            if !isCrossedOut {
                Button("Undo") {
                    for update in kept {
                        facts.undo(update)
                    }
                }
                .buttonStyle(AgentInlineButtonStyle())
                .accessibilityHint(Text("Takes back what the assistant just remembered"))
            }
        }
        .foregroundStyle(.secondary)
        .animation(Theme.Motion.quick, value: isCrossedOut)
    }
}
