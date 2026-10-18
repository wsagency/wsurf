// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct CommandPaletteSettings: View {
    let settings: BrowserSettings

    var body: some View {
        let order = settings.commandPaletteOrder

        SettingsSection(
            title: "Command palette",
            symbol: "command",
            footnote: """
            Return runs the first result. An address you type keeps “Search or ask” first, and a command that \
            matches strongly appears right under the first section.
            """
        ) {
            DetailRow(
                title: "Section order",
                caption: "Choose where each group of command palette results appears. The best matches stay first within a group."
            ) {
                SettingsButton(title: "Reset to Default") {
                    settings.resetCommandPaletteOrder()
                }
                .disabled(order == CommandPaletteSection.allCases)
            }
            .settingsAnchor("general.paletteOrder")

            ForEach(Array(order.enumerated()), id: \.element) { position, section in
                RowSeparator()

                CommandPaletteOrderRow(section: section, position: position, count: order.count) { offset in
                    settings.moveCommandPaletteSection(section, by: offset)
                    announce(section)
                }
            }
        }
    }

    /// The buttons move a row away from the one VoiceOver is reading, so say where it went.
    private func announce(_ section: CommandPaletteSection) {
        let order = settings.commandPaletteOrder
        guard let index = order.firstIndex(of: section) else { return }
        let message = String(
            localized: "\(String(localized: section.title)), position \(index + 1) of \(order.count)"
        )
        AccessibilityNotification.Announcement(message).post()
    }
}

private struct CommandPaletteOrderRow: View {
    let section: CommandPaletteSection
    let position: Int
    let count: Int
    let move: (Int) -> Void

    var body: some View {
        let name = String(localized: section.title)

        DetailRow(title: section.title, caption: section.summary, controlWidth: nil) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.up", help: "Move Up") {
                    move(-1)
                }
                .disabled(position == 0)
                .accessibilityLabel(Text("Move \(name) Up"))

                IconButton(symbol: "chevron.down", help: "Move Down") {
                    move(1)
                }
                .disabled(position == count - 1)
                .accessibilityLabel(Text("Move \(name) Down"))
            }
        }
    }
}
