// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// A row that restores the save prompts of one kind on the sites where the person chose not to be asked again.
struct AutofillSavePromptReset: View {
    let kind: AutofillSaveKind
    let context: BrowserProfileContext
    @State private var isBusy = false
    @State private var showsError = false

    private var title: LocalizedStringResource {
        switch kind {
        case .password:
            "Password save suggestions"
        case .card:
            "Card save suggestions"
        case .contact:
            "Address save suggestions"
        }
    }

    var body: some View {
        DetailRow(title: title, caption: "Restore prompts on excluded sites.") {
            SettingsButton(title: "Reset") {
                isBusy = true
                Task {
                    do {
                        try await Task.detached { [kind, profileID = context.profile.id] in
                            try AutofillSaveIndex.resetBlocks(kind: kind, profileID: profileID)
                        }.value
                        AutofillSaveCoordinator.shared.resetDismissals(kind: kind, context: context)
                    } catch { showsError = true }
                    isBusy = false
                }
            }
            .disabled(isBusy || context.profile.isPrivate)
        }
        .alert("Couldn’t Reset Save Suggestions", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        }
    }
}
