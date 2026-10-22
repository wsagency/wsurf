// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension CredentialSettings {
    /// Pages stop offering to save a password on a site the user chose "Never for This Site" for. The list is the open vault's own,
    /// so this card is there only while the vault is unlocked.
    var saveSuggestionsCard: some View {
        SettingsCard {
            DetailRow(title: "Save suggestions", caption: saveSuggestionsCaption) {
                SettingsButton(title: "Reset") { run { await model.resetSaveSuggestions() } }
                    .disabled(model.isBusy || model.blockedSiteCount == 0)
            }
        }
    }

    private var saveSuggestionsCaption: LocalizedStringResource {
        switch model.blockedSiteCount {
        case 0:
            "No sites are excluded."
        case 1:
            "Restore prompts on 1 excluded site."
        case let count:
            "Restore prompts on \(count) excluded sites."
        }
    }
}
