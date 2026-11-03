// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

struct AutofillSavePromptReset: View {
    let kind: AutofillSaveKind
    let context: BrowserProfileContext
    @State private var isBusy = false
    @State private var showsError = false

    var body: some View {
        SettingsCard {
            DetailRow(title: "Save suggestions", caption: "Restore prompts on excluded sites.") {
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
        }
        .alert("Couldn’t Reset Save Suggestions", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        }
    }
}
