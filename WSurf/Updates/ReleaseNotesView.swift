// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

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
            ReleaseNotesList(sections: sections, isRunning: notes.isRunning)
                .padding(.horizontal, 12)
                .padding(.top, 14)
        }
    }
}

/// The installed build's section and the older ones below it, newest first, as the Release Notes page lists them.
struct ReleaseNotesList: View {
    let sections: [ChangelogSection]
    let isRunning: (ChangelogSection) -> Bool

    var body: some View {
        // Lazy, and each section equatable: the notes of a release far down the page are not parsed or laid out until it scrolls near.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                ReleaseNotesSection(section: section, isRunning: isRunning(section), isFirst: index == 0)
                    .equatable()
            }
        }
    }
}

private struct ReleaseNotesSection: View, Equatable {
    let section: ChangelogSection
    let isRunning: Bool
    let isFirst: Bool

    /// The hairline above is part of the section, so that the lazy list has one item per release.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                RowSeparator()
                    .padding(.vertical, 20)
            }
            details
        }
    }

    private var details: some View {
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
