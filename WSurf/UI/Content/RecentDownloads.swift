// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// What the Downloads button lists when the pointer rests on it: the newest few downloads of this profile.
enum RecentDownloads {
    static let limit = 5

    /// The manager keeps its list newest first, so these are the newest, in the order the Downloads page shows them.
    static func newest(_ items: [DownloadManager.Item]) -> [DownloadManager.Item] {
        Array(items.prefix(limit))
    }
}

extension DownloadManager.Item {
    /// Open needs a finished download whose file is still where it was saved.
    var canOpen: Bool {
        availableFile != nil
    }

    /// Show in Finder needs only the file: a download that stopped halfway can leave one behind.
    var canReveal: Bool {
        existingFile != nil
    }

    /// A finished download whose file was moved or deleted since.
    var isMissing: Bool {
        state == .finished && existingFile == nil
    }

    /// The short line under the name: the size when done, the progress while running, and for a stopped one a few words in
    /// place of the reason, which the row's tooltip carries.
    var shortStatus: String {
        switch state {
        case .failed:
            String(localized: "Failed")
        case .finished where isMissing:
            String(localized: "File moved or deleted")
        default:
            sizeSummary
        }
    }
}

/// What the Downloads button opens over itself while the pointer is on it: the newest downloads, each with Open and Show in
/// Finder. Pressing the button still opens the Downloads page, which is also the way in for VoiceOver and the keyboard.
struct RecentDownloadsList: View {
    let downloads: DownloadManager
    /// Opens the Downloads page.
    let showAll: () -> Void
    let dismiss: () -> Void

    @Environment(\.windowColorScheme) private var windowColorScheme

    var body: some View {
        let recent = RecentDownloads.newest(downloads.items)
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Downloads")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            if recent.isEmpty {
                Text("No recent downloads.")
                    .font(Theme.Font.row)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(recent) { item in
                        RecentDownloadRow(item: item, downloads: downloads, dismiss: dismiss)
                    }
                }
            }

            Divider().opacity(0.5)

            Button {
                dismiss()
                showAll()
            } label: {
                Text("Show All Downloads")
                    .font(Theme.Font.control)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 300)
        .background(.ultraThickMaterial)
        .environment(\.colorScheme, windowColorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recent Downloads"))
    }
}

private struct RecentDownloadRow: View {
    let item: DownloadManager.Item
    let downloads: DownloadManager
    let dismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.listSymbol)
                    .font(.system(size: 14))
                    .foregroundStyle(item.canOpen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.filename)
                        .font(Theme.Font.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(verbatim: item.shortStatus)
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if item.isRunning, let fraction = item.fraction {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            ChromeIcon.rowControl(
                symbol: "arrow.up.forward.app",
                isEnabled: item.canOpen,
                help: String(localized: "Open")
            ) {
                dismiss()
                downloads.open(item)
            }
            .accessibilityLabel(Text("Open"))

            ChromeIcon.rowControl(
                symbol: "folder",
                isEnabled: item.canReveal,
                help: String(localized: "Show in Finder")
            ) {
                dismiss()
                downloads.revealInFinder(item)
            }
            .accessibilityLabel(Text("Show in Finder"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? Theme.Wash.hairline : Color.clear)
        )
        .help(item.stoppedReason ?? "")
        .onHover { hovering = $0 }
    }
}
