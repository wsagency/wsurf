// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// Where a Settings search result or a deep link lands on the Autofill page: a tab, and on the Vault tab a section. Every Autofill
/// entry of `SettingsIndex` resolves to one; the anchor itself is on the row it names, so the row is highlighted there.
enum AutofillDestination: Equatable {
    case vault(CredentialListFilter)
    case inputHistory
    case settings

    init?(anchor: String?) {
        switch anchor {
        case "autofill.credentials":
            self = .vault(.all)
        case "autofill.inputHistory":
            self = .inputHistory
        case "autofill.passwords", "autofill.cards", "autofill.applePay", "autofill.contacts":
            self = .settings
        default:
            return nil
        }
    }
}

/// Settings > Autofill. The page is the vault's (`CredentialSettings`): its Vault and Settings tabs also hold Input History, the
/// autofill switches and the move of the cards and addresses saved on this Mac into the vault.
struct AutofillSettings: View {
    let coordinator: AppCoordinator
    var highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            CredentialSettings(context: coordinator.context, highlight: highlight) { url in
                // The window this page is in: the same profile, so a private window never opens a normal one.
                coordinator.browser.newTab(url: url, activate: true, after: coordinator.browser.activeTab)
            }
        }
        .environment(\.settingsDescriptionLineLimit, 1)
        .id(coordinator.context.contextID)
    }
}

struct AutofillPageStatus: View {
    let isBusy: Bool
    let error: String?
    let kind: AutofillSaveKind

    private var loadingMessage: LocalizedStringResource {
        switch kind {
        case .password:
            "Accessing passwords…"
        case .card:
            "Accessing cards…"
        case .contact:
            "Accessing addresses…"
        }
    }

    var body: some View {
        if isBusy {
            HStack(spacing: 8) {
                Spinner(size: 14)
                Text(loadingMessage).foregroundStyle(.secondary)
            }.padding(.vertical, 12)
        }
        if let error {
            Text(verbatim: error).foregroundStyle(.secondary).font(Theme.Font.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
        }
    }
}
