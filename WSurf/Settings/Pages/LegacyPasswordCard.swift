// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// On the Autofill page while the passwords saved before Credential Manager have not been moved. The page reads `state` with
/// `LegacyPasswordMigration.state()`, which asks the Keychain whether the old list exists and nothing more: no password is read
/// and the system never prompts.
struct LegacyPasswordCard: View {
    let state: LegacyPasswordMigration.State?
    let open: () -> Void

    var body: some View {
        if let state, state != .done {
            SettingsCard {
                DetailRow(title: "Passwords saved before Credential Manager", caption: caption(state)) {
                    Button("Open Credential Manager", action: open).buttonStyle(.bordered)
                }
            }
        }
    }

    private func caption(_ state: LegacyPasswordMigration.State) -> LocalizedStringResource {
        state == .imported
            ? "Your passwords are imported. Remove the old list in Credential Manager when you’re ready."
            : "Import the passwords saved before Credential Manager. WSurf doesn’t fill them until you do."
    }
}
