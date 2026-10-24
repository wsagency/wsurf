// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

/// The installed build's notes and the older ones below, from the `CHANGELOG.md` inside the app. Nothing is fetched.
struct ReleaseNotesView: View {
    let browser: BrowserModel
    let notes: ReleaseNotesModel

    var body: some View {
        let sections = notes.sections
        DestinationPage {
            toolbar(count: sections.count)
        } content: {
            content(sections)
        }
    }

    private func toolbar(count: Int) -> some View {
        HStack(spacing: 10) {
            DestinationTitle(title: "Release Notes") {
                browser.dismissInternalPage(.releaseNotes)
            }

            if count > 0 {
                DestinationCount(count: count)
            }

            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private func content(_ sections: [ChangelogSection]) -> some View {
        if sections.isEmpty {
            // The changelog ships inside the app, so this is a build that lost it.
            Text("No notes are published yet.")
                .font(Theme.Font.row)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 28)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        RowSeparator()
                            .padding(.vertical, 20)
                    }
                    ReleaseNotesSection(section: section, isRunning: notes.isRunning(section))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
        }
    }
}

private struct ReleaseNotesSection: View {
    let section: ChangelogSection
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(verbatim: section.title)
                        .font(.system(size: 15, weight: .semibold))

                    if isRunning {
                        Text(verbatim: String(
                            localized: "releaseNotes.installedBadge",
                            defaultValue: "Installed",
                            comment: """
                                Badge beside the version you are running, in the list of every \
                                release on the Release Notes page. Shares its English text with \
                                the Chrome Web Store marker of the same name, which is why it \
                                carries a key of its own.
                                """
                        ))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                }

                if let date = section.date {
                    // The heading names a day, not a moment: read and shown in UTC so it cannot move to another day.
                    Text(verbatim: date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
                        .font(Theme.Font.label)
                        .foregroundStyle(.tertiary)
                }
            }

            if section.body.isEmpty {
                Text("No notes for this release.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.tertiary)
            } else {
                ChatMarkdown(text: section.body, fontSize: 12, spacing: 8, joinsWrappedLines: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
