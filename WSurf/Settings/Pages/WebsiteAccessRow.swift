// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// How much of a website the assistant may use when the website has no setting of its own.
struct WebsiteAccessRow: View {
    let permissions: SitePermissions
    let isPrivate: Bool
    /// Where the level paired apps may follow is kept. Changing the default here keeps it in step; nothing else does.
    var trust: MCPTrustStore?

    var body: some View {
        DetailRow(
            title: "Website access",
            caption: isPrivate ? "Private windows always ask." : permissions.assistantDefault.defaultCaption
        ) {
            SettingsMenu(
                options: AssistantAccessPolicy.defaultChoices.map {
                    .init(value: $0, label: String(localized: $0.label))
                },
                selection: Binding(
                    get: { permissions.assistantDefault },
                    set: { policy in
                        permissions.setAssistantDefault(policy)
                        // Best effort: if the keychain write fails, apps keep the level they had.
                        try? trust?.setAppsDefaultLevel(policy)
                    }
                )
            )
            .disabled(isPrivate)
        }
        .settingsAnchor("assistant.defaultAccess")
    }
}
