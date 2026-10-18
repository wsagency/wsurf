// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Whether the assistant may close an ordinary tab without asking. Shown only under the Allow Control default: with any other
/// default it asks first, and the row would offer a choice that changes nothing.
struct TabClosingRow: View {
    let permissions: SitePermissions

    static func appears(defaultAccess: AssistantAccessPolicy, isPrivate: Bool) -> Bool {
        defaultAccess == .control && !isPrivate
    }

    var body: some View {
        DetailRow(title: "Closing tabs", caption: AssistantTabClosing.caption) {
            SettingsMenu(
                options: AssistantTabClosing.allCases.map { .init(value: $0, label: String(localized: $0.label)) },
                selection: Binding(
                    get: { permissions.assistantTabClosing },
                    set: { permissions.setAssistantTabClosing($0) }
                )
            )
        }
        .settingsAnchor("assistant.tabClosing")
    }
}
