// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension CredentialSettings {
    var statisticsSection: some View {
        CredentialStatisticsSection(model: model)
    }
}

/// How many of each kind the open vault holds. Counts only, from the summaries the page already has and the vault's verified Trash
/// and earlier-version counts; no secret is read.
struct CredentialStatisticsSection: View {
    let model: CredentialSettingsModel
    @State private var statistics: CredentialStatistics?

    private struct Key: Equatable {
        let vault: UUID?
        let epoch: UInt64?
        let revision: UInt64
    }

    private struct Line: Identifiable {
        let title: LocalizedStringResource
        let value: Int?
        var caption: LocalizedStringResource?

        var id: String {
            String(localized: title)
        }
    }

    /// Said only when it adds something: one passkey per credential needs no explanation.
    private var passkeyCaption: LocalizedStringResource? {
        guard let statistics, statistics.passkeys != statistics.credentialsWithPasskeys else { return nil }
        switch statistics.credentialsWithPasskeys {
        case 1:
            return "On 1 credential"
        case let count:
            return "On \(count) credentials"
        }
    }

    private var lines: [Line] {
        [
            Line(title: "Credentials", value: statistics?.credentials),
            Line(title: "Logins", value: statistics?.logins),
            Line(title: "Passkeys", value: statistics?.passkeys, caption: passkeyCaption),
            Line(title: "Verification codes", value: statistics?.codes),
            Line(title: "Notes", value: statistics?.notes),
            Line(title: "Cards and other items", value: statistics?.items),
            Line(title: "Without a website", value: statistics?.withoutWebsite),
            Line(title: "In Trash", value: model.trashTotal),
            Line(title: "Earlier versions", value: model.earlierVersionCount),
        ]
    }

    var body: some View {
        SettingsSection(
            title: "Statistics",
            symbol: "chart.bar",
            footnote: "A credential that holds several kinds counts under each. Passkeys counts every passkey."
        ) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                row(line)
                if index < lines.count - 1 {
                    RowSeparator()
                }
            }
        }
        .task(id: Key(vault: model.selectedVaultID, epoch: model.authorizationEpoch, revision: model.revision)) {
            statistics = CredentialStatistics(model.summaries)
            // A read that fails leaves the two vault counts as dashes; the rest came from the page.
            try? await model.loadStatistics()
        }
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(Theme.Font.rowTitle)
                if let caption = line.caption {
                    Text(caption).font(Theme.Font.label).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: line.value.map { $0.formatted() } ?? "—")
                .font(Theme.Font.row)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
