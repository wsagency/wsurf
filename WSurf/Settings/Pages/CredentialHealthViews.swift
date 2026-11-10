// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfVault

/// "Weak" and "Reused" on a credential's row, from the vault's password health report (S4). Nothing while there is nothing to flag
/// or no report yet.
struct CredentialHealthBadges: View {
    let health: PasswordHealthFinding?

    var body: some View {
        if let health {
            HStack(spacing: 4) {
                if !health.weaknesses.isEmpty {
                    badge("Weak").accessibilityLabel("Weak password")
                }
                if health.reuse != nil {
                    badge("Reused").accessibilityLabel("Password also saved for another website")
                }
            }
        }
    }

    private func badge(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.Font.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

/// Under the editor's sign-in: why the saved password is flagged, from the same report as the row's badges. It speaks of the password
/// as saved: what the editor holds unsaved is not checked.
struct CredentialHealthNote: View {
    let model: CredentialSettingsModel

    var body: some View {
        if let id = model.draft?.accountID, let summary = model.summaries.first(where: { $0.id == id }), let health = summary.health {
            VStack(alignment: .leading, spacing: 4) {
                if !health.weaknesses.isEmpty {
                    Label {
                        Text(verbatim: Self.weakness(health.weaknesses))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                if let reuse = health.reuse {
                    Label {
                        Text(verbatim: Self.reuse(reuse, sharedWith: model.sharingPassword(with: summary).map(\.title)))
                    } icon: {
                        Image(systemName: "key.horizontal")
                    }
                }
            }
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One sentence for the weak rules the saved password breaks.
    static func weakness(_ weaknesses: Set<PasswordWeakness>) -> String {
        let reasons = PasswordWeakness.allCases.filter(weaknesses.contains).map { weakness in
            switch weakness {
            case .short:
                String(localized: "it is shorter than 8 characters")
            case .oneKind:
                String(localized: "it is only digits, or letters of one case")
            case .pattern:
                String(localized: "most of it is a pattern, such as 123456 or qwerty")
            case .personal:
                String(localized: "it contains the username or the website’s name")
            }
        }
        return String(localized: "The saved password is weak: \(reasons.formatted(.list(type: .and))).")
    }

    /// How many other websites save the same password, and the credentials that do (three by name).
    static func reuse(_ reuse: PasswordReuse, sharedWith titles: [String]) -> String {
        let count = reuse.otherSites == 1
            ? String(localized: "The same password is saved for one other website.")
            : String(localized: "The same password is saved for \(reuse.otherSites) other websites.")
        guard !titles.isEmpty else { return count }
        let shown = titles.count > 3 ? Array(titles.prefix(3)) + [String(localized: "\(titles.count - 3) more")] : titles
        let named = String(localized: "Also saved in \(shown.formatted(.list(type: .and))).")
        return "\(count) \(named)"
    }
}
