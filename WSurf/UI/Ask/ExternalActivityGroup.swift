// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What one external app did on a tab, under the assistant's own tasks in Agent Activity.
struct ExternalActivityGroup: View {
    let log: ExternalActivityLog
    let tabID: UUID

    /// The log keeps 1,000 entries; the panel draws the newest ones so a long session stays cheap to scroll.
    static let visibleLimit = 50

    var body: some View {
        let entries = log.entries(forTab: tabID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                Text("External: \(log.client)")
                    .font(Theme.Font.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

            if entries.count > Self.visibleLimit {
                Text("Showing the latest \(Self.visibleLimit) of \(entries.count)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(entries.suffix(Self.visibleLimit)) { entry in
                ExternalActivityRow(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExternalActivityRow: View {
    let entry: ExternalActivityLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: entry.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text(verbatim: Self.summary(of: entry))
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            switch entry.outcome {
            case .succeeded:
                EmptyView()
            case .failed:
                Text("Failed")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
            case .stopped where entry.event != .stopped:
                Text("Stopped")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            case .stopped:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The tool, then what it acted on. The tab is the panel's own, so its title is not repeated.
    static func summary(of entry: ExternalActivityLog.Entry) -> String {
        var parts: [String] = []
        switch entry.event {
        case .tool(let name):
            parts.append(MCPBrowserSession.actionTitle(forTool: name) ?? name)
        case .stopped:
            parts.append(String(localized: "You stopped this connection"))
        }
        if let target = entry.target {
            parts.append(target)
        }
        if let detail = entry.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }
}
